//
//  LogRetentionTests.swift
//
//  What survives in Logs/Glimmer: the sweep's age and byte passes (older traces,
//  then older 1Hz, then the latest session; Diag logs and receipts only ever age
//  out) and the per-frame trace rollover, which keeps the connect segment.
//

import Foundation
import os
import Testing
@testable import Glimmer

struct LogSweepTests {

    private let log = Logger(subsystem: "io.ugfugl.Glimmer.tests", category: "LogSweep")
    private let budget = TelemetryExporter.logsByteBudget
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let now = Date()

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `size`-byte file created `created` ago (default `age`) and last modified
    /// `age` ago. Sparse, so a budget-sized file costs no real disk.
    private func make(
        _ name: String, in dir: URL, size: UInt64 = 1_024, age: TimeInterval, created: TimeInterval? = nil
    ) throws {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        try FileManager.default.setAttributes([
            .creationDate: now.addingTimeInterval(-(created ?? age)),
            .modificationDate: now.addingTimeInterval(-age)
        ], ofItemAtPath: url.path)
    }

    private func names(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    /// Over budget, the oldest trace goes first. The older 1Hz file, the Diag
    /// log and the receipt a bug report asks for all survive, as does a
    /// foreign file.
    @Test func budgetDropsTracesBeforeAnythingElse() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try make("glimmer-a.log", in: dir, age: 3 * day)
        try make("telemetry-session-a.json", in: dir, age: 3 * day)
        try make("telemetry-a.ndjson", in: dir, size: budget / 3, age: 3 * day)
        try make("telemetry-frames-a.ndjson", in: dir, size: budget / 2, age: 2 * day)
        try make("telemetry-frames-b.ndjson", in: dir, size: budget / 2, age: hour)
        try make("telemetry-b.ndjson", in: dir, age: hour)
        try make("notes.txt", in: dir, size: budget, age: 3 * day)

        TelemetryExporter.sweepLogsDirectory(dir, log: log)

        #expect(try names(in: dir) == [
            "glimmer-a.log", "telemetry-session-a.json", "telemetry-a.ndjson",
            "telemetry-frames-b.ndjson", "telemetry-b.ndjson", "notes.txt"])
    }

    /// With every older trace gone and still over budget, 1Hz files go
    /// oldest-first, and the Diag log still stays.
    @Test func budgetThenDropsTheOldestNDJSON() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try make("glimmer-a.log", in: dir, age: 4 * day)
        try make("telemetry-a.ndjson", in: dir, size: budget * 3 / 5, age: 3 * day)
        try make("telemetry-b.ndjson", in: dir, size: budget * 3 / 5, age: day)
        try make("telemetry-frames-c.ndjson", in: dir, age: 2 * day)

        TelemetryExporter.sweepLogsDirectory(dir, log: log)

        #expect(try names(in: dir) == ["glimmer-a.log", "telemetry-b.ndjson"])
    }

    /// Older traces, then older 1Hz files, go before anything from the latest
    /// session, which then loses its middle segments first: its connect segment,
    /// newest tail and 1Hz file survive.
    @Test func budgetKeepsTheLatestSessionsConnectAndTail() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = budget * 3 / 10
        // Latest session written first, so only the creation dates mark it as latest.
        let latest = "2026-09-21T18:30:00Z"
        try make("telemetry-\(latest).ndjson", in: dir, size: budget / 5, age: hour, created: 4 * hour)
        try make("telemetry-frames-\(latest).ndjson", in: dir, size: segment, age: 3 * hour, created: 4 * hour)
        try make("telemetry-frames-\(latest)-1.ndjson", in: dir, size: segment, age: 2 * hour, created: 3 * hour)
        try make("telemetry-frames-\(latest)-2.ndjson", in: dir, size: segment, age: 1.5 * hour, created: 2 * hour)
        try make("telemetry-frames-\(latest)-3.ndjson", in: dir, size: segment, age: hour, created: 1.5 * hour)
        try make("telemetry-2026-09-17T10:00:00Z.ndjson", in: dir, size: budget * 9 / 20, age: 4 * day)
        try make("telemetry-frames-2026-09-17T10:00:00Z.ndjson", in: dir, size: segment, age: 4 * day)
        try make("telemetry-frames-2026-09-17T10:00:00Z-1.ndjson", in: dir, size: segment, age: 4 * day)
        try make("telemetry-2026-09-19T10:00:00Z.ndjson", in: dir, size: budget * 9 / 20, age: 2 * day)
        try make("telemetry-frames-2026-09-19T10:00:00Z.ndjson", in: dir, size: segment, age: 2 * day)

        TelemetryExporter.sweepLogsDirectory(dir, log: log)

        #expect(try names(in: dir) == [
            "telemetry-\(latest).ndjson", "telemetry-frames-\(latest).ndjson",
            "telemetry-frames-\(latest)-3.ndjson"])
    }

    /// The launch sweep ages out every family but leaves an over-budget
    /// directory to the next diagnostics session.
    @Test func launchSweepOnlyAges() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try make("glimmer-old.log", in: dir, age: 15 * day)
        try make("telemetry-session-old.json", in: dir, age: 15 * day)
        try make("telemetry-frames-old.ndjson", in: dir, age: 15 * day)
        try make("telemetry-frames-new.ndjson", in: dir, size: budget * 2, age: hour)

        TelemetryExporter.sweepLogsDirectory(dir, log: log, enforceBudget: false)

        #expect(try names(in: dir) == ["telemetry-frames-new.ndjson"])
    }
}

struct FrameTraceRolloverTests {

    @Test func overflowDropsOldestHalfInOneTrim() {
        let limit = 10_000
        var pending = (0..<limit).map(String.init)
        pending.append("newest")

        pending.trimOldestOverflow(maxCount: limit)

        #expect(pending.count == limit / 2)
        #expect(pending.first == String(limit / 2 + 1))
        #expect(pending.last == "newest")
    }

    /// Long sessions keep the first segment (connect, first IDR, pacer
    /// lock-in) plus the newest ones; the middle segments are what go.
    @Test func rolloverKeepsTheConnectSegment() {
        let limit = FrameTraceWriter.maxTraceFiles
        let segments = (0..<(limit + 3)).map { URL(fileURLWithPath: "/segment-\($0).ndjson") }
        var kept: [URL] = []
        var deleted: [URL] = []
        for segment in segments {
            kept.append(segment)
            deleted += FrameTraceWriter.trimSegments(&kept)
        }
        #expect(kept == [segments[0]] + segments.suffix(limit - 1))
        #expect(deleted == Array(segments[1...3]))
    }
}
