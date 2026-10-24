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
        guard viewSize.width.isFinite, viewSize.height.isFinite,
              viewPoint.x.isFinite, viewPoint.y.isFinite,
              viewSize.width > 0, viewSize.height > 0, refW >= 1, refH >= 1,
              refW <= CGFloat(Int16.max), refH <= CGFloat(Int16.max) else { return nil }

        // The picture's rectangle inside the view, aspect-fit and centred -
        // what `.resizeAspect` composites.
        let fit = min(viewSize.width / refW, viewSize.height / refH)
        let pictureWidth = refW * fit
        let pictureHeight = refH * fit
        let originX = (viewSize.width - pictureWidth) / 2
        let originY = (viewSize.height - pictureHeight) / 2

        let across = (viewPoint.x - originX) / pictureWidth
        let down = 1 - (viewPoint.y - originY) / pictureHeight

        // Floor, then clamp: flooring picks the pixel the point sits ON, and a
        // point exactly on the right or bottom edge floors to refW / refH,
        // which the clamp pulls back onto the last real pixel.
        let x = clamped((across * refW).rounded(.down), upperBound: refW - 1)
        let y = clamped((down * refH).rounded(.down), upperBound: refH - 1)
        return StreamPoint(
            x: Int16(clamping: Int(x)), y: Int16(clamping: Int(y)),
            refW: Int16(clamping: Int(refW)), refH: Int16(clamping: Int(refH)))
    }

    /// Clamp into `0 ... upperBound`. NaN (only reachable from a degenerate
    /// input the guard above already rejects) lands on 0 rather than
    /// propagating into the Int conversion, which would trap.
    private static func clamped(_ value: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), upperBound)
    }
}
