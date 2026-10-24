// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerArtwork: View {
    let family: ControllerDiagramFamily
    let rear: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var shellTones: [Color] {
        if family.darkShell { return [Color(white: 0.30), Color(white: 0.18), Color(white: 0.10)] }
        return colorScheme == .dark
            ? [Color(white: 0.77), Color(white: 0.67), Color(white: 0.53)]
            : [Color(white: 0.98), Color(white: 0.9), Color(white: 0.74)]
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 480
            let outline = ControllerBodyShape(family: family)
            ZStack {
                if family.isBackbone {
                    RoundedRectangle(cornerRadius: 8 * scale).fill(Color(white: 0.14))
                        .frame(width: 320 * scale, height: 100 * scale)
                        .position(x: 240 * scale, y: 170 * scale)
                }
                outline.fill(.regularMaterial)
                    .overlay { outline.fill(LinearGradient(colors: shellTones.map { $0.opacity(0.94) },
                                                          startPoint: .topLeading, endPoint: .bottomTrailing)) }
                    .overlay { outline.stroke(Color.white.opacity(0.3), lineWidth: 1.5 * scale) }
                    .overlay { outline.stroke(Color.black.opacity(0.3), lineWidth: 0.6 * scale) }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.18), radius: 5 * scale, y: 4 * scale)
                if rear {
                    rearDetails(scale: scale).clipShape(outline)
                } else {
                    frontDetails(scale: scale)
                }
                if family.isBackbone { phone(scale: scale) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frontDetails(scale: CGFloat) -> some View {
        ZStack {
            ControllerSurfaceShape(family: family, detail: .trim)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.065), Color(white: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    ControllerSurfaceShape(family: family, detail: .trim)
                        .stroke(Color.white.opacity(0.13), lineWidth: scale)
                }
                .clipShape(ControllerBodyShape(family: family))
            ControllerSurfaceShape(family: family, detail: .grips)
                .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if family == .xboxElite {
                ControllerSurfaceShape(family: family, detail: .gripTexture).fill(.white.opacity(0.12))
                eliteProfile(scale: scale)
            }
            if !family.isDualSense {
                ControllerSurfaceShape(family: family, detail: .seams)
                    .stroke(Color.black.opacity(0.4), lineWidth: scale)
            }
            if family.isPlayStation {
                ControllerSurfaceShape(family: family, detail: .speaker).fill(Color.black.opacity(0.8))
                ControllerSurfaceShape(family: family, detail: .speaker)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7 * scale)
                if family.isDualSense {
                    ControllerSurfaceShape(family: family, detail: .lightBar)
                        .stroke(Color.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                }
            }
            if family == .dualSenseEdge {
                ControllerSurfaceShape(family: family, detail: .functionButtons)
                    .fill(LinearGradient(colors: [.gray, Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                    .overlay { ControllerSurfaceShape(family: family, detail: .functionButtons)
                        .stroke(.white.opacity(0.3), lineWidth: scale) }
            }
        }
    }

    private func rearDetails(scale: CGFloat) -> some View {
        ZStack {
            ControllerSurfaceShape(family: family, detail: .rearSeams)
                .stroke(Color.black.opacity(0.35), lineWidth: 1.2 * scale)
            ControllerSurfaceShape(family: family, detail: .rearPanel)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.075)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay { ControllerSurfaceShape(family: family, detail: .rearPanel)
                    .stroke(Color.black.opacity(0.22), lineWidth: scale) }
            if family == .dualSenseEdge || family == .xboxElite {
                ForEach(family.isXbox ? [145.0, 335.0] : [153.0, 327.0], id: \.self) { x in
                    Capsule().fill(Color(white: 0.1))
                        .overlay { Capsule().stroke(.white.opacity(0.3), lineWidth: scale) }
                        .frame(width: 9 * scale, height: 30 * scale)
                        .position(x: x * scale, y: (family.isXbox ? 153 : 87) * scale)
                }
            }
            RoundedRectangle(cornerRadius: 3 * scale)
                .fill(Color(white: 0.08))
                .overlay { RoundedRectangle(cornerRadius: 3 * scale).stroke(.white.opacity(0.25), lineWidth: scale) }
                .frame(width: 27 * scale, height: 9 * scale)
                .position(x: 240 * scale, y: 54 * scale)
            if family == .xboxElite {
                HStack(spacing: 9 * scale) {
                    ForEach(0..<3) { _ in Circle().fill(Color(white: 0.3)).frame(width: 3 * scale, height: 3 * scale) }
                }
                .position(x: 240 * scale, y: 172 * scale)
            } else {
                Capsule().fill(Color(white: 0.035))
                    .overlay { Capsule().stroke(.white.opacity(0.2), lineWidth: scale) }
                    .frame(width: 16 * scale, height: 6 * scale)
                    .position(x: 240 * scale, y: 204 * scale)
                Circle().fill(Color(white: 0.035)).frame(width: 3 * scale, height: 3 * scale)
                    .position(x: 240 * scale, y: 162 * scale)
            }
        }
    }

    private func eliteProfile(scale: CGFloat) -> some View {
        VStack(spacing: 20 * scale) {
            Capsule().fill(Color(white: 0.06))
                .overlay { Capsule().stroke(.white.opacity(0.17), lineWidth: scale) }
                .frame(width: 20 * scale, height: 10 * scale)
            VStack(spacing: 4 * scale) {
                ForEach(0..<3) { _ in Capsule().fill(.white.opacity(0.65)).frame(width: 7 * scale, height: 2 * scale) }
            }
        }
        .position(x: 240 * scale, y: 183 * scale)
    }

    private func phone(scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 17 * scale)
            .fill(Color(white: 0.045))
            .overlay { RoundedRectangle(cornerRadius: 17 * scale).stroke(Color(white: 0.36), lineWidth: 3 * scale) }
            .overlay {
                RoundedRectangle(cornerRadius: 12 * scale)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.075)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(5 * scale)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(.black).frame(width: 6 * scale, height: 36 * scale).padding(.leading, 10 * scale)
            }
            .frame(width: 280 * scale, height: 146 * scale)
            .position(x: 240 * scale, y: 170 * scale)
    }
}
