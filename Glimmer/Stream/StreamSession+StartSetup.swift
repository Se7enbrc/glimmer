// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

import GlimmerEngine
import Foundation
import AppKit
import GameController
import os

extension StreamSession {

    static func sessionActivityOptions(hidden: Bool) -> ProcessInfo.ActivityOptions {
        let options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]
        return hidden ? options : options.union([.idleDisplaySleepDisabled, .idleSystemSleepDisabled])
    }

    /// The collected inputs `buildStreamSubsystems` needs: the negotiated config,
    /// the initial stats-overlay state, the live hotkey/chord provider closures,
    /// and the optional backgrounded callback. Bundled into one value type so the
    /// builder's signature stays under the parameter-count limit; carried by value
    /// (the closures are `@MainActor`, matching the builder's isolation).
    struct StreamSetupOptions {
        let config: StreamConfig
        /// The bitrate we ACTUALLY asked the host for, after the connect-time
        /// quality gate. NOT `config.bitrateKbps`, which is the pre-gate demand
        /// figure: reporting that one made the overlay and the
        /// `negotiated_bitrate_mbps` telemetry claim 67.2 Mbps while the session
        /// was really running at a gated 33.6, which is exactly the kind of lie
        /// that costs an hour of diagnosis.
        let negotiatedBitrateKbps: Int
        let initialStatsOverlay: Bool
        let initialStatsCorner: StatsOverlayCorner
        let quitHotkeyProvider: @MainActor () -> HotkeyChord
        let statsHotkeyProvider: @MainActor () -> HotkeyChord
        let bookmarkHotkeyProvider: @MainActor () -> HotkeyChord
        let releasePointerHotkeyProvider: @MainActor () -> HotkeyChord
        let miniPlayerHotkeyProvider: @MainActor () -> HotkeyChord
        let controllerQuitChordProvider: @MainActor () -> ControllerQuitChord
        let customControllerChordProvider: @MainActor () -> Set<ControllerButton>
        let onBackgroundedChanged: (@MainActor (Bool) -> Void)?
        let onMiniPlayerChanged: (@MainActor (Bool) -> Void)?
        let onCancelConnect: (@MainActor () -> Void)?
    }

    /// Build the leave-hint string: the keyboard hotkey, plus the controller chord
    /// when one is set and a controller is connected, unless that chord needs a
    /// DualSense center button macOS drops with raw-HID off (it couldn't fire).
    static func leaveHintText(
        hotkey: HotkeyChord, chord: ControllerQuitChord,
        customChord: Set<ControllerButton>
    ) -> String {
        let base = "Press \(hotkey.displayString)"
        guard chord != .none, !GCController.controllers().isEmpty else {
            return "\(base) to stop streaming"
        }
        // Honesty: a Create/Mute-based chord can't fire on a DualSense without
        // the raw-HID reader; drop the clause rather than promise it.
        if InputForwarder.needsRawHIDCenterButtons(chord: chord, custom: customChord) && !DualSenseHID.isEnabled {
            return "\(base) to stop streaming"
        }
        let chordText = chord == .custom
            ? ControllerButton.describe(customChord) : chord.displayName
        return "\(base) (or hold \(chordText) on the controller) to stop streaming"
    }

    /// Spend one leave-hint show for `text`. A rebound hotkey or chord changes
    /// the text, and a new chord is a new lesson, so its budget starts over.
    static func claimLeaveHintShow(_ text: String, defaults: UserDefaults = PersistentStorage.defaults) -> Bool {
        if defaults.string(forKey: leaveHintShownKey) != text {
            defaults.set(text, forKey: leaveHintShownKey)
            defaults.removeObject(forKey: HintBudget.leaveStream.defaultsKey)
        }
        return HintBudget.leaveStream.claimShow(in: defaults)
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
        let onMiniPlayerChanged = options.onMiniPlayerChanged
        // The display mode is a construction-time choice (it picks the style
        // mask); the notch flag, title, and stream size feed show().
        let win = StreamWindow(displayMode: config.displayMode)
        win.coversNotch = config.coversNotch
        win.windowTitle = config.windowTitle
        win.streamPixelSize = CGSize(width: config.width, height: config.height)
        let dec = VideoDecoder(macColorSpace: config.colorSpace, colorRange: config.colorRange)
        dec.attach(to: win.displayLayer)
        // Focus drives the launcher; actual visibility drives decode presentation and power.
        win.onBackgroundedChanged = onBackgroundedChanged
        win.onPresentationSuppressedChanged = { [weak self, weak dec, id] suppressed, visibility in
            dec?.setPresentSuppressed(suppressed, visibility: visibility, sessionGeneration: id)
            Task { [weak self] in await self?.refreshPowerAssertion() }
        }
        let inp = InputForwarder()
        inp.onControllerMouseChanged = { [weak win] message, enabled in
            win?.showControllerMouseMode(message, enabled: enabled)
        }
        // Hotkey chords need to be readable LIVE on every keyDown so
        // changes in Settings take effect without restarting the
        // stream. Capture-at-attach silently strands edits. The
        // provider closures route back to the caller-supplied
        // resolvers (typically `{ moonlight.quitHotkey }`).
        inp.quitHotkeyProvider = options.quitHotkeyProvider
        inp.statsHotkeyProvider = options.statsHotkeyProvider
        inp.bookmarkHotkeyProvider = options.bookmarkHotkeyProvider
        inp.releasePointerHotkeyProvider = options.releasePointerHotkeyProvider
        inp.miniPlayerHotkeyProvider = options.miniPlayerHotkeyProvider
        inp.controllerQuitChordProvider = options.controllerQuitChordProvider
        inp.customControllerChordProvider = options.customControllerChordProvider
        inp.onCancelConnect = options.onCancelConnect
        dec.statsOverlayEnabled = initialStatsOverlay
        dec.setNegotiatedBitrateKbps(options.negotiatedBitrateKbps)
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
        let leaveHint: @MainActor () -> String = {
            Self.leaveHintText(
                hotkey: hotkeyProvider(), chord: chordProvider(), customChord: customChordProvider())
        }
        // A hold or reconnect that outstays its welcome says how to leave.
        win.reconnectBanner.lingerHint = leaveHint
        dec.onFirstDecodedFrame = { [weak win] in
            win?.fadeInOnFirstFrame()
            // Discoverability toast: Esc is a game input and the menu bar is
            // hidden, so the quit chord is otherwise undiscoverable. Skipped
            // while ordered out, so a show nobody sees doesn't spend the budget.
            guard let win, win.window.isVisible else { return }
            let text = leaveHint()
            guard Self.claimLeaveHintShow(text) else { return }
            win.showStreamToast(text, for: 5)
        }
        // Stream window moved to another display / its display woke or
        // changed mode → rebind the pacer's CADisplayLink so frames
        // present on the new screen's true refresh.
        win.onScreenChanged = { [weak dec] in
            dec?.pacingScreenDidChange()
        }
        win.onDisplaysWoke = { [weak dec] in
            dec?.pacingRebuildLink(reason: "display_wake")
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
        CruiseTraversal.configure(inp, streamWidth: config.width)
        // Share cursor ownership and capture edges across all presentations.
        inp.isWindowMode = config.displayMode == .window
        // The reference frame absolute positions are measured against.
        inp.streamPixelSize = CGSize(width: config.width, height: config.height)
        Self.wireWindowPointerModel(win: win, inp: inp, onMiniPlayerChanged: onMiniPlayerChanged)
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

    /// The window ⇄ forwarder edges of the window pointer model: capture
    /// edges drive the cursor, a mode flip switches the pointer policy, and
    /// the mini player edge reaches the forwarder (click-to-capture) before
    /// the launcher and menu bar hear about it.
    @MainActor
    private static func wireWindowPointerModel(
        win: StreamWindow, inp: InputForwarder, onMiniPlayerChanged: (@MainActor (Bool) -> Void)?
    ) {
        win.fullscreenRelativePointer = inp.fullscreenRelativePointer
        inp.onPointerCaptureChanged = { [weak win, weak inp] captured in
            win?.fullscreenRelativePointer = inp?.fullscreenRelativePointer ?? true
            win?.setPointerCaptured(captured)
        }
        inp.onPointerModeToggled = { [weak win] captured in
            win?.showPointerModeHint(captured: captured)
        }
        win.onDisplayModeChanged = { [weak inp] mode in
            inp?.setWindowMode(mode == .window)
        }
        win.onMiniPlayerChanged = { [weak inp] mini in
            inp?.setMiniPlayer(mini)
            onMiniPlayerChanged?(mini)
        }
        inp.onMiniPlayerHoverChanged = { [weak win] hovering in
            win?.setMiniPlayerHovering(hovering)
        }
    }
}
