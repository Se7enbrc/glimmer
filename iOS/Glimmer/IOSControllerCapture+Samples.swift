// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

extension IOSControllerCapture {
    nonisolated static func sample(_ pad: GCExtendedGamepad) -> ControllerInputSample {
        let buttons = elements(pad).reduce(into: ControllerButtons()) { result, pair in
            if pair.0.isPressed { result.insert(pair.1) }
        }
        let touch = touchpad(pad).map {
            ControllerTouchpadSample(primaryX: $0.0.xAxis.value, primaryY: $0.0.yAxis.value,
                                     secondaryX: $0.1.xAxis.value, secondaryY: $0.1.yAxis.value,
                                     clicked: $0.2.isPressed)
        }
        return ControllerInputSample(buttons: buttons,
            leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value,
            leftStickX: pad.leftThumbstick.xAxis.value, leftStickY: pad.leftThumbstick.yAxis.value,
            rightStickX: pad.rightThumbstick.xAxis.value, rightStickY: pad.rightThumbstick.yAxis.value,
            touchpad: touch)
    }

    static func descriptor(_ controller: GCController, pad: GCExtendedGamepad) -> ControllerDescriptor {
        let buttons = elements(pad).reduce(into: ControllerButtons()) { $0.insert($1.1) }
        var caps: ControllerDescriptor.Capabilities = [.analogTriggers]
        if touchpad(pad) != nil { caps.insert(.touchpad) }
        let kind: ControllerDescriptor.Kind = pad is GCXboxGamepad ? .xbox
            : pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? .playStation : glyphKind(pad)
        return ControllerDescriptor(kind: kind, supportedButtons: buttons, capabilities: caps)
    }

    static func glyphKind(_ pad: GCExtendedGamepad) -> ControllerDescriptor.Kind {
        let symbols = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY].map {
            $0.unmappedSfSymbolsName?.replacingOccurrences(of: ".fill", with: "")
        }
        let playStation = ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"]
        return symbols == playStation.map(Optional.some) ? .playStation : .unknown
    }

    private nonisolated static func elements(
        _ pad: GCExtendedGamepad
    ) -> [(GCControllerButtonInput, ControllerButtons)] {
        var values: [(GCControllerButtonInput?, ControllerButtons)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown),
            (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftThumbstickButton, .leftStick), (pad.rightThumbstickButton, .rightStick),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options), (pad.buttonHome, .home)
        ]
        if let touch = touchpad(pad) { values.append((touch.2, .touchpad)) }
        if let xbox = pad as? GCXboxGamepad { values.append((xbox.buttonShare, .share)) }
        return values.compactMap { button, flag in button.map { ($0, flag) } }
    }

    private nonisolated static func touchpad(_ pad: GCExtendedGamepad)
        -> (GCControllerDirectionPad, GCControllerDirectionPad, GCControllerButtonInput)? {
        if let dual = pad as? GCDualSenseGamepad {
            return (dual.touchpadPrimary, dual.touchpadSecondary, dual.touchpadButton)
        }
        if let dual = pad as? GCDualShockGamepad {
            return (dual.touchpadPrimary, dual.touchpadSecondary, dual.touchpadButton)
        }
        return nil
    }
}
