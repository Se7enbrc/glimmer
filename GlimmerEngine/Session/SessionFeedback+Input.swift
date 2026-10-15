// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension SessionFeedback {
    package static func input(_ input: StreamInput, attempt: UUID) -> SessionFeedback {
        var feedback = SessionFeedback()
        feedback.activated = { _ in input.enqueueActivation(true, attempt: attempt) }
        feedback.deactivated = { input.enqueueActivation(false, attempt: attempt) }
        feedback.rumble = { input.feedback(slot: $0, .rumble(lowFrequency: $1, highFrequency: $2), attempt: attempt) }
        feedback.triggers = { input.feedback(slot: $0, .triggerRumble(left: $1, right: $2), attempt: attempt) }
        feedback.rgb = { input.feedback(slot: $0, .rgbLED(red: $1, green: $2, blue: $3), attempt: attempt) }
        feedback.player = { input.feedback(slot: $0, .playerLEDs(solid: $1, flashing: $2), attempt: attempt) }
        feedback.motion = { input.feedback(slot: $0, .motion(type: $1, reportRateHz: $2), attempt: attempt) }
        return feedback
    }
}
