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

    static func execute(_ command: Command) async -> CommandResult {
        await Task.detached(priority: .utility) { executeBlocking(command) }.value
    }

    private static func executeBlocking(_ command: Command) -> CommandResult {
        let started = Date()
        let process = Process()
        let complete = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in complete.signal() }
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
            let deadline = ProcessInfo.processInfo.systemUptime + command.timeoutSeconds
            var reason = "completed"
            while complete.wait(timeout: .now() + 1) == .timedOut {
                if let limit = outputLimit(command) { reason = limit; break }
                if ProcessInfo.processInfo.systemUptime >= deadline { reason = "timed_out"; break }
            }
            if reason != "completed", process.isRunning {
                process.interrupt()
                if complete.wait(timeout: .now() + 10) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    _ = complete.wait(timeout: .now() + 10)
                }
            }
            if reason == "completed", let limit = outputLimit(command) { reason = limit }
            return CommandResult(command: command, started: started, ended: Date(),
                                 exitCode: process.isRunning ? nil : process.terminationStatus, status: reason)
        } catch {
            return CommandResult(command: command, started: started, ended: Date(), exitCode: nil,
                                 status: "launch_failed", detail: String(describing: error))
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
        if free < 2 * 1_073_741_824 { return "disk_reserve" }
        if let directory = command.captureDirectory {
            guard let bytes = captureBytes(directory) else { return "capture_size_unverified" }
            if bytes > 20 * 1_073_741_824 { return "capture_size_limit" }
        }
        return nil
    }

    private static func captureBytes(_ directory: URL) -> Int64? {
        guard let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return nil }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in entries {
            count += 1
            guard count <= 100_000,
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
            if values.isRegularFile == true {
                guard let size = values.fileSize else { return nil }
                total += Int64(size)
                if total > 20 * 1_073_741_824 { return total }
            }
        }
        return total
    }
}
