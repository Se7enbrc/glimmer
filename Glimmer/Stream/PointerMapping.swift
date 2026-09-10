//
//  PointerMapping.swift
//
//  Pure view-point → stream-pixel math for Window mode's absolute pointer. In
//  a window the pointer is a normal Mac pointer and the host cursor tracks it
//  1:1, so every motion, click and drag has to say WHERE it is rather than how
//  far it moved - and that answer is a coordinate conversion with no AppKit,
//  no window and no screen in it. Kept here so it can be unit-tested directly;
//  InputForwarder+WindowPointer.swift feeds it the live view bounds and the
//  stream's pixel size and hands the result to `sendMousePosition`.
//
//  Full screen never calls this: relative aim there sends deltas, exactly as
//  it always has.
//

import CoreGraphics

enum PointerMapping {

    /// A point in the host's stream-pixel space, with the reference frame it
    /// was measured against. Maps 1:1 onto the four arguments of
    /// `StreamingBackend.sendMousePosition(x:y:refW:refH:)`; the wire's GFE
    /// `- 1` rounding workaround lives in the encoder, so `refW`/`refH` here
    /// are the true pixel dimensions.
    struct StreamPoint: Equatable {
        let x: Int16
        let y: Int16
        let refW: Int16
        let refH: Int16
    }

    /// Convert a point in the stream view's coordinate space to stream pixels.
    ///
    /// Two conversions happen at once:
    ///
    ///   * ORIGIN. AppKit's view space is y-UP from the bottom left; the
    ///     host's pixel space is y-DOWN from the top left. Y is flipped on the
    ///     way across, or the picture is mirrored vertically and aim goes the
    ///     wrong way.
    ///   * LETTERBOX. The display layer runs `.resizeAspect`, so a view whose
    ///     aspect differs from the stream's shows bars, and the picture is not
    ///     the whole view. Window mode locks the content aspect to the stream
    ///     so the two normally agree exactly - but they disagree for the few
    ///     frames around a live resize and on the first frame of a restored
    ///     frame, so the fit is derived rather than assumed.
    ///
    /// The result is clamped into `0 ..< refW` × `0 ..< refH`: a drag that
    /// leaves the view (macOS keeps delivering dragged events to the view that
    /// took the mouse-down) must pin to the edge, not wrap or overflow the
    /// Int16 the wire carries.
    ///
    /// Returns nil for a degenerate view or stream size - a window mid-resize
    /// can momentarily report a zero bound, and there is no meaningful pixel
    /// to name then.
    static func streamPoint(
        viewPoint: CGPoint, viewSize: CGSize, streamPixelSize: CGSize
    ) -> StreamPoint? {
        let refW = streamPixelSize.width.rounded()
        let refH = streamPixelSize.height.rounded()
        guard viewSize.width > 0, viewSize.height > 0, refW >= 1, refH >= 1 else { return nil }

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
