//
//  StreamWindowGeometry.swift
//
//  Pure sizing math for the Window-mode stream window: the pixel-mapped
//  opening size, the fit-to-screen clamp, and the aspect conformance applied to
//  a restored autosaved frame. No AppKit types beyond CGSize so the rules are
//  unit-tested without a window or a screen; StreamWindow+Windowed.swift feeds
//  them the live scale factor and visible frame.
//

import CoreGraphics

enum StreamWindowGeometry {
    /// The narrowest a stream window may be dragged, in points. 640 wide (so
    /// 360 tall at 16:9) keeps the picture legible and the title bar's traffic
    /// lights from overlapping the title; anything smaller is a thumbnail.
    static let minimumContentWidth: CGFloat = 640

    /// Content size in points that shows `pixelWidth` x `pixelHeight` stream
    /// pixels 1:1 on a display with `backingScaleFactor` - a 1080p stream on a
    /// 2x Retina panel opens at 960 x 540 points. A non-positive scale (a
    /// screen mid-reconfigure) is treated as 1x rather than producing an
    /// infinite size.
    static func pixelMappedContentSize(
        pixelWidth: Int, pixelHeight: Int, backingScaleFactor: CGFloat
    ) -> CGSize {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }

    /// Scale `size` DOWN (never up) to fit inside `available`, preserving its
    /// aspect. The opening size for a 4K request on a 1080p-class panel: the
    /// pixel-mapped window would spill off the screen, so it opens as large as
    /// the visible area allows at the stream's aspect instead.
    static func fitted(_ size: CGSize, within available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else {
            return size
        }
        let scale = min(available.width / size.width, available.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Conform a restored autosaved content size to this stream's aspect: keep
    /// the width the user last chose, derive the height, then fit to the
    /// screen. A frame saved from a 16:10 session opened for a 16:9 stream
    /// would otherwise letterbox on the first frame - the exact bars the
    /// aspect lock exists to prevent - because `setFrame` restores the saved
    /// rectangle verbatim (the aspect ratio only constrains interactive
    /// resizing).
    static func conformed(_ size: CGSize, toAspect aspect: CGSize, within available: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0, size.width > 0 else { return size }
        let conformed = CGSize(width: size.width, height: size.width * aspect.height / aspect.width)
        return fitted(conformed, within: available)
    }

    /// The minimum content size at this aspect: `minimumContentWidth` wide,
    /// the matching height, so the floor sits ON the aspect line and the
    /// resize constraint never fights the minimum.
    static func minimumContentSize(aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else {
            return CGSize(width: minimumContentWidth, height: minimumContentWidth * 9 / 16)
        }
        return CGSize(width: minimumContentWidth, height: minimumContentWidth * aspect.height / aspect.width)
    }
}
