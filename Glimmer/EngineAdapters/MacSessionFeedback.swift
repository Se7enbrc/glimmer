// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

extension SessionFeedback {
    static func mac() -> SessionFeedback {
        var result = SessionFeedback()
        result.activated = { backend in
            ControllerHaptics.shared.streamActivated()
            if let backend { ControllerMotion.shared.streamActivated(backend: backend) }
        }
        result.deactivated = {
            DispatchQueue.main.async { ControllerHaptics.shared.stopAll(reason: "stream teardown") }
            ControllerMotion.shared.stopAll(reason: "stream teardown")
        }
        result.rumble = { ControllerHaptics.shared.setRumble(controllerNumber: $0, lowFreq: $1, highFreq: $2) }
        result.triggers = { ControllerHaptics.shared.setTriggerRumble(controllerNumber: $0, left: $1, right: $2) }
        result.rgb = { ControllerHaptics.shared.setLight(controllerNumber: $0, red: $1, green: $2, blue: $3) }
        result.player = { ControllerHaptics.shared.setPlayerLEDs(controllerNumber: $0, solid: $1, flashing: $2) }
        result.motion = { ControllerMotion.shared.setMotionEventState(controllerNumber: $0, motionType: $1, reportRateHz: $2) }
        result.adaptive = { slot, flags, typeLeft, typeRight, left, right in
            guard let device = DualSenseRouting.shared.device(slot: slot) else { return }
            DualSenseHID.shared.setAdaptiveTriggers(device: device, eventFlags: flags,
                typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
        }
        return result
    }
}
