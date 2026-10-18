// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
import os
@testable import Glimmer

struct GlimmerDiagnosticCaptureTests {
    private static let identity = "17 Sun Oct 18 10:00:00 2026 /Applications/Glimmer.app/Contents/MacOS/Glimmer"

    private static let options = """
        {"Time Profiler":{"contextSwitchSampling":true,"recordWaitingThreads":true,"recordKernelStacks":true}}
        """

    private static let toc = """
        <trace-toc><run number="1"><info><target><process pid="17"/>
        <environment><item key="PRIVATE_ENV" value="omit"/></environment></target><summary>
        <start-date>2026-10-18T10:00:00Z</start-date><end-date>2026-10-18T10:15:01Z</end-date>
        <duration>901</duration></summary></info><data>
        <table schema="time-profile" record-waiting-threads="1" needs-kernel-callstack="1" context-switch-sampling="1"/>
        <table schema="time-sample" all-thread-states="YES" sample-rate-micro-seconds="5000"/>
        <table schema="thread-state"/></data></run></trace-toc>
        """

    private static func rows(clock: String) -> String {
        """
        <trace-query-result><node><row><\(clock) id="1">1000000</\(clock)>
        <thread><process id="2"><pid id="3">17</pid></process></thread><process ref="2"/></row>
        <row><\(clock) ref="1"/><process ref="2"/></row>
        <row><\(clock) id="4">900000000000</\(clock)><process ref="2"/></row>
        <row><\(clock) id="5">999000000000</\(clock)><process id="6"><pid>99</pid></process>
        <thread><process ref="2"/></thread></row></node></trace-query-result>
        """
    }

    private static func clockRows(secondOffset: UInt64 = 1_000_000_000, secondTrace: UInt64 = 2_000_000_000) -> String {
        var rows = "<root>"
        for id in [UInt64(1), 2] {
            let trace = id == 1 ? 1_000_000_000 : secondTrace
            let uptime = trace + (id == 1 ? 1_000_000_000 : secondOffset)
            for begin in [true, false] {
                let event = begin ? "Begin" : "End"
                let field = begin ? "before" : "after"
                let clock = begin ? uptime : uptime + 500
                let process = id == 1 && begin
                    ? "<process id='p'><pid>17</pid></process>" : "<process ref='p'/>"
                rows += """
                    <row><event-time>\(trace + (begin ? 0 : 1000))</event-time>\(process)
                    <signpost-name>GlimmerClockAnchor\(event)</signpost-name>
                    <subsystem>io.ugfugl.Glimmer</subsystem><category>PointsOfInterest</category>
                    <os-log-metadata>session=0123456789abcdef anchor_id=\(id) uptime_\(field)_ns=\(clock)</os-log-metadata></row>
                    """
            }
        }
        return rows + "</root>"
    }

    private func fixture() throws -> (base: URL, output: URL, options: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let options = base.appendingPathComponent("options.json")
        try Data(Self.options.utf8).write(to: options)
        return (base, base.appendingPathComponent("capture"), options)
    }

    @Test func captureVerifiesActualTargetRowsAndKeepsTheConfiguredProbe() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calls = OSAllocatedUnfairLock(initialState: [GlimmerDiagnosticCapture.Command]())
        let manifest = try await GlimmerDiagnosticCapture.run(pid: 17, output: fixture.output,
            recordingOptions: fixture.options, runner: { command in
                calls.withLock { $0.append(command) }
                let text: String
                switch command.label {
                case "target", "target-before", "target-after", "target-after-preflight": text = Self.identity
                case "options": text = Self.options
                case "toc": text = Self.toc
                case "time-profile": text = Self.rows(clock: "sample-time")
                case "thread-state": text = Self.rows(clock: "start-time")
                case "clock-anchors": text = Self.clockRows()
                default: text = "fixture"
                }
                try? Data(text.utf8).write(to: command.stdout)
                return .init(command: command, started: Date(), ended: Date(), exitCode: 0, status: "completed")
            }, spaceAvailable: { _ in 30 * 1_073_741_824 })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(GlimmerDiagnosticCapture.Manifest.self, from: Data(contentsOf: manifest))
        #expect(report.status == "observed_rows_with_bounded_clock_anchors")
        #expect(report.coverage?.targetSampleRows == 3 && report.coverage?.targetSchedulingRows == 3)
        #expect(report.coverage?.firstSampleNanos == 1_000_000)
        #expect(report.coverage?.lastSampleNanos == 900_000_000_000)
        #expect(report.coverage?.configuredSamplePeriodsMicroseconds == [5000])
        #expect(try !String(contentsOf: fixture.output.appendingPathComponent("toc.stdout"), encoding: .utf8)
            .contains("PRIVATE_ENV"))
        let commands = calls.withLock { $0 }
        let record = try #require(commands.first { $0.label == "record" })
        #expect(record.arguments.contains("--attach") && record.arguments.contains("15m"))
        #expect(!record.arguments.contains("--launch") && record.timeoutSeconds == 1200)
        let scheduling = try #require(commands.first { $0.label == "thread-state" })
        #expect(scheduling.maximumOutputBytes == 12 * 1_073_741_824 && scheduling.timeoutSeconds == 600)
    }

    @Test func failedAttachmentNeverBecomesSuccessfulBecauseAnOutputDirectoryExists() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let manifest = try await GlimmerDiagnosticCapture.run(pid: 17, output: fixture.output,
            recordingOptions: fixture.options, runner: { command in
                calls.withLock { $0.append(command.label) }
                let text = command.label.hasPrefix("target") ? Self.identity
                    : (command.label == "clock-anchors" ? Self.clockRows() : Self.options)
                try? Data(text.utf8).write(to: command.stdout)
                if command.label == "record" {
                    try? Data("Failed to attach to target process".utf8).write(to: command.stderr)
                }
                return .init(command: command, started: Date(), ended: Date(),
                    exitCode: command.label == "record" ? 1 : 0, status: "completed")
            }, spaceAvailable: { _ in 30 * 1_073_741_824 })
        let row = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(row["status"] as? String == "permission_or_attachment_failed")
        #expect(!calls.withLock { $0.contains("toc") || $0.contains("thread-state") })
    }

    @Test func insufficientSpaceStartsNoProfilerAndMissingTimeReferencesStayUnverified() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let manifest = try await GlimmerDiagnosticCapture.run(pid: 17, output: fixture.output,
            recordingOptions: fixture.options, runner: { command in
                calls.withLock { $0 += 1 }
                return .init(command: command, started: Date(), ended: Date(), exitCode: 0, status: "completed")
            }, spaceAvailable: { _ in 1 })
        let row = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(row["status"] as? String == "insufficient_free_space" && calls.withLock { $0 } == 0)
        let samples = fixture.base.appendingPathComponent("samples.xml")
        try Data("<root><row><sample-time ref='999'/><process><pid>17</pid></process></row></root>".utf8)
            .write(to: samples)
        #expect(GlimmerDiagnosticCapture.inspectSamples(samples, pid: 17) == nil)
    }

    @Test func changedProcessIdentityStopsBeforeRecording() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let manifest = try await GlimmerDiagnosticCapture.run(pid: 17, output: fixture.output,
            recordingOptions: fixture.options, runner: { command in
                calls.withLock { $0.append(command.label) }
                var text = command.label.hasPrefix("target") ? Self.identity : Self.options
                if command.label == "target-before" { text = text.replacingOccurrences(of: "10:00:00", with: "10:00:01") }
                try? Data(text.utf8).write(to: command.stdout)
                return .init(command: command, started: Date(), ended: Date(), exitCode: 0, status: "completed")
            }, spaceAvailable: { _ in 30 * 1_073_741_824 })
        let row = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(row["status"] as? String == "target_changed_before_recording")
        #expect(!calls.withLock { $0.contains("record") })
    }

    @Test func unknownProcessReferencesDoNotCountAsVerifiedNonTargetRows() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let url = fixture.base.appendingPathComponent("rows.xml")
        let text = "<root><row><start-time>123</start-time><process ref='missing'/></row></root>"
        try Data(text.utf8).write(to: url)
        #expect(GlimmerDiagnosticCapture.inspectSamples(url, pid: 17) == nil)
        #expect(GlimmerDiagnosticCapture.boundedRead(url, maximum: 8) == nil)
    }

    @Test func timestampCacheNeedsOnlyReferencedDefinitions() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let url = fixture.base.appendingPathComponent("rows.xml")
        try Data(Self.rows(clock: "start-time").utf8).write(to: url)
        let parser = try #require(XMLParser(contentsOf: url))
        let refs = GlimmerDiagnosticCapture.ClockReferences(deadline: ProcessInfo.processInfo.systemUptime + 60)
        parser.delegate = refs
        #expect(parser.parse() && refs.ids == [1])
        let summary = try #require(GlimmerDiagnosticCapture.inspectSamples(url, pid: 17))
        #expect(summary.rows == 4 && summary.targetRows == 3)
    }

    @Test func clockAnchorsBoundAlignmentAndRejectDiscontinuitiesOrMissingPairs() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let url = fixture.base.appendingPathComponent("clock.xml")
        try Data(Self.clockRows().utf8).write(to: url)
        let clock = GlimmerDiagnosticCapture.inspectClock(url, pid: 17)
        #expect(clock.status == "bounded_clock_verified")
        #expect(clock.lowerOffsetNanos == 1_000_000_000 && clock.upperOffsetNanos == 1_000_000_500)
        #expect(clock.anchors.count == 2 && clock.firstTraceNanos == 1_000_000_000)
        #expect(clock.sessions.first?.largestGapNanos == 1_000_000_000 && clock.sessions.first?.pairs == 2)
        #expect(GlimmerDiagnosticCapture.inspectClock(url, pid: 99).status == "anchors_insufficient")
        try Data(Self.clockRows(secondTrace: 5_000_000_000).utf8).write(to: url)
        #expect(GlimmerDiagnosticCapture.inspectClock(url, pid: 17).status == "clock_alignment_partial")
        try Data(Self.clockRows().replacingOccurrences(of: "ref='p'", with: "ref='missing'").utf8).write(to: url)
        #expect(GlimmerDiagnosticCapture.inspectClock(url, pid: 17).status == "anchors_malformed")
        try Data(Self.clockRows(secondOffset: 2_000_000_000).utf8).write(to: url)
        #expect(GlimmerDiagnosticCapture.inspectClock(url, pid: 17).status == "clock_intervals_disagree")
        try Data(Self.clockRows().replacingOccurrences(of: "GlimmerClockAnchorEnd", with: "OtherEvent").utf8).write(to: url)
        let missing = GlimmerDiagnosticCapture.inspectClock(url, pid: 17)
        #expect(missing.status == "anchors_unpaired" && missing.unpairedEvents == 2)
    }

    @Test func preflightRejectsMissingMetadataBeforeLongRecording() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let manifest = try await GlimmerDiagnosticCapture.run(pid: 17, output: fixture.output,
            recordingOptions: fixture.options, runner: { command in
                calls.withLock { $0.append(command.label) }
                let text = command.label.hasPrefix("target") ? Self.identity : Self.options
                try? Data(text.utf8).write(to: command.stdout)
                return .init(command: command, started: Date(), ended: Date(), exitCode: 0, status: "completed")
            }, spaceAvailable: { _ in 30 * 1_073_741_824 })
        let row = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(row["status"] as? String == "clock_preflight_failed")
        #expect(calls.withLock { $0.contains("clock-preflight-record") && !$0.contains("record") })
    }
}
