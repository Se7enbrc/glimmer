// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
#if os(macOS)
import AppKit

typealias StatsFont = NSFont
typealias StatsColor = NSColor
typealias StatsView = NSView
typealias StatsInsets = NSEdgeInsets
#else
import UIKit

typealias StatsFont = UIFont
typealias StatsColor = UIColor
typealias StatsView = UIView
typealias StatsInsets = UIEdgeInsets
#endif

extension StatsOverlayLayer {
    /// Point geometry, rather than pixel density, keeps a resized window and an external display consistent.
    static func viewportScale(in size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 1 }
        return min(1.6, max(1, sqrt(min(size.width, size.height) / 440)))
    }

    var resolvedLabelFont: StatsFont {
        #if os(macOS)
        Self.labelFont
        #else
        UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: hudTraits)
        #endif
    }

    var resolvedDetailFont: StatsFont {
        #if os(macOS)
        Self.detailFont
        #else
        UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(
            forTextStyle: .footnote, compatibleWith: hudTraits).pointSize, weight: .medium)
        #endif
    }

    func resolvedValueFont(bold: Bool) -> StatsFont {
        #if os(macOS)
        Self.platformValueFont(bold: bold)
        #else
        UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(
            forTextStyle: .title3, compatibleWith: hudTraits).pointSize,
            weight: bold ? .bold : .semibold)
        #endif
    }

    #if os(iOS)
    // The HUD stops growing at the largest standard size so accessibility sizes cannot bury the picture.
    private var hudTraits: UITraitCollection? {
        guard let traits = displayView?.traitCollection,
              traits.preferredContentSizeCategory > .extraExtraExtraLarge else { return displayView?.traitCollection }
        return traits.modifyingTraits { $0.preferredContentSizeCategory = .extraExtraExtraLarge }
    }
    #endif

    var resolvedTextScale: CGFloat {
        #if os(macOS)
        1
        #else
        resolvedLabelFont.pointSize / 11
        #endif
    }

    static var platformLabelFont: StatsFont {
        #if os(macOS)
        NSFont.preferredFont(forTextStyle: .caption2, options: [:])
        #else
        UIFont.preferredFont(forTextStyle: .caption2)
        #endif
    }

    static func platformValueFont(bold: Bool) -> StatsFont {
        #if os(macOS)
        NSFont.monospacedDigitSystemFont(ofSize: 20, weight: bold ? .bold : .semibold)
        #else
        UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
                                        weight: bold ? .bold : .semibold)
        #endif
    }

    static var platformDetailFont: StatsFont {
        #if os(macOS)
        NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize, weight: .medium)
        #else
        UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                                        weight: .medium)
        #endif
    }

    static var reduceTransparencyEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #else
        UIAccessibility.isReduceTransparencyEnabled
        #endif
    }

    static var differentiateWithoutColorEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        #else
        UIAccessibility.shouldDifferentiateWithoutColor
        #endif
    }

    /// Short landscape windows keep detailed rows readable by continuing in the next column.
    static func columnCount(height: CGFloat, width: CGFloat, available: CGRect) -> Int {
        #if os(macOS)
        1
        #else
        let desired = Int(ceil((height + 12 * textScale) / max(1, available.height - 32)))
        let fits = Int((max(0, available.width - 32) + 24) / (max(1, width) + 24))
        return max(1, min(desired, fits))
        #endif
    }

    static var textScale: CGFloat {
        #if os(macOS)
        1
        #else
        platformLabelFont.pointSize / 11
        #endif
    }

    static var fadeDuration: Double {
        #if os(macOS)
        Motion.short
        #else
        UIAccessibility.isReduceMotionEnabled ? 0 : 0.18
        #endif
    }

    var displayScale: CGFloat? {
        #if os(macOS)
        displayView?.window?.backingScaleFactor
        #else
        displayView?.window?.traitCollection.displayScale
        #endif
    }

    func hostPosition(frame: CGRect, bounds: CGRect) -> CGPoint {
        #if os(macOS)
        CGPoint(x: frame.midX, y: frame.midY)
        #else
        CGPoint(x: frame.midX, y: bounds.maxY - frame.midY)
        #endif
    }

    func sampleOrigin(rect: CGRect, picture: CGRect) -> CGFloat {
        #if os(macOS)
        (picture.maxY - rect.maxY) / picture.height
        #else
        (rect.minY - picture.minY) / picture.height
        #endif
    }

    var layoutVideoSize: CGSize {
        #if os(macOS)
        videoSize
        #else
        .zero
        #endif
    }

    func pictureRect(in bounds: CGRect) -> CGRect {
        #if os(macOS)
        AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        #else
        let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
        #endif
    }

    #if os(iOS)
    func updateAccessibleRows(_ rows: [StatsRow], cap: String) {
        guard let view = displayView else { return }
        let value = isVisible
            ? (rows.map { "\($0.label): \($0.value)" } + (cap.isEmpty ? [] : [cap])).joined(separator: ", ") : nil
        if view.accessibilityValue != value { view.accessibilityValue = value }
    }

    func updateAccessibilityFrames() {}
    #endif
}
