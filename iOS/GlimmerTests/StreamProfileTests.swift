// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

struct StreamProfileTests {
    @Test(arguments: [CGSize(width: 750, height: 972), CGSize(width: 1536, height: 2048),
                      CGSize(width: 1014, height: 1290), CGSize(width: 2064, height: 2752),
                      CGSize(width: 1488, height: 2266), CGSize(width: 1620, height: 2160),
                      CGSize(width: 1668, height: 2224), CGSize(width: 1640, height: 2360),
                      CGSize(width: 1668, height: 2388), CGSize(width: 1668, height: 2420),
                      CGSize(width: 2048, height: 2732)])
    func iPadWindowKeepsItsPixelOrder(pixels: CGSize) throws {
        for size in [pixels, CGSize(width: pixels.height, height: pixels.width)] {
            let format = try StreamProfile.native120.resolve(windowPixels: size, maximumFramesPerSecond: 60)
            #expect(format == StreamFormat(width: Int(size.width), height: Int(size.height), fps: 60))
        }
    }

    @Test func iPadFullHDKeepsWindowAspectWithoutUpscaling() throws {
        let portrait = try StreamProfile.fullHD60.resolve(windowPixels: CGSize(width: 1536, height: 2048),
                                                          maximumFramesPerSecond: 120)
        #expect(portrait == StreamFormat(width: 1080, height: 1440, fps: 60))
        let narrow = try StreamProfile.fullHD120.resolve(windowPixels: CGSize(width: 750, height: 1706),
                                                        maximumFramesPerSecond: 60)
        #expect(narrow == StreamFormat(width: 750, height: 1706, fps: 60))
    }

    @Test(arguments: [CGSize(width: 751, height: 973), CGSize(width: 600, height: 1000),
                      CGSize(width: 9000, height: 7000), CGSize(width: 1000, height: 3000)],
          StreamProfile.allCases)
    func iPadRequestsRespectSharedBoundsAndKeepAspect(pixels: CGSize, profile: StreamProfile) throws {
        let format = try profile.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
        #expect(StreamSizeBounds.width.contains(format.width) && StreamSizeBounds.height.contains(format.height))
        #expect(format.width.isMultiple(of: 2) && format.height.isMultiple(of: 2))
        let error = abs(Double(format.width) / Double(format.height) - pixels.width / pixels.height)
        #expect(error < 0.005)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1000),
                      CGSize(width: 1000, height: CGFloat.nan), CGSize(width: -1, height: 10000)])
    func invalidWindowDoesNotRequestAnInvalidDecoderSize(pixels: CGSize) {
        #expect(throws: StreamProfile.Failure.self) {
            try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
        }
    }

    @Test(arguments: StreamProfile.allCases)
    func tallNarrowWindowNeverFailsTheDecoderMinimum(profile: StreamProfile) throws {
        let format = try profile.resolve(windowPixels: CGSize(width: 640, height: 2752),
                                         maximumFramesPerSecond: 120)
        #expect(format.width == 640)
        #expect(format.height == (profile == .native120 ? 2752 : 1920))
    }

    @Test func mouseHandUsesTheMatchingSharedEngineMapping() {
        #expect(ControllerMouseStick.right.mapping == .rightStick)
        #expect(ControllerMouseStick.left.mapping == .leftStick)
        #expect(ControllerMouseStick.right.controls.contains("R2 clicks. R1 right-clicks."))
        #expect(ControllerMouseStick.left.controls.contains("L2 clicks. L1 right-clicks."))
    }

    @Test(arguments: ["", " ", "https://pc.local", "pc.local:47989", "pc.local/path", "pc.local?x=1",
                      "user@pc.local", "pc.local#fragment", "999.1.2.3", "pc..local", "-pc.local"])
    func manualAddressRejectsNonAddressInput(text: String) {
        #expect(PCAddress.parse(text) == nil)
    }

    @Test func manualAddressAcceptsNativeIPAndSimpleHostnames() {
        #expect(PCAddress.parse(" 192.0.2.50\n") == "192.0.2.50")
        #expect(PCAddress.parse("2001:db8::1") == "2001:db8::1")
        #expect(PCAddress.parse("Gaming-PC.local") == "gaming-pc.local")
    }

    @Test(arguments: [CGSize(width: 1206, height: 2622), CGSize(width: 2622, height: 1206)])
    func nativePixelsStayLandscapeAcrossOrientation(pixels: CGSize) throws {
        let format = try StreamProfile.native120.resolve(nativePixels: pixels, maximumFramesPerSecond: 120)
        #expect(format == StreamFormat(width: 2622, height: 1206, fps: 120))
        #expect(format.pacingFPS == 120)
        #expect(format.summary == "2622 × 1206 · 120 fps")
    }

    @Test(arguments: [
        (CGSize(width: 2436, height: 1125), StreamFormat(width: 2436, height: 1124, fps: 60)),
        (CGSize(width: 1179, height: 2556), StreamFormat(width: 2556, height: 1178, fps: 120)),
        (CGSize(width: 2557, height: 1179), StreamFormat(width: 2556, height: 1178, fps: 120))
    ])
    func nativeRequestsRoundBothDimensionsDownToEven(pixels: CGSize, expected: StreamFormat) throws {
        let format = try StreamProfile.native120.resolve(nativePixels: pixels,
                                                         maximumFramesPerSecond: expected.fps)
        #expect(format == expected)
    }

    @Test func profilesKeepResolutionAndCapPacingToDisplayCapability() throws {
        let pixels = CGSize(width: 1206, height: 2622)
        let baseline = try StreamProfile.fullHD60.resolve(nativePixels: pixels, maximumFramesPerSecond: 120)
        let fast = try StreamProfile.fullHD120.resolve(nativePixels: pixels, maximumFramesPerSecond: 120)
        let capped = try StreamProfile.native120.resolve(nativePixels: pixels, maximumFramesPerSecond: 60)
        #expect(baseline == StreamFormat(width: 1920, height: 1080, fps: 60))
        #expect(fast == StreamFormat(width: 1920, height: 1080, fps: 120))
        #expect(capped == StreamFormat(width: 2622, height: 1206, fps: 60))
        #expect(capped.pacingFPS == 60 && capped.summary.hasSuffix("60 fps"))
        let anotherDisplay = try StreamProfile.native120.resolve(
            nativePixels: CGSize(width: 2048, height: 2732), maximumFramesPerSecond: 120)
        #expect(anotherDisplay.width == 2732 && anotherDisplay.height == 2048)
    }

    @Test func missingDisplayCannotSilentlyBecomeA1080pNativeStream() {
        #expect(throws: StreamProfile.Failure.self) {
            try StreamProfile.native120.resolve(nativePixels: .zero, maximumFramesPerSecond: 120)
        }
        #expect(throws: StreamProfile.Failure.self) {
            try StreamProfile.native120.resolve(nativePixels: CGSize(width: 1206, height: 2622),
                                                maximumFramesPerSecond: 0)
        }
    }

    @Test func nativeIsTheFirstStreamFormat() {
        #expect(StreamProfile.allCases.first == .native120)
    }
}
