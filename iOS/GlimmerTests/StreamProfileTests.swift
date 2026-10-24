// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

struct StreamProfileTests {
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
