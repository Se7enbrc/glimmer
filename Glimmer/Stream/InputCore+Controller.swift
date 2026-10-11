// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController

extension InputForwarder {
    nonisolated static func controllerAnalog(_ pad: GCExtendedGamepad) -> GamepadAnalog {
        func trigger(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        func axis(_ value: Float) -> Int16 { Int16(max(-32768, min(32767, (value * 32767).rounded()))) }
        return GamepadAnalog(leftTrigger: trigger(pad.leftTrigger.value), rightTrigger: trigger(pad.rightTrigger.value),
                             leftStickX: axis(pad.leftThumbstick.xAxis.value),
                             leftStickY: axis(pad.leftThumbstick.yAxis.value),
                             rightStickX: axis(pad.rightThumbstick.xAxis.value),
                             rightStickY: axis(pad.rightThumbstick.yAxis.value))
    }

    nonisolated static func controllerChordButtons(_ pad: GCExtendedGamepad, buttons: Int32) -> Int32 {
        var buttons = buttons & ~StreamProtocol.MISC_FLAG
        let hid = dualSenseButtons(pad: pad)
        let extras: [(Bool, Int32)] = [(hid.l1, StreamProtocol.LB_FLAG), (hid.r1, StreamProtocol.RB_FLAG),
                                      (hid.options, StreamProtocol.PLAY_FLAG), (hid.create, StreamProtocol.BACK_FLAG),
                                      (hid.ps, StreamProtocol.SPECIAL_FLAG), (hid.mute, StreamProtocol.MISC_FLAG)]
        for (held, flag) in extras where held { buttons |= flag }
        return buttons
    }
}

extension InputCore {
    func registerController(id: ObjectIdentifier, slot: UInt8, buttons: Int32, analog: GamepadAnalog) {
        withLock { controllers[id] = ControllerSample(slot: slot, buttons: buttons, analog: analog) }
    }

    func removeController(id: ObjectIdentifier) {
        withLock {
            guard let sample = controllers.removeValue(forKey: id) else { return }
            current[sample.slot] = nil
            chordSlots.remove(sample.slot)
        }
    }

    func receiveController(id: ObjectIdentifier, buttons: Int32, analog: GamepadAnalog,
                           chordButtons: Int32, capturedAt: TimeInterval) {
        withLock {
            guard let sample = controllers[id] else { return }
            InputDeliverStamp.shared.stamp(slot: Int(sample.slot), nanos: DispatchTime.now().uptimeNanoseconds)
            defer { _ = InputDeliverStamp.shared.take(slot: Int(sample.slot)) }
            controllers[id] = ControllerSample(slot: sample.slot, buttons: buttons, analog: analog)
            receive(slot: sample.slot, buttons: buttons, analog: analog,
                    chordButtons: chordButtons, capturedAt: capturedAt)
        }
    }

    func receiveHID(slot: UInt8, token: UUID, buttons: Int32, analog: GamepadAnalog, capturedAt: TimeInterval) {
        withLock {
            guard hidRegistrations[slot] == token else { return }
            receive(slot: slot, buttons: buttons, analog: analog, capturedAt: capturedAt)
        }
    }

    func receiveCenterButtons(device: DualSenseDeviceKey, capturedAt: TimeInterval? = nil) {
        withLock {
            if let capturedAt, capturedAt < snapshot.acceptEventsAfter { return }
            guard let id = DualSenseRouting.shared.controller(for: device), let sample = controllers[id] else { return }
            let hid = DualSenseHID.shared.state(for: id)?.buttons ?? DualSenseExtraButtons()
            let centerMask = StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG
                | StreamProtocol.SPECIAL_FLAG | StreamProtocol.MISC_FLAG
            var buttons = sample.buttons & ~centerMask
            let extras: [(Bool, Int32)] = [
                (hid.options, StreamProtocol.PLAY_FLAG), (hid.create, StreamProtocol.BACK_FLAG),
                                          (hid.ps, StreamProtocol.SPECIAL_FLAG), (hid.mute, StreamProtocol.MISC_FLAG)]
            for (pressed, flag) in extras where pressed { buttons |= flag }
            var chord = buttons
            if hid.l1 { chord |= StreamProtocol.LB_FLAG }
            if hid.r1 { chord |= StreamProtocol.RB_FLAG }
            receive(slot: sample.slot, buttons: buttons, analog: sample.analog,
                    chordButtons: chord, capturedAt: capturedAt)
            if snapshot.ready, snapshot.focused, !chordSlots.contains(sample.slot), hid.options || hid.create {
                onCenterPartial?(sample.slot)
            }
        }
    }
}
