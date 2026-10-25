// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

enum ControllerShoulderGeometry {
    static func isShoulder(_ source: ControllerLayoutSource) -> Bool {
        switch source {
        case .trigger, .button(.leftShoulder), .button(.rightShoulder): true
        default: false
        }
    }

    static func isTrigger(_ source: ControllerLayoutSource) -> Bool {
        if case .trigger = source { return true }
        return false
    }

    static func isLeft(_ source: ControllerLayoutSource) -> Bool {
        source == .button(.leftShoulder) || source == .trigger(.left)
    }

    static func placement(family: ControllerDiagramFamily, source: ControllerLayoutSource,
                          rear: Bool) -> ControllerDiagramPlacement {
        let bounds = rawPath(family: family, trigger: isTrigger(source), rear: rear).boundingRect
        return .init(point: CGPoint(x: isLeft(source) != rear ? bounds.midX : 480 - bounds.midX, y: bounds.midY),
                     width: bounds.width, height: bounds.height, rear: rear)
    }

    static func path(family: ControllerDiagramFamily, trigger: Bool, rear: Bool) -> Path {
        let part = rawPath(family: family, trigger: trigger, rear: rear)
        guard trigger else { return part }
        let exposed = part.subtracting(bumper(family))
        guard !rear else { return exposed }
        let body = ControllerBodyShape(family: family).path(in: CGRect(x: 0, y: 0, width: 480, height: 330))
        return exposed.subtracting(body)
    }

    static func rawPath(family: ControllerDiagramFamily, trigger: Bool, rear: Bool) -> Path {
        guard trigger else { return bumper(family) }
        let part = triggerPath(family)
        guard rear else { return part }
        return part.applying(.init(translationX: 0, y: -part.boundingRect.minY))
            .applying(.init(scaleX: 1, y: 1.8))
            .applying(.init(translationX: 0, y: bumper(family).boundingRect.minY + 5))
    }

    static func labelPoint(family: ControllerDiagramFamily, trigger: Bool, rear: Bool) -> CGPoint {
        if rear && trigger {
            let bounds = rawPath(family: family, trigger: true, rear: true).boundingRect
            return CGPoint(x: bounds.midX, y: bounds.maxY - 14)
        }
        switch family {
        case .dualSense, .dualSenseEdge: return trigger ? CGPoint(x: 111, y: 43) : CGPoint(x: 115, y: 58.5)
        case .dualShock: return trigger ? CGPoint(x: 110, y: 45) : CGPoint(x: 114, y: 61)
        case .xbox, .xboxElite: return trigger ? CGPoint(x: 121, y: 39) : CGPoint(x: 134, y: 55)
        case .backbone, .backbonePlayStation: return trigger ? CGPoint(x: 63, y: 66) : CGPoint(x: 63, y: 82.5)
        case .generic: return trigger ? CGPoint(x: 116, y: 49) : CGPoint(x: 123, y: 64.5)
        }
    }

    static func legend(family: ControllerDiagramFamily, source: ControllerLayoutSource) -> String {
        let side = isLeft(source) ? "L" : "R"
        return side + (family.isXbox ? (isTrigger(source) ? "T" : "B") : (isTrigger(source) ? "2" : "1"))
    }

    static func targetCore(family: ControllerDiagramFamily, left: Bool, rear: Bool, scale: CGFloat) -> CGRect {
        let bumper = placement(family: family, source: .button(left ? .leftShoulder : .rightShoulder), rear: rear).bounds
        let trigger = placement(family: family, source: .trigger(left ? .left : .right), rear: rear).bounds
        let parts = bumper.union(trigger).applying(.init(scaleX: scale, y: scale))
        let onLeft = left != rear
        var nearestControl = onLeft ? min(family.leftStick.y - family.stickDiameter / 2,
                                         family.dpad.y - family.dpadDiameter / 2)
            : min(family.rightStick.y - family.stickDiameter / 2,
                  family.faces.y - family.faceSpacing - (family.isBackbone ? 10 : 16))
        let systemButton = ControllerLayoutControl(id: .button(onLeft ? .options : .menu), name: "", symbol: "")
        if let button = ControllerDiagramGeometry.placement(systemButton, family: family) {
            nearestControl = min(nearestControl, button.bounds.minY)
        }
        let bottom = rear ? parts.maxY : min(parts.maxY, (nearestControl - 3) * scale)
        let width = max(44, parts.width)
        return CGRect(x: parts.midX - width / 2, y: max(0, bottom - 44), width: width, height: 44)
    }

    static func targetFrame(family: ControllerDiagramFamily, left: Bool, rear: Bool, scale: CGFloat) -> CGRect {
        let bumper = placement(family: family, source: .button(left ? .leftShoulder : .rightShoulder), rear: rear).bounds
        let trigger = placement(family: family, source: .trigger(left ? .left : .right), rear: rear).bounds
        return targetCore(family: family, left: left, rear: rear, scale: scale)
            .union(bumper.union(trigger).applying(.init(scaleX: scale, y: scale)))
    }

    private static func bumper(_ family: ControllerDiagramFamily) -> Path {
        switch family {
        case .dualSense, .dualSenseEdge:
            return strip(start: CGPoint(x: 62, y: 80), upper: [CGPoint(x: 78, y: 57), CGPoint(x: 106, y: 49)],
                         end: CGPoint(x: 143, y: 50), inner: CGPoint(x: 143, y: 63),
                         lower: [CGPoint(x: 111, y: 61), CGPoint(x: 87, y: 73)], outer: CGPoint(x: 70, y: 90))
        case .dualShock:
            return strip(start: CGPoint(x: 62, y: 78), upper: [CGPoint(x: 81, y: 49), CGPoint(x: 123, y: 49)],
                         end: CGPoint(x: 151, y: 62), inner: CGPoint(x: 150, y: 74),
                         lower: [CGPoint(x: 116, y: 62), CGPoint(x: 88, y: 63)], outer: CGPoint(x: 71, y: 89))
        case .xbox, .xboxElite:
            return strip(start: CGPoint(x: 66, y: 86), upper: [CGPoint(x: 88, y: 57), CGPoint(x: 124, y: 46)],
                         end: CGPoint(x: 161, y: 49), inner: CGPoint(x: 161, y: 61),
                         lower: [CGPoint(x: 127, y: 59), CGPoint(x: 100, y: 67)], outer: CGPoint(x: 77, y: 92))
        case .backbone, .backbonePlayStation:
            return strip(start: CGPoint(x: 24, y: 93), upper: [CGPoint(x: 42, y: 77), CGPoint(x: 69, y: 73)],
                         end: CGPoint(x: 95, y: 76), inner: CGPoint(x: 95, y: 87),
                         lower: [CGPoint(x: 68, y: 84), CGPoint(x: 44, y: 88)], outer: CGPoint(x: 29, y: 102))
        case .generic:
            return strip(start: CGPoint(x: 62, y: 94), upper: [CGPoint(x: 76, y: 68), CGPoint(x: 109, y: 56)],
                         end: CGPoint(x: 153, y: 58), inner: CGPoint(x: 151, y: 70),
                         lower: [CGPoint(x: 112, y: 64), CGPoint(x: 85, y: 74)], outer: CGPoint(x: 73, y: 101))
        }
    }

    private static func strip(start: CGPoint, upper: [CGPoint], end: CGPoint, inner: CGPoint,
                              lower: [CGPoint], outer: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addCurve(to: end, control1: upper[0], control2: upper[1])
            path.addQuadCurve(to: inner, control: CGPoint(x: end.x + 2, y: inner.y))
            path.addCurve(to: outer, control1: lower[0], control2: lower[1])
            path.addQuadCurve(to: start, control: CGPoint(x: start.x - 2, y: outer.y))
            path.closeSubpath()
        }
    }

    private static func triggerPath(_ family: ControllerDiagramFamily) -> Path {
        switch family {
        case .dualSense, .dualSenseEdge:
            return trigger(start: CGPoint(x: 79, y: 67), corner: CGPoint(x: 83, y: 39),
                           crown: CGPoint(x: 108, y: 29), innerTop: CGPoint(x: 132, y: 34), end: CGPoint(x: 140, y: 65))
        case .dualShock:
            return trigger(start: CGPoint(x: 79, y: 70), corner: CGPoint(x: 86, y: 40),
                           crown: CGPoint(x: 112, y: 34), innerTop: CGPoint(x: 136, y: 42), end: CGPoint(x: 141, y: 69))
        case .xbox, .xboxElite:
            return trigger(start: CGPoint(x: 87, y: 72), corner: CGPoint(x: 91, y: 33),
                           crown: CGPoint(x: 115, y: 27), innerTop: CGPoint(x: 145, y: 32), end: CGPoint(x: 149, y: 65))
        case .backbone, .backbonePlayStation:
            return trigger(start: CGPoint(x: 35, y: 94), corner: CGPoint(x: 40, y: 60),
                           crown: CGPoint(x: 64, y: 53), innerTop: CGPoint(x: 86, y: 59), end: CGPoint(x: 89, y: 89))
        case .generic:
            return trigger(start: CGPoint(x: 85, y: 79), corner: CGPoint(x: 90, y: 43),
                           crown: CGPoint(x: 115, y: 38), innerTop: CGPoint(x: 138, y: 43), end: CGPoint(x: 143, y: 74))
        }
    }

    private static func trigger(start: CGPoint, corner: CGPoint, crown: CGPoint, innerTop: CGPoint, end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addQuadCurve(to: corner, control: CGPoint(x: start.x - 2, y: corner.y))
            path.addQuadCurve(to: innerTop, control: crown)
            path.addQuadCurve(to: end, control: CGPoint(x: end.x, y: innerTop.y + 4))
            path.addQuadCurve(to: start, control: CGPoint(x: crown.x, y: start.y + 3))
            path.closeSubpath()
        }
    }
}
