// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

enum TouchElement: String, CaseIterable, Codable, Sendable, Identifiable {
    case leftStick, rightStick, dpad, a, b, x, y
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStickButton, rightStickButton, options, menu

    var id: Self { self }
    var name: String { Self.names[self] ?? rawValue }
    var title: String { Self.titles[self] ?? name }
    var button: ControllerButtons { Self.buttons[self] ?? [] }
    var isStick: Bool { self == .leftStick || self == .rightStick }
    var isTrigger: Bool { self == .leftTrigger || self == .rightTrigger }
    var isLeft: Bool {
        [.leftStick, .dpad, .leftShoulder, .leftTrigger, .leftStickButton, .options].contains(self)
    }

    var mouseSources: Set<ControllerLayoutSource> {
        switch self {
        case .leftStick: return ControllerMouseMapping.stick(right: false)
        case .rightStick: return ControllerMouseMapping.stick(right: true)
        case .leftTrigger: return [.trigger(.left)]
        case .rightTrigger: return [.trigger(.right)]
        default:
            return Set(ControllerMappedButton.allCases.filter { UInt32(bitPattern: button.rawValue) & $0.rawValue != 0 }
                .map { ControllerLayoutSource.button($0) })
        }
    }

    private static let names: [Self: String] = [
        .leftStick: "Left stick", .rightStick: "Right stick", .dpad: "Directional pad",
        .a: "A", .b: "B", .x: "X", .y: "Y", .leftShoulder: "Left shoulder", .rightShoulder: "Right shoulder",
        .leftTrigger: "Left trigger", .rightTrigger: "Right trigger", .leftStickButton: "Left stick click",
        .rightStickButton: "Right stick click", .options: "Options", .menu: "Menu"
    ]
    private static let titles: [Self: String] = [
        .leftShoulder: "L1", .rightShoulder: "R1", .leftTrigger: "L2", .rightTrigger: "R2",
        .leftStickButton: "L3", .rightStickButton: "R3"
    ]
    private static let buttons: [Self: ControllerButtons] = [
        .a: .a, .b: .b, .x: .x, .y: .y, .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftStickButton: .leftStick, .rightStickButton: .rightStick, .options: .options, .menu: .menu
    ]

    static var descriptor: ControllerDescriptor {
        let buttons = Self.buttons.values.reduce(ControllerButtons()) { $0.union($1) }
        return ControllerDescriptor(kind: .unknown,
            supportedButtons: buttons.union([.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
            capabilities: [.analogTriggers])
    }

    func size(expanded: Bool) -> CGSize {
        if isStick { return CGSize(width: expanded ? 112 : 96, height: expanded ? 112 : 96) }
        if self == .dpad { return CGSize(width: 132, height: 132) }
        if isTrigger { return CGSize(width: 84, height: 44) }
        if self == .leftShoulder || self == .rightShoulder { return CGSize(width: 64, height: 44) }
        let side: CGFloat = [.a, .b, .x, .y].contains(self) ? (expanded ? 52 : 46) : 44
        return CGSize(width: side, height: side)
    }
}
