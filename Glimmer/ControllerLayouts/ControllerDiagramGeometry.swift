// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

enum ControllerDiagramFamily: String, CaseIterable {
    case xbox, xboxElite, dualSense, dualSenseEdge, dualShock, backbone, generic

    static func identify(category: String, name: String, controls: [ControllerLayoutControl]) -> Self {
        let description = (category + " " + name).lowercased()
        if description.contains("backbone") { return .backbone }
        if description.contains("dualsense") && description.contains("edge") { return .dualSenseEdge }
        if description.contains("xbox") && description.contains("elite") { return .xboxElite }
        if category == "PS5 Controller" { return .dualSense }
        if category == "PS4 Controller" { return .dualShock }
        if description.contains("dualsense") { return .dualSense }
        if description.contains("dualshock") { return .dualShock }
        if description.contains("xbox") { return .xbox }
        if controls.contains(where: { $0.id == .button(.touchpad) }) { return .dualSense }
        return .generic
    }

    func symbol(for control: ControllerLayoutControl) -> String {
        guard control.symbol == control.id.layoutSymbol else { return control.symbol }
        let playStation: [ControllerLayoutSource: String] = [
            .button(.a): "xmark", .button(.b): "circle", .button(.x): "square", .button(.y): "triangle",
            .button(.home): "playstation.logo"]
        let xbox: [ControllerLayoutSource: String] = [
            .button(.home): "xbox.logo", .trigger(.left): "lt.button.roundedtop.horizontal",
            .trigger(.right): "rt.button.roundedtop.horizontal", .button(.leftShoulder): "lb.button.roundedbottom.horizontal",
            .button(.rightShoulder): "rb.button.roundedbottom.horizontal"]
        if isPlayStation { return playStation[control.id] ?? control.symbol }
        if isXbox { return xbox[control.id] ?? control.symbol }
        return control.symbol
    }

    var isDualSense: Bool { self == .dualSense || self == .dualSenseEdge }
    var isPlayStation: Bool { isDualSense || self == .dualShock }
    var isXbox: Bool { self == .xbox || self == .xboxElite }
    var darkShell: Bool { isXbox || self == .dualShock || self == .backbone }
    var stickDiameter: CGFloat { self == .backbone ? 40 : 68 }
    var dpadDiameter: CGFloat { self == .backbone ? 42 : 66 }

    var leftStick: CGPoint {
        switch self {
        case .xbox, .xboxElite: CGPoint(x: 104, y: 119)
        case .backbone: CGPoint(x: 55, y: 112)
        case .dualShock: CGPoint(x: 173, y: 208)
        default: CGPoint(x: 175, y: 202)
        }
    }

    var rightStick: CGPoint {
        switch self {
        case .backbone: CGPoint(x: 425, y: 175)
        case .dualShock: CGPoint(x: 307, y: 208)
        case .xbox, .xboxElite: CGPoint(x: 302, y: 203)
        default: CGPoint(x: 305, y: 202)
        }
    }

    var dpad: CGPoint {
        switch self {
        case .xbox, .xboxElite: CGPoint(x: 176, y: 203)
        case .backbone: CGPoint(x: 55, y: 175)
        default: CGPoint(x: 100, y: 118)
        }
    }
    var faces: CGPoint { self == .backbone ? CGPoint(x: 425, y: 112) : CGPoint(x: 380, y: 118) }
    var faceSpacing: CGFloat { self == .backbone ? 21 : 29 }
    var shoulderX: CGFloat { self == .backbone ? 55 : isXbox ? 113 : 102 }
    var touchpad: CGRect {
        CGRect(x: 164, y: isDualSense ? 53 : 73, width: 152, height: isDualSense ? 82 : 64)
    }
}

struct ControllerDiagramPlacement {
    let point: CGPoint
    var width: CGFloat = 30
    var height: CGFloat = 30
    var rear = false

    var bounds: CGRect {
        CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }
}

enum ControllerDiagramGeometry {
    static func placement(_ control: ControllerLayoutControl, family: ControllerDiagramFamily) -> ControllerDiagramPlacement? {
        if let position = control.position { return extra(position, family: family) }
        switch control.id {
        case .button(let button): return buttonPlacement(button, family: family)
        case .trigger(let trigger):
            return .init(point: CGPoint(x: trigger == .left ? family.shoulderX : 480 - family.shoulderX,
                                       y: family == .backbone ? 49 : 24),
                         width: family == .backbone ? 44 : 64, height: 25)
        default: return nil
        }
    }

    static func visiblePlacement(_ control: ControllerLayoutControl, family: ControllerDiagramFamily,
                                 rear: Bool) -> ControllerDiagramPlacement? {
        guard let placement = placement(control, family: family) else { return nil }
        let onBothSides: Bool
        switch control.id {
        case .trigger, .button(.leftShoulder), .button(.rightShoulder): onBothSides = true
        default: onBothSides = false
        }
        if rear && onBothSides {
            return .init(point: CGPoint(x: 480 - placement.point.x, y: placement.point.y),
                         width: placement.width, height: placement.height, rear: true)
        }
        return placement.rear == rear ? placement : nil
    }

    private static func buttonPlacement(_ button: ControllerMappedButton,
                                        family: ControllerDiagramFamily) -> ControllerDiagramPlacement? {
        let faces = family.faces
        let offset = family.faceSpacing
        let size: CGFloat = family == .backbone ? 20 : 29
        switch button {
        case .a: return .init(point: CGPoint(x: faces.x, y: faces.y + offset), width: size, height: size)
        case .b: return .init(point: CGPoint(x: faces.x + offset, y: faces.y), width: size, height: size)
        case .x: return .init(point: CGPoint(x: faces.x - offset, y: faces.y), width: size, height: size)
        case .y: return .init(point: CGPoint(x: faces.x, y: faces.y - offset), width: size, height: size)
        case .leftShoulder, .rightShoulder:
            return .init(point: CGPoint(x: button == .leftShoulder ? family.shoulderX : 480 - family.shoulderX,
                                       y: family == .backbone ? 70 : 49),
                         width: family == .backbone ? 54 : 78, height: 20)
        case .menu, .options:
            let x: CGFloat = family == .backbone ? 76 : family.isPlayStation ? 147 : 206
            return .init(point: CGPoint(x: button == .options ? x : 480 - x,
                                       y: family == .backbone ? 223 : family.isPlayStation ? 91 : 128),
                         width: family.isPlayStation ? 12 : 20, height: family.isPlayStation ? 24 : 20)
        case .home, .share: return centerButton(button, family: family)
        case .touchpad:
            return .init(point: CGPoint(x: family.touchpad.midX, y: family.touchpad.midY),
                         width: family.touchpad.width, height: family.touchpad.height)
        case .paddle1: return extra(.backRightPrimary, family: family)
        case .paddle2: return extra(.backLeftPrimary, family: family)
        case .paddle3: return extra(.backRightSecondary, family: family)
        case .paddle4: return extra(.backLeftSecondary, family: family)
        default: return nil
        }
    }

    private static func centerButton(_ button: ControllerMappedButton,
                                     family: ControllerDiagramFamily) -> ControllerDiagramPlacement {
        if family == .backbone {
            return .init(point: CGPoint(x: button == .home ? 438 : 42, y: 212), width: 19, height: 19)
        }
        if button == .home {
            return .init(point: CGPoint(x: 240, y: family.isPlayStation ? 198 : 86), width: 25, height: 25)
        }
        return .init(point: CGPoint(x: 240, y: family.isPlayStation ? 226 : 161),
                     width: family.isPlayStation ? 24 : 19, height: family.isPlayStation ? 9 : 19)
    }

    private static func extra(_ position: ControllerLayoutControl.Position,
                              family: ControllerDiagramFamily) -> ControllerDiagramPlacement {
        let outer: CGFloat = family == .backbone ? 55 : family.isDualSense ? 170 : 161
        let width: CGFloat = family.isDualSense ? 29 : 60
        let height: CGFloat = family.isDualSense ? 67 : 27
        switch position {
        case .backLeftPrimary: return .init(point: CGPoint(x: 480 - outer, y: 170), width: width, height: height, rear: true)
        case .backRightPrimary: return .init(point: CGPoint(x: outer, y: 170), width: width, height: height, rear: true)
        case .backLeftSecondary: return .init(point: CGPoint(x: 480 - outer + 10, y: 227), width: 29, height: 48, rear: true)
        case .backRightSecondary: return .init(point: CGPoint(x: outer - 10, y: 227), width: 29, height: 48, rear: true)
        case .topLeftInner: return .init(point: CGPoint(x: 188, y: 49), width: 26, height: 20)
        case .topRightInner: return .init(point: CGPoint(x: 292, y: 49), width: 26, height: 20)
        }
    }
}
