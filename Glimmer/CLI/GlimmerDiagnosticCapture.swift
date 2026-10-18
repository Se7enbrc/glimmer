// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

/// Explicit CLI capture only: attaches to an existing PID without launching, installing or re-signing it.
enum GlimmerDiagnosticCapture {
    struct Command: Codable, Sendable {
        let label: String
        let executable: String
        let arguments: [String]
        let timeoutSeconds: Double
        let stdout: URL
        let stderr: URL
        var maximumOutputBytes: Int64 = 1_048_576
        var captureDirectory: URL?
    }

    struct CommandResult: Codable, Sendable {
        let command: Command
        let started: Date
        let ended: Date
        let exitCode: Int32?
        let status: String
        var detail: String?
        var succeeded: Bool { status == "completed" && exitCode == 0 }
    }

    struct Coverage: Codable, Sendable {
        var targetMatched = false
        var startDate: String?
        var endDate: String?
        var durationSeconds: Double?
        var schemas: [String] = []
        var requestedProbesConfigured = false
        var configuredSamplePeriodsMicroseconds: [Int] = []
        var sampleRows: Int = 0
        var targetSampleRows: Int = 0
        var firstSampleNanos: UInt64?
        var lastSampleNanos: UInt64?
        var sampleXMLParsed = false
        var schedulingRowsVerified = false
        var schedulingRows = 0
        var targetSchedulingRows = 0
        var firstSchedulingNanos: UInt64?
        var lastSchedulingNanos: UInt64?
    }

    struct Manifest: Codable, Sendable {
        let pid: Int32
        let requestedSeconds: Int
        let started: Date
        var ended: Date?
        var status = "preflight"
        var commands: [CommandResult] = []
        var coverage: Coverage?
        var clockAlignment: ClockAlignment?
        var preflightClockAlignment: ClockAlignment?
        var freeBytesBefore: Int64?
        var limitations = [
            "VM checkpoints are before and after recording, not automatically before and after streaming.",
            "Footprint growth is not proof of leaked allocations; allocation stacks are not recorded here.",
            "System Trace changes measurement overhead. GPU utilization and physical scanout are not established.",
            "Observed row endpoints do not prove continuous stack or scheduling coverage.",
            "The raw trace may retain target environment values; only the TOC sidecar is sanitized.",
            "PID identity checks use ps start time at second precision, not a kernel process handle.",
            "Capture is capped at 20 GiB with 2 GiB free reserve; exceeding either preserves partial evidence."
        ]
    }

    enum CaptureError: Error { case invalidPID }

    typealias Runner = @Sendable (Command) async -> CommandResult
    static let recordingSeconds = 900
    static let waitingSamplesTable = "table[@schema='time-profile'][@record-waiting-threads='1']"
        + "[@needs-kernel-callstack='1'][@context-switch-sampling='1']"

    static func run(pid: Int32, output: URL, recordingOptions: URL,
                    runner: Runner = execute,
                    spaceAvailable: @Sendable (URL) -> Int64? = freeBytes,
                    progress: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            throw CaptureError.invalidPID
        }
        let files = FileManager.default
        let options = try prepareOutput(output, recordingOptions: recordingOptions)
        let manifestURL = output.appendingPathComponent("capture-manifest.json")
        var manifest = Manifest(pid: pid, requestedSeconds: recordingSeconds, started: Date())
        manifest.freeBytesBefore = spaceAvailable(output)
        guard let free = manifest.freeBytesBefore, free >= 30 * 1_073_741_824 else {
            manifest.status = "insufficient_free_space"
            return try finish(&manifest, at: manifestURL)
        }
        func invoke(_ label: String, _ executable: String, _ arguments: [String],
                    timeout: Double = 30, maximum: Int64 = 1_048_576) async throws -> CommandResult {
            let command = Command(label: label, executable: executable, arguments: arguments,
                timeoutSeconds: timeout, stdout: output.appendingPathComponent(label + ".stdout"),
                stderr: output.appendingPathComponent(label + ".stderr"),
                maximumOutputBytes: maximum, captureDirectory: output)
            let result = await runner(command)
            manifest.commands.append(result)
            try save(manifest, to: manifestURL)
            return result
        }
        let identity = await captureIdentity(pid: pid, output: output, label: "target", runner: runner)
        manifest.commands.append(identity)
        guard identity.succeeded, let target = processIdentity(identity.command.stdout), target.pid == pid else {
            manifest.status = "target_unavailable"
            return try finish(&manifest, at: manifestURL)
        }
        let preflight = try await invoke("options", "/usr/bin/xcrun", ["xctrace", "record", "--template",
            "System Trace", "--show-recording-options"])
        guard preflight.succeeded, supportsRequestedOptions(at: preflight.command.stdout) else {
            manifest.status = preflight.succeeded ? "options_unsupported" : failureStatus(preflight)
            return try finish(&manifest, at: manifestURL)
        }
        _ = try await invoke("vmmap-before", "/usr/bin/vmmap", ["-summary", String(pid)], timeout: 60)
        guard await revalidateIdentity(target, manifest: &manifest, output: output, label: "target-before", runner: runner) else {
            manifest.status = "target_changed_before_recording"
            return try finish(&manifest, at: manifestURL)
        }
        manifest.status = "clock_preflight"
        try save(manifest, to: manifestURL)
        guard try await preflightClock(manifest: &manifest, output: output, options: options, runner: runner) else {
            manifest.status = "clock_preflight_failed"
            return try finish(&manifest, at: manifestURL)
        }
        guard await revalidateIdentity(target, manifest: &manifest, output: output, label: "target-after-preflight", runner: runner) else {
            manifest.status = "target_changed_during_preflight"
            return try finish(&manifest, at: manifestURL)
        }
        manifest.status = "recording"
        try save(manifest, to: manifestURL)
        let trace = output.appendingPathComponent("system.trace")
        progress("Clock check passed. Starting the 15-minute recording now.")
        let recording = try await invoke("record", "/usr/bin/xcrun", ["xctrace", "record", "--template",
            "System Trace", "--attach", String(pid), "--time-limit", "15m", "--recording-options", options.path,
            "--output", trace.path], timeout: Double(recordingSeconds + 300))
        guard recording.succeeded else {
            manifest.status = failureStatus(recording)
            return try finish(&manifest, at: manifestURL)
        }
        progress("Recording finished; exporting and validating the captured evidence.")
        guard await revalidateIdentity(target, manifest: &manifest, output: output, label: "target-after", runner: runner) else {
            manifest.status = "target_changed_during_recording"
            return try finish(&manifest, at: manifestURL)
        }
        _ = try await invoke("vmmap-after", "/usr/bin/vmmap", ["-summary", String(pid)], timeout: 60)
        let toc = try await invoke("toc", "/usr/bin/xcrun", ["xctrace", "export", "--input", trace.path, "--toc"],
                                   timeout: 120, maximum: 4_194_304)
        guard toc.succeeded, let coverage = inspectTOC(toc.command.stdout, pid: pid) else {
            try? files.removeItem(at: toc.command.stdout)
            manifest.status = "toc_unverified"
            return try finish(&manifest, at: manifestURL)
        }
        manifest.coverage = coverage
        return try await exportSamples(manifest: &manifest, manifestURL: manifestURL, output: output,
                                       trace: trace, runner: runner, spaceAvailable: spaceAvailable)
    }

    private static func prepareOutput(_ output: URL, recordingOptions: URL) throws -> URL {
        let files = FileManager.default
        guard !files.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try files.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let options = output.appendingPathComponent("recording-options.json")
        guard let data = boundedRead(recordingOptions, maximum: 1_048_576) else { throw CocoaError(.fileReadTooLarge) }
        try privateWrite(data, to: options)
        return options
    }

    struct ProcessIdentity: Equatable {
        let pid: Int32
        let start: String
        let executable: String
    }

    static func processIdentity(_ url: URL) -> ProcessIdentity? {
        guard let data = boundedRead(url, maximum: 65_536), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 6, whereSeparator: \.isWhitespace)
        guard fields.count == 7, let pid = Int32(fields[0]),
              fields[6].hasSuffix("/Contents/MacOS/Glimmer") else { return nil }
        return ProcessIdentity(pid: pid, start: fields[1...5].joined(separator: " "), executable: String(fields[6]))
    }

    private static func revalidateIdentity(_ target: ProcessIdentity, manifest: inout Manifest,
                                           output: URL, label: String, runner: Runner) async -> Bool {
        let result = await captureIdentity(pid: target.pid, output: output, label: label, runner: runner)
        manifest.commands.append(result)
        return result.succeeded && processIdentity(result.command.stdout) == target
    }

    private static func captureIdentity(pid: Int32, output: URL, label: String,
                                        runner: Runner) async -> CommandResult {
        await runner(Command(label: label, executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "pid=,lstart=,comm="], timeoutSeconds: 10,
            stdout: output.appendingPathComponent(label + ".stdout"),
            stderr: output.appendingPathComponent(label + ".stderr"),
            maximumOutputBytes: 65_536, captureDirectory: output))
    }

    private static func exportSamples(manifest: inout Manifest, manifestURL: URL, output: URL,
                                      trace: URL, runner: Runner,
                                      spaceAvailable: @Sendable (URL) -> Int64?) async throws -> URL {
        guard manifest.coverage?.targetMatched == true,
              manifest.coverage?.requestedProbesConfigured == true else {
            manifest.status = "target_or_probes_unverified"
            return try finish(&manifest, at: manifestURL)
        }
        guard let free = spaceAvailable(output), free >= 20 * 1_073_741_824 else {
            manifest.status = "export_insufficient_free_space"
            return try finish(&manifest, at: manifestURL)
        }
        for schema in ["time-profile", "thread-state"] {
            guard manifest.coverage?.schemas.contains(schema) == true else { continue }
            let table = schema == "time-profile" ? Self.waitingSamplesTable : "table[@schema='thread-state']"
            let command = Command(label: schema, executable: "/usr/bin/xcrun", arguments: ["xctrace", "export",
                "--input", trace.path, "--xpath", "/trace-toc/run[@number='1']/data/" + table],
                timeoutSeconds: 600, stdout: output.appendingPathComponent(schema + ".xml"),
                stderr: output.appendingPathComponent(schema + ".stderr"),
                maximumOutputBytes: (schema == "thread-state" ? 12 : 2) * 1_073_741_824,
                captureDirectory: output)
            let result = await runner(command)
            manifest.commands.append(result)
            if result.succeeded, let samples = inspectSamples(command.stdout, pid: manifest.pid) {
                updateCoverage(&manifest, samples: samples, scheduling: schema == "thread-state")
            }
            try save(manifest, to: manifestURL)
        }
        try await exportClock(manifest: &manifest, output: output, trace: trace, runner: runner)
        let coverage = manifest.coverage
        let samplesCover = coversRequestedWindow(first: coverage?.firstSampleNanos, last: coverage?.lastSampleNanos)
        let scheduleCovers = coversRequestedWindow(first: coverage?.firstSchedulingNanos,
                                                   last: coverage?.lastSchedulingNanos)
        if coverage?.sampleXMLParsed == true, coverage?.schedulingRowsVerified == true,
           samplesCover, scheduleCovers {
            manifest.status = manifest.clockAlignment?.status == "bounded_clock_verified"
                ? "observed_rows_with_bounded_clock_anchors" : "clock_alignment_unverified"
        } else {
            manifest.status = "row_coverage_unverified"
        }
        return try finish(&manifest, at: manifestURL)
    }

    private static func updateCoverage(_ manifest: inout Manifest, samples: SampleSummary, scheduling: Bool) {
        if scheduling {
            manifest.coverage?.schedulingRows = samples.rows
            manifest.coverage?.targetSchedulingRows = samples.targetRows
            manifest.coverage?.firstSchedulingNanos = samples.first
            manifest.coverage?.lastSchedulingNanos = samples.last
            manifest.coverage?.schedulingRowsVerified = samples.targetRows > 0
        } else {
            manifest.coverage?.sampleRows = samples.rows
            manifest.coverage?.targetSampleRows = samples.targetRows
            manifest.coverage?.firstSampleNanos = samples.first
            manifest.coverage?.lastSampleNanos = samples.last
            manifest.coverage?.sampleXMLParsed = samples.targetRows > 0
        }
    }

    private static func coversRequestedWindow(first: UInt64?, last: UInt64?) -> Bool {
        guard let first, let last else { return false }
        return first < 10_000_000_000 && last >= UInt64(recordingSeconds - 10) * 1_000_000_000
    }

    static func freeBytes(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func finish(_ manifest: inout Manifest, at url: URL) throws -> URL {
        manifest.ended = Date()
        try save(manifest, to: url)
        return url
    }

    private static func save(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try privateWrite(encoder.encode(manifest), to: url)
    }

    static func supportsRequestedOptions(at url: URL) -> Bool {
        guard let data = boundedRead(url, maximum: 1_048_576),
              let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiler = options["Time Profiler"] as? [String: Any] else { return false }
        return ["contextSwitchSampling", "recordWaitingThreads", "recordKernelStacks"].allSatisfy { profiler[$0] is Bool }
    }

    private static func failureStatus(_ result: CommandResult) -> String {
        let file = try? FileHandle(forReadingFrom: result.command.stderr)
        defer { try? file?.close() }
        let data = (try? file?.read(upToCount: 65_536)) ?? Data()
        let text = String(bytes: data, encoding: .utf8)?.lowercased() ?? ""
        if ["permission", "not authorized", "not permitted", "failed to attach"].contains(where: text.contains) {
            return "permission_or_attachment_failed"
        }
        return result.status == "timed_out" ? "capture_timed_out" : "capture_failed"
    }

    static func inspectTOC(_ url: URL, pid: Int32) -> Coverage? {
        guard let data = boundedRead(url, maximum: 4_194_304),
              let document = try? XMLDocument(data: data, options: []) else { return nil }
        var coverage = Coverage()
        func text(_ path: String) -> String? { try? document.nodes(forXPath: path).first?.stringValue }
        coverage.targetMatched = text("/trace-toc/run[1]/info/target/process/@pid") == String(pid)
        coverage.startDate = text("/trace-toc/run[1]/info/summary/start-date")
        coverage.endDate = text("/trace-toc/run[1]/info/summary/end-date")
        coverage.durationSeconds = text("/trace-toc/run[1]/info/summary/duration").flatMap(Double.init)
        coverage.schemas = (try? document.nodes(forXPath: "/trace-toc/run[1]/data/table/@schema")
            .compactMap(\.stringValue)) ?? []
        coverage.requestedProbesConfigured = ((try? document.nodes(
            forXPath: "/trace-toc/run[1]/data/" + waitingSamplesTable).count) ?? 0) > 0
        coverage.configuredSamplePeriodsMicroseconds = (try? document.nodes(
            forXPath: "/trace-toc/run[1]/data/table[@schema='time-sample'][@all-thread-states='YES']/@sample-rate-micro-seconds")
            .compactMap { $0.stringValue.flatMap(Int.init) }) ?? []
        // TOC may carry the target's environment; keep it out of the easy-to-share XML sidecar.
        for node in (try? document.nodes(forXPath: "//environment")) ?? [] { node.detach() }
        do { try privateWrite(document.xmlData(options: [.nodePrettyPrint]), to: url) } catch { return nil }
        return coverage
    }
}
