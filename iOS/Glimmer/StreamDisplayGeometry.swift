// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreGraphics

enum StreamDisplayGeometry {
    static func pixels(viewSize: CGSize, scale: CGFloat, screenPixels: CGSize) -> CGSize {
        guard valid(viewSize), valid(screenPixels), scale.isFinite, scale > 0 else { return .zero }
        let pixels = CGSize(width: viewSize.width * scale, height: viewSize.height * scale)
        guard valid(pixels) else { return .zero }
        let limit = min(1, screenPixels.width / pixels.width, screenPixels.height / pixels.height)
        return CGSize(width: pixels.width * limit, height: pixels.height * limit)
    }

    static func relativeMotion(_ delta: CGPoint, viewSize: CGSize, streamSize: CGSize) -> CGPoint {
        guard valid(viewSize), valid(streamSize), delta.x.isFinite, delta.y.isFinite else { return .zero }
        // Touch remains a relative trackpad on the control window even when video moves to another display.
        let scale = max(streamSize.width / viewSize.width, streamSize.height / viewSize.height)
        let result = CGPoint(x: delta.x * scale, y: delta.y * scale)
        return result.x.isFinite && result.y.isFinite ? result : .zero
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
