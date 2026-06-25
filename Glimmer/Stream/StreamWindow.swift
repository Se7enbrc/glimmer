//
//  StreamWindow.swift
//
//  Fullscreen NSWindow hosting the AVSampleBufferDisplayLayer that
//  VideoDecoder enqueues decoded sample buffers into. Owned by StreamSession.
//  Captures the cursor while frontmost, releases it when the user invokes
//  the quit hotkey.
//
//  Why AVSampleBufferDisplayLayer and not CAMetalLayer
//  ---------------------------------------------------
//  We tried - three times - to get correct HDR out of a CAMetalLayer driven
//  by a custom MSL fragment shader doing BT.2020 NCL YUV→RGB + range
//  scaling. On the a 4K@240 HDR1000 panel, every variant landed somewhere
//  on the same wrong axis: overbright midtones, washed highlights, milky
//  blacks. moonlight-qt on the same display, host, and content shows inky
//  blacks and proper bright highlights.
//
//  The reason: on macOS, moonlight-qt's HDR-correct path is not
//  `vt_metal.mm` (its Metal-shader fallback). The default macOS path is
//  `vt_avsamplelayer.mm`, which sidesteps Metal entirely. It hands the OS a
//  CVPixelBuffer wrapped in a CMSampleBuffer and lets AVFoundation +
//  CoreAnimation do colorspace conversion, PQ EOTF application, and EDR
//  tone-mapping against the display's actual peak luminance. There is no
//  shader. There is no manual CSC. The OS owns the pipeline end-to-end.
//
//  When you write PQ-encoded BT.2020 codes into a CAMetalLayer with a
//  custom shader, even with all the right metadata (itur_2100_PQ
//  colorspace, EDRMetadata, wantsExtendedDynamicRangeContent), the
//  compositor still has to reverse-engineer what the shader did. The
//  AVSampleBufferDisplayLayer path skips that round trip: the
//  CVPixelBuffer carries primaries / transfer / matrix attachments,
//  the CMFormatDescription carries mastering-display + content-light
//  metadata, and the layer's colorspace tells the compositor exactly
//  how to interpret the bits. No guesswork, no shader-vs-OS fight.
//
//  This is the same architectural choice moonlight-qt made on macOS and
//  the reason their HDR output is correct on the same panel.
//
//  Why we don't use `NSWindow.toggleFullScreen(_:)`:
//
//    `toggleFullScreen` puts the window in macOS's *Space-based* fullscreen
//    mode. That mode is owned by the OS, which means:
//      • Cursor-to-top reveals the menu bar.
//      • Esc / ⌘Esc can yank the user out of the stream.
//      • Cmd-Tab into the app surfaces the menu bar and Dock.
//    None of that is acceptable for a game-streaming client where Esc is a
//    game input and the user genuinely wants the host to own the screen.
//
//  What we do instead - same approach SDL's `SDL_WINDOW_FULLSCREEN_DESKTOP`
//  takes on macOS, which moonlight-qt selects on this platform:
//
//    • Borderless window sized to the target NSScreen's full frame.
//    • Window level kept at `.normal` (same as SDL FULLSCREEN_DESKTOP).
//      `CGShieldingWindowLevel()` looks attractive - chrome can't paint
//      above it - but it's the screen-lock / screensaver level, and
//      AppKit lets a window become first responder at that level while
//      silently dropping `sendEvent:` key delivery, so hotkeys (quit,
//      stats) stop firing in-stream. The
//      `presentationOptions = [.autoHideMenuBar, .autoHideDock]` gate is
//      what hides the chrome, NOT the window level.
//    • `collectionBehavior` includes `.canJoinAllSpaces` so the window stays
//      visible across Space switches, and explicitly does NOT include
//      `.fullScreenPrimary` (we're not using Space-based fullscreen).
//    • `NSApplication.presentationOptions` is set to auto-hide the menu bar
//      and Dock while the stream is up, then restored on close.

import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import os.log

@MainActor
public final class StreamWindow {
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Window")

    public let window: NSWindow
    /// The OS-driven display layer. VideoDecoder enqueues CMSampleBuffers
    /// onto this; CoreAnimation handles colorspace conversion, PQ EOTF, and
    /// EDR tone-mapping with zero shader involvement on our side.
    ///
    /// `var`, not `let`: the AVSampleBufferVideoRenderer can latch
    /// `.status == .failed` (the 4K240 HDR hard-freeze) and a bare
    /// `flush()` does not always clear it - a hard-failed renderer needs a fresh
    /// layer. `rebuildDisplayLayer()` swaps in a new one so the present-path
    /// self-heal can recover a wedge that flush alone can't. Mutated on the main
    /// actor only.
    public private(set) var displayLayer: AVSampleBufferDisplayLayer
    /// In-stream stats overlay (toggled with the user's stats hotkey). Lives
    /// as a *sublayer* of `displayLayer` so it composites above the video
    /// without breaking the AVSampleBufferDisplayLayer-as-root-layer
    /// requirement that keeps the EDR signal direct from the video layer to
    /// the window surface. Created hidden; `StreamSession`'s overlay timer
    /// drives visibility and content updates.
    public let statsOverlay: StatsOverlayLayer
    /// Top-center "Reconnecting..." banner shown over the frozen frame during a
    /// silent reconnect episode or a watchdog video-hold (the launcher's phase
    /// chip is occluded by this fullscreen window).
    public let reconnectBanner: StreamBannerLayer
    /// Bottom-center "Network unstable" pill, auto-shown when the link enters
    /// caution/distress - independent of the full stats HUD toggle.
    public let networkBanner: StreamBannerLayer
    /// Bottom-center one-time "press <chord> to leave" toast shown on the first
    /// stream so the quit chord is discoverable (Esc is a game input).
    public let leaveHintBanner: StreamBannerLayer
    let displayView: DisplayContainerView
    /// The NSView hosting the AVSampleBufferDisplayLayer. Exposed so the
    /// session can bind the FramePacer's CADisplayLink to this view's screen
    /// (`NSView.displayLink(target:selector:)`, macOS 14+) - the link must be
    /// driven off the display the stream window actually lives on, and the
    /// view tracks that display as the window moves between screens.
    public var streamContentView: NSView { displayView }
    /// SINGLE SOURCE OF TRUTH for cursor visibility. The only authority on
    /// whether Glimmer has hidden the system cursor. Every hide/show goes
    /// through `setCursorHidden(_:)`, which drives `CGDisplayHideCursor` /
    /// `CGDisplayShowCursor` idempotently off this flag so the (counted)
    /// display-hide latch is never pushed above 1 and never left negative.
    /// InputForwarder must NEVER touch cursor visibility - it only owns
    /// relative-aim engagement (`isMouseCaptured`).
    var didHideCursor = false

    /// Observers that track stream-window key status. We hide the cursor only
    /// while the stream window is key; on Cmd-Tab-away the window resigns key
    /// status and we restore the cursor globally so the user can interact
    /// with whatever they Cmd-Tabbed to. Without these, the display-hide latch
    /// would leave the cursor invisible across the entire Mac while Glimmer is
    /// foregrounded but the stream window isn't key.
    var keyObservers: [NSObjectProtocol] = []
    /// Observers registered on `NSWorkspace.shared.notificationCenter` (a
    /// DIFFERENT center than `NotificationCenter.default`). Tracked separately
    /// so `close()` removes them from the correct center - removing a workspace
    /// observer from the default center is a silent no-op and leaks it. Used
    /// for the display-wake observer that rebinds the pacer's CADisplayLink.
    var workspaceObservers: [NSObjectProtocol] = []
    /// Path B's ONE-SHOT `didEnterFullScreenNotification` token (safe-area /
    /// Space-based fullscreen only; nil on the borderless covering path). The
    /// happy path consumes it inside its own closure the moment AppKit posts
    /// the enter notification - but a session that tears down first (a
    /// connect-fail inside the ~1s Space-enter animation, or the dropped-
    /// notification quirk show()'s 1.5s backstop exists for) never fires it.
    /// Stored here, not in a closure-local box, so `close()` can sweep it:
    /// block-based observers are retained by NotificationCenter until
    /// explicitly removed, so an unswept token leaked the observation per
    /// aborted Path-B session.
    var enterFullScreenObserver: NSObjectProtocol?
    var didClose = false

    /// `NSApplication.presentationOptions` we observed at `show()` time, so we
    /// can restore exactly that on `close()` rather than guessing at a sane
    /// default. If the app embeds Glimmer inside a larger surface later (e.g.
    /// the menu-bar agent path), preserving the host's options is the only
    /// safe thing to do.
    var previousPresentationOptions: NSApplication.PresentationOptions?

    /// Whether to extend the fullscreen window into the notch zone on
    /// notched MacBook displays. When `true`, we override AppKit's
    /// `window(_:willUseFullScreenContentSize:)` delegate to claim the
    /// full physical panel (screen.frame plus the safeAreaInsets.top
    /// notch reserve), so a bitstream at the panel's true native
    /// resolution renders 1:1 without letterboxing. When `false`, AppKit's
    /// default safe-area-trimmed framing is used and a host bitstream
    /// taller than the trimmed framebuffer letterboxes left/right - the
    /// classic "panel-native stream content in safe-area fullscreen
    /// window" symptom. moonlight-qt exposes the same choice as a
    /// per-host preference.
    public var coversNotch: Bool = true

    /// Called whenever the window's "is it currently visible or sitting
    /// orderOut'd in the background?" state flips. The session owner wires
    /// this to MoonlightManager so the launcher can show a "Back to stream"
    /// affordance while the stream window is hidden.
    public var onBackgroundedChanged: (@MainActor (Bool) -> Void)?

    /// Called when the stream window moves to a different display (or its
    /// backing display's properties change - refresh rate, wake from sleep).
    /// The session owner wires this to `VideoDecoder.pacingScreenDidChange()`
    /// so the FramePacer rebinds its CADisplayLink to the new screen's true
    /// vsync cadence; presenting on a stale link after a 60↔120Hz display swap
    /// would pace to the wrong refresh.
    public var onScreenChanged: (@MainActor () -> Void)?

    /// Set by `show()` and cleared by the first-frame fade-in. Guards
    /// the fade-in animation against being re-fired on subsequent first-
    /// frame events (e.g. a mid-stream resolution change that flushes the
    /// decoder and produces a new "first" frame - the window is already
    /// visible, no fade needed).
    var awaitingFirstFrameFadeIn = false

    /// The window level `show()` parked the streaming window at (in the
    /// `coversNotch == true` borderless-covering path, `mainMenuWindow + 1`).
    /// Snapshotted so the foreground re-engage can restore it after a resign
    /// dropped us to `.normal`. `nil` until `show()` runs. In the Space-based
    /// `coversNotch == false` path AppKit owns the level, so the re-engage
    /// only touches the level when `coversNotch` is true (matching the
    /// becomeKey observer's gate).
    var streamingWindowLevel: NSWindow.Level?

    /// Monotonically-incrementing token used to debounce sub-second key blips
    /// on the borderless stream window. A transient app activation - most
    /// notably a DualSense/HID controller connecting over Bluetooth mid-stream
    /// - makes the WindowServer briefly flutter key status away from our
    /// borderless window and post `didResignKeyNotification`, then snap key
    /// back within a frame (`didBecomeKeyNotification`). The naive
    /// resign-handler `orderOut`'d the stream window synchronously, which
    /// uncovered the still-alive (merely dimmed) launcher window for one frame
    /// - a blank/dark flash over the stream on every mid-stream controller
    /// connect. The resign handler now defers its teardown and bails if this
    /// token changed (a becomeKey landed) or the app never actually
    /// deactivated. Bumped by BOTH observers so the later event always wins.
    var resignGeneration = 0

    /// Called once the window is on screen and key. InputForwarder uses this
    /// to install its StreamInputView as the window's first responder.
    ///
    /// Why this hook exists: a borderless KeyableWindow can be on screen,
    /// orderedFront, and *still* not be key if the app wasn't active at the
    /// moment makeKeyAndOrderFront ran. We delay first-responder install
    /// until after we've confirmed key status; without this delay the
    /// responder chain silently routes nowhere and `keyDown` never reaches
    /// our content view.
    ///
    /// (Historical note: we used to drive this off `didEnterFullScreenNotification`
    /// because `toggleFullScreen` was async and reset the responder chain
    /// as part of its Space transition. We no longer go through Space-based
    /// fullscreen, so there's no async transition and no responder reset -
    /// we fire this synchronously once the window is up.)
    public var onDidBecomeReadyForInput: (@MainActor () -> Void)?

    public init() {
        // Pick the screen the user is *currently* on at construction time.
        // StreamSession constructs us right when the user clicks "Stream",
        // so NSScreen.main reflects the display the launcher window was on
        // - i.e. the display the user is actually looking at. If they later
        // drag a multi-monitor setup around mid-stream, we deliberately do
        // not follow; the stream picks the screen once and stays there for
        // the duration of the session.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // A Mac with zero attached displays cannot host a stream window;
            // there is no frame to size to and no NSScreen to bind the window's
            // backing display. This mirrors the prior force-unwrap's crash-on-nil
            // contract (init must hand back a fully-formed window), but spells out
            // why rather than trapping with a bare `!`.
            preconditionFailure("StreamWindow.init: no attached display to host the stream window")
        }
        let style: NSWindow.StyleMask = [.borderless]
        // Borderless NSWindows return canBecomeKeyWindow = false by default,
        // which means makeKeyAndOrderFront silently fails to make us key and
        // the responder chain never delivers keyDown to our content view.
        // KeyableWindow overrides both canBecomeKeyWindow + canBecomeMainWindow
        // to return true so input routes correctly.
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: style,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false

        // Window level: keep at `.normal` (the AppKit default). This is the
        // same level SDL uses for SDL_WINDOW_FULLSCREEN_DESKTOP and what
        // moonlight-qt rides on for its borderless cover on macOS.
        //
        // We *tried* `NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))`
        // - the level the system uses for the screen-lock window. It is
        // indeed above all chrome. But it has a fatal flaw for an interactive
        // app: AppKit will mark a window at that level as `isKeyWindow = true`
        // and `firstResponder` will point at our StreamInputView, yet
        // `sendEvent:` silently drops keyDown/keyUp delivery. The window
        // becomes a one-way visual surface - mouse hover works (it's
        // position-based), but the user's quit / stats hotkeys never fire.
        //
        // The right gate for hiding the menu bar + Dock is
        // `NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]`
        // below, NOT the window level. AppKit will not surface the menu bar
        // over our content while those options are set, even at `.normal`.
        // If a future macOS release decides to paint chrome over us anyway,
        // bump to `.mainMenu` (one above the menu bar's level, still inside
        // AppKit's event-routable range) - never to shielding level.
        window.level = .normal

        // Collection behavior:
        //   .fullScreenPrimary - declare we're a primary fullscreen window so
        //                        `toggleFullScreen:` puts us into a Space-
        //                        based fullscreen. This is REQUIRED for
        //                        macOS to engage display HDR mode on the
        //                        connected panel: the OS only bumps
        //                        NSScreen.maximumExtendedDynamicRangeColor-
        //                        ComponentValue above 1.0 for windows that
        //                        own a dedicated Space. A borderless cover
        //                        at .normal level + .fullScreenAuxiliary
        //                        gets treated as a regular window and the
        //                        compositor tone-maps PQ → SDR (= dark,
        //                        washed-out, no panel HDR engagement).
        //                        moonlight-qt uses SDL_WINDOW_FULLSCREEN_-
        //                        DESKTOP which on macOS is exactly this:
        //                        toggleFullScreen + Space.
        //   .stationary        - don't get tossed into a different Space
        //                        when Mission Control reflows windows.
        window.collectionBehavior = [.fullScreenPrimary, .stationary]
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false

        // SECURITY: refuse to be screen-captured. Prevents
        // ScreenCaptureKit, the screencapture(1) tool, Cmd-Shift-5, Zoom /
        // Teams / Discord screen-share, and the Quick-Time screen recording
        // path from pulling the stream surface. Apps capturing the screen
        // see a black region where the stream is drawn. Same posture as
        // Apple TV+ and Netflix's macOS playback windows. If a user wants
        // to record their stream they can use the host PC's own recording
        // tools, where the underlying stream is unencrypted bytes the host
        // owns - Glimmer is not the right place to expose that.
        window.sharingType = .none

        let view = DisplayContainerView(frame: screen.frame)

        // ---- AVSampleBufferDisplayLayer setup (parallels moonlight-qt's
        // vt_avsamplelayer.mm - `m_StreamView.layer = m_DisplayLayer;
        // m_StreamView.wantsLayer = YES;`).
        //
        // CRITICAL for HDR: we make the AVSampleBufferDisplayLayer the
        // view's ROOT layer (set BEFORE wantsLayer = true), not a sublayer
        // of a default backing layer. When a display layer is a sublayer of
        // a regular sRGB CALayer, the OS's compositor flattens the EDR
        // signal at the parent layer boundary, dropping HDR back to SDR
        // before it reaches the panel. The "root layer" form keeps the EDR
        // path direct from the layer to the window surface.
        //
        // moonlight-qt sets `videoGravity = AVLayerVideoGravityResizeAspect`
        // - letterboxes rather than crops to fill. Matches what we want for
        // streaming a 16:9 host onto a 16:9 panel (the common case) while
        // gracefully handling odd aspect ratios on multi-monitor setups.
        // It also marks the layer opaque so the compositor can skip blending
        // it against whatever's underneath.
        let layer = StreamWindow.makeDisplayLayer(frame: view.bounds)
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view

        // Stats overlay - sublayer of the display layer, positioned in the
        // top-left with a fixed inset. We attach it as a sublayer rather than
        // a sibling because AVSampleBufferDisplayLayer is the view's root
        // layer (a precondition for HDR-correct compositing - see the long
        // comment near `view.layer = layer` above). CALayer's sublayer
        // contract lets us stack arbitrary content on top, and the OS
        // composites the overlay's sRGB text against the layer's HDR
        // contents correctly.
        //
        // Created hidden - StreamSession's overlay timer toggles
        // `isHidden` from `VideoDecoder.statsOverlayEnabled` and pushes
        // text updates at 4 Hz (the FPS rows stay on a ~1s average; the
        // latency rows refresh live each tick).
        let overlay = StatsOverlayLayer()
        overlay.attach(to: layer)
        overlay.setVisible(false)

        // Transient signal pills (sibling sublayers of the display layer, above
        // the stats panel). Created hidden; the session drives them on edges.
        let reconnect = StreamBannerLayer(
            anchor: .topCenter, accent: NSColor.systemOrange.cgColor)
        reconnect.attach(to: layer)
        let network = StreamBannerLayer(
            anchor: .bottomCenter, accent: NSColor.systemYellow.cgColor)
        network.attach(to: layer)
        let leaveHint = StreamBannerLayer(
            anchor: .bottomCenter, accent: NSColor.white.cgColor)
        leaveHint.attach(to: layer)

        // Install the delegate that overrides fullscreen content size so
        // the window covers the panel's notch reserve zone on notched
        // MacBooks. The delegate is created up-front so its `coversNotch`
        // flag stays in sync with `self.coversNotch` via show() time.
        let delegate = StreamWindowDelegate()
        window.delegate = delegate

        self.window = window
        self.displayLayer = layer
        self.statsOverlay = overlay
        self.reconnectBanner = reconnect
        self.networkBanner = network
        self.leaveHintBanner = leaveHint
        self.displayView = view
        self.streamDelegate = delegate
    }

    /// Strong ref so the window delegate isn't deallocated mid-stream
    /// (NSWindow.delegate is `weak`).
    let streamDelegate: StreamWindowDelegate

    /// Build a fresh AVSampleBufferDisplayLayer configured exactly as the
    /// HDR-correct root-layer path requires (see the long comment at the top of
    /// this file). Factored out so `init` and `rebuildDisplayLayer()` produce
    /// byte-for-byte identical layers - the rebuild must not subtly differ from
    /// the original or HDR engagement could regress after a recovery.
    private static func makeDisplayLayer(frame: CGRect) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = frame
        layer.videoGravity = .resizeAspect
        layer.isOpaque = true
        return layer
    }

    /// Rebuild the display layer from scratch and swap it in as the view's root
    /// layer. The last-resort present-path self-heal: the
    /// AVSampleBufferVideoRenderer can latch `.status == .failed` (a 4K240 HDR panel
    /// 4K240 HDR hard-freeze) and stay failed after a bare `flush()` - a
    /// hard-failed renderer only clears with a fresh layer. We create a new
    /// AVSampleBufferDisplayLayer, re-attach the stats overlay sublayer, swap it
    /// in as the view's ROOT layer (preserving the EDR-direct compositing
    /// contract), and return it so the caller can re-point the decoder at it.
    ///
    /// Runs on the main actor (the only place that touches AppKit layers). The
    /// decoder snapshots `displayLayer` into a local before each enqueue, so a
    /// concurrent present on the pacer/decode queue keeps operating on the OLD
    /// layer until it picks up the new reference - race-safe by construction.
    @discardableResult
    public func rebuildDisplayLayer() -> AVSampleBufferDisplayLayer {
        let view = displayView
        let fresh = StreamWindow.makeDisplayLayer(frame: view.bounds)
        // Re-attach the stats overlay + signal pills as sublayers of the NEW
        // root layer before the swap, so they keep compositing above the video.
        // attach() re-parents (addSublayer removes from any prior superlayer).
        statsOverlay.attach(to: fresh)
        reconnectBanner.attach(to: fresh)
        networkBanner.attach(to: fresh)
        leaveHintBanner.attach(to: fresh)
        // Swap as the view's root layer - same construction as init so the
        // EDR-direct path is preserved (root layer, not a sublayer of a backing
        // layer). wantsLayer stays true.
        view.layer = fresh
        view.wantsLayer = true
        self.displayLayer = fresh
        log.notice("Rebuilt AVSampleBufferDisplayLayer (present-path self-heal)")
        return fresh
    }

    /// Animate the window from invisible (alphaValue 0) to fully visible
    /// over 350ms using the same ease-in-out timing macOS uses for app
    /// activation. Called by the session owner when VideoDecoder produces
    /// its first decoded frame. Idempotent - only runs once per show()
    /// (guarded by `awaitingFirstFrameFadeIn`), so mid-stream re-fires of
    /// the first-frame event (resolution change, decoder flush) don't
    /// re-animate an already-visible window.
    public func fadeInOnFirstFrame() {
        guard awaitingFirstFrameFadeIn else { return }
        awaitingFirstFrameFadeIn = false
        // The window is at level `mainMenuWindow + 1` (notch path) or in a
        // fullscreen Space (safe-area path), so as alphaValue ramps 0 → 1
        // it visually covers the menu bar (level 24) and the Dock (level
        // ~20). We DEFER hiding them via `NSApp.presentationOptions` until
        // AFTER the fade completes: setting those flags is instant in the
        // compositor, so doing it at fade-start leaves a one-vsync window
        // where the bars are gone but the window is still at ~0 alpha -
        // that's the "bare-desktop flash" the user was seeing. Post-fade
        // the flags become a no-op user-side because the now-opaque
        // window is already covering everything they hide.
        let win = window
        let cover = coversNotch
        // Under Reduce Motion, snap to visible instead of the 350ms fade -
        // the fade is exactly the kind of large-surface opacity ramp the
        // setting exists to suppress. We still defer presentationOptions to
        // after alpha is set so the menu bar / Dock never visibly vanish
        // against a transparent window (the "bare-desktop flash").
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 1.0
            applyPresentationOptions(coversNotch: cover)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().alphaValue = 1.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated { self.applyPresentationOptions(coversNotch: cover) }
        })
    }

    /// Hide/auto-hide the menu bar + Dock once the stream window is opaque.
    /// Extracted from `fadeInOnFirstFrame` so the fade completion handler
    /// captures no non-Sendable closure - the handler runs on the main run
    /// loop, so MainActor isolation is sound.
    private func applyPresentationOptions(coversNotch cover: Bool) {
        if cover {
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        } else {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
    }

    /// Tear the stream window down cleanly. Safe to call more than once.
    public func close() {
        guard !didClose else { return }
        didClose = true

        // 1. Display-layer flush is DEFERRED to the fade completion (step 5).
        //    Flushing here (removingDisplayedImage) blanks the layer before the
        //    fade runs, so the user only ever sees an already-empty window fade
        //    out - imperceptible. Keeping the last decoded frame on screen
        //    until the fade finishes makes the fade-out land on the actual
        //    stream content, mirroring the first-frame fade-in.

        // 2. Restore the cursor. `setCursorHidden(false)` is idempotent and
        //    drives the counted CGDisplay latch strictly off `didHideCursor`,
        //    so this brings the count back to exactly 0 - never negative. The
        //    old unconditional belt-and-braces `NSCursor.unhide()` is gone:
        //    with the latch capped at 1 by the single-owner helper it could
        //    only ever over-show and corrupt the count, which is the very
        //    failure mode (cursor left invisible / over-visible) we're fixing.
        setCursorHidden(false)

        // Drop the key-status observers so we don't get a delayed
        // become/resign callback after the window has been torn down.
        for token in keyObservers {
            NotificationCenter.default.removeObserver(token)
        }
        keyObservers.removeAll()
        // Workspace observers live on NSWorkspace's own notification center -
        // remove them from THAT center, not the default one.
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsnc.removeObserver(token)
        }
        workspaceObservers.removeAll()
        // Path B's one-shot didEnterFullScreen token: consumed by its own
        // closure on the happy path, but a session that ends before AppKit
        // posts the enter notification leaves it registered - sweep it here.
        if let token = enterFullScreenObserver {
            NotificationCenter.default.removeObserver(token)
            enterFullScreenObserver = nil
        }

        // 3. Restore the app's presentation options BEFORE orderOut'ing the
        //    window. Order matters: if we orderOut first, the user briefly
        //    sees their desktop with the menu bar/Dock still hidden as
        //    AppKit catches up - a flash of "what happened to my menu bar".
        //    Restoring first means by the time the window disappears, the
        //    chrome is already back.
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
            previousPresentationOptions = nil
        }

        // 4. Exit the Space-based fullscreen. If the window never made it
        //    into fullscreen (early failure path), this is a no-op.
        //    `toggleFullScreen` runs an async animation; orderOut + activate
        //    after the exit notification fires would be cleaner, but the
        //    in-flight orderOut below still works in practice because AppKit
        //    queues the orderOut after the exit-fullscreen Space animation.
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        // 5. Drop first responder, fade out, orderOut. Fading instead of a
        //    hard orderOut gives the user a 250ms acknowledgement that the
        //    stream ended - without the fade the window snaps off and the
        //    launcher snaps in, which reads as a crash. Apple's first-party
        //    fullscreen surfaces (Apple TV's playback window, QuickTime's
        //    presentation mode) all fade on exit.
        window.makeFirstResponder(nil)
        let win = window

        // Under Reduce Motion, snap instead of the 250ms opacity ramp - same
        // policy as the first-frame fade-in (a large-surface opacity animation
        // is exactly what Reduce Motion asks us to drop).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 0.0
            finishClose()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 0.0
        }, completionHandler: {
            // runAnimationGroup delivers the completion on the main run loop,
            // so we are already on the MainActor - assumeIsolated bridges the
            // SDK's non-isolated @Sendable handler back to MainActor state.
            MainActor.assumeIsolated { self.finishClose() }
        })
    }

    /// Final teardown step, run once the close fade has finished (or
    /// immediately under Reduce Motion). Extracted from `close()` so the fade
    /// completion handler captures no non-Sendable closure - it runs on the
    /// main run loop, so MainActor isolation is sound.
    ///
    /// Hands off to the launcher only AFTER the stream has faded out. Doing it
    /// synchronously (during the fade) brings the launcher in front of the
    /// still-fading stream window, which masks the fade entirely and reads as a
    /// hard cut. Deferring it makes the exit a real fade-out, mirroring the
    /// first-frame fade-in. `NSApp.activate()` is the macOS 14+ replacement for
    /// `activate(ignoringOtherApps:)`.
    private func finishClose() {
        // Now that the window is invisible, drop the last frame + hide it.
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        window.orderOut(nil)
        // Reset alphaValue so a future show() of this window isn't
        // invisible (defensive - close() is currently the last call).
        window.alphaValue = 1.0
        NSApp.activate()
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Glimmer" }) {
            main.makeKeyAndOrderFront(nil)
        }
    }
}
