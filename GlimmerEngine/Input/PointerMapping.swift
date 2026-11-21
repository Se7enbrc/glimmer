// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Absolute pointer coordinates follow the aspect-fitted picture in any presentation.

import CoreGraphics

package enum PointerMapping {
    /// Host stream-pixel coordinates and true reference dimensions; the encoder owns the wire rounding
    /// workaround.
    package struct StreamPoint: Equatable {
        package let x: Int16
        package let y: Int16
        package let refW: Int16
        package let refH: Int16
    }

    /// Convert bottom-left view coordinates through the aspect-fitted picture to top-left host pixels.
    /// Clamp drags to the picture edge; reject invalid dimensions before integer conversion.
    package static func streamPoint(
        viewPoint: CGPoint, viewSize: CGSize, streamPixelSize: CGSize
    ) -> StreamPoint? {
        let refW = streamPixelSize.width.rounded()
        let refH = streamPixelSize.height.rounded()
        guard let point = picturePoint(viewPoint: viewPoint, viewSize: viewSize, width: refW, height: refH)
        else { return nil }

        // Floor, then clamp: flooring picks the pixel the point sits ON, and a
        // point exactly on the right or bottom edge floors to refW / refH,
        // which the clamp pulls back onto the last real pixel.
        let x = clamped((point.x * refW).rounded(.down), upperBound: refW - 1)
        let y = clamped((point.y * refH).rounded(.down), upperBound: refH - 1)
        return StreamPoint(
            x: Int16(clamping: Int(x)), y: Int16(clamping: Int(y)),
            refW: Int16(clamping: Int(refW)), refH: Int16(clamping: Int(refH)))
    }

    package static func touchPoint(viewPoint: CGPoint, viewSize: CGSize, streamPixelSize: CGSize,
                                   begins: Bool) -> CGPoint? {
        guard let point = picturePoint(viewPoint: viewPoint, viewSize: viewSize,
                                      width: streamPixelSize.width.rounded(), height: streamPixelSize.height.rounded()),
              point.x.isFinite, point.y.isFinite else { return nil }
        if begins, !(0...1).contains(point.x) || !(0...1).contains(point.y) { return nil }
        return CGPoint(x: clamped(point.x, upperBound: 1), y: clamped(point.y, upperBound: 1))
    }

    private static func picturePoint(viewPoint: CGPoint, viewSize: CGSize, width: CGFloat, height: CGFloat) -> CGPoint? {
        guard viewSize.width.isFinite, viewSize.height.isFinite,
              viewPoint.x.isFinite, viewPoint.y.isFinite,
              viewSize.width > 0, viewSize.height > 0, width >= 1, height >= 1,
              width <= CGFloat(Int16.max), height <= CGFloat(Int16.max) else { return nil }

        // The picture's rectangle inside the view, aspect-fit and centred -
        // what `.resizeAspect` composites.
        let fit = min(viewSize.width / width, viewSize.height / height)
        let pictureWidth = width * fit
        let pictureHeight = height * fit
        let originX = (viewSize.width - pictureWidth) / 2
        let originY = (viewSize.height - pictureHeight) / 2

        return CGPoint(x: (viewPoint.x - originX) / pictureWidth,
                       y: 1 - (viewPoint.y - originY) / pictureHeight)
    }

    /// Clamp into `0 ... upperBound`. NaN (only reachable from a degenerate
    /// input the guard above already rejects) lands on 0 rather than
    /// propagating into the Int conversion, which would trap.
    private static func clamped(_ value: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), upperBound)
    }
}
