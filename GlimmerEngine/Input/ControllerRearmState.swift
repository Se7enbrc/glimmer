// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// Independently rearms GC-normalized controls after native UI ownership; adds no deadzone or tuning.
struct ControllerRearmState {
    var lastButtons: Int32 = 0
    var blockedButtons: Int32 = 0
    var lastAnalog = InputCore.neutral
    var blockedAxes: UInt8 = 0
    var lastTouch: ControllerTouchpadSample?
    var blockedContacts: UInt8 = 0
    var blockedTouchClick = false

    mutating func suppressHeld() {
        blockedButtons = lastButtons
        blockedAxes = 0
        for (index, value) in axes(lastAnalog).enumerated() where value != 0 { blockedAxes |= 1 << index }
        blockedContacts = Self.contacts(lastTouch)
        blockedTouchClick = lastTouch?.clicked == true
    }

    mutating func filter(buttons: Int32, analog: GamepadAnalog, touch: ControllerTouchpadSample?)
        -> (buttons: Int32, analog: GamepadAnalog, touch: ControllerTouchpadSample?) {
        lastButtons = buttons
        lastAnalog = analog
        lastTouch = touch
        blockedButtons &= buttons
        var values = axes(analog)
        for index in values.indices {
            if values[index] == 0 { blockedAxes &= ~(1 << index) }
            if blockedAxes & (1 << index) != 0 { values[index] = 0 }
        }
        blockedContacts &= Self.contacts(touch)
        if touch?.clicked != true { blockedTouchClick = false }
        var acceptedTouch = touch
        if blockedContacts & 1 != 0 { acceptedTouch?.primaryX = 0; acceptedTouch?.primaryY = 0 }
        if blockedContacts & 2 != 0 { acceptedTouch?.secondaryX = 0; acceptedTouch?.secondaryY = 0 }
        if blockedTouchClick { acceptedTouch?.clicked = false }
        return (buttons & ~blockedButtons,
            GamepadAnalog(leftTrigger: UInt8(values[0]), rightTrigger: UInt8(values[1]),
                leftStickX: values[2], leftStickY: values[3], rightStickX: values[4], rightStickY: values[5]),
            acceptedTouch)
    }

    private func axes(_ analog: GamepadAnalog) -> [Int16] {
        [Int16(analog.leftTrigger), Int16(analog.rightTrigger), analog.leftStickX, analog.leftStickY,
         analog.rightStickX, analog.rightStickY]
    }

    private static func contacts(_ touch: ControllerTouchpadSample?) -> UInt8 {
        guard let touch else { return 0 }
        return (touch.primaryX != 0 || touch.primaryY != 0 ? 1 : 0)
            | (touch.secondaryX != 0 || touch.secondaryY != 0 ? 2 : 0)
    }
}
