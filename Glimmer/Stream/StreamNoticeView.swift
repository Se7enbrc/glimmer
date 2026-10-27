// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

/// The one in-stream notice look on Mac, iPhone and iPad: a capsule over the moving picture.
struct StreamNoticeView: View {
    let text: String
    var symbol: String?
    var accent: Color?
    var glass = Self.glassAvailable

    static var glassAvailable: Bool {
        if #available(macOS 26, iOS 26, *) { return true }
        return false
    }

    var body: some View {
        surface(HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).imageScale(.medium).accessibilityHidden(true)
            } else if let accent {
                Circle().fill(accent).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout.weight(.medium))
        .padding(.vertical, 8).padding(.horizontal, 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
    }

    // macOS 15 has no Liquid Glass: the same capsule gets the system material and a hairline.
    @ViewBuilder private func surface(_ content: some View) -> some View {
        if glass, #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}
