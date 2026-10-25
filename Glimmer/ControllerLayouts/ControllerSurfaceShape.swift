// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerSurfaceShape: Shape {
    enum Detail { case trim, seams, lightBar, speaker, rearPanel, rearSeams, functionButtons, grips }
    let family: ControllerDiagramFamily
    let detail: Detail

    func path(in rect: CGRect) -> Path {
        let path: Path
        switch detail {
        case .trim: path = trim
        case .seams: path = seams
        case .lightBar: path = lightBar
        case .speaker: path = speaker
        case .rearPanel: path = rearPanel
        case .rearSeams: path = rearSeams
        case .functionButtons: path = functionButtons
        case .grips: path = grips
        }
        return path.applying(.init(scaleX: rect.width / 480, y: rect.height / 330))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    private var trim: Path {
        if family.isDualSense {
            return Path { path in
                path.move(to: CGPoint(x: 160, y: 50))
                path.addCurve(to: CGPoint(x: 151, y: 143), control1: CGPoint(x: 151, y: 91), control2: CGPoint(x: 165, y: 125))
                path.addCurve(to: CGPoint(x: 78, y: 306), control1: CGPoint(x: 118, y: 175), control2: CGPoint(x: 84, y: 265))
                path.addCurve(to: CGPoint(x: 132, y: 218), control1: CGPoint(x: 97, y: 277), control2: CGPoint(x: 102, y: 218))
                path.addCurve(to: CGPoint(x: 348, y: 218), control1: CGPoint(x: 198, y: 220), control2: CGPoint(x: 282, y: 220))
                path.addCurve(to: CGPoint(x: 402, y: 306), control1: CGPoint(x: 378, y: 218), control2: CGPoint(x: 383, y: 277))
                path.addCurve(to: CGPoint(x: 329, y: 143), control1: CGPoint(x: 396, y: 265), control2: CGPoint(x: 362, y: 175))
                path.addCurve(to: CGPoint(x: 320, y: 50), control1: CGPoint(x: 315, y: 125), control2: CGPoint(x: 329, y: 91))
                path.closeSubpath()
            }
        }
        if family == .dualShock {
            var path = Path(ellipseIn: CGRect(x: 40, y: 58, width: 120, height: 120))
            path.addEllipse(in: CGRect(x: 320, y: 58, width: 120, height: 120))
            return path
        }
        return Path()
    }

    private var seams: Path {
        if family.isBackbone {
            return Path { path in
                for x: CGFloat in [95, 385] {
                    path.move(to: CGPoint(x: x, y: 89))
                    path.addLine(to: CGPoint(x: x, y: 235))
                }
            }
        }
        let left = Path { path in
            path.move(to: CGPoint(x: 67, y: family.isXbox ? 84 : 152))
            path.addCurve(to: CGPoint(x: 82, y: 284), control1: CGPoint(x: 87, y: 183), control2: CGPoint(x: 119, y: 227))
        }
        var path = left
        path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
        if family.isXbox {
            path.move(to: CGPoint(x: 94, y: 62))
            path.addQuadCurve(to: CGPoint(x: 386, y: 62), control: CGPoint(x: 240, y: 42))
        }
        return path
    }

    private var lightBar: Path {
        if family.isDualSense {
            let left = Path { path in
                path.move(to: CGPoint(x: 161, y: 57))
                path.addQuadCurve(to: CGPoint(x: 163, y: 132), control: CGPoint(x: 148, y: 104))
                path.addQuadCurve(to: CGPoint(x: 198, y: 139), control: CGPoint(x: 171, y: 138))
            }
            var path = left
            path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
            return path
        }
        return Path(roundedRect: CGRect(x: 184, y: 81, width: 112, height: 3), cornerRadius: 1.5)
    }

    private var speaker: Path {
        var path = Path()
        for row in 0..<3 {
            for column in 0..<(7 - row) {
                let x = 221 + CGFloat(column) * 6 + CGFloat(row) * 3
                path.addEllipse(in: CGRect(x: x, y: 153 + CGFloat(row) * 6, width: 2.5, height: 2.5))
            }
        }
        return path
    }

    private var rearPanel: Path {
        if family.isXbox {
            return Path { path in
                path.move(to: CGPoint(x: 90, y: 90))
                path.addQuadCurve(to: CGPoint(x: 390, y: 90), control: CGPoint(x: 240, y: 66))
                path.addQuadCurve(to: CGPoint(x: 337, y: 160), control: CGPoint(x: 393, y: 145))
                path.addLine(to: CGPoint(x: 337, y: 227))
                path.addQuadCurve(to: CGPoint(x: 143, y: 227), control: CGPoint(x: 240, y: 237))
                path.addLine(to: CGPoint(x: 143, y: 160))
                path.addQuadCurve(to: CGPoint(x: 90, y: 90), control: CGPoint(x: 87, y: 145))
                path.closeSubpath()
            }
        }
        return Path { path in
            path.move(to: CGPoint(x: 240, y: 119))
            path.addCurve(to: CGPoint(x: 342, y: 150), control1: CGPoint(x: 307, y: 116), control2: CGPoint(x: 329, y: 120))
            path.addLine(to: CGPoint(x: 345, y: 217))
            path.addQuadCurve(to: CGPoint(x: 135, y: 217), control: CGPoint(x: 240, y: 221))
            path.addLine(to: CGPoint(x: 138, y: 150))
            path.addCurve(to: CGPoint(x: 240, y: 119), control1: CGPoint(x: 151, y: 120), control2: CGPoint(x: 173, y: 116))
            path.closeSubpath()
        }
    }

    private var grips: Path {
        guard family == .xboxElite || family == .dualShock else { return Path() }
        let left = Path { path in
            path.move(to: CGPoint(x: 64, y: 108))
            path.addCurve(to: CGPoint(x: 137, y: 227), control1: CGPoint(x: 50, y: 172), control2: CGPoint(x: 120, y: 193))
            path.addCurve(to: CGPoint(x: 46, y: 306), control1: CGPoint(x: 100, y: 264), control2: CGPoint(x: 75, y: 315))
            path.addCurve(to: CGPoint(x: 25, y: 246), control1: CGPoint(x: 23, y: 302), control2: CGPoint(x: 20, y: 269))
            path.addCurve(to: CGPoint(x: 64, y: 108), control1: CGPoint(x: 32, y: 195), control2: CGPoint(x: 46, y: 133))
            path.closeSubpath()
        }
        var path = left
        path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
        return path
    }

    private var rearSeams: Path {
        let left = Path { path in
            path.move(to: CGPoint(x: 111, y: 62))
            path.addCurve(to: CGPoint(x: 141, y: 168), control1: CGPoint(x: 156, y: 83), control2: CGPoint(x: 146, y: 132))
            path.addCurve(to: CGPoint(x: 68, y: 294), control1: CGPoint(x: 135, y: 208), control2: CGPoint(x: 95, y: 273))
        }
        var path = left
        path.addPath(left.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 480, ty: 0)))
        return path
    }

    private var functionButtons: Path {
        var path = Path()
        for x: CGFloat in [170, 310] {
            path.addRoundedRect(in: CGRect(x: x - 13, y: 215, width: 26, height: 19),
                                cornerSize: CGSize(width: 6, height: 6))
        }
        return path
    }
}

struct ControllerTouchpadShape: Shape {
    let family: ControllerDiagramFamily

    func path(in rect: CGRect) -> Path {
        let topInset: CGFloat = family.isDualSense ? 0 : 0.04
        let bottomInset: CGFloat = family.isDualSense ? 0.06 : 0.08
        let path = Path { path in
            path.move(to: CGPoint(x: topInset + 0.08, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0.92 - topInset, y: 0), control: CGPoint(x: 0.5, y: 0))
            path.addQuadCurve(to: CGPoint(x: 1 - topInset, y: 0.14), control: CGPoint(x: 1 - topInset, y: 0))
            path.addLine(to: CGPoint(x: 1 - bottomInset, y: 0.87))
            path.addQuadCurve(to: CGPoint(x: 0.96 - bottomInset, y: 1), control: CGPoint(x: 1 - bottomInset, y: 1))
            path.addQuadCurve(to: CGPoint(x: bottomInset + 0.04, y: 1), control: CGPoint(x: 0.5, y: 1))
            path.addQuadCurve(to: CGPoint(x: bottomInset, y: 0.87), control: CGPoint(x: bottomInset, y: 1))
            path.addLine(to: CGPoint(x: topInset, y: 0.14))
            path.addQuadCurve(to: CGPoint(x: topInset + 0.08, y: 0), control: CGPoint(x: topInset, y: 0))
            path.closeSubpath()
        }
        return path.applying(.init(scaleX: rect.width, y: rect.height))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }
}

struct ControllerButtonShape: Shape {
    let family: ControllerDiagramFamily
    let placement: ControllerDiagramPlacement
    let source: ControllerLayoutSource

    var isPaddle: Bool {
        switch source {
        case .trigger, .button(.leftShoulder), .button(.rightShoulder): false
        default: placement.rear
        }
    }

    func path(in rect: CGRect) -> Path {
        if ControllerShoulderGeometry.isShoulder(source) { return shoulderPath(in: rect) }
        if source == .button(.touchpad) { return ControllerTouchpadShape(family: family).path(in: rect) }
        let contour: Path
        guard isPaddle else {
            return rect.width == rect.height ? Path(ellipseIn: rect) : Capsule().path(in: rect)
        }
        if family == .xboxElite {
            contour = placement.height > 40 ? lowerPaddle : horizontalPaddle
        } else {
            contour = verticalPaddle
        }
        let facing = placement.point.x < 240 ? contour
            : contour.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0))
        return facing.applying(.init(scaleX: rect.width, y: rect.height))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    private func shoulderPath(in rect: CGRect) -> Path {
        let trigger = ControllerShoulderGeometry.isTrigger(source)
        let bounds = ControllerShoulderGeometry.rawPath(family: family, trigger: trigger, rear: placement.rear).boundingRect
        var part = ControllerShoulderGeometry.path(family: family, trigger: trigger, rear: placement.rear)
            .applying(.init(translationX: -bounds.minX, y: -bounds.minY))
        if placement.point.x > 240 { part = part.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0)) }
        return part.applying(.init(scaleX: rect.width / bounds.width, y: rect.height / bounds.height))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    private var horizontalPaddle: Path {
        Path { path in
            path.move(to: CGPoint(x: 0.92, y: 0.08))
            path.addQuadCurve(to: CGPoint(x: 0.98, y: 0.62), control: CGPoint(x: 1, y: 0.28))
            path.addLine(to: CGPoint(x: 0.46, y: 0.64))
            path.addQuadCurve(to: CGPoint(x: 0.12, y: 0.97), control: CGPoint(x: 0.2, y: 0.65))
            path.addQuadCurve(to: CGPoint(x: 0.05, y: 0.4), control: CGPoint(x: 0, y: 0.99))
            path.addQuadCurve(to: CGPoint(x: 0.4, y: 0.07), control: CGPoint(x: 0.1, y: 0.08))
            path.closeSubpath()
        }
    }

    private var lowerPaddle: Path {
        Path { path in
            path.move(to: CGPoint(x: 0.93, y: 0.03))
            path.addQuadCurve(to: CGPoint(x: 0.97, y: 0.3), control: CGPoint(x: 1, y: 0.06))
            path.addQuadCurve(to: CGPoint(x: 0.49, y: 0.34), control: CGPoint(x: 0.69, y: 0.28))
            path.addCurve(to: CGPoint(x: 0.22, y: 0.94), control1: CGPoint(x: 0.65, y: 0.46),
                          control2: CGPoint(x: 0.52, y: 0.77))
            path.addQuadCurve(to: CGPoint(x: 0.03, y: 0.88), control: CGPoint(x: 0.1, y: 1.06))
            path.addCurve(to: CGPoint(x: 0.27, y: 0.13), control1: CGPoint(x: 0.02, y: 0.65),
                          control2: CGPoint(x: 0.12, y: 0.26))
            path.addQuadCurve(to: CGPoint(x: 0.93, y: 0.03), control: CGPoint(x: 0.42, y: 0))
            path.closeSubpath()
        }
    }

    private var verticalPaddle: Path {
        Path { path in
            path.move(to: CGPoint(x: 0.35, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0.85, y: 0.08), control: CGPoint(x: 0.85, y: -0.02))
            path.addCurve(to: CGPoint(x: 0.74, y: 0.53), control1: CGPoint(x: 0.92, y: 0.25),
                          control2: CGPoint(x: 0.75, y: 0.34))
            path.addCurve(to: CGPoint(x: 0.8, y: 0.9), control1: CGPoint(x: 0.74, y: 0.69),
                          control2: CGPoint(x: 0.88, y: 0.8))
            path.addQuadCurve(to: CGPoint(x: 0.2, y: 0.94), control: CGPoint(x: 0.64, y: 1.06))
            path.addQuadCurve(to: CGPoint(x: 0.08, y: 0.72), control: CGPoint(x: 0.01, y: 0.88))
            path.addCurve(to: CGPoint(x: 0.35, y: 0), control1: CGPoint(x: 0.35, y: 0.41),
                          control2: CGPoint(x: 0.25, y: 0.23))
            path.closeSubpath()
        }
    }
}

// Even-odd clipping hides shell strokes without opaque paint or Boolean curve reconstruction.
struct ControllerArtworkVisibleSurface: Shape {
    let family: ControllerDiagramFamily
    let rear: Bool
    let controls: [ControllerLayoutControl]

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 480
        var surface = Path(rect)
        for control in controls {
            guard let placement = ControllerDiagramGeometry.visiblePlacement(control, family: family, rear: rear) else {
                continue
            }
            let bounds = placement.bounds.applying(.init(scaleX: scale, y: scale))
                .offsetBy(dx: rect.minX, dy: rect.minY)
            let shape = ControllerButtonShape(family: family, placement: placement, source: control.id)
            surface.addPath(shape.path(in: bounds))
        }
        if !rear {
            for point in [family.leftStick, family.rightStick, family.dpad] {
                let diameter = point == family.dpad ? family.dpadDiameter + 8 : family.stickDiameter
                let bounds = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                    width: diameter, height: diameter)
                    .applying(.init(scaleX: scale, y: scale)).offsetBy(dx: rect.minX, dy: rect.minY)
                surface.addEllipse(in: bounds)
            }
        }
        return surface
    }
}
