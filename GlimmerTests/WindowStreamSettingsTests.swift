//
//  WindowStreamSettingsTests.swift
//
//  Covers the Window-mode request derivation (size choice + refresh choice,
//  clamped to the shared bounds and capped at the display), the persisted
//  defaults and migration (a fresh install is Full screen; Custom remembers
//  the last values entered; out-of-range values heal on load), and the
//  window geometry (pixel-mapped opening size, fit-to-screen, aspect
//  conformance of a restored frame). All pure - no AppModel, screen, or
//  window involved.
//

import CoreGraphics
import Foundation
import Testing
@testable import Glimmer

struct WindowStreamSettingsTests {

    // MARK: Request derivation

    @Test func presetSizesResolveToTheCuratedPixels() {
        var settings = WindowStreamSettings()
        settings.refreshChoice = .displayMax
        let expected: [(WindowStreamSizeChoice, Int, Int)] = [
            (.hd720, 1280, 720), (.hd1080, 1920, 1080), (.qhd1440, 2560, 1440), (.uhd4K, 3840, 2160)
        ]
        for (choice, width, height) in expected {
            settings.sizeChoice = choice
            #expect(settings.request(displayMaxHz: 120) == WindowStreamRequest(width: width, height: height, fps: 120))
        }
    }

    @Test func customSizeIsClampedToTheSharedBounds() {
        var settings = WindowStreamSettings()
        settings.sizeChoice = .custom
        settings.customWidth = 99_999
        settings.customHeight = 10
        var request = settings.request(displayMaxHz: 60)
        #expect(request.width == 7680)
        #expect(request.height == 480)
        settings.customWidth = 100
        settings.customHeight = 99_999
        request = settings.request(displayMaxHz: 60)
        #expect(request.width == 640)
        #expect(request.height == 4320)
        // In-range custom values pass through untouched.
        settings.customWidth = 2560
        settings.customHeight = 1600
        request = settings.request(displayMaxHz: 60)
        #expect(request.width == 2560)
        #expect(request.height == 1600)
    }

    @Test func displayMaximumFollowsTheDisplay() {
        var settings = WindowStreamSettings()
        settings.refreshChoice = .displayMax
        #expect(settings.request(displayMaxHz: 120).fps == 120)
        #expect(settings.request(displayMaxHz: 60).fps == 60)
        #expect(settings.request(displayMaxHz: 240).fps == 240)
    }

    @Test func fixedRefreshIsCappedAtTheDisplay() {
        var settings = WindowStreamSettings()
        settings.refreshChoice = .hz120
        // A 60 Hz panel can't show 120 - asking would only drop frames.
        #expect(settings.request(displayMaxHz: 60).fps == 60)
        #expect(settings.request(displayMaxHz: 144).fps == 120)
        settings.refreshChoice = .hz60
        #expect(settings.request(displayMaxHz: 120).fps == 60)
    }

    @Test func customRefreshIsClampedThenCapped() {
        var settings = WindowStreamSettings()
        settings.refreshChoice = .custom
        settings.customFPS = 144
        #expect(settings.request(displayMaxHz: 120).fps == 120)
        #expect(settings.request(displayMaxHz: 240).fps == 144)
        settings.customFPS = 5
        #expect(settings.request(displayMaxHz: 120).fps == 30)
        settings.customFPS = 1000
        #expect(settings.request(displayMaxHz: 240).fps == 240)
    }

    @Test func unknownDisplayRefreshFallsBackTo60() {
        var settings = WindowStreamSettings()
        settings.refreshChoice = .displayMax
        #expect(settings.request(displayMaxHz: 0).fps == 60)
        settings.refreshChoice = .hz120
        #expect(settings.request(displayMaxHz: -1).fps == 60)
    }

    // MARK: Defaults + persistence

    private func freshSuite() throws -> UserDefaults {
        let name = "io.ugfugl.Glimmer.tests.windowStream.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test func freshInstallIsFullScreenWithTheDefaultWindowRequest() throws {
        #expect(StreamDisplayMode.persisted(rawValue: nil) == .fullScreen)
        #expect(StreamDisplayMode.defaultMode == .fullScreen)
        let loaded = WindowStreamSettings.load(from: try freshSuite())
        #expect(loaded == WindowStreamSettings())
        #expect(loaded.sizeChoice == .hd1080)
        #expect(loaded.refreshChoice == .displayMax)
        #expect(loaded.request(displayMaxHz: 120) == WindowStreamRequest(width: 1920, height: 1080, fps: 120))
    }

    @Test func modeRawValuesDecodeAndUnknownLandsOnFullScreen() {
        #expect(StreamDisplayMode.persisted(rawValue: "window") == .window)
        #expect(StreamDisplayMode.persisted(rawValue: "fullScreen") == .fullScreen)
        // A downgrade from a build with a mode this one doesn't know.
        #expect(StreamDisplayMode.persisted(rawValue: "floating") == .fullScreen)
        #expect(StreamDisplayMode.persisted(rawValue: "") == .fullScreen)
    }

    @Test func customValuesRoundTripAndSurviveAPresetChoice() throws {
        let suite = try freshSuite()
        var settings = WindowStreamSettings()
        settings.sizeChoice = .custom
        settings.customWidth = 2560
        settings.customHeight = 1600
        settings.refreshChoice = .custom
        settings.customFPS = 144
        settings.save(to: suite)
        #expect(WindowStreamSettings.load(from: suite) == settings)
        // Picking a preset must not forget the custom numbers - switching back
        // to Custom finds the last values entered.
        settings.sizeChoice = .hd720
        settings.refreshChoice = .hz60
        settings.save(to: suite)
        let reloaded = WindowStreamSettings.load(from: suite)
        #expect(reloaded.sizeChoice == .hd720)
        #expect(reloaded.refreshChoice == .hz60)
        #expect(reloaded.customWidth == 2560)
        #expect(reloaded.customHeight == 1600)
        #expect(reloaded.customFPS == 144)
    }

    @Test func outOfRangePersistedValuesHealOnLoad() throws {
        let suite = try freshSuite()
        suite.set(99_999, forKey: WindowStreamSettings.Keys.width)
        suite.set(10, forKey: WindowStreamSettings.Keys.height)
        suite.set(1000, forKey: WindowStreamSettings.Keys.fps)
        suite.set("nonsense", forKey: WindowStreamSettings.Keys.sizeChoice)
        let loaded = WindowStreamSettings.load(from: suite)
        #expect(loaded.customWidth == 7680)
        #expect(loaded.customHeight == 480)
        #expect(loaded.customFPS == 240)
        // An unrecognised choice keeps the declared default.
        #expect(loaded.sizeChoice == .hd1080)
    }

    @Test func absentKeysKeepDeclaredDefaults() throws {
        let suite = try freshSuite()
        suite.set("uhd4K", forKey: WindowStreamSettings.Keys.sizeChoice)
        let loaded = WindowStreamSettings.load(from: suite)
        #expect(loaded.sizeChoice == .uhd4K)
        #expect(loaded.customWidth == 1920)
        #expect(loaded.customHeight == 1080)
        #expect(loaded.customFPS == 60)
        #expect(loaded.refreshChoice == .displayMax)
    }

    @Test func windowKeysNeverTouchTheFullscreenCustomPreset() {
        // The split the file header promises: none of the window keys is one
        // of the Custom preset's.
        let windowKeys = [
            WindowStreamSettings.Keys.sizeChoice, WindowStreamSettings.Keys.width,
            WindowStreamSettings.Keys.height, WindowStreamSettings.Keys.refreshChoice,
            WindowStreamSettings.Keys.fps
        ]
        for key in windowKeys {
            #expect(!["customWidth", "customHeight", "customFPS"].contains(key))
        }
    }

    // MARK: Window geometry

    @Test func pixelMappedSizeDividesByTheBackingScale() {
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1920, pixelHeight: 1080, backingScaleFactor: 2)
            == CGSize(width: 960, height: 540))
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1920, pixelHeight: 1080, backingScaleFactor: 1)
            == CGSize(width: 1920, height: 1080))
        // A screen mid-reconfigure reports 0 - treat as 1x, never divide by it.
        #expect(StreamWindowGeometry.pixelMappedContentSize(pixelWidth: 1280, pixelHeight: 720, backingScaleFactor: 0)
            == CGSize(width: 1280, height: 720))
    }

    @Test func fitPreservesAspectAndNeverScalesUp() {
        let fourK = CGSize(width: 3840, height: 2160)
        #expect(StreamWindowGeometry.fitted(fourK, within: CGSize(width: 1920, height: 1200))
            == CGSize(width: 1920, height: 1080))
        // Height-bound: a tall available area limits by height.
        #expect(StreamWindowGeometry.fitted(fourK, within: CGSize(width: 4000, height: 1080))
            == CGSize(width: 1920, height: 1080))
        // Already fits: unchanged, never enlarged.
        let small = CGSize(width: 960, height: 540)
        #expect(StreamWindowGeometry.fitted(small, within: CGSize(width: 1920, height: 1080)) == small)
    }

    @Test func restoredFrameIsConformedToTheStreamAspect() {
        // A 16:10 saved frame opened for a 16:9 stream keeps its width and
        // takes the 16:9 height - no letterbox on the first frame.
        let saved = CGSize(width: 1000, height: 625)
        let aspect = CGSize(width: 1920, height: 1080)
        #expect(StreamWindowGeometry.conformed(saved, toAspect: aspect, within: CGSize(width: 3000, height: 2000))
            == CGSize(width: 1000, height: 562.5))
        // ...and still fits the screen afterwards.
        #expect(StreamWindowGeometry.conformed(saved, toAspect: aspect, within: CGSize(width: 800, height: 600))
            == CGSize(width: 800, height: 450))
    }

    @Test func minimumSizeSitsOnTheAspectLine() {
        #expect(StreamWindowGeometry.minimumContentSize(aspect: CGSize(width: 16, height: 9))
            == CGSize(width: 640, height: 360))
        #expect(StreamWindowGeometry.minimumContentSize(aspect: CGSize(width: 16, height: 10))
            == CGSize(width: 640, height: 400))
        // A degenerate aspect falls back to 16:9 rather than a zero height.
        #expect(StreamWindowGeometry.minimumContentSize(aspect: .zero) == CGSize(width: 640, height: 360))
    }
}
