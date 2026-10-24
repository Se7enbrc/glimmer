// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

enum ControllerDiagramFamily: String, CaseIterable {
    case xbox, xboxElite, dualSense, dualSenseEdge, dualShock, backbone, backbonePlayStation, generic

    static func identify(category: String, name: String, controls: [ControllerLayoutControl]) -> Self {
        let description = (category + " " + name).lowercased()
        if description.contains("backbone") {
            return description.contains("playstation") ? .backbonePlayStation : .backbone
        }
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
            .button(.home): "playstation.logo", .button(.menu): "line.3.horizontal",
            .button(.options): "line.3.horizontal.decrease", .button(.share): "mic.slash"]
        let xbox: [ControllerLayoutSource: String] = [
            .button(.home): "xbox.logo", .trigger(.left): "lt.button.roundedtop.horizontal",
            .trigger(.right): "rt.button.roundedtop.horizontal", .button(.leftShoulder): "lb.button.roundedbottom.horizontal",
            .button(.rightShoulder): "rb.button.roundedbottom.horizontal"]
        if isBackbone {
            let buttons: [ControllerLayoutSource: String] = [.button(.options): "ellipsis",
                .button(.menu): "line.3.horizontal", .button(.share): "viewfinder", .button(.home): "house"]
            if let symbol = buttons[control.id] { return symbol }
            return self == .backbonePlayStation ? playStation[control.id] ?? control.symbol : control.symbol
        }
        if isPlayStation { return playStation[control.id] ?? control.symbol }
        if isXbox { return xbox[control.id] ?? control.symbol }
        return control.symbol
    }

    var isBackbone: Bool { self == .backbone || self == .backbonePlayStation }
    var isDualSense: Bool { self == .dualSense || self == .dualSenseEdge }
    var isPlayStation: Bool { isDualSense || self == .dualShock }
    var isXbox: Bool { self == .xbox || self == .xboxElite }
    var stickDiameter: CGFloat { isBackbone ? 40 : 68 }
    var dpadDiameter: CGFloat { isBackbone ? 42 : 66 }

    var leftStick: CGPoint {
        switch self {
        case .xbox, .xboxElite: CGPoint(x: 104, y: 119)
        case .backbone, .backbonePlayStation: CGPoint(x: 54, y: 128)
        case .dualShock: CGPoint(x: 171, y: 204)
        default: CGPoint(x: 170, y: 184)
        }
    }

    var rightStick: CGPoint {
        switch self {
        case .backbone, .backbonePlayStation: CGPoint(x: 426, y: 187)
        case .dualShock: CGPoint(x: 309, y: 204)
        case .xbox, .xboxElite: CGPoint(x: 302, y: 203)
        default: CGPoint(x: 310, y: 184)
        }
    }

    var dpad: CGPoint {
        switch self {
        case .xbox, .xboxElite: CGPoint(x: 176, y: 203)
        case .backbone, .backbonePlayStation: CGPoint(x: 54, y: 187)
        default: CGPoint(x: 100, y: 118)
        }
    }
    var faces: CGPoint { isBackbone ? CGPoint(x: 426, y: 128) : CGPoint(x: 380, y: 126) }
    var faceSpacing: CGFloat { isBackbone ? 21 : 33 }
    var shoulderX: CGFloat { isBackbone ? 55 : isXbox ? 113 : 102 }
    var touchpad: CGRect {
        CGRect(x: 164, y: isDualSense ? 49 : 68, width: 152, height: isDualSense ? 85 : 74)
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
                                       y: family.isBackbone ? 64 : 40),
                         width: family.isBackbone ? 52 : 66, height: 22)
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
            let trigger: Bool
            if case .trigger = control.id { trigger = true } else { trigger = false }
            return .init(point: CGPoint(x: 480 - placement.point.x, y: trigger ? 72 : 42),
                         width: placement.width, height: trigger ? 42 : 16, rear: true)
        }
        return placement.rear == rear ? placement : nil
    }

    private static func buttonPlacement(_ button: ControllerMappedButton,
                                        family: ControllerDiagramFamily) -> ControllerDiagramPlacement? {
        let faces = family.faces
        let offset = family.faceSpacing
        let size: CGFloat = family.isBackbone ? 20 : 32
        switch button {
        case .a: return .init(point: CGPoint(x: faces.x, y: faces.y + offset), width: size, height: size)
        case .b: return .init(point: CGPoint(x: faces.x + offset, y: faces.y), width: size, height: size)
        case .x: return .init(point: CGPoint(x: faces.x - offset, y: faces.y), width: size, height: size)
        case .y: return .init(point: CGPoint(x: faces.x, y: faces.y - offset), width: size, height: size)
        case .leftShoulder, .rightShoulder:
            return .init(point: CGPoint(x: button == .leftShoulder ? family.shoulderX : 480 - family.shoulderX,
                                       y: family.isBackbone ? 84 : 63),
                         width: family.isBackbone ? 64 : 78, height: 20)
        case .menu, .options:
            let x: CGFloat = family.isBackbone ? 43 : family.isPlayStation ? 147 : 206
            return .init(point: CGPoint(x: button == .options ? x : 480 - x,
                                       y: family.isBackbone ? 237 : family.isPlayStation ? 91 : 128),
                         width: family.isPlayStation ? 12 : 20, height: family.isPlayStation ? 24 : 20)
        case .share where family == .dualShock || family == .xboxElite: return nil
        case .home, .share: return centerButton(button, family: family)
        case .touchpad:
            guard family.isPlayStation else { return nil }
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
        if family.isBackbone {
            return .init(point: CGPoint(x: button == .home ? 409 : 71, y: 222), width: 19, height: 19)
        }
        if button == .home {
            return .init(point: CGPoint(x: 240, y: family.isDualSense ? 182 : family == .dualShock ? 204 : 86), width: 25, height: 25)
        }
        return .init(point: CGPoint(x: 240, y: family.isPlayStation ? 210 : 161),
                     width: family.isPlayStation ? 24 : 19, height: family.isPlayStation ? 9 : 19)
    }

    private static func extra(_ position: ControllerLayoutControl.Position,
                              family: ControllerDiagramFamily) -> ControllerDiagramPlacement {
        let outer: CGFloat = family.isBackbone ? 55 : family.isDualSense ? 168 : 157
        let width: CGFloat = family.isDualSense ? 27 : 58
        let height: CGFloat = family.isDualSense ? 60 : 25
        let primaryY: CGFloat = family.isDualSense ? 177 : 190
        switch position {
        case .backLeftPrimary: return .init(point: CGPoint(x: 480 - outer, y: primaryY), width: width, height: height, rear: true)
        case .backRightPrimary: return .init(point: CGPoint(x: outer, y: primaryY), width: width, height: height, rear: true)
        case .backLeftSecondary: return .init(point: CGPoint(x: 480 - outer + 7, y: 235), width: 62, height: 56, rear: true)
        case .backRightSecondary: return .init(point: CGPoint(x: outer - 7, y: 235), width: 62, height: 56, rear: true)
        case .topLeftInner: return .init(point: CGPoint(x: 188, y: 49), width: 26, height: 20)
        case .topRightInner: return .init(point: CGPoint(x: 292, y: 49), width: 26, height: 20)
        }
    }
}
