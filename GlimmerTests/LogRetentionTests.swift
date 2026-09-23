//
//  LogRetentionTests.swift
//
//  What survives in Logs/Glimmer: the sweep's age and byte passes (traces go
//  before 1Hz NDJSON; Diag logs and receipts only ever age out) and the
//  per-frame trace rollover, which keeps the connect segment.
//

import Foundation
import os
import Testing
@testable import Glimmer

struct LogSweepTests {

    private let log = Logger(subsystem: "io.ugfugl.Glimmer.tests", category: "LogSweep")
    private let budget = TelemetryExporter.logsByteBudget
    private let day: TimeInterval = 86_400

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `size`-byte file last modified `age` ago. Sparse, so a budget-sized
    /// file costs no real disk.
    private func make(_ name: String, in dir: URL, size: UInt64 = 1_024, age: TimeInterval) throws {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
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
        try make("telemetry-frames-b.ndjson", in: dir, size: budget / 2, age: 3_600)
        try make("telemetry-b.ndjson", in: dir, age: 3_600)
        try make("notes.txt", in: dir, size: budget, age: 3 * day)

        TelemetryExporter.sweepLogsDirectory(dir, log: log)

        #expect(try names(in: dir) == [
            "glimmer-a.log", "telemetry-session-a.json", "telemetry-a.ndjson",
            "telemetry-frames-b.ndjson", "telemetry-b.ndjson", "notes.txt"])
    }

    /// With every trace gone and still over budget, 1Hz files go oldest-first,
    /// and the Diag log still stays.
    @Test func budgetThenDropsTheOldestNDJSON() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try make("glimmer-a.log", in: dir, age: 4 * day)
        try make("telemetry-a.ndjson", in: dir, size: budget * 3 / 5, age: 3 * day)
        try make("telemetry-b.ndjson", in: dir, size: budget * 3 / 5, age: day)
        try make("telemetry-frames-c.ndjson", in: dir, age: 3_600)

        TelemetryExporter.sweepLogsDirectory(dir, log: log)

        #expect(try names(in: dir) == ["glimmer-a.log", "telemetry-b.ndjson"])
    }

    /// The launch sweep ages out every family but leaves an over-budget
    /// directory to the next diagnostics session.
    @Test func launchSweepOnlyAges() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try make("glimmer-old.log", in: dir, age: 15 * day)
        try make("telemetry-session-old.json", in: dir, age: 15 * day)
        try make("telemetry-frames-old.ndjson", in: dir, age: 15 * day)
        try make("telemetry-frames-new.ndjson", in: dir, size: budget * 2, age: 3_600)

        TelemetryExporter.sweepLogsDirectory(dir, log: log, enforceBudget: false)

        #expect(try names(in: dir) == ["telemetry-frames-new.ndjson"])
    }
}

struct FrameTraceRolloverTests {

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
