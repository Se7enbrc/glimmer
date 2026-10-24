// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

enum ControllerDiagramFamily: String, CaseIterable {
    case xbox, dualSense, dualShock, backbone, generic

    static func identify(category: String, name: String, controls: [ControllerLayoutControl]) -> Self {
        let description = (category + " " + name).lowercased()
        if description.contains("backbone") { return .backbone }
        if category == "PS5 Controller" { return .dualSense }
        if category == "PS4 Controller" { return .dualShock }
        if description.contains("dualsense") { return .dualSense }
        if description.contains("dualshock") { return .dualShock }
        if description.contains("xbox") { return .xbox }
        if controls.contains(where: { $0.id == .button(.touchpad) }) { return .dualSense }
        return .generic
    }

    var leftStick: CGPoint {
        switch self {
        case .xbox: CGPoint(x: 122, y: 123)
        case .backbone: CGPoint(x: 62, y: 120)
        default: CGPoint(x: 174, y: 204)
        }
    }

    var rightStick: CGPoint { self == .backbone ? CGPoint(x: 418, y: 208) : CGPoint(x: 306, y: 204) }
    var dpad: CGPoint {
        switch self {
        case .xbox: CGPoint(x: 174, y: 204)
        case .backbone: CGPoint(x: 62, y: 208)
        default: CGPoint(x: 112, y: 130)
        }
    }
    var faces: CGPoint { self == .backbone ? CGPoint(x: 418, y: 120) : CGPoint(x: 368, y: 130) }
    var faceSpacing: CGFloat { self == .backbone ? 25 : 34 }
    var isPlayStation: Bool { self == .dualSense || self == .dualShock }
}

struct ControllerDiagramPlacement {
    let point: CGPoint
    var width: CGFloat = 32
    var height: CGFloat = 32
    var rear = false
}

enum ControllerDiagramGeometry {
    static func placement(_ control: ControllerLayoutControl, family: ControllerDiagramFamily) -> ControllerDiagramPlacement? {
        if let position = control.position { return extra(position, family: family) }
        switch control.id {
        case .button(let button): return buttonPlacement(button, family: family)
        case .trigger(let trigger):
            return .init(point: CGPoint(x: trigger == .left ? shoulderX(family) : 480 - shoulderX(family), y: 26),
                         width: 58, height: 34)
        default: return nil
        }
    }

    private static func shoulderX(_ family: ControllerDiagramFamily) -> CGFloat { family == .backbone ? 62 : 126 }

    private static func buttonPlacement(_ button: ControllerMappedButton,
                                        family: ControllerDiagramFamily) -> ControllerDiagramPlacement? {
        let faces = family.faces
        let offset = family.faceSpacing
        let size: CGFloat = family == .backbone ? 26 : 32
        switch button {
        case .a: return .init(point: CGPoint(x: faces.x, y: faces.y + offset), width: size, height: size)
        case .b: return .init(point: CGPoint(x: faces.x + offset, y: faces.y), width: size, height: size)
        case .x: return .init(point: CGPoint(x: faces.x - offset, y: faces.y), width: size, height: size)
        case .y: return .init(point: CGPoint(x: faces.x, y: faces.y - offset), width: size, height: size)
        case .leftShoulder, .rightShoulder:
            return .init(point: CGPoint(x: button == .leftShoulder ? shoulderX(family) : 480 - shoulderX(family), y: 64),
                         width: 70, height: 26)
        case .menu, .options:
            let x: CGFloat = family == .backbone ? 62 : family.isPlayStation ? 186 : 203
            return .init(point: CGPoint(x: button == .options ? x : 480 - x,
                                       y: family == .backbone ? 266 : family.isPlayStation ? 104 : 128),
                         width: 24, height: 24)
        case .home:
            return .init(point: CGPoint(x: family == .backbone ? 445 : 240,
                                       y: family == .backbone ? 254 : family.isPlayStation ? 206 : 93), width: 26, height: 26)
        case .share:
            return .init(point: CGPoint(x: family == .backbone ? 35 : 240,
                                       y: family == .backbone ? 254 : family.isPlayStation ? 238 : 166), width: 24, height: 24)
        case .touchpad:
            return .init(point: CGPoint(x: 240, y: 116), width: 78, height: 50)
        case .paddle1: return extra(.backRightPrimary, family: family)
        case .paddle2: return extra(.backLeftPrimary, family: family)
        case .paddle3: return extra(.backRightSecondary, family: family)
        case .paddle4: return extra(.backLeftSecondary, family: family)
        default: return nil
        }
    }

    private static func extra(_ position: ControllerLayoutControl.Position,
                              family: ControllerDiagramFamily) -> ControllerDiagramPlacement {
        let outer: CGFloat = family == .backbone ? 62 : 160
        let width: CGFloat = family.isPlayStation ? 50 : 36
        let height: CGFloat = family.isPlayStation ? 28 : 64
        switch position {
        case .backLeftPrimary: return .init(point: CGPoint(x: 480 - outer, y: 155), width: width, height: height, rear: true)
        case .backRightPrimary: return .init(point: CGPoint(x: outer, y: 155), width: width, height: height, rear: true)
        case .backLeftSecondary: return .init(point: CGPoint(x: 480 - outer + 18, y: 229), width: 42, height: 54, rear: true)
        case .backRightSecondary: return .init(point: CGPoint(x: outer - 18, y: 229), width: 42, height: 54, rear: true)
        case .topLeftInner: return .init(point: CGPoint(x: 190, y: 65), width: 26, height: 26)
        case .topRightInner: return .init(point: CGPoint(x: 290, y: 65), width: 26, height: 26)
        }
    }
}

struct ControllerBodyShape: Shape {
    let family: ControllerDiagramFamily

    func path(in rect: CGRect) -> Path {
        let path: Path
        if family == .backbone {
            var body = Path(roundedRect: CGRect(x: 18, y: 74, width: 88, height: 222), cornerRadius: 36)
            body.addRoundedRect(in: CGRect(x: 374, y: 74, width: 88, height: 222), cornerSize: CGSize(width: 36, height: 36))
            body.addRoundedRect(in: CGRect(x: 90, y: 124, width: 300, height: 108), cornerSize: CGSize(width: 8, height: 8))
            path = body
        } else {
            path = handheld
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 480, y: rect.height / 330))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private var handheld: Path {
        let playStation = family.isPlayStation
        let inner: CGFloat = 255
        let outer: CGFloat = family == .dualShock || family == .generic ? 440 : 460
        let grip: CGFloat = playStation ? 309 : family == .xbox ? 292 : 290
        let top: CGFloat = family == .xbox ? 54 : family == .generic ? 78 : 61
        return Path { path in
            path.move(to: CGPoint(x: 116, y: 73))
            path.addCurve(to: CGPoint(x: 364, y: 73),
                          control1: CGPoint(x: 184, y: top),
                          control2: CGPoint(x: 296, y: top))
            path.addCurve(to: CGPoint(x: 428, y: 125),
                          control1: CGPoint(x: 407, y: 68),
                          control2: CGPoint(x: 425, y: 92))
            path.addCurve(to: CGPoint(x: outer, y: grip - 27),
                          control1: CGPoint(x: 445, y: 171),
                          control2: CGPoint(x: 455, y: 237))
            path.addCurve(to: CGPoint(x: 405, y: grip),
                          control1: CGPoint(x: outer + 5, y: grip + 5),
                          control2: CGPoint(x: 430, y: grip + 17))
            path.addCurve(to: CGPoint(x: 332, y: inner),
                          control1: CGPoint(x: 380, y: grip - 19),
                          control2: CGPoint(x: 359, y: inner))
            path.addCurve(to: CGPoint(x: 148, y: inner),
                          control1: CGPoint(x: 285, y: inner + 9),
                          control2: CGPoint(x: 195, y: inner + 9))
            path.addCurve(to: CGPoint(x: 75, y: grip),
                          control1: CGPoint(x: 121, y: inner),
                          control2: CGPoint(x: 100, y: grip - 19))
            path.addCurve(to: CGPoint(x: 480 - outer, y: grip - 27),
                          control1: CGPoint(x: 50, y: grip + 17),
                          control2: CGPoint(x: 475 - outer, y: grip + 5))
            path.addCurve(to: CGPoint(x: 52, y: 125),
                          control1: CGPoint(x: 25, y: 237),
                          control2: CGPoint(x: 35, y: 171))
            path.addCurve(to: CGPoint(x: 116, y: 73),
                          control1: CGPoint(x: 55, y: 92),
                          control2: CGPoint(x: 73, y: 68))
            path.closeSubpath()
        }
    }
}
