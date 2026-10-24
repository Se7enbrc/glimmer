// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import GameController

extension InputForwarder {
    nonisolated static func controllerAnalog(_ pad: GCExtendedGamepad) -> GamepadAnalog {
        ControllerInputSample.normalizedAnalog(((pad.leftTrigger.value, pad.rightTrigger.value),
            (pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value),
            (pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)))
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
    func receiveCenterButtons(
        device: DualSenseDeviceKey, capturedAt: TimeInterval? = nil,
        controller: (DualSenseDeviceKey) -> (id: ObjectIdentifier, token: UUID)? = {
            DualSenseRouting.shared.inputRegistration(for: $0)
        },
        buttons: (ObjectIdentifier) -> DualSenseExtraButtons = {
            DualSenseHID.shared.state(for: $0)?.buttons ?? DualSenseExtraButtons()
        }
    ) {
        guard let registration = controller(device) else { return }
        let hid = buttons(registration.id)
        var center: Int32 = 0
        if hid.options { center |= StreamProtocol.PLAY_FLAG }
        if hid.create { center |= StreamProtocol.BACK_FLAG }
        if hid.ps { center |= StreamProtocol.SPECIAL_FLAG }
        if hid.mute { center |= StreamProtocol.MISC_FLAG }
        let shoulders = (hid.l1 ? StreamProtocol.LB_FLAG : 0) | (hid.r1 ? StreamProtocol.RB_FLAG : 0)
        receiveCenterButtons(id: registration.id, token: registration.token, buttons: center, shoulders: shoulders, capturedAt: capturedAt)
    }
}
