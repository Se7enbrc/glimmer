// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

/// The one in-stream notice look on Mac, iPhone and iPad: a capsule over the moving picture.
struct StreamNoticeView: View {
    let text: String
    var symbol: String?
    var accent: Color?
    var glass = Self.glassAvailable
    /// A glyph-only badge (empty text) still needs a spoken name.
    var accessibilityName: String?
    @Environment(\.dynamicTypeSize) private var textSize

    static var glassAvailable: Bool {
        if #available(macOS 26, iOS 26, *) { return true }
        return false
    }

    var body: some View {
        surface(HStack(spacing: 8) {
            if let symbol {
                // A glyph-only badge gets a square box so its capsule reads as a circle.
                Image(systemName: symbol).imageScale(.medium).accessibilityHidden(true)
                    .frame(width: text.isEmpty ? 22 : nil, height: text.isEmpty ? 22 : nil)
            } else if let accent {
                Circle().fill(accent).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            // Accessibility text sizes wrap rather than truncate the notice.
            if !text.isEmpty { Text(text).lineLimit(textSize.isAccessibilitySize ? nil : 1).truncationMode(.tail) }
        }
        .font(.callout.weight(.medium))
        // A badge is a circle of the pill's height; a notice keeps the wider capsule padding.
        .padding(.vertical, 8).padding(.horizontal, text.isEmpty ? 8 : 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName.map(Text.init) ?? Text(text))
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

/// Where the persistent mouse-mode badge sits, in top-left-origin coordinates shared by both platforms.
enum StreamModeBadgeLayout {
    static let clearance: CGFloat = 12

    /// The clear spot nearest a top corner (trailing first unless `leadingFirst`), sliding along the top and
    /// then the bottom edge when touch controls hold the corners. Nil when nothing is clear.
    static func frame(size: CGSize, in area: CGRect, avoiding overlays: [CGRect], inset: CGFloat = 16,
                      leadingFirst: Bool = false) -> CGRect? {
        let leading = area.minX + inset
        let trailing = area.maxX - inset - size.width
        guard trailing >= leading else { return nil }
        let steps = stride(from: CGFloat(0), through: (trailing - leading) / 2, by: 4)
        let xs = steps.flatMap { step in leadingFirst ? [leading + step, trailing - step] : [trailing - step, leading + step] }
        let ys = [area.minY + inset, area.maxY - inset - size.height]
        for y in ys {
            for x in xs {
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
                let padded = frame.insetBy(dx: -clearance, dy: -clearance)
                if area.contains(frame), !overlays.contains(where: { $0.intersects(padded) }) { return frame }
            }
        }
        return nil
    }
}
