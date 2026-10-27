// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerStatsTests {
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
