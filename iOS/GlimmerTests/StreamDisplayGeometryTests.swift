// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

struct StreamDisplayGeometryTests {
    @Test func nativeStreamUsesDrawableWindowPixelsWithoutExceedingThePanel() throws {
        let pixels = StreamDisplayGeometry.pixels(viewSize: CGSize(width: 500, height: 700), scale: 2,
                                                  screenPixels: CGSize(width: 2388, height: 1668))
        #expect(pixels == CGSize(width: 1000, height: 1400))
        let format = try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
        #expect(StreamDisplayModes.bundled.contains(format) && format.height > format.width)
        #expect(StreamDisplayGeometry.pixels(viewSize: CGSize(width: 3840, height: 2160), scale: 2,
            screenPixels: CGSize(width: 3840, height: 2160)) == CGSize(width: 3840, height: 2160))
    }

    @Test(arguments: [(CGSize(width: 3840, height: 2160), 60), (CGSize(width: 1080, height: 1920), 120),
                      (CGSize(width: 3440, height: 1440), 144)])
    func externalModesKeepTheirOwnOrientationAndRefreshLimit(pixels: CGSize, refresh: Int) throws {
        let format = try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: refresh)
        #expect(StreamDisplayModes.bundled.contains(format))
        #expect((format.width > format.height) == (pixels.width > pixels.height))
        #expect(format.fps <= min(120, refresh))
    }

    @Test func relativeInputUsesTheFittedPictureInTheControlWindow() {
        let delta = CGPoint(x: 10, y: -5)
        let stream = CGSize(width: 1920, height: 1080)
        let letterboxed = StreamDisplayGeometry.relativeMotion(delta,
            viewSize: CGSize(width: 1000, height: 1000), streamSize: stream)
        #expect(abs(letterboxed.x - 19.2) < 0.001)
        #expect(abs(letterboxed.y + 9.6) < 0.001)
        let pillarboxed = StreamDisplayGeometry.relativeMotion(delta,
            viewSize: CGSize(width: 2000, height: 500), streamSize: stream)
        #expect(abs(pillarboxed.x - 21.6) < 0.001)
        #expect(abs(pillarboxed.y + 10.8) < 0.001)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: -1)])
    func detachedOrInvalidGeometryDoesNotProduceInputOrDimensions(size: CGSize) {
        #expect(StreamDisplayGeometry.pixels(viewSize: size, scale: 2,
            screenPixels: CGSize(width: 3840, height: 2160)) == .zero)
        #expect(StreamDisplayGeometry.relativeMotion(CGPoint(x: 10, y: 10), viewSize: size,
            streamSize: CGSize(width: 1920, height: 1080)) == .zero)
    }
}
