// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

extension InputForwarder {
    struct AttachedHIDController {
        let slot: UInt8
        let device: HIDGamepadDevice
        let arrival: ControllerArrival
    }

    func setupHIDGamepads() {
        let manager = HIDGamepadManager.shared
        manager.onAttach = { [weak self] pad in self?.attachHID(pad) }
        manager.onDetach = { [weak self] pad in self?.detachHID(pad) }
        manager.retain()
        for pad in manager.devices.values { attachHID(pad) }
    }

    func attachHID(_ pad: HIDGamepadDevice) {
        guard attachedHIDControllers[pad.id] == nil else { return }
        guard let slot = inputCore.reserveControllerSlot() else {
            Diag.notice("HID attach refused: all 16 slots occupied (\(pad.name))", "Controller")
            return
        }
        publishInputSnapshot()
        registerNintendoController(slot: slot, type: NintendoControllerType.identify(pad))
        var caps = ControllerBattery.shared.register(slot: slot, hid: pad)
        if pad.mapping.hasAnalogTriggers { caps |= UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) }
        if pad.rumble.available { caps |= UInt16(StreamProtocol.LI_CCAP_RUMBLE) }
        // Generic HID has no standard player LEDs, motion or touchpad surface; those remain GameController-only.
        let arrival = ControllerArrival(type: pad.mapping.controllerType,
                                        supportedButtons: pad.mapping.supportedButtons, caps: caps)
        attachedHIDControllers[pad.id] = AttachedHIDController(slot: slot, device: pad, arrival: arrival)
        if isReady { sendArrival(slot: slot, arrival) }
        let token = UUID()
        inputCore.withLock { inputCore.hidRegistrations[slot] = token }
        pad.capture.setHandler { [inputCore] buttons, analog, timestamp in
            inputCore.receiveHID(slot: slot, token: token, buttons: buttons, analog: analog, capturedAt: timestamp)
        }
        HIDGamepadManager.shared.register(slot: slot, pad: pad)
        if isReady { pushHID(pad) }
    }

    func pushHID(_ pad: HIDGamepadDevice) {
        guard let attached = attachedHIDControllers[pad.id] else { return }
        pushHID(slot: attached.slot, state: pad.state) { [weak pad] in
            pad?.state
        }
    }

    /// The pad's decoded state as values; `readState` re-reads it for the quit-chord dwell.
    func pushHID(slot: UInt8, state: (buttons: Int32, analog: GamepadAnalog),
                 readState: @escaping @MainActor () -> (buttons: Int32, analog: GamepadAnalog)?) {
        guard forwardsControllerEvents else { return }
        publishInputSnapshot()
        let result = inputCore.receive(slot: slot, buttons: state.buttons, analog: state.analog)
        if result == .chord { armQuitChordDwell(slot: slot, readState: readState) }
    }

    func detachHID(_ pad: HIDGamepadDevice, sendFinal: Bool = true) {
        guard let attached = attachedHIDControllers.removeValue(forKey: pad.id) else { return }
        inputCore.withLock {
            inputCore.hidRegistrations[attached.slot] = nil
            inputCore.current[attached.slot] = nil
            inputCore.updateChord(slot: attached.slot, held: false, invalidate: true)
        }
        pad.capture.setHandler(nil)
        nintendoControllerTypes[attached.slot] = nil
        resetControllerMouse(slot: attached.slot)
        gamepadMask &= ~(UInt16(1) << attached.slot)
        HIDGamepadManager.shared.unregister(slot: attached.slot)
        ControllerBattery.shared.unregister(slot: attached.slot)
        pad.rumble.close()
        if quitChordDwellSlot == attached.slot { cancelQuitChordDwell(reason: "HID pad detached") }
        if isReady && sendFinal { sendControllerRemoval(slot: attached.slot) }
    }

    func releaseHIDControllers() {
        for state in Array(attachedHIDControllers.values) { detachHID(state.device, sendFinal: false) }
        let manager = HIDGamepadManager.shared
        manager.onAttach = nil
        manager.onDetach = nil
        manager.release()
    }
}
