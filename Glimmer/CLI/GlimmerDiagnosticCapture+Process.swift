// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

extension GlimmerDiagnosticCapture {
    static func boundedRead(_ url: URL, maximum: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return data
    }

    static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func runCommand(_ command: Command, runner: Runner) async -> CommandResult {
        let started = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        var result: CommandResult
        if Task.isCancelled {
            result = CommandResult(command: command, started: Date(), ended: Date(), exitCode: nil, status: "cancelled")
        } else {
            result = await runner(command)
        }
        result.startedUptimeSeconds = started
        result.endedUptimeSeconds = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        switch command.label {
        case "record": result.instrumentationPhase = "attachment_recording_finalization"
        case "clock-preflight-record": result.instrumentationPhase = "clock_preflight_recording_finalization"
        case "toc", "time-profile", "thread-state", "clock-anchors": result.instrumentationPhase = "export"
        default: result.instrumentationPhase = "preflight_or_identity_check"
        }
        return result
    }

    @concurrent
    static func execute(_ command: Command) async -> CommandResult {
        await execute(command, started: { _ in })
    }

    @concurrent
    static func execute(_ command: Command, started: @Sendable (Int32) -> Void,
                        resourceCheck: @Sendable (Command) -> String? = outputLimit) async -> CommandResult {
        let began = Date()
        guard !Task.isCancelled else {
            return CommandResult(command: command, started: began, ended: Date(), exitCode: nil, status: "cancelled")
        }
        if let limit = resourceCheck(command) {
            return CommandResult(command: command, started: began, ended: Date(), exitCode: nil, status: limit)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        do {
            let files = FileManager.default
            guard files.createFile(atPath: command.stdout.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  files.createFile(atPath: command.stderr.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let out = try FileHandle(forWritingTo: command.stdout)
            let err = try FileHandle(forWritingTo: command.stderr)
            defer { try? out.close(); try? err.close() }
            process.standardOutput = out
            process.standardError = err
            try process.run()
            started(process.processIdentifier)
            let reason = await monitor(process, command: command, resourceCheck: resourceCheck)
            let forced = reason == "completed" ? false : await stopOwnedProcess(process, command: command)
            let reaped = !process.isRunning
            return CommandResult(command: command, started: began, ended: Date(),
                exitCode: reaped ? process.terminationStatus : nil,
                status: reaped ? reason : "child_cleanup_unconfirmed", forcedTermination: forced, childExitObserved: reaped)
        } catch {
            return CommandResult(command: command, started: began, ended: Date(), exitCode: nil,
                                 status: "launch_failed", detail: String(describing: error))
        }
    }

    private static func monitor(_ process: Process, command: Command,
                                resourceCheck: @Sendable (Command) -> String?) async -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + command.timeoutSeconds
        var nextBudgetCheck = 0.0
        while process.isRunning {
            if Task.isCancelled { return "cancelled" }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextBudgetCheck {
                if let limit = resourceCheck(command) { return limit }
                nextBudgetCheck = now + 1
            }
            if now >= deadline { return "timed_out" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if Task.isCancelled { return "cancelled" }
        return resourceCheck(command) ?? "completed"
    }

    private static func stopOwnedProcess(_ process: Process, command: Command) async -> Bool {
        guard process.isRunning else { return false }
        process.interrupt()
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        let directory = command.captureDirectory ?? command.stdout.deletingLastPathComponent()
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            guard let free = freeBytes(at: directory), free >= 2 * 1_073_741_824 else { break }
            await cleanupPause()
        }
        guard process.isRunning else { return false }
        kill(process.processIdentifier, SIGKILL)
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline { await cleanupPause() }
        return true
    }

    // Cleanup must still wait for the owned child after the caller's task has been cancelled.
    private static func cleanupPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
        }
    }

    static func outputLimit(_ command: Command) -> String? {
        let files = FileManager.default
        func size(_ url: URL) -> Int64? {
            (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        if (size(command.stdout) ?? 0) > command.maximumOutputBytes || (size(command.stderr) ?? 0) > 16_777_216 {
            return "output_limit"
        }
        let directory = command.captureDirectory ?? command.stdout.deletingLastPathComponent()
        guard let free = freeBytes(at: directory) else { return "disk_space_unverified" }
        if free < 4 * 1_073_741_824 { return "disk_reserve" }
        if let directory = command.captureDirectory {
            guard let bytes = captureBytes(directory) else { return "capture_size_unverified" }
            if bytes > 8 * 1_073_741_824 { return "capture_size_limit" }
        }
        return nil
    }

    static func captureBytes(_ directory: URL) -> Int64? {
        var enumerationFailed = false
        guard let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { return nil }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in entries {
            count += 1
            guard count <= 100_000,
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
            if values.isRegularFile == true {
                guard let size = values.fileSize else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(Int64(size))
                guard !overflow else { return nil }
                total = sum
            }
        }
        return enumerationFailed ? nil : total
    }
}
