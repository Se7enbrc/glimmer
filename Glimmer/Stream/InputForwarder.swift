//
//  InputForwarder.swift
//
//  Forwards keyboard, mouse, and gamepad input from the local Mac to the
//  remote host via the native backend's input-uplink methods (the LiSend*
//  family the GameStream protocol defines). Hosts the user's configurable
//  in-stream quit hotkey.
//
//  Implementation notes - read before editing:
//
//   * Input goes through a custom NSView (`StreamInputView`) installed as the
//     window's contentView's responder. Earlier revisions used
//     `NSEvent.addLocalMonitorForEvents`, but on macOS 26 the responder chain
//     consumes mouseMoved/keyDown events for content views that accept first
//     responder *before* the local monitor block fires. Routing through
//     NSResponder overrides is the only thing that's reliably ordered.
//
//   * The native backend's input queue is gated on the input stream being
//     started, which happens only after the control stream's RTSP handshake
//     completes. Any send call made before that returns -2 and does NOT
//     enqueue. We expose `setReady(_:)` so StreamSession can flip the gate
//     when the `connectionStarted` listener callback fires; until then we
//     drop events on the floor instead of generating a flood of -2 log lines.
//
//   * Keyboard codes are sent as positional scancodes via
//     `LiSendKeyboardEvent2(Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)), ...)`. The high bit asks the host to
//     skip its layout-correction pass (GFE tries to "fix" AZERTY → QWERTY by
//     remapping VK_*; we want the position to win because the user is looking
//     at their physical keyboard). This is the same convention moonlight-qt
//     uses in its Mac build.
//
//   * NKRO: every physical key-down or key-up emits one and only one
//     `LiSendKeyboardEvent2` - there is NO "single key in flight" state, no
//     per-event modifier reset, no "release before press" coalescing. macOS
//     delivers each physical-key transition as its own NSEvent (AppKit does
//     not collapse simultaneous presses), and the responder chain hands each
//     to `keyDown(with:)`/`keyUp(with:)` independently. With four fingers on
//     four keys we send four down events; lifting any one sends exactly one
//     up event for that key. `releaseStuckModifiers()` is called ONLY in
//     `detach()` (stream teardown) so it never resets state mid-game.
//     `lastModFlags` is diffed against the new mask in `flagsChanged` so we
//     only emit modifier transitions, not modifier state on every key. This
//     matches moonlight-qt's `m_KeysDown` QSet semantics.
//
//   * Mouse motion is *relative* via the SDL associate-false model
//     (P0 mouse-snap fix). When relative aim is engaged we call
//     `CGAssociateMouseAndMouseCursorPosition(false)` (enterCapturedMode) so the
//     OS STOPS physically moving the on-screen cursor - exactly
//     SDL_SetRelativeMouseMode(true) on macOS. This is the airtight fix for the
//     in-game aim snapping to a screen edge/corner: the prior model kept the
//     cursor associated and warped it back to centre near an edge, but an
//     associate-TRUE warp posts a reconciling mouse-moved event carrying the
//     full edge→centre delta (~1500px), which (with no suppression anywhere) was
//     read as pure HID motion and sent to the host. Under associate-false the
//     cursor never moves, so there is no edge, no warp, and no reconciliation
//     delta to leak - the bug class is structurally gone. Ownership:
//       1. Visibility: owned ENTIRELY by StreamWindow, which hides the cursor
//          with `CGDisplayHideCursor` (single source of truth =
//          `StreamWindow.didHideCursor`). CGDisplayHideCursor (unlike
//          NSCursor.hide) does not require the cursor to be over our window, so
//          the hide can't no-op. With the cursor hidden there is no visible
//          pointer to "freeze" - the two reasons associate-false was previously
//          abandoned (visible freeze + dead deltas) both no longer apply.
//       2. Relative deltas: read off the CGEvent backing each mouseMoved
//          NSEvent via `CGEventGetIntegerValueField(_, kCGMouseEventDeltaX/Y)`.
//          These raw, accel-free HID deltas stay valid AND become pure HID under
//          associate-false (the exact field SDL reads in relative mode). Only
//          NSEvent.deltaX/Y goes silent under associate-false - and we don't use
//          it. The previous Glimmer revision read NSEvent.deltaX/Y and wrongly
//          concluded associate-false killed deltas; the right field is the
//          CGEvent layer underneath.
//       3. Association: every associate-false (enterCapturedMode) is paired with
//          a guaranteed associate-true (exitCapturedMode, run on resign-key and
//          detach) so Cmd-Tab / teardown restores a normal OS-controlled pointer.
//          Hot corners are a non-issue: the OS doesn't move the cursor, so it
//          can never reach a corner - warpCursorIfNearEdge was deleted.
//     This is the SDL relative-mouse recipe on macOS: hide (CGDisplayHideCursor)
//     + associate-false + read kCGMouseEventDeltaX/Y.
//     A local NSEvent monitor for the gesture family
//     (`.magnify`/`.smartMagnify`/`.swipe`/`.rotate`) swallows the high-
//     level gesture events while the stream window is key so a trackpad
//     pinch can't reach macOS's window scaler. The narrower mask is
//     intentional: a broader set (`.gesture`/`.beginGesture`/`.endGesture`/
//     `.pressure`) swallows raw trackpad pan/scroll data on laptops with
//     no external mouse, killing cursor + scroll because the OS
//     synthesises mouseMoved from the same gesture stream we're eating.
//     (Ctrl+scroll Accessibility Zoom is the one trigger the freeze used to
//     gate that a monitor cannot - its non-freezing replacement is the
//     kCGAnnotatedSessionEventTap escalation, not yet installed; see
//     InputForwarder+Capture.swift.)
//
//   * Diagnostic event tap: while a stream is live (isReady == true) we
//     install two NSEvent monitors (local + global) that log every input
//     event AppKit delivers to the process at .info level. Reproducing the
//     mid-game macOS-zoom bug once and grepping for "DiagEvent"
//     in the log shows exactly which event type fires immediately
//     before the zoom - that drives whether we need to escalate to a
//     CGEventTap (see TODO(eventtap) in installDiagnosticMonitors). Rate-
//     limited to ~100 events/sec via a 1-second windowed sampler.
//
//   * macOS Accessibility Zoom keyboard shortcuts (⌥⌘8, ⌥⌘=, ⌥⌘-) are
//     intercepted unconditionally in streamView(_:handleKeyDown:) - we
//     return `true` so StreamInputView.keyDown skips its `super.keyDown`
//     path (which doesn't get called in any code path; see the comment
//     in StreamInputView.keyDown below) and the OS never sees the chord.
//     These are pure-OS chords with no game meaning; the intercept is
//     orthogonal to `captureSysKeys`.
//
//   * Gamepad arrival is announced via `LiSendControllerArrivalEvent`. Some
//     host versions register a controller slot only after seeing this; without
//     it `LiSendMultiControllerEvent` events appear to be silently dropped on
//     newer Sunshine builds.

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GameController
import os.log

@MainActor
public final class InputForwarder {
    // Internal (default) so the ControllerForwarder extension in
    // ControllerForwarder.swift can log with the same subsystem/category.
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Input")

    weak var window: NSWindow?
    weak var inputView: StreamInputView?

    /// Called when the user presses the configured quit hotkey. The session
    /// owner wires this to stop streaming.
    public var onQuitHotkey: (@MainActor () -> Void)?

    /// Provider for the quit hotkey. Called on every keyDown so changes the
    /// user makes in Settings while a stream is live take effect immediately
    /// - capturing the chord once at attach time meant the live edit silently
    /// did nothing until the next stream restart, which is a real UX trap.
    public var quitHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultQuit }

    /// Called when the user presses the configured stats-overlay hotkey.
    /// The session owner wires this to toggle the in-stream stats overlay.
    /// Like `onQuitHotkey`, the chord fires BEFORE the sys-key-capture gate
    /// so a non-Cmd default keeps working regardless of `captureSysKeys`.
    public var onStatsHotkey: (@MainActor () -> Void)?

    /// Provider for the stats-overlay hotkey. See `quitHotkeyProvider` for
    /// why this is a closure rather than a stored chord value.
    public var statsHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultStats }

    /// Called when the user presses the telemetry-bookmark chord (signal 4 -
    /// "that felt bad"). CLIENT-ONLY: the chord is consumed in the input path and
    /// NEVER forwarded to the host (mirrors the quit/stats intercept). The session
    /// owner wires this to `TelemetryExporter.recordBookmark()`. Like the quit
    /// hotkey, the match fires BEFORE the sys-key-capture gate so the non-Cmd
    /// default works regardless of `captureSysKeys`.
    ///
    /// GATED: the chord is only intercepted when this handler is wired AND
    /// `TelemetryGate.isEnabled` (see `streamView(_:handleKeyDown:)`). With
    /// telemetry OFF - the default - there is no live telemetry to bookmark
    /// into, so ⌃B is NOT swallowed and passes straight through to the host
    /// like any other key.
    public var onBookmarkHotkey: (@MainActor () -> Void)?

    /// Provider for the bookmark chord. See `quitHotkeyProvider` for why this is
    /// a closure rather than a stored chord value.
    public var bookmarkHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultBookmark }

    /// Controller-side quit chord. The ControllerForwarder extension
    /// consults this on every gamepad update and fires `onQuitHotkey`
    /// when all chord buttons are held simultaneously. Closure so live
    /// edits in Settings take effect on the next gamepad event.
    public var controllerQuitChordProvider: (@MainActor () -> ControllerQuitChord) = { .none }

    /// The user-recorded button set for the `.custom` quit chord.
    /// Consulted only when `controllerQuitChordProvider()` returns `.custom`.
    public var customControllerChordProvider: (@MainActor () -> Set<ControllerButton>) = { [] }

    /// In-flight hold-to-quit dwell for the controller quit chord. Armed by
    /// the ControllerForwarder extension when the chord first reads fully
    /// held; cancelled when it releases, when the arming pad detaches, or at
    /// session teardown (`detach()`). Stored here because extensions can't
    /// add stored properties - the dwell logic lives with the chord matcher
    /// in ControllerForwarder+QuitChord.swift.
    var quitChordDwellTask: Task<Void, Never>?

    /// Slot that armed the in-flight dwell. Only that pad's value-changed
    /// frames may cancel the count - a second pad's frames (which won't
    /// match the chord) say nothing about whether the holder is still
    /// holding.
    var quitChordDwellSlot: UInt8?

    /// Whether macOS-level "system" modifier combos that use the Cmd key
    /// should be forwarded to the host or left to macOS.
    ///
    /// macOS owns a lot of meaningful Cmd chords - ⌘-Tab (app switcher),
    /// ⌘-Space (Spotlight), ⌘-Q (quit), ⌘-` (window cycle), ⌘-H/⌘-M (hide/
    /// miniaturise). The Cmd key reports as `VK_LWIN`/`VK_RWIN` to the host,
    /// so the naive thing to do - forward everything - turns ⌘-Tab into a
    /// Win+Tab on the gaming PC, popping Windows' Task View while the
    /// streamer is trying to leave the stream. That's the bug we're closing.
    ///
    /// When this is `false` (the default), the InputForwarder:
    ///   * Drops `keyDown` events whose modifier mask contains `.command`
    ///     so they're handled by the macOS responder chain instead. ⌘-Q
    ///     quits Glimmer; ⌘-Tab switches apps; ⌘-Space opens Spotlight.
    ///   * Skips the `flagsChanged` path for the `.command` modifier so
    ///     we never emit a LWIN/RWIN down/up to the host.
    ///   * Strips `MODIFIER_META` from `modifierByte(from:)` so a
    ///     non-Cmd key that happens to be pressed while the user holds
    ///     Cmd doesn't reach the host with a phantom Win-key modifier.
    ///
    /// When this is `true`, the InputForwarder is transparent - every Cmd
    /// chord is forwarded as a Win-key chord - at the cost of macOS no
    /// longer reacting to those combos until the stream ends. That's the
    /// mode power users on dedicated streaming hardware want.
    ///
    /// Note: the configured quit hotkey (see `quitHotkey`) is detected
    /// BEFORE this gate, so a Cmd-bearing quit hotkey (the default ⌃⌘Q)
    /// keeps working regardless of capture state.
    public var captureSysKeys: Bool = false

    /// Set to true once the native backend's `connectionStarted` callback has
    /// fired. Until then send calls return -2 (input stream not yet
    /// initialized). Honouring this flag avoids a noisy log stream during the
    /// 200ms-or-so RTSP handshake window between window-show and stream-ready.
    public private(set) var isReady: Bool = false

    /// The streaming engine input is forwarded to. Injected by StreamSession at
    /// attach time so the forwarder talks to the protocol (`backend.send*`)
    /// instead of calling Li* directly. Optional + nil-guarded: until it's set
    /// (or if a teardown nils it), `send(...)` returns the -2 "input stream not
    /// ready" contract so nothing crashes. The ControllerForwarder extension
    /// reads it through the same property. The default-injected backend is the
    /// proven C path, so behavior is identical to the prior inline LiSend*.
    var backend: StreamingBackend?

    /// Set the backend the forwarder uses. Called by StreamSession right after
    /// `attach(to:)`.
    public func setBackend(_ backend: StreamingBackend) {
        self.backend = backend
    }

    /// Track of which controllers have had their arrival event sent so we
    /// only do it once per connect. Keyed by GCController's hashable identity.
    /// Internal so the ControllerForwarder extension can read/write.
    var attachedControllers: [ObjectIdentifier: AttachedController] = [:]

    /// Bitmask of slots currently in use; bit N == 1 means slot N is occupied.
    /// Sent to the host as `activeGamepadMask` on every controller event.
    var gamepadMask: UInt16 = 0

    /// Per-slot DualSense/DualShock touchpad finger tracking, so the touchpad
    /// surface can be forwarded as host touch events (down/move/up). Keyed by
    /// controller slot. The physical touchpad *click* rides the normal button
    /// bitmask (TOUCHPAD_FLAG); only the finger surface needs this state.
    var touchpadStates: [UInt8: TouchpadState] = [:]

    /// Monotonic pointer-id source for controller touch events. The host
    /// correlates a finger's down→move→up by pointerId, so each new contact
    /// gets a fresh id. Never 0 (some hosts treat 0 as "no pointer").
    var nextTouchPointerId: UInt32 = 1

    /// Cached connection observers so we can deregister on `detach()`.
    var connectObserver: NSObjectProtocol?
    var disconnectObserver: NSObjectProtocol?

    /// Sub-pixel mouse-move residual so motion under 1px per event isn't
    /// rounded to zero. macOS coalesces mouseMoved at ~120Hz on ProMotion;
    /// with a slow-moving trackpad we routinely see 0.3px/event. The
    /// accumulator carries the fraction forward until it crosses a
    /// whole-pixel boundary, which is what the host expects.
    var mouseResidualX: Double = 0
    var mouseResidualY: Double = 0

    /// Pull the relative delta out of a mouseMoved NSEvent. Reads the CGEvent
    /// integer fields `kCGMouseEventDeltaX/Y` (valid whether or not the cursor is
    /// associated; NSEvent.deltaX/Y goes silent under associate-false), falling
    /// back to NSEvent.deltaX/Y only for a synthetic event with no CGEvent
    /// backing. NOTE: these deltas carry macOS's pointer-acceleration curve -
    /// no accel-free path was adopted for the mouse (CGEventTap is also
    /// accelerated; the system accel-disable is intrusive and was
    /// deliberately not adopted).
    /// Returned in the same down-positive Y convention macOS uses so the
    /// LiSendMouseMoveEvent call site needs no sign flip.
    func mouseDelta(from event: NSEvent) -> (dx: Double, dy: Double) {
        if let cg = event.cgEvent {
            return (
                Double(cg.getIntegerValueField(.mouseEventDeltaX)),
                Double(cg.getIntegerValueField(.mouseEventDeltaY))
            )
        }
        return (event.deltaX, event.deltaY)
    }

    /// True when relative-aim mode is engaged. Flipped by `enterCapturedMode()`
    /// / `exitCapturedMode()` from the window's becomeKey/resignKey hooks.
    /// Re-entrant: enter while already-captured is a no-op.
    ///
    /// Under the SDL associate-false model (P0 mouse-snap fix) this
    /// flag ALSO gates the cursor-association latch:
    /// `enterCapturedMode` calls `CGAssociateMouseAndMouseCursorPosition(false)`
    /// when flipping it true, and `exitCapturedMode` re-associates (true) when
    /// flipping it false. It's the in-memory record of whether the disassociate
    /// is currently in effect, so the re-associate on resign/teardown is paired
    /// exactly once. The CGEvent-delta read in `mouseDelta(from:)` does not
    /// branch on it - the deltas are pure HID under associate-false regardless.
    var isMouseCaptured: Bool = false

    /// Saved `NSEvent.isMouseCoalescingEnabled` from BEFORE we engaged relative
    /// aim, restored on disengage so the rest of the system keeps its default.
    /// nil while we have not overridden coalescing (no save to restore). See
    /// `enterCapturedMode()` for why we turn coalescing OFF in relative aim.
    var savedMouseCoalescing: Bool?

    /// Saved global mouse pointer-acceleration from BEFORE we linearized it for
    /// relative aim, restored on disengage. nil while we have NOT overridden it
    /// (feature off, read/write failed, or the user already runs linear) - so the
    /// restore in `exitCapturedMode()` is paired exactly once with the override.
    /// The same value is also persisted to UserDefaults while engaged so a crash
    /// can't strand the pointer in linear mode; see `MouseAccelerationControl`.
    var savedMouseAcceleration: Double?

    /// NSEvent local-monitor token for gesture suppression. While the stream
    /// window is key, we swallow gesture-family events so macOS's pinch-to-
    /// zoom, smart-zoom, swipe-to-Mission-Control, and rotate don't reach
    /// default handlers under the stream layer. We do NOT swallow
    /// `.scrollWheel` here - scrolls need to reach our StreamInputView so we
    /// can forward them as host scroll events. This monitor alone is
    /// sufficient for the trackpad gesture family now that the freeze is gone;
    /// the one trigger it can't reach is Ctrl+scroll Accessibility Zoom (a
    /// WindowServer-level interlock), whose non-freezing replacement is the
    /// kCGAnnotatedSessionEventTap escalation described in
    /// InputForwarder+Capture.swift - not the old associate-false freeze.
    var gestureSuppressionMonitor: Any?

    /// NSEvent local-monitor token for the diagnostic event tap. While
    /// streaming (i.e. `isReady == true`) and the stream window is key, this
    /// monitor logs every event AppKit delivers to our process so we can
    /// identify exactly which event type triggers macOS Accessibility Zoom
    /// during gameplay. Pass-through (returns `event` unchanged) - this is
    /// observation only, suppression is the other monitor's job. Rate-limited
    /// to 100 events/sec to keep the log manageable.
    var diagnosticLocalMonitor: Any?

    /// NSEvent global-monitor token. Sees events delivered to OTHER apps and
    /// system-level chords WindowServer intercepts before they reach us
    /// (e.g. ⌥⌘8 toggling Accessibility Zoom). Global monitors are
    /// observation-only by API contract - they can't consume - which is
    /// exactly what we want for diagnostics. Same rate-limit as the local
    /// monitor.
    var diagnosticGlobalMonitor: Any?

    /// Rolling 1-second window of event counts for the diagnostic sampler.
    /// When the rate crosses 100/sec we sample down to one in N to bound
    /// the log volume during gestural floods (e.g. a long .scrollWheel
    /// burst with phase data on every frame).
    var diagSampleWindowStart: TimeInterval = 0
    var diagSampleCount: Int = 0
    var diagSampleDivisor: Int = 1

    /// becomeKey/resignKey observers, kept so we can flip captured mode on
    /// focus transitions and tear down cleanly in `detach()`.
    var didBecomeKeyObserver: NSObjectProtocol?
    var didResignKeyObserver: NSObjectProtocol?

    public init() {
        setupGamepadObservers()
    }

    isolated deinit {
        // GCController observers retain self via closure; release here.
        // `isolated deinit` keeps us on MainActor (the class's isolation) so
        // we can safely touch MainActor-isolated stored observer tokens; without
        // it, Swift 6's default nonisolated deinit refuses to read them.
        if let observer = connectObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = disconnectObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// Install the input view on the given window and start forwarding.
    /// Call from MainActor after the window's contentView has been set.
    ///
    /// IMPORTANT: this method only puts the view in the hierarchy. It does
    /// NOT make it first responder - that has to wait until the window is
    /// actually on screen AND key. A borderless KeyableWindow can be on
    /// screen, orderedFront, and *still* not be key if NSApp wasn't active
    /// at makeKeyAndOrderFront time; any makeFirstResponder we call before
    /// the window is key is silently dropped. The caller (StreamWindow.show()
    /// via its onDidBecomeReadyForInput hook) invokes `installFirstResponder()`
    /// at the correct moment.
    public func attach(to window: NSWindow) {
        self.window = window

        // Wrap (or replace) the existing contentView with a StreamInputView so
        // we can intercept events at the responder level. We keep the old
        // contentView as a subview so the AVSampleBufferDisplayLayer hosted
        // on it keeps receiving and presenting enqueued sample buffers.
        let frame = window.contentView?.bounds ?? window.frame
        let view = StreamInputView(frame: frame)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.delegate = self

        if let existing = window.contentView {
            // Re-parent the existing contentView (which hosts the Metal layer)
            // under our input view so video keeps rendering. The Metal layer
            // sits on `existing`, not on our view - so we don't need to move
            // the layer itself, just adopt the view hierarchy.
            existing.translatesAutoresizingMaskIntoConstraints = true
            existing.autoresizingMask = [.width, .height]
            existing.frame = view.bounds
            view.addSubview(existing)
        }
        window.contentView = view
        self.inputView = view
        window.acceptsMouseMovedEvents = true

        log.info("InputForwarder attached to window; first-responder install deferred until window is key")
    }

    /// Apply first-responder to our StreamInputView. Called by StreamWindow
    /// once the window is on screen and key. Idempotent - calling it more
    /// than once is a no-op past the first successful install.
    public func installFirstResponder() {
        guard let window = self.window, let view = self.inputView else {
            log.error("installFirstResponder called with no window/view attached")
            return
        }
        // Verify preconditions before we ask AppKit to do anything. Each of
        // these is a known way for makeFirstResponder to silently fail; logging
        // them gives us a paper trail if a future macOS release changes the
        // rules out from under us.
        if !window.isKeyWindow {
            log.error("Window is not key at first-responder install - keyDown will not be delivered")
        }
        if view.window !== window {
            log.error("StreamInputView is not in the target window's hierarchy")
        }
        if !NSApp.isActive {
            log.error("NSApp is not active at first-responder install - system will not route key events to us")
        }
        let ok = window.makeFirstResponder(view)
        let responder = String(describing: window.firstResponder)
        log.info("makeFirstResponder(StreamInputView) returned \(ok, privacy: .public); first responder = \(responder, privacy: .public)")

        // Engage captured mouse mode + gesture suppression now that the
        // window is the input target. We track key/resignKey transitions
        // so Cmd-Tabbing away releases the cursor and reattaches cleanly
        // when the user comes back. This is the macOS-side equivalent of
        // SDL_SetRelativeMouseMode(true) - see the file-top comment.
        installFocusObservers(for: window)
        installGestureSuppressionMonitor()
        if window.isKeyWindow {
            enterCapturedMode()
        }
    }

    public func detach() {
        // Send key-up for any modifiers we believe are pressed so we don't
        // leave the host with phantom-held modifiers if we tear down mid-press.
        releaseStuckModifiers()

        // Disengage relative-aim mode + remove gesture defaults.
        // `exitCapturedMode()` RE-ASSOCIATES the cursor
        // (CGAssociateMouseAndMouseCursorPosition(true)) - the guaranteed `true`
        // that pairs with the `false` from enterCapturedMode, so stream teardown
        // always hands a normal OS-controlled pointer back. Cursor VISIBILITY is
        // owned by StreamWindow: its close() / resign-key path shows the cursor
        // via `setCursorHidden(false)`, so the user is never left with an
        // invisible cursor after teardown.
        exitCapturedMode()
        removeGestureSuppressionMonitor()
        removeDiagnosticMonitors()
        removeFocusObservers()

        inputView?.delegate = nil
        inputView = nil
        window = nil
        isReady = false

        // A quit-chord hold can be mid-dwell at teardown (the dwell firing is
        // itself one way the session ends) - cancel it so the timer can't
        // invoke onQuitHotkey against a session that's already stopping.
        cancelQuitChordDwell()

        // Balance per-controller acquisitions (DualSenseHID retain, the
        // Battery/Motion/Haptics singleton slots) and drop the controller
        // bookkeeping - the measured session-teardown leak; see
        // releaseAttachedControllers() in ControllerForwarder.swift.
        releaseAttachedControllers()
    }

    /// Called by StreamSession when the connection's `connectionStarted`
    /// callback fires. Inputs queued before this point are dropped (the C
    /// queue is closed and would just return -2).
    public func setReady(_ ready: Bool) {
        let was = isReady
        isReady = ready
        if ready != was {
            log.info("Input forwarding ready=\(ready, privacy: .public)")
            if ready {
                // Re-send arrival events for any already-attached controllers
                // so the host learns about them now that the stream is up.
                for state in attachedControllers.values {
                    sendArrival(state)
                }
                installDiagnosticMonitors()
            } else {
                removeDiagnosticMonitors()
            }
        }
    }

    // MARK: - LiSend wrappers with diagnostic logging
    //
    // Every LiSend* call returns int. Common return values we care about:
    //   0   → enqueued
    //  -1   → packet allocation failed (input queue full)
    //  -2   → input stream not initialized (called before connectionStarted)
    //  -5501 (LI_ERR_UNSUPPORTED) → host doesn't support this entry point
    // We log on first non-zero return per code so a transient backpressure
    // burst doesn't drown the log, but persistent failures stay visible.

    private var loggedFailureCodes: Set<Int32> = []

    /// Count of input events the host's queue rejected with -1 (packet
    /// allocation failed under backpressure). A climbing value during heavy
    /// simultaneous key/stick input is the signature of the host draining
    /// slower than we send - i.e. the only path by which n-key rollover can
    /// drop a key. Not fatal (the next event re-establishes state), but
    /// counted so the loss isn't silent. We deliberately do NOT retry/sleep
    /// in this hot path: blocking the GameController/NSEvent callback to
    /// re-send a full queue would jank input far worse than the rare drop.
    private(set) var droppedInputEvents: Int = 0

    // Internal so the ControllerForwarder extension can call `record` from
    // ControllerForwarder.swift to log non-zero LiSend* return codes.
    func record(_ name: StaticString, _ rc: Int32) {
        guard rc != 0 else { return }
        if rc == -1 {
            // Backpressure, not a protocol error. Count every drop; log once
            // at warning so a burst doesn't flood the unified log.
            droppedInputEvents += 1
            if !loggedFailureCodes.contains(rc) {
                loggedFailureCodes.insert(rc)
                log.warning("\(name, privacy: .public): host input queue full (-1), event dropped; further drops in droppedInputEvents")
            }
            return
        }
        if !loggedFailureCodes.contains(rc) {
            loggedFailureCodes.insert(rc)
            log.error("\(name, privacy: .public) returned \(rc) (first occurrence)")
        }
    }

    // MARK: - Modifier mapping

    /// Last-seen modifier mask, so we can diff against the previous flagsChanged
    /// event and emit per-modifier down/up.
    var lastModFlags: NSEvent.ModifierFlags = []

    func modifierByte(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var b: Int32 = 0
        if flags.contains(.control) { b |= StreamProtocol.MODIFIER_CTRL }
        if flags.contains(.shift) { b |= StreamProtocol.MODIFIER_SHIFT }
        if flags.contains(.option) { b |= StreamProtocol.MODIFIER_ALT }
        // Only fold Cmd into MODIFIER_META when sys-key capture is on. With
        // capture off, the user expects Cmd to be a macOS-only key - sending
        // MODIFIER_META alongside an unrelated keypress would make the host
        // see e.g. "Win+T" for a stray ⌘-T the user pressed to open a tab in
        // a backgrounded mac app.
        if flags.contains(.command), captureSysKeys { b |= StreamProtocol.MODIFIER_META }
        return UInt8(truncatingIfNeeded: b)
    }

    /// Send key-up for any modifier our state thinks is currently down. Used
    /// during detach so the host doesn't see a "ctrl is held forever" state.
    ///
    /// We deliberately omit the Cmd modifier when `captureSysKeys` is false:
    /// the corresponding VK_LWIN/VK_RWIN down was never sent (we filter Cmd
    /// out of `flagsChanged`), so sending a stray up here would be a
    /// fabricated event the host would react to.
    private func releaseStuckModifiers() {
        guard isReady else { return }
        let flags = lastModFlags
        var pairs: [(NSEvent.ModifierFlags, Int16)] = [
            (.control, 0xA2), // VK_LCONTROL
            (.shift, 0xA0), // VK_LSHIFT
            (.option, 0xA4) // VK_LMENU (Alt)
        ]
        if captureSysKeys {
            pairs.append((.command, 0x5B)) // VK_LWIN
        }
        for (flag, vk) in pairs where flags.contains(flag) {
            let rc = backend?.sendKeyboard(
                keyCode: Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)),
                action: Int8(StreamProtocol.KEY_ACTION_UP), modifiers: 0, flags: 0) ?? -2
            record("LiSendKeyboardEvent2(modifier release)", rc)
        }
        lastModFlags = []
    }

    // Gamepad path (GameController framework integration, slot allocation,
    // arrival announcements, per-frame value-changed handlers) lives in
    // ControllerForwarder.swift.
}
