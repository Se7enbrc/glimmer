// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerControlArtwork: View {
    let control: ControllerLayoutControl
    let placement: ControllerDiagramPlacement
    let family: ControllerDiagramFamily
    let scale: CGFloat

    private var isFace: Bool {
        [.button(.a), .button(.b), .button(.x), .button(.y)].contains(control.id)
    }

    var body: some View {
        let shape = ControllerButtonShape(family: family, placement: placement, source: control.id)
        ZStack {
            if !shape.isPaddle && placement.width == placement.height {
                Circle().stroke(.primary, lineWidth: 1.2 * scale)
            } else {
                shape.stroke(.primary, style: StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .overlay {
            if !shape.isPaddle && control.id != .button(.touchpad) {
                Image(systemName: family.symbol(for: control))
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .frame(width: min(placement.width - 6, isFace ? 20 : 25) * scale,
                           height: min(placement.height - 6, isFace ? 20 : 15) * scale)
            }
            if control.id == .button(.touchpad) && family == .dualShock {
                Capsule().stroke(.secondary, lineWidth: scale)
                    .frame(width: 112 * scale, height: 2 * scale).offset(y: -24 * scale)
            }
        }
        .frame(width: placement.width * scale, height: placement.height * scale)
    }
}

struct ControllerStickArtwork: View {
    let family: ControllerDiagramFamily
    let scale: CGFloat

    var body: some View {
        Circle().stroke(.primary, lineWidth: 1.2 * scale)
            .overlay { Circle().stroke(.secondary, lineWidth: scale).padding(4 * scale) }
            .overlay { Circle().stroke(.primary, lineWidth: 1.2 * scale).padding(10 * scale) }
            .frame(width: family.stickDiameter * scale, height: family.stickDiameter * scale)
    }
}

struct ControllerDpadArtwork: View {
    let family: ControllerDiagramFamily
    let scale: CGFloat

    var body: some View {
        ZStack {
            if family.isXbox {
                Circle().stroke(.secondary, lineWidth: scale).padding(-4 * scale)
                ControllerDpadShape(dish: true, roundDish: family == .xboxElite)
                    .stroke(.primary, lineWidth: 1.2 * scale)
                ControllerDpadCross().stroke(.secondary, lineWidth: scale).padding(7 * scale)
            } else if family.isPlayStation {
                ForEach(0..<4) { index in
                    ControllerDpadShape(dish: false)
                        .stroke(.primary, lineWidth: 1.2 * scale)
                        .rotationEffect(.degrees(Double(index) * 90))
                }
            } else {
                ControllerDpadCross().stroke(.primary, lineWidth: 1.2 * scale)
            }
        }
        .frame(width: family.dpadDiameter * scale, height: family.dpadDiameter * scale)
    }
}

struct ControllerDpadShape: Shape {
    let dish: Bool
    var roundDish = false

    func path(in rect: CGRect) -> Path {
        if dish && roundDish { return Path(ellipseIn: rect) }
        if !dish {
            let lobe = Path { path in
                path.move(to: CGPoint(x: 0.4, y: 0.02))
                path.addLine(to: CGPoint(x: 0.6, y: 0.02))
                path.addQuadCurve(to: CGPoint(x: 0.65, y: 0.07), control: CGPoint(x: 0.65, y: 0.02))
                path.addLine(to: CGPoint(x: 0.65, y: 0.26))
                path.addQuadCurve(to: CGPoint(x: 0.53, y: 0.4), control: CGPoint(x: 0.65, y: 0.29))
                path.addQuadCurve(to: CGPoint(x: 0.47, y: 0.4), control: CGPoint(x: 0.5, y: 0.44))
                path.addQuadCurve(to: CGPoint(x: 0.35, y: 0.26), control: CGPoint(x: 0.35, y: 0.29))
                path.addLine(to: CGPoint(x: 0.35, y: 0.07))
                path.addQuadCurve(to: CGPoint(x: 0.4, y: 0.02), control: CGPoint(x: 0.35, y: 0.02))
                path.closeSubpath()
            }
            return lobe.applying(.init(scaleX: rect.width, y: rect.height))
                .applying(.init(translationX: rect.minX, y: rect.minY))
        }
        let points: [CGPoint] = [.init(x: 0.3, y: 0), .init(x: 0.7, y: 0), .init(x: 1, y: 0.3), .init(x: 1, y: 0.7),
                                 .init(x: 0.7, y: 1), .init(x: 0.3, y: 1), .init(x: 0, y: 0.7), .init(x: 0, y: 0.3)]
        return Path { path in
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            path.closeSubpath()
        }
    }
}
