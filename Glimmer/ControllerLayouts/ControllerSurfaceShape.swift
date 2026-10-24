// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerSurfaceShape: Shape {
    enum Detail { case trim, seams, lightBar, speaker, rearPanel, rearSeams, functionButtons }
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
        }
        return path.applying(.init(scaleX: rect.width / 480, y: rect.height / 330))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    private var trim: Path {
        if family.isDualSense {
            return Path { path in
                path.move(to: CGPoint(x: 164, y: 54))
                path.addQuadCurve(to: CGPoint(x: 156, y: 131), control: CGPoint(x: 148, y: 93))
                path.addCurve(to: CGPoint(x: 127, y: 188), control1: CGPoint(x: 161, y: 156), control2: CGPoint(x: 140, y: 164))
                path.addCurve(to: CGPoint(x: 78, y: 295), control1: CGPoint(x: 114, y: 215), control2: CGPoint(x: 101, y: 268))
                path.addQuadCurve(to: CGPoint(x: 135, y: 226), control: CGPoint(x: 115, y: 277))
                path.addCurve(to: CGPoint(x: 345, y: 226), control1: CGPoint(x: 190, y: 252), control2: CGPoint(x: 290, y: 252))
                path.addQuadCurve(to: CGPoint(x: 402, y: 295), control: CGPoint(x: 365, y: 277))
                path.addCurve(to: CGPoint(x: 353, y: 188), control1: CGPoint(x: 379, y: 268), control2: CGPoint(x: 366, y: 215))
                path.addCurve(to: CGPoint(x: 324, y: 131), control1: CGPoint(x: 340, y: 164), control2: CGPoint(x: 319, y: 156))
                path.addQuadCurve(to: CGPoint(x: 316, y: 54), control: CGPoint(x: 332, y: 93))
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
        if family == .backbone {
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
            return Path(roundedRect: CGRect(x: 192, y: 77, width: 96, height: 112), cornerRadius: 10)
        }
        return Path(roundedRect: CGRect(x: 211, y: 216, width: 58, height: 12), cornerRadius: 4)
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
        for x: CGFloat in [175, 305] {
            path.addRoundedRect(in: CGRect(x: x - 10, y: 228, width: 20, height: 23),
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
            path.addQuadCurve(to: CGPoint(x: 0.92 - topInset, y: 0), control: CGPoint(x: 0.5, y: -0.035))
            path.addQuadCurve(to: CGPoint(x: 1 - topInset, y: 0.14), control: CGPoint(x: 1 - topInset, y: 0))
            path.addLine(to: CGPoint(x: 1 - bottomInset, y: 0.87))
            path.addQuadCurve(to: CGPoint(x: 0.96 - bottomInset, y: 1), control: CGPoint(x: 1 - bottomInset, y: 1))
            path.addQuadCurve(to: CGPoint(x: bottomInset + 0.04, y: 1), control: CGPoint(x: 0.5, y: 1.035))
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
        if source == .button(.touchpad) { return ControllerTouchpadShape(family: family).path(in: rect) }
        let contour: Path
        switch source {
        case .trigger: contour = shoulder(trigger: true)
        case .button(.leftShoulder), .button(.rightShoulder): contour = shoulder(trigger: false)
        default:
            guard isPaddle else { return Capsule().path(in: rect) }
            contour = placement.width > placement.height ? horizontalPaddle : verticalPaddle
        }
        let facing = placement.point.x < 240 ? contour
            : contour.applying(.init(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0))
        return facing.applying(.init(scaleX: rect.width, y: rect.height))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }

    private func shoulder(trigger: Bool) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0.04, y: 0.4))
            path.addQuadCurve(to: CGPoint(x: 0.23, y: 0.04), control: CGPoint(x: 0.05, y: 0.12))
            path.addQuadCurve(to: CGPoint(x: 0.88, y: 0.07), control: CGPoint(x: 0.6, y: -0.02))
            path.addQuadCurve(to: CGPoint(x: 0.98, y: 0.3), control: CGPoint(x: 1, y: 0.1))
            path.addLine(to: CGPoint(x: trigger ? 0.89 : 0.97, y: 0.83))
            path.addQuadCurve(to: CGPoint(x: 0.68, y: 0.96), control: CGPoint(x: 0.87, y: 1))
            path.addLine(to: CGPoint(x: 0.13, y: 0.92))
            path.addQuadCurve(to: CGPoint(x: 0.04, y: 0.4), control: CGPoint(x: -0.02, y: 0.9))
            path.closeSubpath()
        }
    }

    private var horizontalPaddle: Path {
        Path { path in
            path.move(to: CGPoint(x: 0.75, y: 0.04))
            path.addQuadCurve(to: CGPoint(x: 0.98, y: 0.23), control: CGPoint(x: 1, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0.77, y: 0.75), control: CGPoint(x: 1, y: 0.57))
            path.addLine(to: CGPoint(x: 0.15, y: 0.98))
            path.addQuadCurve(to: CGPoint(x: 0.05, y: 0.58), control: CGPoint(x: -0.03, y: 0.93))
            path.addQuadCurve(to: CGPoint(x: 0.75, y: 0.04), control: CGPoint(x: 0.33, y: 0.37))
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
