// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerArtwork: View {
    let family: ControllerDiagramFamily
    let rear: Bool
    let controls: [ControllerLayoutControl]

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 480
            ZStack {
                ControllerBodyShape(family: family)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
                if rear {
                    rearDetails(scale: scale)
                } else {
                    frontDetails(scale: scale)
                }
                if family.isBackbone { phone(scale: scale) }
            }
            .clipShape(ControllerArtworkVisibleSurface(family: family, rear: rear, controls: controls),
                       style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frontDetails(scale: CGFloat) -> some View {
        ZStack {
            ControllerSurfaceShape(family: family, detail: .trim)
                .stroke(.secondary, lineWidth: scale)
                .clipShape(ControllerBodyShape(family: family))
            ControllerSurfaceShape(family: family, detail: .grips)
                .stroke(.secondary, lineWidth: scale)
                .clipShape(ControllerBodyShape(family: family))
            if family == .xboxElite { eliteProfile(scale: scale) }
            if !family.isDualSense {
                ControllerSurfaceShape(family: family, detail: .seams)
                    .stroke(.secondary, lineWidth: scale)
                    .clipShape(ControllerBodyShape(family: family))
            }
            if family.isPlayStation {
                ControllerSurfaceShape(family: family, detail: .speaker)
                    .stroke(.secondary, lineWidth: scale)
                ControllerSurfaceShape(family: family, detail: .lightBar)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: scale, lineCap: .round))
            }
            if family == .dualSenseEdge {
                ControllerSurfaceShape(family: family, detail: .functionButtons)
                    .stroke(.secondary, lineWidth: scale)
            }
        }
    }

    private func rearDetails(scale: CGFloat) -> some View {
        ZStack {
            ControllerSurfaceShape(family: family, detail: .rearSeams)
                .stroke(.secondary, lineWidth: scale)
            ControllerSurfaceShape(family: family, detail: .rearPanel)
                .stroke(.secondary, lineWidth: scale)
            ForEach(family.isXbox ? [145.0, 335.0] : [153.0, 327.0], id: \.self) { x in
                Capsule().stroke(.secondary, lineWidth: scale)
                    .frame(width: 9 * scale, height: 30 * scale)
                    .position(x: x * scale, y: (family.isXbox ? 153 : 87) * scale)
            }
            RoundedRectangle(cornerRadius: 3 * scale)
                .stroke(.secondary, lineWidth: scale)
                .frame(width: 27 * scale, height: 9 * scale)
                .position(x: 240 * scale, y: 54 * scale)
            if family == .xboxElite {
                HStack(spacing: 9 * scale) {
                    ForEach(0..<3) { _ in
                        Circle().stroke(.secondary, lineWidth: scale).frame(width: 3 * scale, height: 3 * scale)
                    }
                }
                .position(x: 240 * scale, y: 172 * scale)
            } else {
                Capsule().stroke(.secondary, lineWidth: scale)
                    .frame(width: 16 * scale, height: 6 * scale)
                    .position(x: 240 * scale, y: 204 * scale)
                Circle().stroke(.secondary, lineWidth: scale).frame(width: 3 * scale, height: 3 * scale)
                    .position(x: 240 * scale, y: 162 * scale)
            }
        }
        .clipShape(ControllerBodyShape(family: family))
    }

    private func eliteProfile(scale: CGFloat) -> some View {
        VStack(spacing: 20 * scale) {
            Capsule().stroke(.secondary, lineWidth: scale)
                .frame(width: 20 * scale, height: 10 * scale)
            VStack(spacing: 4 * scale) {
                ForEach(0..<3) { _ in
                    Capsule().stroke(.secondary, lineWidth: scale).frame(width: 7 * scale, height: 2 * scale)
                }
            }
        }
        .position(x: 240 * scale, y: 183 * scale)
    }

    private func phone(scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 17 * scale)
            .stroke(.primary, lineWidth: 1.8 * scale)
            .overlay {
                RoundedRectangle(cornerRadius: 12 * scale)
                    .stroke(.secondary, lineWidth: scale).padding(5 * scale)
            }
            .overlay(alignment: .leading) {
                Capsule().stroke(.secondary, lineWidth: scale)
                    .frame(width: 6 * scale, height: 36 * scale).padding(.leading, 10 * scale)
            }
            .frame(width: 280 * scale, height: 146 * scale)
            .position(x: 240 * scale, y: 170 * scale)
    }
}
