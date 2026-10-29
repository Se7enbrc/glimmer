// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine

extension ControllerMappedButton {
    var layoutName: String {
        switch self {
        case .up: "D-pad up"
        case .down: "D-pad down"
        case .left: "D-pad left"
        case .right: "D-pad right"
        case .menu: "Menu"
        case .options: "Options"
        case .leftStick: "Left stick button"
        case .rightStick: "Right stick button"
        case .leftShoulder: "Left shoulder"
        case .rightShoulder: "Right shoulder"
        case .home: "Home"
        case .a: "A · Bottom"
        case .b: "B · Right"
        case .x: "X · Left"
        case .y: "Y · Top"
        case .paddle1: "Paddle 1"
        case .paddle2: "Paddle 2"
        case .paddle3: "Paddle 3"
        case .paddle4: "Paddle 4"
        case .touchpad: "Touchpad button"
        case .share: "Share"
        }
    }

    var layoutSymbol: String {
        switch self {
        case .a: "a.circle"
        case .b: "b.circle"
        case .x: "x.circle"
        case .y: "y.circle"
        case .up: "dpad.up.filled"
        case .down: "dpad.down.filled"
        case .left: "dpad.left.filled"
        case .right: "dpad.right.filled"
        case .menu: "line.3.horizontal.circle"
        case .options: "rectangle.on.rectangle.circle"
        case .home: "house.circle"
        case .leftShoulder: "l1.button.roundedbottom.horizontal"
        case .rightShoulder: "r1.button.roundedbottom.horizontal"
        case .leftStick: "l.joystick.press.down"
        case .rightStick: "r.joystick.press.down"
        case .paddle1: "1.circle"
        case .paddle2: "2.circle"
        case .paddle3: "3.circle"
        case .paddle4: "4.circle"
        case .touchpad: "rectangle.and.hand.point.up.left"
        case .share: "square.and.arrow.up"
        }
    }
}

extension ControllerMappedAxis {
    var layoutName: String {
        switch self {
        case .leftX: "Left stick horizontal"
        case .leftY: "Left stick vertical"
        case .rightX: "Right stick horizontal"
        case .rightY: "Right stick vertical"
        }
    }

    func directionName(positive: Bool) -> String {
        switch self {
        case .leftX: positive ? "Left stick right" : "Left stick left"
        case .leftY: positive ? "Left stick up" : "Left stick down"
        case .rightX: positive ? "Right stick right" : "Right stick left"
        case .rightY: positive ? "Right stick up" : "Right stick down"
        }
    }
}

extension ControllerLayoutSource {
    var identityName: String {
        switch self {
        case .button(let button): "button:\(button.rawValue)"
        case .extra(let name): "extra:\(name)"
        case .trigger(let trigger): "trigger:\(trigger.rawValue)"
        case .axis(let axis): "axis:\(axis.rawValue)"
        case .direction(let axis, let positive): "direction:\(axis.rawValue):\(positive ? 1 : 0)"
        }
    }

    var layoutName: String {
        switch self {
        case .button(let button): button.layoutName
        case .extra(let name): name
        case .trigger(let trigger): trigger == .left ? "Left trigger" : "Right trigger"
        case .axis(let axis): axis.layoutName
        case .direction(let axis, let positive): axis.directionName(positive: positive)
        }
    }

    var layoutSymbol: String {
        switch self {
        case .button(let button): button.layoutSymbol
        case .trigger(let trigger): trigger == .left ? "l2.button.roundedtop.horizontal" : "r2.button.roundedtop.horizontal"
        case .axis(let axis), .direction(let axis, _):
            axis == .leftX || axis == .leftY ? "l.joystick" : "r.joystick"
        case .extra: "button.horizontal"
        }
    }
}

extension ControllerLayoutDestination {
    var layoutName: String {
        switch self {
        case .button(let button): button.layoutName
        case .trigger(let trigger): trigger == .left ? "Left trigger" : "Right trigger"
        case .axis(let axis, let inverted): inverted ? "\(axis.layoutName) (reversed)" : axis.layoutName
        case .direction(let axis, let positive): axis.directionName(positive: positive)
        case .disabled: "No action"
        }
    }

    static func choices(for source: ControllerLayoutSource) -> [Self] {
        if case .axis = source {
            return ControllerMappedAxis.allCases.flatMap { [Self.axis($0, inverted: false), .axis($0, inverted: true)] }
                + [.disabled]
        }
        return ControllerMappedButton.allCases.map { .button($0) }
            + ControllerMappedTrigger.allCases.map { .trigger($0) }
            + ControllerMappedAxis.allCases.flatMap { [Self.direction($0, positive: false), .direction($0, positive: true)] }
            + [.disabled]
    }
}
