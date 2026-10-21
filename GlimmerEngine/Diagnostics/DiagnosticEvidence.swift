// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Offline evidence export. Completeness describes recorded evidence, never physical display delivery.
package enum DiagnosticEvidence {
    package enum Failure: Error { case invalidSession, unsafePath, outputExists, limit, malformed }
    static let maxBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maxMetadata = 4 * 1024 * 1024
    static let maxLine = 1024 * 1024
    static let unknowns = ["Physical scanout is unobserved.",
                           "VideoToolbox hardware execution and internal queue wait are unobserved.",
                           "Allocation stacks require a separately verified external capture."]

    struct FileRecord: Codable {
        let name: String
        let bytes: UInt64
        let sha256: String
        let sourceChanged: Bool
    }

    struct Segment {
        let name: String
        let records: Int
        let first: UInt64?
        let last: UInt64?
        let bytes: UInt64
    }

    struct Bookmark: Codable {
        let timeMs: Double
        let total: UInt64?
        let windowStartMs: Double
        let windowEndMs: Double
        var counts: [String: Int] = [:]
        var maximumMs: [String: Double] = [:]
        var observations = 0

        init(timeMs: Double, total: UInt64? = nil) {
            self.timeMs = timeMs
            self.total = total
            windowStartMs = max(0, timeMs - 10_000)
            windowEndMs = timeMs + 2000
        }
    }

    struct Report: Codable {
        let schema: Int
        let session: String
        let complete: Bool
        let issues: [String]
        let files: [FileRecord]
        let counts: [String: Int]
        let attempts: [String]
        let bookmarks: [Bookmark]
        let unknowns: [String]
    }

    final class Context {
        let session: String
        let source: URL
        let output: URL
        var files: [FileRecord] = []
        var issues: Set<String> = []
        var bytes: UInt64 = 0
        var metrics: String?
        var report: String?
        var expectedMetricRows: Int?
        var startedMs: Double?
        var frames: [Segment] = []
        var counts: [String: Int] = [:]
        var eventLabels: Set<String> = []
        var attempts: Set<String> = []
        var bookmarks: [Bookmark] = []
        var lastSequence: UInt64 = 0

        init(session: String, source: URL, output: URL) {
            self.session = session; self.source = source; self.output = output
        }

        func issue(_ text: String) { issues.insert(text) }
    }

    /// The caller chooses a new directory; existing files and the source capture are never modified.
    @discardableResult
    package static func bundle(sessionID: String, source: URL, output: URL) throws -> URL {
        guard sessionID.count == 16, sessionID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw Failure.invalidSession
        }
        try validateDirectory(source)
        try validateDirectory(output.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.outputExists }
        guard safeName(output.lastPathComponent), output.standardizedFileURL.path != source.standardizedFileURL.path else {
            throw Failure.unsafePath
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let context = Context(session: sessionID, source: source, output: output)
        selectFiles(context)
        analyze(context)
        let report = Report(schema: 1, session: sessionID, complete: context.issues.isEmpty,
                            issues: context.issues.sorted(), files: context.files.sorted { $0.name < $1.name },
                            counts: context.counts, attempts: context.attempts.sorted(),
                            bookmarks: context.bookmarks, unknowns: unknowns)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try writePrivate(encoder.encode(report), to: output.appendingPathComponent("manifest.json"))
        try writePrivate(Data(markdown(report).utf8), to: output.appendingPathComponent("summary.md"))
        return output.appendingPathComponent("manifest.json")
    }

    static func markdown(_ report: Report) -> String {
        var lines = ["# Diagnostic evidence: \(report.session)", "",
                     report.complete ? "Capture completeness: complete." : "Capture completeness: INCOMPLETE.", "",
                     "\(report.files.count) copied files; originals preserved. SHA-256 hashes are in manifest.json."]
        if !report.issues.isEmpty { lines += [""] + report.issues.map { "- \($0)" } }
        lines += ["", "## Observed rows", ""]
        lines += report.counts.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
        lines += ["", "## Bookmark context", "",
                  "Each window covers 10 seconds before and 2 seconds after the bookmark on the process uptime clock."]
        if report.bookmarks.isEmpty { lines.append("No bookmark was recorded.") }
        for bookmark in report.bookmarks {
            lines += ["", "### \(String(format: "%.3f", bookmark.timeMs)) ms", "",
                      "\(bookmark.observations) timestamped rows in this window."]
            lines += bookmark.counts.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
            lines += bookmark.maximumMs.sorted { $0.key < $1.key }.map {
                "- Maximum observed \($0.key): \(String(format: "%.3f", $0.value)) ms"
            }
        }
        lines += ["", "## Measurement limits", ""] + report.unknowns.map { "- \($0)" }
        lines += ["- Timing intervals describe client boundaries; no cause is inferred from coincidence.", ""]
        return lines.joined(separator: "\n")
    }
}
