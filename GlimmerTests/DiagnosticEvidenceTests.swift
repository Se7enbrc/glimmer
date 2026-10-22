// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
@testable import Glimmer
import CryptoKit
import Foundation
import Testing

struct DiagnosticEvidenceTests {
    private let session = "0123456789abcdef"

    private func fixture() throws -> URL {
        let root = URL.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let metrics = "telemetry-test.ndjson", report = "telemetry-session-test.json"
        try Data("{\"session\":\"\(session)\",\"event\":\"bookmark\",\"t_ms\":1000}\n".utf8)
            .write(to: source.appendingPathComponent(metrics))
        try writeJSON(["session": session], to: source.appendingPathComponent(report))
        try writeJSON(["schema": 1, "session": session, "closed": true,
                       "rows_written": 1, "rows_failed": 0, "write_failures": 0, "started_ms": 0,
                       "metrics_file": metrics, "report_file": report],
                      to: source.appendingPathComponent("telemetry-evidence-\(session).json"))
        let writer = FrameTraceWriter(directory: source, sessionId: session, now: { 1_000_000_000 })
        writer.start(isoStamp: "test")
        writer.appendFrame(FrameTimingTracker.TraceRecord(frameIndex: 1, rtpTimestamp: 90,
            frameBytes: 100, isIDR: false, presentUptimeMs: 1100, isResumePresent: false,
            outputToPresent: 2, attemptID: UUID().uuidString), sessionId: session)
        writer.stop()
        return root
    }

    private func writeJSON(_ row: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: url)
    }

    private func manifest(_ output: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("manifest.json")))
            as? [String: Any])
    }

    @Test func closedCaptureCopiesHashesAndSummarizesBookmarkWindowPrivately() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("bundle")
        try DiagnosticEvidence.bundle(sessionID: session, source: source, output: output)
        let report = try manifest(output)
        #expect(report["complete"] as? Bool == true)
        let files = try #require(report["files"] as? [[String: Any]])
        #expect(files.count == 5)
        for file in files {
            let name = try #require(file["name"] as? String)
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            #expect(data == (try Data(contentsOf: source.appendingPathComponent(name))))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(file["sha256"] as? String == hash)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((permissions[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o700)
        let bookmarks = try #require(report["bookmarks"] as? [[String: Any]])
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0]["window_start_ms"] as? Double == 0)
        #expect(bookmarks[0]["window_end_ms"] as? Double == 3000)
        #expect((bookmarks[0]["maximum_ms"] as? [String: Double])?["output_to_present_ms"] == 2)
        let summary = try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("Physical scanout is unobserved"))
        #expect(summary.contains("no cause is inferred"))
        #expect(summary.contains("10 seconds before and 2 seconds after"))
    }

    @Test(arguments: [false, true])
    func bookmarkCopiesWithDifferentTimestampPrecisionShareOneWindow(legacy: Bool) throws {
        let context = DiagnosticEvidence.Context(session: session, source: .temporaryDirectory, output: .temporaryDirectory)
        let identity = legacy ? "" : "\"bookmark_total\":1,"
        let metrics = try #require(JSONSerialization.jsonObject(with: Data(
            "{\"event\":\"bookmark\",\(identity)\"t_ms\":207221163.30325}".utf8)) as? [String: Any])
        let trace = try #require(JSONSerialization.jsonObject(with: Data(
            "{\"event\":\"bookmark\",\(identity)\"t_ms\":207221163.303}".utf8)) as? [String: Any])
        DiagnosticEvidence.observe(metrics, frame: false, context: context)
        DiagnosticEvidence.observe(trace, frame: true, context: context)
        #expect(context.bookmarks.count == 1)
        #expect(context.bookmarks.first?.timeMs == 207_221_163.30325)
        #expect(context.issues.isEmpty)
        #expect(context.counts["metrics_bookmark"] == 1)
        #expect(context.counts["trace_bookmark"] == 1)
    }

    @Test func separateBookmarkIdentitiesArePreservedEvenAtTheSameTimestamp() {
        let context = DiagnosticEvidence.Context(session: session, source: .temporaryDirectory, output: .temporaryDirectory)
        for total in UInt64(1)...2 {
            DiagnosticEvidence.observe(["event": "bookmark", "bookmark_total": total, "t_ms": 1000.0],
                                       frame: false, context: context)
        }
        #expect(context.bookmarks.count == 2)
        #expect(context.issues.isEmpty)
    }

    @Test func conflictingBookmarkIdentityMarksEvidenceIncomplete() {
        let context = DiagnosticEvidence.Context(session: session, source: .temporaryDirectory, output: .temporaryDirectory)
        for stamp in [1000.0, 2000.0] {
            DiagnosticEvidence.observe(["event": "bookmark", "bookmark_total": UInt64(1), "t_ms": stamp],
                                       frame: false, context: context)
        }
        #expect(context.issues.contains("Bookmark identity has conflicting timestamps."))
    }

    @Test(arguments: [(-10_000.001, false), (-10_000.0, true), (-2040.0, true),
                      (0.0, true), (2000.0, true), (2000.001, false)])
    func bookmarkWindowIncludesReactionTimeButRemainsBounded(_ offset: Double, _ included: Bool) {
        let context = DiagnosticEvidence.Context(session: session, source: .temporaryDirectory, output: .temporaryDirectory)
        context.bookmarks = [DiagnosticEvidence.Bookmark(timeMs: 20_000)]
        DiagnosticEvidence.observeWindows(["event": "decode_output", "t_ms": 20_000 + offset,
                                           "submit_to_output_ms": 2.4], frame: true, context: context)
        #expect(context.bookmarks[0].observations == (included ? 1 : 0))
        #expect(context.bookmarks[0].maximumMs["submit_to_output_ms"] == (included ? 2.4 : nil))
    }

    @Test(arguments: ["missing", "malformed", "sequence", "loss"])
    func incompleteCapturesNeverClaimComplete(_ mode: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("bundle")
        let frame = source.appendingPathComponent("telemetry-frames-test.ndjson")
        if mode == "missing" {
            try FileManager.default.removeItem(at: source.appendingPathComponent("telemetry-evidence-\(session).json"))
        } else if mode == "malformed" {
            try Data("not-json\n".utf8).write(to: frame)
        } else if mode == "sequence" {
            let text = try String(contentsOf: frame, encoding: .utf8).replacingOccurrences(of: "\"trace_seq\":1", with: "\"trace_seq\":3")
            try Data(text.utf8).write(to: frame)
        } else {
            let url = source.appendingPathComponent("telemetry-frames-test-manifest.json")
            var row = try DiagnosticEvidence.metadata(url)
            row["pruned_records"] = 3
            try writeJSON(row, to: url)
        }
        try DiagnosticEvidence.bundle(sessionID: session, source: source, output: output)
        #expect(try manifest(output)["complete"] as? Bool == false)
        #expect(!(try #require(manifest(output)["issues"] as? [String])).isEmpty)
    }

    @Test(arguments: ["symlink", "traversal", "wrong_session"])
    func unsafeOrOtherSessionReferencesAreIncomplete(_ mode: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("bundle")
        let metrics = source.appendingPathComponent("telemetry-test.ndjson")
        if mode == "symlink" {
            let target = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: metrics, to: target)
            try FileManager.default.createSymbolicLink(at: metrics, withDestinationURL: target)
        } else if mode == "traversal" {
            let receipt = source.appendingPathComponent("telemetry-evidence-\(session).json")
            var row = try DiagnosticEvidence.metadata(receipt)
            row["metrics_file"] = "telemetry-../outside.ndjson"
            try writeJSON(row, to: receipt)
        } else {
            try Data("{\"session\":\"ffffffffffffffff\"}\n".utf8).write(to: metrics)
        }
        try DiagnosticEvidence.bundle(sessionID: session, source: source, output: output)
        #expect(try manifest(output)["complete"] as? Bool == false)
    }

    @Test func invalidSessionAndExistingOutputAreRejectedWithoutModification() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        #expect(throws: (any Error).self) {
            try DiagnosticEvidence.bundle(sessionID: "../escape", source: source, output: root.appendingPathComponent("new"))
        }
        #expect(throws: (any Error).self) {
            try DiagnosticEvidence.bundle(sessionID: session, source: source, output: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("telemetry-test.ndjson").path))
    }
    @MainActor @Test(arguments: [false, true])
    func bundleCommandExitStatusReflectsEvidenceCompleteness(_ incomplete: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("bundle")
        if incomplete {
            try FileManager.default.removeItem(at: source.appendingPathComponent("telemetry-evidence-\(session).json"))
        }
        let command = GlimmerCLI.Command(verb: .diagnostics, arguments: ["bundle", session, output.path])
        let status = await GlimmerCLI.diagnostics(command, source: source)
        #expect(status == (incomplete ? GlimmerCLI.Exit.failed : GlimmerCLI.Exit.ok))
        #expect(try manifest(output)["complete"] as? Bool == !incomplete)
    }
}
