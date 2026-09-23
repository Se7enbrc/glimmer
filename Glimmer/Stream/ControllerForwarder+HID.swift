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
        manager.onReport = { [weak self] pad in self?.pushHID(pad) }
        manager.retain()
        for pad in manager.devices.values { attachHID(pad) }
    }

    func attachHID(_ pad: HIDGamepadDevice) {
        guard attachedHIDControllers[pad.id] == nil else { return }
        guard let slot = (0..<UInt8(16)).first(where: { gamepadMask & (1 << $0) == 0 }) else {
            Diag.notice("HID attach refused: all 16 slots occupied (\(pad.name))", "Controller")
            return
        }
        gamepadMask |= UInt16(1) << slot
        var caps = ControllerBattery.shared.register(slot: slot, hid: pad)
        if pad.mapping.hasAnalogTriggers { caps |= UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) }
        if pad.rumble.available { caps |= UInt16(StreamProtocol.LI_CCAP_RUMBLE) }
        // Generic HID has no standard player LEDs, motion or touchpad surface; those remain GameController-only.
        let arrival = ControllerArrival(type: pad.mapping.controllerType,
                                        supportedButtons: pad.mapping.supportedButtons, caps: caps)
        attachedHIDControllers[pad.id] = AttachedHIDController(slot: slot, device: pad, arrival: arrival)
        HIDGamepadManager.shared.register(slot: slot, pad: pad)
        if isReady { sendArrival(slot: slot, arrival); pushHID(pad) }
    }

    func pushHID(_ pad: HIDGamepadDevice) {
        guard isReady, let attached = attachedHIDControllers[pad.id] else { return }
        let state = pad.state
        if matchesControllerQuitChord(buttons: state.buttons, leftTrigger: state.analog.leftTrigger,
                                      rightTrigger: state.analog.rightTrigger) {
            armQuitChordDwell(slot: attached.slot) { [weak pad] in
                guard let pad else { return nil }
                return pad.state
            }
            return
        }
        if quitChordDwellSlot == attached.slot { cancelQuitChordDwell(reason: "HID chord released") }
        let result = backend?.sendMultiController(num: Int16(attached.slot), mask: Int16(bitPattern: gamepadMask),
                                                  buttons: state.buttons, analog: state.analog) ?? -2
        record("LiSendMultiControllerEvent(HID)", result)
    }

    func detachHID(_ pad: HIDGamepadDevice, sendFinal: Bool = true) {
        guard let attached = attachedHIDControllers.removeValue(forKey: pad.id) else { return }
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
        manager.onReport = nil
        manager.release()
    }
}
