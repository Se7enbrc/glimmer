// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
import SwiftUI
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerStatsTests {
    @Test func touchHelpNeverRequiresAnAbsentKeyboard() {
        #expect(StreamControlsHelp.menuHint.hasPrefix("Tap"))
        #expect(!StreamControlsHelp.menuHint.contains("Control-"))
        #expect(StreamControlsHelp.keyboardHint(connected: false, stats: "⌃Z", stop: "⌃Q") == nil)
        let hint = StreamControlsHelp.keyboardHint(connected: true, stats: "⌃Z", stop: "⌃Q")
        #expect(hint?.contains("⌃Z") == true && hint?.contains("⌃Q") == true)
    }

    @Test func chromeSharesMacHysteresisAndIgnoresInvalidSamples() {
        let appearance = StreamOverlayAppearance()
        #expect(appearance.colorScheme == nil)
        appearance.update(luminance: .nan)
        #expect(appearance.colorScheme == nil)
        appearance.update(luminance: 0)
        #expect(appearance.colorScheme == .dark)
        appearance.update(luminance: pow(0.60, 2.4))
        #expect(appearance.colorScheme == .dark)
        appearance.update(luminance: pow(0.63, 2.4))
        #expect(appearance.colorScheme == .light)
        for value in [pow(0.5, 2.4), Double.infinity, -1] { appearance.update(luminance: value) }
        #expect(appearance.colorScheme == .light)
        appearance.update(luminance: pow(0.47, 2.4))
        #expect(appearance.colorScheme == .dark)
    }

    @Test func chromeDoesNotCollectStatsAndStopsWhenAllOverlaysHide() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var collections: [Bool] = []
        var sampling: [Bool] = []
        var reads = 0
        var rect = CGRect.zero
        let stats = StreamStats(surface: surface, snapshot: { reads += 1; return .init() },
            collection: { collections.append($0) }, videoSize: { CGSize(width: 1920, height: 1080) },
            backdrop: { rect = $0; return 0.85 }, chromeSampling: { sampling.append($0) })
        stats.setChromeVisible(true)
        #expect(stats.isRefreshing && !stats.overlay.isVisible && reads == 0 && collections.isEmpty)
        #expect(sampling == [true] && rect.width == 1)
        #expect(surface.overlayAppearance.colorScheme == .light)
        stats.setVisible(true)
        #expect(reads == 1 && collections == [true])
        stats.setVisible(false)
        #expect(stats.isRefreshing && reads == 1)
        stats.setChromeVisible(false)
        #expect(!stats.isRefreshing && sampling == [true, false] && rect == .zero)
    }

    @Test func chromeSamplesOnlyTheVisiblePictureAfterAspectFill() {
        let video = CGSize(width: 1920, height: 1080)
        let wide = StreamStats.chromeSampleRect(view: CGSize(width: 800, height: 400), video: video)
        #expect(wide.width == 1 && wide.height < 1 && wide.minY > 0)
        let narrow = StreamStats.chromeSampleRect(view: CGSize(width: 320, height: 600), video: video)
        #expect(narrow.width < 1 && narrow.height == 1 && narrow.minX > 0)
        #expect(StreamStats.chromeSampleRect(view: .zero, video: video) == .zero)
    }

    @Test func statsGrowWithTheWindowAndHonorItsTextSize() throws {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 667, height: 375))
        let overlay = StatsOverlayLayer()
        overlay.displayView = surface
        overlay.attach(to: surface.layer)
        overlay.update(snapshot: .init(), enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        let phone = overlay.layer.frame.size
        surface.bounds.size = CGSize(width: 1376, height: 1032)
        overlay.layoutInHost(surface.layer)
        #expect(overlay.layer.frame.width > phone.width)
        #expect(overlay.layer.frame.height > phone.height)
        surface.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        surface.updateTraitsIfNeeded()
        overlay.update(snapshot: .init(), enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        #expect(overlay.resolvedLabelFont.pointSize > 20)
        for size in [CGSize(width: 320, height: 600), CGSize(width: 667, height: 375),
                     CGSize(width: 1920, height: 1080)] {
            surface.bounds.size = size
            overlay.update(snapshot: .init(), enabled: StatsOverlayDefaults.extendedRows, targetFps: 60)
            #expect(surface.bounds.contains(overlay.layer.frame))
        }
    }

    @Test func shortcutAndMenuToggleTheSameOverlayOnlyDuringStreaming() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.toggleStats()
        #expect(!model.statsShown)
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        fixture.statsHistory.removeAll()
        model.receive(fixture.update(.input(.statsRequested)))
        #expect(model.statsShown && fixture.statsHistory == [true])
        model.toggleStats()
        #expect(!model.statsShown && fixture.statsHistory == [true, false])
        model.stop()
        await model.waitUntilStopped()
        model.receive(fixture.update(.input(.statsRequested)))
        #expect(!model.statsShown)
    }

    @Test func statsStopRefreshingWhenHiddenOrBackgroundedAndExposeAccessibleRows() throws {
        let configuration = StreamConnection.Configuration(width: 64, height: 64, fps: 60,
                                                            bitrateKbps: 20_000, videoFormats: .h264)
        let decoder = VideoDecoder(configuration: configuration, displayInfo: { nil })
        defer { decoder.teardown() }
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        surface.layoutIfNeeded()
        let stats = StreamStats(surface: surface, snapshot: { decoder.overlaySnapshot() },
            collection: { decoder.statsOverlayEnabled = $0 }, videoSize: { CGSize(width: 1920, height: 1080) },
            backdrop: { decoder.hudBackdropRect = $0; return decoder.hudBackdropLuminance })
        stats.setVisible(true)
        #expect(stats.overlay.isVisible && stats.isRefreshing)
        #expect(surface.accessibilityValue?.isEmpty == false)
        stats.setVisible(false)
        #expect(!stats.overlay.isVisible && !stats.isRefreshing)
        #expect(surface.accessibilityValue == nil)
        stats.setVisible(true)
        #expect(stats.overlay.isVisible)
        stats.setVisible(false)
    }

    @Test func overlaySamplesTheVisibleTopOfTheCroppedPicture() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        surface.layoutIfNeeded()
        let overlay = StatsOverlayLayer()
        overlay.displayView = surface
        overlay.attach(to: surface.displayLayer)
        overlay.videoSize = CGSize(width: 1920, height: 1080)
        overlay.update(snapshot: .init(), enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        overlay.setVisible(true)
        let rect = overlay.backdropSampleRect
        #expect(rect.width > 0 && rect.height > 0 && rect.minY < 0.25)
        #expect(surface.displayLayer.bounds.contains(overlay.layer.frame))
    }

    @Test func controlQAlwaysOffersAnIndependentStopCommand() throws {
        let controller = StreamViewController(model: PlaybackFixture().model(), close: {})
        let command = try #require(controller.keyCommands?.first { $0.input == "q" })
        #expect(controller.canBecomeFirstResponder)
        #expect(command.input == "q" && command.modifierFlags == .control)
        #expect(command.wantsPriorityOverSystemBehavior)
    }
}
