// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// GameController owns full snapshots; raw HID contributes centre-button edges without repeating touch.

import GlimmerEngine
import AppKit
import Foundation
import GameController

extension InputForwarder {

    var forwardsControllerEvents: Bool {
        isReady && (isMiniPlayer || window?.isKeyWindow != false)
    }

    func updateControllerBackgroundEvents() {
        publishInputSnapshot()
        ControllerBackgroundEvents.setEnabled(isMiniPlayer && isReady, for: controllerBackgroundEventsID)
        ControllerHaptics.shared.setBackgroundPlayEnabled(isMiniPlayer && isReady,
                                                          for: controllerBackgroundEventsID)
        for state in attachedControllers.values {
            ControllerMotion.shared.setInputEnabled(
                forwardsControllerEvents && controllerMouseStates[state.slot]?.isMouse != true, slot: state.slot)
        }
    }

    // MARK: - Per-frame state push

    /// Only GameController snapshots own the surface, so centre-button edges cannot double-feed touch.
    func sendGamepadUpdate(pad: GCExtendedGamepad, slot: UInt8,
                           touchpadUpdate: (@MainActor () -> Void)? = nil) {
        guard pushControllerState(pad: pad, slot: slot) else { return }
        if let touchpadUpdate { touchpadUpdate() } else { forwardTouchpad(pad: pad, slot: slot) }
    }

    /// Raw-HID centre and shoulder edges re-run the chord check when GameController is late or silent.
    /// Axes still come from GameController; the batcher merges them without repeating surface events.
    func sendCenterButtonUpdate(pad: GCExtendedGamepad, slot: UInt8) {
        let pushed = pushControllerState(pad: pad, slot: slot)
        // Keep the rate-limited partial-hold breadcrumb: it identifies which centre button never registered.
        guard pushed, controllerMouseStates[slot]?.isMouse != true, quitChordUsesCentreButtons() else { return }
        let hid = dualSenseButtons(pad: pad)
        if hid.options || hid.create {
            quitChordBreadcrumb(.partial, "partial hold on slot \(slot)", pad: pad)
        }
    }

    /// Only the GameController frame owns touchpad forwarding, so centre-button edges cannot double-feed it.
    /// Returns false when input is gated or the quit chord is held; mouse mode still needs the surface.
    @discardableResult
    private func pushControllerState(pad: GCExtendedGamepad, slot: UInt8) -> Bool {
        guard forwardsControllerEvents else { return false }
        publishInputSnapshot()
        if let controller = pad.controller, let sample = controllerLayouts?.sample(for: controller, slot: slot) {
            let result = inputCore.receive(slot: slot, buttons: Int32(bitPattern: sample.game.buttons),
                analog: sample.game.gamepadAnalog, extras: sample.physical.extras, physicalSample: sample.physical,
                rawSupplement: sample.supplement.map { (Int32(bitPattern: $0), Int32(bitPattern: $0)) })
            return result == .forwarded || result == .mouse
        }
        let buttons = pressedButtonFlags(pad: pad)
        let result = inputCore.receive(slot: slot, buttons: buttons, analog: Self.controllerAnalog(pad),
                                       chordButtons: Self.controllerChordButtons(pad, buttons: buttons))
        if result == .chord || result == .mouse { _ = InputDeliverStamp.shared.take(slot: Int(slot)) }
        return result == .forwarded || result == .mouse
    }

    /// The host button bitmask for a gamepad's current state. Table-driven so
    /// the full button map lives in one declarative place (and a flat fold
    /// keeps it off the cyclomatic-complexity radar that a 17-way if-chain
    /// trips). The DualSense/DualShock touchpad *click* rides here as
    /// TOUCHPAD_FLAG (Sunshine's touchpad button); the touchpad *surface* is
    /// forwarded separately as touch events.
    nonisolated func pressedButtonFlags(pad: GCExtendedGamepad) -> Int32 {
        let mapping: [(Bool, Int32)] = [
            (pad.buttonA.isPressed, StreamProtocol.A_FLAG),
            (pad.buttonB.isPressed, StreamProtocol.B_FLAG),
            (pad.buttonX.isPressed, StreamProtocol.X_FLAG),
            (pad.buttonY.isPressed, StreamProtocol.Y_FLAG),
            (pad.dpad.up.isPressed, StreamProtocol.UP_FLAG),
            (pad.dpad.down.isPressed, StreamProtocol.DOWN_FLAG),
            (pad.dpad.left.isPressed, StreamProtocol.LEFT_FLAG),
            (pad.dpad.right.isPressed, StreamProtocol.RIGHT_FLAG),
            (pad.leftShoulder.isPressed, StreamProtocol.LB_FLAG),
            (pad.rightShoulder.isPressed, StreamProtocol.RB_FLAG),
            (pad.leftThumbstickButton?.isPressed == true, StreamProtocol.LS_CLK_FLAG),
            (pad.rightThumbstickButton?.isPressed == true, StreamProtocol.RS_CLK_FLAG),
            (pad.buttonOptions?.isPressed == true, StreamProtocol.BACK_FLAG),
            (pad.buttonMenu.isPressed, StreamProtocol.PLAY_FLAG),
            (pad.buttonHome?.isPressed == true, StreamProtocol.SPECIAL_FLAG),
            (touchpadElements(of: pad)?.button.isPressed == true, StreamProtocol.TOUCHPAD_FLAG),
            // Xbox Share/Capture → MISC_FLAG (the spare misc/touchpad-button
            // host slot; same slot the DualSense Mute uses below). nil/false on
            // any pad without an Xbox Share button, so the OR is additive.
            (xboxShareButton(of: pad)?.isPressed == true, StreamProtocol.MISC_FLAG)
        ]
        var buttons: Int32 = 0
        for (pressed, flag) in mapping where pressed { buttons |= flag }

        // DualSense Options / Create / PS / Mute come from the raw-HID
        // side-channel (GameController doesn't deliver them). The GC-mapped
        // buttonMenu/buttonOptions/buttonHome above stay false on a DualSense,
        // so this OR is purely additive (and the same flags work for Xbox via
        // GameController). Mapped to the host's semantics: Options → Start,
        // Create/Share → Back, PS → Guide, Mute → misc.
        if pad is GCDualSenseGamepad {
            let hid = dualSenseButtons(pad: pad)
            if hid.options { buttons |= StreamProtocol.PLAY_FLAG }
            if hid.create { buttons |= StreamProtocol.BACK_FLAG }
            if hid.ps { buttons |= StreamProtocol.SPECIAL_FLAG }
            if hid.mute { buttons |= StreamProtocol.MISC_FLAG }
        }
        return buttons
    }

    // MARK: - Focus loss

    /// The all-zero analog state a removal and a focus-loss release both send.
    static let neutralControllerAnalog = InputCore.neutral

    /// Release every pad when focus leaves ordinary playback; Mini Player keeps its controller ownership.
    func neutralizeControllers() {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        controllerOwnershipSuspended = true
        publishInputSnapshot(focused: false)
        inputCore.clearChords()
        releaseControllerTouches()
        suspendControllerMouse()
        for state in attachedControllers.values {
            ControllerMotion.shared.setInputEnabled(false, slot: state.slot)
        }
        let slots = Set(attachedControllers.values.map(\.slot) + attachedHIDControllers.values.map(\.slot)
            + Array(controllerButtons.keys))
        for slot in slots.sorted()
            where controllerButtons[slot] != 0 || releases.held.contains(.controller(slot)) {
            releases.hold(.controller(slot))
            releases.release(.controller(slot))
            controllerButtons[slot] = 0
            controllerAnalogs[slot] = Self.neutralControllerAnalog
        }
        flushPendingReleases()
        if !slots.isEmpty {
            Diag.info("input: \(slots.count) controller release obligations on focus loss", "Stream")
        }
    }
}

extension InputForwarder {
    func installMappedController(_ state: AttachedController, token: UUID) {
        guard let controller = state.controller,
              let (reader, configuration) = controllerLayouts?.configure(state) else { return }
        let id = ObjectIdentifier(controller)
        let slot = state.slot
        let routesHID = state.retainedHID
        let mapsGameInput = configuration.plan != nil
        ControllerStreamHandlers.install(controller: controller, input: reader.input, queue: controllerCaptureQueue,
            mapsGameInput: mapsGameInput, shortcutElements: reader.shortcutElements(configuration),
            read: reader.sample) { @Sendable [core = inputCore] sample, now in
                if routesHID {
                    DualSenseRouting.shared.gc(controller: id, buttons: sample.buttons, at: now)
                }
                let supplement = routesHID ? MacControllerLayouts.centerButtons(for: id) : nil
                InputTimingContext.begin(source: .controller, timestamp: now)
                defer { InputTimingContext.end() }
                core.withLock {
                    guard let registered = core.controllers[id], registered.token == token,
                          now >= registered.registeredAt else { return }
                    let game = mapsGameInput ? sample : reader.systemSample()
                    core.controllers[id] = InputCore.ControllerSample(slot: slot, token: token,
                        registeredAt: registered.registeredAt, buttons: Int32(bitPattern: game.buttons),
                        analog: game.gamepadAnalog, extras: sample.extras)
                    core.receive(slot: slot, buttons: Int32(bitPattern: game.buttons), analog: game.gamepadAnalog,
                                 capturedAt: now, extras: sample.extras, physicalSample: sample,
                                 rawSupplement: supplement.map { (Int32(bitPattern: $0), Int32(bitPattern: $0)) })
                    if let touch = reader.touchSample(clicked: sample.buttons & ControllerMappedButton.touchpad.rawValue != 0) {
                        core.forwardTouchpad(slot: slot, primary: (touch.primaryX, touch.primaryY),
                            secondary: (touch.secondaryX, touch.secondaryY), clicked: touch.clicked, now: now)
                    }
                    core.retainMouseTiming(slot: slot)
                }
            }
    }
}
