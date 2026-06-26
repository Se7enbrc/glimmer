//
//  StreamSession+StartSetup.swift
//
//  The two large main-actor setup blocks the start path runs BEFORE the
//  connection: standing up the window/decoder/input subsystems
//  (`buildStreamSubsystems`) and wiring the per-subsystem backends + callbacks
//  (`wireSubsystemBackends`), plus the `StreamSetupOptions` value type that
//  carries the start(...) inputs into the builder. Split out of
//  StreamSession+Start.swift to keep each unit under the length limit; the
//  orchestrating start() in that file calls straight into these. Behavior is
//  identical to the prior inline form.
//

import Foundation
import AppKit
import GameController
import os

extension StreamSession {

    /// The collected inputs `buildStreamSubsystems` needs: the negotiated config,
    /// the initial stats-overlay state, the live hotkey/chord provider closures,
    /// and the optional backgrounded callback. Bundled into one value type so the
    /// builder's signature stays under the parameter-count limit; carried by value
    /// (the closures are `@MainActor`, matching the builder's isolation).
    struct StreamSetupOptions {
        let config: StreamConfig
        let initialStatsOverlay: Bool
        let initialStatsCorner: StatsOverlayCorner
        let quitHotkeyProvider: @MainActor () -> HotkeyChord
        let statsHotkeyProvider: @MainActor () -> HotkeyChord
        let bookmarkHotkeyProvider: @MainActor () -> HotkeyChord
        let controllerQuitChordProvider: @MainActor () -> ControllerQuitChord
        let customControllerChordProvider: @MainActor () -> Set<ControllerButton>
        let onBackgroundedChanged: (@MainActor (Bool) -> Void)?
    }

    /// Build the one-time leave-hint string: the keyboard hotkey, plus the
    /// controller chord when one is set AND a controller is connected. Omits the
    /// controller clause when its chord depends on a DualSense center button
    /// macOS drops with raw-HID off - advertising a chord that can't fire is worse
    /// than silence.
    static func leaveHintText(
        hotkey: HotkeyChord, chord: ControllerQuitChord,
        customChord: Set<ControllerButton>
    ) -> String {
        let base = "Press \(hotkey.displayString)"
        guard chord != .none, !GCController.controllers().isEmpty else {
            return "\(base) to leave the stream"
        }
        // Honesty: a Create/Mute-based chord can't fire on a DualSense without
        // the raw-HID reader; drop the clause rather than promise it.
        let needsRawHID: Bool
        switch chord {
        case .startSelectL1R1: needsRawHID = true
        case .custom: needsRawHID = !customChord.isDisjoint(with: [.create, .mute])
        case .none, .l1r1, .l1r1l2r2, .l3r3: needsRawHID = false
        }
        if needsRawHID && !DualSenseHID.isEnabled {
            return "\(base) to leave the stream"
        }
        let chordText = chord == .custom
            ? ControllerButton.describe(customChord) : chord.displayName
        return "\(base) (or hold \(chordText) on the controller) to leave"
    }

    /// Stand up the window + decoder + input on the main actor and return them.
    /// Done BEFORE the connection so the decoder's VideoSink has an
    /// AVSampleBufferDisplayLayer to enqueue into the moment frames arrive.
    @MainActor
    func buildStreamSubsystems(
        _ options: StreamSetupOptions
    ) -> (StreamWindow, InputForwarder, VideoDecoder) {
        let config = options.config
        let initialStatsOverlay = options.initialStatsOverlay
        let initialStatsCorner = options.initialStatsCorner
        let onBackgroundedChanged = options.onBackgroundedChanged
        let win = StreamWindow()
        win.coversNotch = config.coversNotch
        let dec = VideoDecoder()
        dec.attach(to: win.displayLayer)
        // Route the window's backgrounded/foregrounded signal to BOTH
        // the caller (launcher "Back to stream" CTA) AND the decoder's
        // present-suppression state. The decoder uses it to stop
        // misreading the intentional non-present backlog as packet loss
        // (no IDR/RFI spam while unfocused) and to flush+resync on
        // refocus. Wrapping here keeps the single source of truth - the
        // window's key/occlusion observers - driving both consumers.
        win.onBackgroundedChanged = { [weak dec] backgrounded in
            dec?.setPresentSuppressed(backgrounded)
            onBackgroundedChanged?(backgrounded)
        }
        let inp = InputForwarder()
        // Hotkey chords need to be readable LIVE on every keyDown so
        // changes in Settings take effect without restarting the
        // stream. Capture-at-attach silently strands edits. The
        // provider closures route back to the caller-supplied
        // resolvers (typically `{ moonlight.quitHotkey }`).
        inp.quitHotkeyProvider = options.quitHotkeyProvider
        inp.statsHotkeyProvider = options.statsHotkeyProvider
        inp.bookmarkHotkeyProvider = options.bookmarkHotkeyProvider
        inp.controllerQuitChordProvider = options.controllerQuitChordProvider
        inp.customControllerChordProvider = options.customControllerChordProvider
        dec.statsOverlayEnabled = initialStatsOverlay
        dec.setNegotiatedBitrateKbps(config.bitrateKbps)
        dec.setActiveAudioConfigLabel(config.audio.displayLabel)
        win.statsOverlay.corner = initialStatsCorner
        // Seed the overlay's visibility from the initial state so the
        // overlay layer is correct from frame zero. The
        // `onStatsOverlayEnabledChanged` callback installed below
        // handles every subsequent flip from the hotkey.
        win.statsOverlay.setVisible(initialStatsOverlay)
        dec.onStatsOverlayEnabledChanged = { [weak win] enabled in
            win?.statsOverlay.setVisible(enabled)
        }
        // First decoded frame → fade the (currently invisible) stream
        // window in. Without this the window sits at alphaValue 0 from
        // show() time and only the launcher (dimmed to 40%) is visible.
        // (This closure is EXTENDED below - after the bridge exists - to
        // ALSO yield `.firstFrame` so a decoded frame promotes the UI to
        // .streaming even if the one-shot .connectionEstablished edge was
        // lost. See the `onFirstDecodedFrame` re-wire in the post-bridge
        // MainActor block.)
        let hotkeyProvider = options.quitHotkeyProvider
        let chordProvider = options.controllerQuitChordProvider
        let customChordProvider = options.customControllerChordProvider
        dec.onFirstDecodedFrame = { [weak win] in
            win?.fadeInOnFirstFrame()
            // One-time discoverability toast: Esc is a game input and the menu
            // bar is hidden, so the quit chord is otherwise undiscoverable. Show
            // it once ever, on the first stream, with the LIVE chord string(s).
            guard let win, !UserDefaults.standard.bool(forKey: Self.leaveHintShownKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.leaveHintShownKey)
            let text = Self.leaveHintText(
                hotkey: hotkeyProvider(),
                chord: chordProvider(),
                customChord: customChordProvider())
            win.leaveHintBanner.setText(text)
            win.leaveHintBanner.setVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak win] in
                win?.leaveHintBanner.setVisible(false)
            }
        }
        // Stream window moved to another display / its display woke or
        // changed mode → rebind the pacer's CADisplayLink so frames
        // present on the new screen's true refresh.
        win.onScreenChanged = { [weak dec] in
            dec?.pacingScreenDidChange()
        }
        // Present-path last-resort self-heal: when the renderer
        // hard-latches `.status == .failed` and a flush won't clear it,
        // the decoder asks for a fresh AVSampleBufferDisplayLayer -
        // rebuild it, re-point the decoder, re-apply colorspace/EDR.
        dec.rebuildDisplayLayerHook = { [weak win, weak dec] in
            guard let win, let dec else { return nil }
            let fresh = win.rebuildDisplayLayer()
            dec.attach(to: fresh)
            dec.configureLayerColorspace()
            return fresh
        }
        // Capture-sys-keys is read from config at attach time and
        // captured by the InputForwarder for the lifetime of the
        // session. The toggle in Settings doesn't take effect until
        // the next stream starts - changing it mid-stream is
        // intentionally a no-op because mid-stream behavior changes
        // for system keys would surprise the user (Cmd-Tab suddenly
        // stops working mid-game, etc.).
        inp.captureSysKeys = config.captureSysKeys
        // Cruise ceiling is derived from the stream width (4K→2.0, 1080p→1.0 inert).
        inp.cruiseGMax = CruiseTraversal.gMax(forStreamWidth: config.width)
        inp.attach(to: win.window)
        // The window installs first responder only after it has
        // become key AND finished its enter-fullscreen transition.
        // macOS resets the responder chain during fullscreen Space
        // creation, so any pre-emptive makeFirstResponder is dropped.
        // We pass a closure that asks InputForwarder to install at the
        // right moment; StreamWindow.show() also installs a fallback
        // timer in case didEnterFullScreen never fires.
        win.onDidBecomeReadyForInput = { [weak inp] in
            inp?.installFirstResponder()
        }
        win.show()
        // Stand up the display-clock frame pacer now that the window
        // is on screen with a real NSScreen - bind its CADisplayLink to
        // the stream content view's display so frames present on the
        // panel's true vsync cadence instead of the instant VT decodes
        // them. Seed the cadence from the negotiated stream fps; the
        // pacer self-corrects from host PTS deltas thereafter. The
        // decoder owns pacer teardown via `teardown()`.
        dec.startPacing(
            drivingView: win.streamContentView,
            configuredFps: Int32(config.fps))
        return (win, inp, dec)
    }

    /// Inject the streaming engine into the input forwarder + decoder and wire
    /// the quit/stats/bookmark/HDR/first-frame callbacks. Done AFTER the bridge
    /// + its event continuation exist so the HDR/first-frame closures can yield
    /// through the bridge.
    @MainActor
    func wireSubsystemBackends(
        setup: (StreamWindow, InputForwarder, VideoDecoder),
        bridge: StreamBridgeContext,
        backend: StreamingBackend
    ) {
        // Inject the streaming engine into the input forwarder so keyboard /
        // mouse / controller / touchpad uplink goes through `backend.send*`.
        // `backend` is passed in (read on the actor by the caller) because it's
        // now an actor-isolated `var` (swappable for reconnect) and this
        // @MainActor method can't read actor state synchronously.
        let backendForInput = backend
        setup.1.setBackend(backendForInput)
        // Same injection for the decoder so its IDR requests + HDR-metadata
        // pulls route through the protocol.
        setup.2.setBackend(backendForInput)
        // Set the quit handler now that the session reference is stable.
        setup.1.onQuitHotkey = { [weak self] in
            Task { await self?.stop() }
        }
        // Stats-overlay toggle. Flips a MainActor-isolated bool on the
        // VideoDecoder (read by the render loop) but intentionally does
        // NOT touch `MoonlightManager.showStreamStats` - the toggle is
        // session-scoped so the user's persisted preference is what the
        // next stream starts with. Capture the decoder weakly so the
        // InputForwarder's closure doesn't extend its lifetime past
        // StreamSession.stop().
        setup.1.onStatsHotkey = { [weak decoder = setup.2] in
            decoder?.toggleStatsOverlay()
        }
        // Bookmark chord (signal 4 - "that felt bad"). Client-only: the chord
        // is consumed in the input path; this just records the marker into the
        // telemetry. `telemetryExporter` is nil unless telemetry is opt-in ON
        // (the exporter is started later in startTelemetryExporter), so when
        // off this is a harmless no-op - the chord is still swallowed (never
        // forwarded to the host), it simply records nothing. Resolved at press
        // time so it picks up the exporter once it exists.
        setup.1.onBookmarkHotkey = { [weak self] in
            // `telemetryExporter` is actor-isolated, so hop onto the session
            // actor to read it. The marker timestamp is taken inside
            // `recordBookmark` (connect-relative), and a "felt bad" marker
            // tolerates the few-ms hop - the user's perception spans hundreds
            // of ms. Mirrors how `onQuitHotkey` hops to `stop()`.
            Task { await self?.recordTelemetryBookmark() }
        }
        // Watch effective HDR-active state. Decoder fires this on the
        // main actor when the layer transitions to/from the PQ pipeline.
        // Yield directly through the bridge's continuation - no actor hop
        // needed; AsyncStream.Continuation is Sendable + ordered.
        setup.2.onHDRActiveChanged = { [weak bridge] active in
            bridge?.eventContinuation?.yield(.hdrActive(active))
        }
        // Re-wire the first-decoded-frame hook (set above for window
        // fade-in) to ALSO yield `.firstFrame` through the bridge now that
        // the bridge + its event continuation exist. This is the
        // belt-and-suspenders for the connecting→streaming transition:
        // `.connectionEstablished` is a ONE-SHOT edge fired from inside the
        // synchronous startConnection - before the consumer's for-await loop
        // is necessarily draining - so if it is ever torn/dropped the
        // launcher would stay stuck at "Connecting" forever even though
        // video is on screen. A decoded frame is GROUND TRUTH that the
        // stream is live, and unlike the established edge it CANNOT be lost
        // (by the time frames flow the consumer is up and the continuation
        // is bound). handleNativeEvent maps `.firstFrame` to
        // streamPhase=.streaming, idempotent with .connectionEstablished:
        // whichever lands first promotes; the second is a harmless
        // re-assert. The window fade-in stays wired here so the original
        // behaviour is preserved exactly.
        let priorFirstFrame = setup.2.onFirstDecodedFrame
        setup.2.onFirstDecodedFrame = { [weak bridge] in
            priorFirstFrame?()
            bridge?.eventContinuation?.yield(.firstFrame)
        }
    }
}
