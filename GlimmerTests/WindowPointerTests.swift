//
//  WindowPointerTests.swift
//
//  Covers the pure parts of Window mode's pointer model: the view-point →
//  stream-pixel mapping (origin flip, aspect fit, clamping), the hold-Esc
//  decision table, and the capture hint's show budget. All pure - no window,
//  no view, no UserDefaults, no clock.
//

import CoreGraphics
import Testing
@testable import Glimmer

struct WindowPointerTests {

    // MARK: Pointer mapping - the happy 1:1 case

    /// A view that is exactly the stream's aspect (what the window's aspect
    /// lock guarantees) maps corner to corner with the Y axis flipped:
    /// AppKit's origin is bottom-left, the host's is top-left.
    @Test func mapsCornersWithTheYAxisFlipped() {
        let view = CGSize(width: 960, height: 540)
        let stream = CGSize(width: 1920, height: 1080)

        // Bottom-left of the view is the BOTTOM-left pixel of the stream.
        let bottomLeft = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 0, y: 0), viewSize: view, streamPixelSize: stream)
        #expect(bottomLeft == PointerMapping.StreamPoint(x: 0, y: 1079, refW: 1920, refH: 1080))

        // Top-left of the view is the origin pixel.
        let topLeft = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 0, y: 540), viewSize: view, streamPixelSize: stream)
        #expect(topLeft == PointerMapping.StreamPoint(x: 0, y: 0, refW: 1920, refH: 1080))

        // Top-right clamps onto the last real pixel rather than overflowing.
        let topRight = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 960, y: 540), viewSize: view, streamPixelSize: stream)
        #expect(topRight == PointerMapping.StreamPoint(x: 1919, y: 0, refW: 1920, refH: 1080))
    }

    /// The middle of the view is the middle of the stream at any scale - the
    /// property that makes the host cursor track this Mac's cursor.
    @Test func mapsTheCentreAtAnyWindowSize() {
        let stream = CGSize(width: 1920, height: 1080)
        for width in [640.0, 960.0, 1920.0, 2400.0] {
            let view = CGSize(width: width, height: width * 9 / 16)
            let point = PointerMapping.streamPoint(
                viewPoint: CGPoint(x: view.width / 2, y: view.height / 2),
                viewSize: view, streamPixelSize: stream)
            #expect(point?.x == 960)
            #expect(point?.y == 540)
        }
    }

    /// The reference frame is the stream's true pixel size, not the view's -
    /// the encoder applies the GFE `- 1` workaround on the wire, so what goes
    /// in here is the honest dimension.
    @Test func reportsTheStreamPixelSizeAsTheReferenceFrame() {
        let point = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 10, y: 10),
            viewSize: CGSize(width: 1280, height: 720),
            streamPixelSize: CGSize(width: 3840, height: 2160))
        #expect(point?.refW == 3840)
        #expect(point?.refH == 2160)
    }

    // MARK: Pointer mapping - clamping

    /// A drag that leaves the view keeps delivering events to the view that
    /// took the mouse-down, so out-of-bounds points are routine. They pin to
    /// the edge; they never wrap, and they never overflow the Int16 the wire
    /// carries.
    @Test func clampsPointsOutsideTheView() {
        let view = CGSize(width: 960, height: 540)
        let stream = CGSize(width: 1920, height: 1080)

        let left = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: -400, y: 270), viewSize: view, streamPixelSize: stream)
        #expect(left?.x == 0)

        let right = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 5000, y: 270), viewSize: view, streamPixelSize: stream)
        #expect(right?.x == 1919)

        let above = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 480, y: 9000), viewSize: view, streamPixelSize: stream)
        #expect(above?.y == 0)

        let below = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 480, y: -9000), viewSize: view, streamPixelSize: stream)
        #expect(below?.y == 1079)
    }

    // MARK: Pointer mapping - letterbox

    /// A view whose aspect does not match the stream's (the few frames around
    /// a live resize) letterboxes: the picture is centred inside the view, so
    /// the mapping has to measure against the PICTURE, not the view.
    @Test func mapsAgainstThePictureWhenTheViewLetterboxes() {
        // 1000x1000 view showing a 2:1 stream -> a 1000x500 picture with 250pt
        // bars top and bottom.
        let view = CGSize(width: 1000, height: 1000)
        let stream = CGSize(width: 1000, height: 500)

        // Centre of the view is still the centre of the picture.
        let centre = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 500, y: 500), viewSize: view, streamPixelSize: stream)
        #expect(centre == PointerMapping.StreamPoint(x: 500, y: 250, refW: 1000, refH: 500))

        // The top edge of the PICTURE (y = 750 in view space) is the stream's
        // first row - not the top of the view.
        let pictureTop = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 500, y: 750), viewSize: view, streamPixelSize: stream)
        #expect(pictureTop?.y == 0)

        // Inside a bar, above the picture: clamped to the first row.
        let inTheBar = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 500, y: 900), viewSize: view, streamPixelSize: stream)
        #expect(inTheBar?.y == 0)
    }

    /// Pillarbox is the same rule on the other axis.
    @Test func mapsAgainstThePictureWhenTheViewPillarboxes() {
        // 1000x1000 view showing a 1:2 stream -> a 500x1000 picture with 250pt
        // bars left and right.
        let view = CGSize(width: 1000, height: 1000)
        let stream = CGSize(width: 500, height: 1000)

        let pictureLeft = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 250, y: 500), viewSize: view, streamPixelSize: stream)
        #expect(pictureLeft?.x == 0)

        let inTheBar = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 20, y: 500), viewSize: view, streamPixelSize: stream)
        #expect(inTheBar?.x == 0)

        let pictureRight = PointerMapping.streamPoint(
            viewPoint: CGPoint(x: 749, y: 500), viewSize: view, streamPixelSize: stream)
        #expect(pictureRight?.x == 499)
    }

    // MARK: Pointer mapping - degenerate input

    /// A window mid-resize can report a zero bound, and a session that has not
    /// set the stream size yet leaves it `.zero`. There is no meaningful pixel
    /// to name in either case, so the caller sends nothing.
    @Test func refusesDegenerateSizes() {
        let point = CGPoint(x: 10, y: 10)
        #expect(PointerMapping.streamPoint(
            viewPoint: point, viewSize: .zero,
            streamPixelSize: CGSize(width: 1920, height: 1080)) == nil)
        #expect(PointerMapping.streamPoint(
            viewPoint: point, viewSize: CGSize(width: 960, height: 540),
            streamPixelSize: .zero) == nil)
        #expect(PointerMapping.streamPoint(
            viewPoint: point, viewSize: CGSize(width: -960, height: 540),
            streamPixelSize: CGSize(width: 1920, height: 1080)) == nil)
    }

    // MARK: Hold Esc

    /// The arming case, and only it: a first Esc down while a windowed session
    /// holds the pointer.
    @Test func escArmsOnlyWhileCapturedInAWindow() {
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: false,
            windowMode: true, captured: true, armed: false) == .arm)
        // Full screen has no released state to return to.
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: false,
            windowMode: false, captured: true, armed: false) == .none)
        // A free pointer has nothing to free.
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: false,
            windowMode: true, captured: false, armed: false) == .none)
        // Any other key is somebody else's business.
        #expect(EscapeHold.onKeyDown(
            keyCode: 13, isRepeat: false,
            windowMode: true, captured: true, armed: false) == .none)
    }

    /// macOS auto-repeat fires further key-downs while Esc is held. They say
    /// nothing the running timer does not already know, so they must not
    /// restart the dwell - otherwise a hold would never expire.
    @Test func escRepeatsAndDoubleArmsAreIgnored() {
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: true,
            windowMode: true, captured: true, armed: true) == .none)
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: true,
            windowMode: true, captured: true, armed: false) == .none)
        #expect(EscapeHold.onKeyDown(
            keyCode: EscapeHold.keyCode, isRepeat: false,
            windowMode: true, captured: true, armed: true) == .none)
    }

    /// A tap - down then up inside the dwell - cancels, which is what leaves
    /// the Esc a plain game input. The cancel is deliberately not gated on
    /// window mode or capture, so a dwell survived by a release from some
    /// other path is still cancellable.
    @Test func escKeyUpCancelsAnArmedHoldOnly() {
        #expect(EscapeHold.onKeyUp(keyCode: EscapeHold.keyCode, armed: true) == .cancel)
        #expect(EscapeHold.onKeyUp(keyCode: EscapeHold.keyCode, armed: false) == .none)
        #expect(EscapeHold.onKeyUp(keyCode: 13, armed: true) == .none)
    }

    /// Long enough that a menu tap can never trip it, short enough to feel
    /// like a way out rather than a wait.
    @Test func escHoldIsAboutASecond() {
        #expect(EscapeHold.holdSeconds == 1.0)
        #expect(EscapeHold.keyCode == 53)   // kVK_Escape
    }

    // MARK: Capture hint budget

    /// Three shows, then never again.
    @Test func theHintShowsThreeTimes() {
        #expect(CaptureHintPolicy.maxShows == 3)
        #expect(CaptureHintPolicy.shouldShow(count: 0))
        #expect(CaptureHintPolicy.shouldShow(count: 1))
        #expect(CaptureHintPolicy.shouldShow(count: 2))
        #expect(!CaptureHintPolicy.shouldShow(count: 3))
        #expect(!CaptureHintPolicy.shouldShow(count: 99))
    }

    /// Walking the budget from a fresh install lands on exactly three shows.
    @Test func theBudgetIsSpentInThreeCaptures() {
        var count = 0
        var shows = 0
        for _ in 0..<10 where CaptureHintPolicy.shouldShow(count: count) {
            shows += 1
            count = CaptureHintPolicy.nextCount(after: count)
        }
        #expect(shows == 3)
        #expect(count == 3)
    }

    /// A corrupt or hand-edited negative default self-heals into the normal
    /// budget instead of showing forever.
    @Test func aNegativeCountSelfHeals() {
        #expect(CaptureHintPolicy.shouldShow(count: -5))
        #expect(CaptureHintPolicy.nextCount(after: -5) == 1)
        #expect(CaptureHintPolicy.nextCount(after: 2) == 3)
    }
}
