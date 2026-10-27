// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamStatsShortcutTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "stats-shortcuts-\(UUID().uuidString)"))
    }

    @Test func freshDefaultsStayAbsentAndExplicitChoicesSurviveReset() throws {
        let defaults = try defaults()
        let shortcuts = StreamShortcuts(defaults: defaults)
        #expect(shortcuts.stats == .defaultStats)
        #expect(defaults.data(forKey: "statsHotkey") == nil)
        #expect(defaults.object(forKey: "statsControlZDefaultApplied") == nil)
        let controlI = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        shortcuts.stats = controlI
        #expect(StreamShortcuts(defaults: defaults).stats == controlI)
        SettingsReset.reset(defaults: defaults)
        let reset = StreamShortcuts(defaults: defaults)
        #expect(reset.stats == .defaultStats)
        #expect(defaults.data(forKey: "statsHotkey") == nil)
        reset.stats = controlI
        #expect(StreamShortcuts(defaults: defaults).stats == controlI)
    }

    @Test func defaultsMigrationPreservesLaterExplicitChoices() throws {
        let defaults = try defaults()
        let old = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        defaults.set(try JSONEncoder().encode(old), forKey: "statsHotkey")
        let shortcuts = StreamShortcuts(defaults: defaults)
        #expect(shortcuts.stats == .defaultStats)
        shortcuts.stats = old
        #expect(StreamShortcuts(defaults: defaults).stats == old)
        #expect(defaults.object(forKey: "showStreamStats") == nil)
    }

    @Test func remappedChordConsumesRepeatsAndReleaseBeforeOtherInput() throws {
        let shortcuts = StreamShortcuts(defaults: try defaults())
        shortcuts.stats = HotkeyChord(ctrl: false, alt: false, shift: true, cmd: true, keyChar: "s")
        var performed: [StreamShortcuts.Action] = []
        #expect(shortcuts.handle(input: "S", modifiers: [.shift, .command]) { performed.append($0) })
        #expect(shortcuts.handle(input: "s", modifiers: [.shift, .command]) { performed.append($0) })
        #expect(performed == [.stats])
        #expect(shortcuts.release(input: "s"))
        #expect(shortcuts.release(input: "s") == false)
        #expect(shortcuts.handle(input: "z", modifiers: .control) { performed.append($0) } == false)
        #expect(shortcuts.handle(input: "s", modifiers: .command) { performed.append($0) } == false)
        #expect(shortcuts.handle(input: "s", modifiers: [.shift, .command]) { performed.append($0) })
        shortcuts.reset()
        #expect(shortcuts.handle(input: "s", modifiers: [.shift, .command]) { performed.append($0) })
        #expect(performed == [.stats, .stats, .stats])
    }

    @Test func recordingRejectsDuplicatesAndShiftOnly() {
        #expect(HotkeyChord.defaultStats.recordingConflict(taken: [("Stats", .defaultStats)])
            == "Already used for Stats.")
        let shift = HotkeyChord(ctrl: false, alt: false, shift: true, cmd: false, keyChar: "a")
        #expect(shift.recordingConflict(taken: []) != nil)
        #expect(HotkeyChord.defaultStats.recordingConflict(taken: [("Stop Streaming", .defaultQuit)]) == nil)
    }

    @Test func overlayFormattingUsesMacOrderAndWords() {
        var snapshot = StreamStatsSnapshot()
        snapshot.hostFps = 59.9
        snapshot.rttMs = 5.9
        snapshot.measuredBitrateMbps = 45.2
        snapshot.videoCodec = "HEVC"
        let rows = StatsOverlayLayer.displayRows(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows,
                                                targetFps: 60, thresholds: .default)
        #expect(rows.map(\.label) == ["Render", "Latency", "Bitrate"])
        #expect(rows.map(\.value) == ["59.9 FPS", "5.90 ms", "45.2 Mbps · HEVC"])
    }

    @Test func extendedRowsUseColumnsInShortLandscapeWindows() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 667, height: 375))
        let overlay = StatsOverlayLayer()
        overlay.displayView = surface
        overlay.attach(to: surface.displayLayer)
        overlay.update(snapshot: StreamStatsSnapshot(), enabled: StatsOverlayDefaults.extendedRows, targetFps: 60)
        #expect(overlay.layer.frame.width > 300)
        #expect(overlay.layer.affineTransform().a > 0.9)
        #expect(surface.bounds.contains(overlay.layer.frame))
        #expect(overlay.rowViews.values.contains { $0.container.frame.minX > 0 })
    }

    @Test func hiddenOverlayHasNoTimerOrSnapshotReadsAndRebindsAfterRendererReplacement() throws {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        var reads = 0
        var collection: [Bool] = []
        var sampledRects: [CGRect] = []
        let stats = StreamStats(surface: surface, defaults: try defaults(), snapshot: {
            reads += 1
            return StreamStatsSnapshot()
        }, collection: { collection.append($0) }, videoSize: { CGSize(width: 1920, height: 1080) },
           backdrop: { sampledRects.append($0); return nil })
        #expect(stats.isRefreshing == false && reads == 0)
        stats.setVisible(true)
        #expect(stats.isRefreshing && reads == 1)
        stats.setVisible(true)
        #expect(reads == 1)
        _ = surface.replaceDisplayLayer { _ in }
        stats.layout()
        #expect(stats.overlay.layer.superlayer === surface.displayLayer)
        stats.setVisible(false)
        #expect(stats.isRefreshing == false && reads == 1)
        #expect(collection == [true, false])
        #expect(sampledRects.last == .zero)
        #expect(surface.accessibilityValue == nil)
    }

    @Test func menuAndKeyboardToggleOnlyThisSessionAndPauseWithScene() async throws {
        let defaults = try defaults()
        defaults.set(true, forKey: "showStreamStats")
        let events = AsyncStream<StreamSession.Update>.makeStream()
        let id = UUID()
        var visibility: [Bool] = []
        let model = StreamSessionModel(launch: testLaunch(), defaults: defaults, makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: events.stream, start: { nil }, stop: {}, screenChanged: {},
                           showStats: { visibility.append($0) })
        })
        model.start(surface: StreamSurface())
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        #expect(model.statsShown && visibility.last == true)
        model.performShortcut(.stats)
        #expect(model.statsShown == false && visibility.last == false)
        model.toggleStats()
        #expect(model.statsShown && visibility.last == true)
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: true)
        #expect(visibility.last == false)
        #expect(defaults.bool(forKey: "showStreamStats"))
        model.stop()
        await model.waitUntilStopped()
        #expect(visibility.last == false)
        events.continuation.finish()
    }

    @Test func shortcutHUDUsesSavedChordsAndSystemPriority() throws {
        let model = PlaybackFixture().model()
        let controller = StreamViewController(model: model, close: {})
        let commands = try #require(controller.keyCommands)
        #expect(commands.map(\.input)
            == ["/", model.shortcuts.quit.keyChar, model.shortcuts.stats.keyChar])
        #expect(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        #expect(commands.map(\.title) == ["Show controls"] + StreamShortcuts.Action.allCases.map(\.title))
    }
}
