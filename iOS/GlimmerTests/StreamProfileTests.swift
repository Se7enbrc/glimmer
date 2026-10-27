// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

struct StreamProfileTests {
    @Test func bothDevicesUseTheSameOrderedProfilesAndListedRequests() throws {
        #expect(StreamProfile.allCases == [.native120, .fullHD60, .fullHD120])
        let pixels = CGSize(width: 751, height: 973)
        #expect(try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
            == StreamFormat(width: 750, height: 972, fps: 60))
        #expect(try StreamProfile.fullHD60.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
            == StreamFormat(width: 1920, height: 1080, fps: 60))
        #expect(try StreamProfile.fullHD120.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
            == StreamFormat(width: 1920, height: 1080, fps: 120))
    }

    @Test func bundledModesAllResolveExactlyWithoutInventingRefreshRates() throws {
        #expect(StreamDisplayModes.bundled.count == 90)
        for mode in StreamDisplayModes.bundled {
            let resolved = try StreamProfile.native120.resolve(
                windowPixels: CGSize(width: mode.width, height: mode.height), maximumFramesPerSecond: mode.fps)
            #expect(resolved == mode)
            #expect(StreamSizeBounds.width.contains(mode.width) && StreamSizeBounds.height.contains(mode.height))
            #expect(mode.width.isMultiple(of: 2) && mode.height.isMultiple(of: 2))
        }
    }

    @Test(arguments: [CGSize(width: 751, height: 973), CGSize(width: 600, height: 1000),
                      CGSize(width: 9000, height: 7000), CGSize(width: 640, height: 2752),
                      CGSize(width: 1179, height: 2556), CGSize(width: 1371, height: 1031)],
          StreamProfile.allCases)
    func everyRequestIsListedAndCapped(pixels: CGSize, profile: StreamProfile) throws {
        for cap in [60, 90, 120, 144] {
            let mode = try profile.resolve(windowPixels: pixels, maximumFramesPerSecond: cap)
            #expect(StreamDisplayModes.bundled.contains(mode))
            #expect(mode.fps <= min(cap, profile == .fullHD60 ? 60 : 120))
            if profile != .native120 { #expect(mode.width == 1920 && mode.height == 1080) }
        }
    }

    @Test(arguments: [60, 120])
    func everyWindowTargetKeepsTheRunningRateListed(fps: Int) throws {
        for target in StreamDisplayModes.bundled {
            let resized = try StreamProfile.native120.resolve(
                windowPixels: CGSize(width: target.width, height: target.height),
                maximumFramesPerSecond: fps, requiredFPS: fps)
            #expect(resized.fps == fps)
            #expect(StreamDisplayModes.bundled.contains(resized))
        }
    }

    @Test func resizedDataModePairsSupportTheRunningFPS() {
        for mode in StreamDisplayModes.bundled {
            let formats = StreamFormats(resizing: mode)
            #expect(formats.full == mode)
            #expect(formats.lowData.fps == mode.fps)
            #expect(StreamDisplayModes.bundled.contains(formats.lowData))
        }
    }

    @Test(arguments: [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1000),
                      CGSize(width: 1000, height: CGFloat.nan), CGSize(width: -1, height: 10000)])
    func invalidWindowCannotRequestAnInvalidMode(pixels: CGSize) {
        #expect(throws: StreamProfile.Failure.self) {
            try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
        }
    }

    @Test(arguments: [
        (CGSize(width: 2436, height: 1125), StreamFormat(width: 2436, height: 1124, fps: 60)),
        (CGSize(width: 2556, height: 1179), StreamFormat(width: 2556, height: 1178, fps: 120)),
        (CGSize(width: 2557, height: 1179), StreamFormat(width: 2556, height: 1178, fps: 120))
    ])
    func phoneNativeRequestsKeepTheirEvenListedSize(pixels: CGSize, expected: StreamFormat) throws {
        #expect(try StreamProfile.native120.resolve(windowPixels: pixels, maximumFramesPerSecond: expected.fps)
            == expected)
    }

    @Test func portraitAndLandscapePreserveTheirDirection() throws {
        let portrait = try StreamProfile.native120.resolve(windowPixels: CGSize(width: 2064, height: 2752),
                                                            maximumFramesPerSecond: 120)
        let landscape = try StreamProfile.native120.resolve(windowPixels: CGSize(width: 2752, height: 2064),
                                                             maximumFramesPerSecond: 120)
        #expect(portrait == StreamFormat(width: 2064, height: 2752, fps: 120))
        #expect(landscape == StreamFormat(width: 2752, height: 2064, fps: 120))
    }

    @Test func modeReaderRejectsMalformedOrUnsafeCatalogs() {
        for body in ["<width>750</width><height>972</height><refresh_rate>60</refresh_rate>",
                     "<width>751</width><height>972</height><refresh_rate>60</refresh_rate>",
                     "<width>750</width><height>972</height><refresh_rate>59</refresh_rate>",
                     "<width>8000</width><height>972</height><refresh_rate>60</refresh_rate>"] {
            let xml = "<vdd_settings><resolutions><resolution>\(body)</resolution></resolutions></vdd_settings>"
            let result = StreamDisplayModes.parse(Data(xml.utf8))
            #expect(result.count == (body.contains("<width>750</width><height>972</height><refresh_rate>60") ? 1 : 0))
        }
        #expect(StreamDisplayModes.parse(Data("<vdd_settings>".utf8)).isEmpty)
    }

    @Test @MainActor func surfaceUsesIdenticalRulesForPhoneAndPad() async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 683, height: 1032))
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        for profile in StreamProfile.allCases {
            surface.traitOverrides.userInterfaceIdiom = .phone
            let phone = try profile.resolve(surface: surface)
            surface.traitOverrides.userInterfaceIdiom = .pad
            #expect(try profile.resolve(surface: surface) == phone)
        }
    }

    @Test @MainActor func nativeUsesPhysicalPixelsWhenRenderScaleDiffers() async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        surface.traitOverrides.displayScale = 1
        // Physical pixels keep the window aspect and are clamped to the panel, never displayScale points.
        let pixels = surface.streamPixels
        #expect(pixels.width > 640 && abs(pixels.width / pixels.height - 640.0 / 480.0) < 0.01)
        let expected = try StreamProfile.native120.resolve(
            windowPixels: pixels, maximumFramesPerSecond: scene.screen.maximumFramesPerSecond)
        #expect(try StreamProfile.native120.resolve(surface: surface) == expected)
    }

    @Test func aSmallAspectDifferenceDoesNotRequestAFourTimesLargerPanel() throws {
        #expect(try StreamProfile.native120.resolve(windowPixels: CGSize(width: 750, height: 1000),
                                                    maximumFramesPerSecond: 120)
            == StreamFormat(width: 750, height: 972, fps: 60))
    }

    @Test @MainActor func fullScreenNativeKeepsTheListedPhysicalPanelSize() async throws {
        let scene = try await testWindowScene()
        let screen = scene.screen
        let window = UIWindow(windowScene: scene)
        let bounds = screen.bounds.size
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: max(bounds.width, bounds.height),
                                                    height: min(bounds.width, bounds.height)))
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        let mode = try StreamProfile.native120.resolve(surface: surface)
        let native = screen.nativeBounds.size
        #expect(mode.width == Int(max(native.width, native.height)) & ~1)
        #expect(mode.height == Int(min(native.width, native.height)) & ~1)
        let geometry = "nativeBounds: \(native); nativeScale: \(screen.nativeScale); "
            + "displayScale: \(surface.traitCollection.displayScale); requested: \(mode.summary)"
        Attachment.record(Array(geometry.utf8), named: "physical-panel-request.txt")
    }

    @MainActor @Test func controllerMouseMatchesMacAndMenuRemainsReachable() {
        let input = StreamInput(emit: { _ in })
        input.setControllerMouseMapping(.rightStick)
        StreamPlayback.configureInput(input)
        #expect(input.core.controllerMouseMapping == .rightStick)
        #expect(input.core.controllerMenuOpensControls)
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

    @Test func nativeIsTheFirstStreamFormat() {
        #expect(StreamProfile.allCases.first == .native120)
    }

    @Test(arguments: StreamProfile.allCases)
    func lowDataModeUsesAReducedListedModeOfAtMost1080p60(profile: StreamProfile) throws {
        let pixels = CGSize(width: 2622, height: 1206)
        let full = try profile.resolve(windowPixels: pixels, maximumFramesPerSecond: 120)
        let formats = try StreamFormats(full: full, windowPixels: pixels, maximumFramesPerSecond: 120)
        #expect(formats.start(lowData: false) == full)
        let reduced = formats.start(lowData: true)
        #expect(reduced.width <= 1920 && reduced.height <= 1080 && reduced.fps <= 60)
        #expect(formats.sizes == DataModeSizes(fullWidth: full.width, fullHeight: full.height,
                                               lowDataWidth: reduced.width, lowDataHeight: reduced.height))
    }

    @Test func launcherNamesNoFixedRateWhenAdaptive() {
        #expect(StreamProfile.fullHD60.summary(adaptive: false) == "1080p · 60 fps · 20 Mbps requested")
        #expect(StreamProfile.fullHD60.summary(adaptive: true) == "1080p · 60 fps · adaptive bitrate")
    }
}
