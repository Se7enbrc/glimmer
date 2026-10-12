// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetrySinkTests.swift
//  NDJSON file, event rows, bookmark and session report, plus the StreamSession start/stop wiring.
//

import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

// Serialized: start() and stop() own the process-wide event sink and pre-start pen.
// A class, so the scratch directory goes in deinit whether the test passed or not.
@Suite(.serialized)
final class TelemetrySinkTests {

    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetrySinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        TelemetryExporter.resetPreStartEventBuffer()
        try? FileManager.default.removeItem(at: dir)
    }

    private func exporter(in directory: URL? = nil, counters: TelemetryCounters = TelemetryCounters())
        -> TelemetryExporter {
        TelemetryExporter.captureBaselines = TelemetryExporter.CaptureBaselines()
        return TelemetryExporter(
            source: TelemetryListenerTests.source(), serverName: "Den PC", outputDirectory: directory ?? dir,
            counters: counters, port: 0, listenOnLAN: false)
    }

    private func lines(_ exporter: TelemetryExporter) throws -> [String] {
        let url = try #require(exporter.workQueue.sync { exporter.ndjsonURL })
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func rows(_ exporter: TelemetryExporter) throws -> [[String: Any]] {
        try lines(exporter).map(TelemetryRenderFixtures.row)
    }

    private func reportNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("telemetry-session-") }
    }

    // MARK: - NDJSON file

    @Test func openCreatesTheDirectoryAndEveryAppendIsOnDiskAtOnce() throws {
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        let exporter = exporter(in: nested)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.appendNDJSON("{\"n\":1}")
        }
        defer { exporter.workQueue.sync { try? exporter.fileHandle?.close() } }
        let url = try #require(exporter.workQueue.sync { exporter.ndjsonURL })
        #expect(url.deletingLastPathComponent().standardizedFileURL == nested.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("telemetry-") && url.pathExtension == "ndjson")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"n\":1}\n")
        exporter.workQueue.sync { exporter.appendNDJSON("{\"n\":2}") }
        #expect(try lines(exporter) == ["{\"n\":1}", "{\"n\":2}"])
    }

    @Test func aDirectoryThatCannotBeCreatedLeavesTheSinkOff() throws {
        let blocker = dir.appendingPathComponent("not-a-dir")
        try Data().write(to: blocker)
        let exporter = exporter(in: blocker)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.appendNDJSON("{\"n\":1}")
            exporter.writeSessionReport()
        }
        #expect(exporter.workQueue.sync { exporter.ndjsonURL } == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["not-a-dir"])
    }

    @Test func openingTheFileSweepsExpiredLogsButNeverAForeignFile() throws {
        let fm = FileManager.default
        let expired = dir.appendingPathComponent("telemetry-2026-09-01T00:00:00Z.ndjson")
        let foreign = dir.appendingPathComponent("notes.txt")
        try Data("old\n".utf8).write(to: expired)
        try Data("keep\n".utf8).write(to: foreign)
        let longAgo = Date(timeIntervalSinceNow: -20 * 24 * 3600)
        try fm.setAttributes([.modificationDate: longAgo, .creationDate: longAgo], ofItemAtPath: expired.path)
        let exporter = exporter()
        exporter.workQueue.sync { exporter.openNDJSONFile() }
        defer { exporter.workQueue.sync { try? exporter.fileHandle?.close() } }
        #expect(!fm.fileExists(atPath: expired.path))
        #expect(fm.fileExists(atPath: foreign.path))
        let url = try #require(exporter.workQueue.sync { exporter.ndjsonURL })
        #expect(fm.fileExists(atPath: url.path))
    }

    @Test func aClosedFileDropsRowsInsteadOfFailing() throws {
        let exporter = exporter()
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.appendNDJSON("{\"n\":1}")
            try? exporter.fileHandle?.close()
            exporter.appendNDJSON("{\"n\":2}")
            exporter.fileHandle = nil
            exporter.appendNDJSON("{\"n\":3}")
        }
        #expect(try lines(exporter) == ["{\"n\":1}"])
    }

    // MARK: - Session report

    @Test func noReportWithoutAnNDJSONFile() throws {
        let exporter = exporter()
        exporter.workQueue.sync { exporter.writeSessionReport() }
        #expect(try reportNames().isEmpty)
    }

    @Test func reportLandsBesideTheRowsWithTheSessionsTally() throws {
        let counters = TelemetryCounters()
        counters.rfiTotal.increment(by: 3)
        let exporter = exporter(counters: counters)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.capture()
            exporter.writeSessionReport()
            try? exporter.fileHandle?.close()
        }
        let name = try #require(try reportNames().first)
        #expect(name.hasSuffix(".json"))
        let report = try TelemetryRenderFixtures.row(
            String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
        #expect(report["schema"] as? String == "glimmer.session_report.v1")
        #expect(report["session"] as? String == exporter.sessionId)
        #expect(report["host"] as? String == TelemetryRenderer.pseudonym("Den PC"))
        #expect(report["ticks"] as? Int == 1)
        #expect(((report["duration_s"] as? Double) ?? -1) >= 0)
        let events = try #require(report["events"] as? [String: Any])
        #expect(events["rfi"] as? Int == 3)
    }

    // MARK: - Bookmark and event rows

    @Test func bookmarkCountsEvenBeforeTheFileOpensButOnlyWritesAfter() throws {
        let counters = TelemetryCounters()
        let exporter = exporter(counters: counters)
        #expect(exporter.recordBookmark() == 1)
        exporter.workQueue.sync { exporter.openNDJSONFile() }
        defer { exporter.workQueue.sync { try? exporter.fileHandle?.close() } }
        #expect(exporter.recordBookmark() == 2)
        exporter.workQueue.sync {}
        let written = try rows(exporter)
        #expect(written.count == 1)
        let row = try #require(written.first)
        #expect(row["event"] as? String == "bookmark" && row["kind"] as? String == "felt_bad")
        #expect(row["bookmark_total"] as? Int == 2)
        #expect(row["session"] as? String == exporter.sessionId)
        #expect(counters.bookmarkTotal.value == 2)
    }

    @Test func liveEventsNeedARunningExporter() {
        TelemetryExporter.resetPreStartEventBuffer()
        var built = false
        TelemetryExporter.recordLiveEvent({ built = true; return ["\"event\":\"gap\""] }())
        #expect(!built)
        TelemetryExporter.recordEvent(["\"event\":\"audio_ttf\""])
        #expect(TelemetryExporter.preStartEvents.drain().map(\.fields) == [["\"event\":\"audio_ttf\""]])
    }

    @Test func preStartPenIsBoundedAndClearedAtTheConnectEdge() {
        TelemetryExporter.resetPreStartEventBuffer()
        for index in 0..<(TelemetryExporter.PreStartEventBuffer.maxBuffered + 5) {
            TelemetryExporter.recordEvent(["\"n\":\(index)"])
        }
        TelemetryExporter.resetPreStartEventBuffer()
        TelemetryExporter.recordEvent(["\"n\":-1"])
        let drained = TelemetryExporter.preStartEvents.drain()
        #expect(drained.map(\.fields) == [["\"n\":-1"]])
        for index in 0..<(TelemetryExporter.PreStartEventBuffer.maxBuffered + 5) {
            TelemetryExporter.recordEvent(["\"n\":\(index)"])
        }
        #expect(TelemetryExporter.preStartEvents.drain().count == TelemetryExporter.PreStartEventBuffer.maxBuffered)
    }

    // MARK: - start() and stop()

    @Test func startFlushesThePenWritesLiveEventsAndStopWritesTheReport() async throws {
        TelemetryExporter.resetPreStartEventBuffer()
        TelemetryExporter.recordEvent(["\"event\":\"audio_ttf\"", "\"ms\":12"])
        let exporter = exporter()
        exporter.start()
        _ = try await TelemetryListenerTests.readyPort(exporter)
        TelemetryExporter.recordEvent(["\"event\":\"audio_pending\""])
        TelemetryExporter.recordLiveEvent(["\"event\":\"video_gap\""])
        exporter.stop()
        TelemetryExporter.recordEvent(["\"event\":\"after_stop\""])

        let events = try rows(exporter).compactMap { $0["event"] as? String }
        #expect(events.first == "config")
        #expect(events.contains("audio_ttf") && events.contains("audio_pending") && events.contains("video_gap"))
        #expect(!events.contains("after_stop"))
        #expect(try rows(exporter).allSatisfy { $0["session"] as? String == exporter.sessionId })
        #expect(try reportNames().count == 1)
        #expect(exporter.workQueue.sync { exporter.fileHandle == nil && exporter.listener == nil })
        #expect(TelemetryExporter.eventSinkBox.withLock { $0 } == nil)
        #expect(FrameTimingTracker.shared == nil)
        #expect(TelemetryExporter.preStartEvents.drain().map(\.fields) == [["\"event\":\"after_stop\""]])
    }

    // MARK: - StreamSession wiring

    @Test func sessionWithTheGateOffBuildsNothing() async {
        let session = StreamSession()
        let decoder = await VideoDecoder()
        await session.startTelemetryExporter(decoder: decoder, serverName: "Den PC", enabled: false) { _, _ in
            Issue.record("built an exporter with telemetry off")
            return nil
        }
        #expect(await session.telemetryExporter == nil)
        await session.recordTelemetryBookmark()
        await session.stopTelemetryExporter()
    }

    @Test func sessionStartsTheExporterWithTheDecodersShapeAndStopsIt() async throws {
        let session = StreamSession()
        let decoder = await VideoDecoder()
        decoder.streamWidth = 3840
        decoder.streamHeight = 2160
        decoder.streamFps = 120
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_MASK_AV1
        let counters = TelemetryCounters()
        let dir = dir
        await session.startTelemetryExporter(decoder: decoder, serverName: "Den PC", enabled: true) { source, name in
            #expect(name == "Den PC")
            #expect(source.displayMode == StreamDisplayMode.defaultMode.rawValue)
            #expect(source.stream?.width == 3840 && source.stream?.height == 2160 && source.stream?.fps == 120)
            #expect(source.stream?.codec == "av1" && source.stream?.bitrate == nil)
            return TelemetryExporter(source: source, serverName: name, outputDirectory: dir,
                                     counters: counters, port: 0, listenOnLAN: false)
        }
        let exporter = try #require(await session.telemetryExporter)
        _ = try await TelemetryListenerTests.readyPort(exporter)
        await session.recordTelemetryBookmark()
        #expect(counters.bookmarkTotal.value == 1)

        await session.stopTelemetryExporter()
        #expect(await session.telemetryExporter == nil)
        #expect(exporter.workQueue.sync { exporter.listener == nil && exporter.fileHandle == nil })
        #expect(try reportNames().count == 1)
        await session.stopTelemetryExporter()
    }
}
