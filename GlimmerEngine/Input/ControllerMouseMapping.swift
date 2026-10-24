// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// Selects pointer/scroll sticks and clicks without changing the shared curve or polling cadence.
/// Handed trigger clicks use the shared half-travel threshold (128 of 255), like controller chords.
public enum ControllerMouseMapping: Sendable, Equatable {
    /// Legacy Mac mapping: left pointer, right scroll; A/B/X and L1/R1 click left/right/middle/back/forward.
    case standard
    /// Left pointer, right scroll; L2 clicks primary and L1 clicks secondary.
    case leftStick
    /// Right pointer, left scroll; R2 clicks primary and R1 clicks secondary.
    case rightStick

    func clicksChanged(buttons: Int32, previous: Int32, analog: GamepadAnalog, oldAnalog: GamepadAnalog) -> Bool {
        switch self {
        case .standard: (buttons ^ previous) & InputCore.controllerMouseClickFlags != 0
        case .leftStick:
            (buttons ^ previous) & StreamProtocol.LB_FLAG != 0
                || triggerPressed(analog.leftTrigger) != triggerPressed(oldAnalog.leftTrigger)
        case .rightStick:
            (buttons ^ previous) & StreamProtocol.RB_FLAG != 0
                || triggerPressed(analog.rightTrigger) != triggerPressed(oldAnalog.rightTrigger)
        }
    }

    func clicks(buttons: Int32, analog: GamepadAnalog) -> Set<Int32> {
        switch self {
        case .standard:
            Set(InputCore.controllerMouseClicks.compactMap { buttons & $0.0 != 0 ? $0.1 : nil })
        case .leftStick:
            handedClicks(trigger: analog.leftTrigger, shoulder: buttons & StreamProtocol.LB_FLAG != 0)
        case .rightStick:
            handedClicks(trigger: analog.rightTrigger, shoulder: buttons & StreamProtocol.RB_FLAG != 0)
        }
    }

    private func triggerPressed(_ value: UInt8) -> Bool {
        value >= ControllerInputSample.triggerPressThreshold
    }

    private func handedClicks(trigger: UInt8, shoulder: Bool) -> Set<Int32> {
        var result: Set<Int32> = []
        if triggerPressed(trigger) { result.insert(StreamProtocol.BUTTON_LEFT) }
        if shoulder { result.insert(StreamProtocol.BUTTON_RIGHT) }
        return result
    }
}
