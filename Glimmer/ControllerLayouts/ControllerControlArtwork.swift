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
    private var dark: Bool {
        !isFace || family.darkShell
    }

    var body: some View {
        if control.id == .button(.touchpad) {
            touchpad
        } else {
            let shape = ControllerButtonShape(family: family, placement: placement, source: control.id)
            shape.fill(LinearGradient(colors: tones, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { glyph }
                .frame(width: placement.width * scale, height: placement.height * scale)
        }
    }

    private var tones: [Color] {
        if ControllerButtonShape(family: family, placement: placement, source: control.id).isPaddle {
            return [Color(white: 0.62), Color(white: 0.28), Color(white: 0.42)]
        }
        return dark ? [Color(white: 0.23), Color(white: 0.09)] : [Color(white: 0.96), Color(white: 0.73)]
    }

    private var glyph: some View {
        Image(systemName: family.symbol(for: control))
            .resizable().scaledToFit()
            .foregroundStyle(dark ? Color(white: 0.83) : Color(white: 0.29))
            .frame(width: min(placement.width - 6, isFace ? 20 : 25) * scale,
                   height: min(placement.height - 6, isFace ? 20 : 15) * scale)
    }

    private var touchpad: some View {
        let shape = ControllerTouchpadShape(family: family)
        let darkPad = family == .dualSenseEdge || family == .dualShock
        return shape.fill(.regularMaterial)
            .overlay {
                shape.fill(LinearGradient(colors: darkPad ? [Color(white: 0.23), Color(white: 0.12)]
                    : [Color(white: 0.91), Color(white: 0.79)], startPoint: .top, endPoint: .bottom))
            }
            .overlay { shape.stroke(Color.black.opacity(0.45), lineWidth: scale) }
            .overlay { shape.stroke(Color.white.opacity(0.25), lineWidth: scale).padding(scale) }
            .overlay {
                if family == .dualShock {
                    Capsule().fill(Color.blue.opacity(0.65)).frame(width: 112 * scale, height: 2 * scale)
                        .offset(y: -24 * scale)
                }
                Image(systemName: family.symbol(for: control)).font(.system(size: max(1, 13 * scale)))
                    .foregroundStyle(darkPad ? Color.white.opacity(0.4) : Color.black.opacity(0.25))
            }
            .frame(width: placement.width * scale, height: placement.height * scale)
    }
}

struct ControllerStickArtwork: View {
    let family: ControllerDiagramFamily
    let left: Bool
    let scale: CGFloat

    var body: some View {
        Circle().fill(Color(white: 0.07))
            .overlay { Circle().stroke(Color.black.opacity(0.5), lineWidth: 2 * scale) }
            .overlay {
                Circle().fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)).padding(4 * scale)
            }
            .overlay {
                Circle().stroke(Color(white: 0.42), style: StrokeStyle(lineWidth: scale, dash: [scale, 2 * scale]))
                    .padding(7 * scale)
            }
            .overlay {
                Circle().fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.26)],
                                             startPoint: .top, endPoint: .bottom))
                    .overlay { Circle().stroke(.black.opacity(0.7), lineWidth: scale) }.padding(10 * scale)
            }
            .overlay {
                Image(systemName: left ? "l.joystick.press.down" : "r.joystick.press.down")
                    .font(.system(size: max(1, (family == .backbone ? 9 : 14) * scale))).foregroundStyle(Color(white: 0.52))
            }
            .shadow(color: .black.opacity(0.4), radius: 2 * scale, y: 2 * scale)
            .frame(width: family.stickDiameter * scale, height: family.stickDiameter * scale)
    }
}

struct ControllerDpadArtwork: View {
    let family: ControllerDiagramFamily
    let scale: CGFloat

    var body: some View {
        ZStack {
            if family.isXbox {
                Circle().fill(Color(white: 0.065)).padding(-4 * scale)
                ControllerDpadShape(dish: true).fill(LinearGradient(colors: [Color(white: 0.48), Color(white: 0.16)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                ControllerDpadShape(dish: true).stroke(Color(white: 0.55), lineWidth: scale)
                Image(systemName: "dpad.fill").resizable().foregroundStyle(Color.black.opacity(0.35)).padding(11 * scale)
            } else if family.isPlayStation {
                ForEach(0..<4) { index in
                    ControllerDpadShape(dish: false)
                        .fill(LinearGradient(colors: family == .dualShock
                            ? [Color(white: 0.3), Color(white: 0.12)] : [Color(white: 0.88), Color(white: 0.62)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay { ControllerDpadShape(dish: false).stroke(Color.black.opacity(0.6), lineWidth: scale) }
                        .rotationEffect(.degrees(Double(index) * 90))
                }
            } else {
                Image(systemName: "dpad.fill").resizable()
                    .foregroundStyle(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.13)],
                                                    startPoint: .top, endPoint: .bottom))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: scale, y: scale)
        .frame(width: family.dpadDiameter * scale, height: family.dpadDiameter * scale)
    }
}

struct ControllerDpadShape: Shape {
    let dish: Bool

    func path(in rect: CGRect) -> Path {
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
