// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
import Darwin
import os
@testable import Glimmer

struct GlimmerDiagnosticCaptureProcessTests {
    private func command(executable: String, arguments: [String] = []) throws -> GlimmerDiagnosticCapture.Command {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        return .init(label: "fixture", executable: executable, arguments: arguments, timeoutSeconds: 10,
                     stdout: base.appendingPathComponent("stdout"), stderr: base.appendingPathComponent("stderr"))
    }

    @Test func alreadyCancelledCommandDoesNotLaunchAChildOrCreateOutput() async throws {
        let command = try command(executable: "/does/not/exist")
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await GlimmerDiagnosticCapture.execute(command)
        }
        let result = await task.value
        #expect(result.status == "cancelled" && result.exitCode == nil)
        #expect(FileManager.default.fileExists(atPath: command.stdout.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWaitsForItsOwnedChildToExit() async throws {
        let command = try command(executable: "/bin/sleep", arguments: ["30"])
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let (started, continuation) = AsyncStream<Int32>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return await GlimmerDiagnosticCapture.execute(command, started: { pid in continuation.yield(pid) }, resourceCheck: { _ in nil })
        }
        var iterator = started.makeAsyncIterator()
        let observed = await iterator.next()
        let pid = try #require(observed)
        task.cancel()
        let result = await task.value
        #expect(result.status == "cancelled")
        #expect(result.childExitObserved && result.exitCode != nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func completedChildStillChecksFinalOutputSize() async throws {
        var command = try command(executable: "/usr/bin/printf", arguments: ["oversized"])
        command.maximumOutputBytes = 2
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let result = await GlimmerDiagnosticCapture.execute(command)
        #expect(result.status == "output_limit" && result.childExitObserved)
    }

    @Test func exhaustedStoragePreventsEvenLaunchingTheChild() async throws {
        let command = try command(executable: "/does/not/exist")
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let result = await GlimmerDiagnosticCapture.execute(command, started: { _ in
            Issue.record("Storage exhaustion must prevent launch.")
        }, resourceCheck: { _ in "disk_reserve" })
        #expect(result.status == "disk_reserve" && result.exitCode == nil)
        #expect(FileManager.default.fileExists(atPath: command.stdout.path) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutReapsTheOwnedChildAndNeverReportsSuccess() async throws {
        let original = try command(executable: "/bin/sleep", arguments: ["30"])
        let command = GlimmerDiagnosticCapture.Command(label: original.label, executable: original.executable,
            arguments: original.arguments, timeoutSeconds: 0, stdout: original.stdout, stderr: original.stderr)
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let result = await GlimmerDiagnosticCapture.execute(command, started: { _ in }, resourceCheck: { _ in nil })
        #expect(result.status == "timed_out" && result.childExitObserved)
        #expect(result.succeeded == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func storageExhaustionAfterLaunchReapsTheOwnedChild() async throws {
        let command = try command(executable: "/bin/sleep", arguments: ["30"])
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        let launched = OSAllocatedUnfairLock(initialState: false)
        let result = await GlimmerDiagnosticCapture.execute(command, started: { _ in launched.withLock { $0 = true } },
            resourceCheck: { _ in launched.withLock { $0 } ? "disk_reserve" : nil })
        #expect(result.status == "disk_reserve" && result.childExitObserved)
        #expect(result.succeeded == false)
    }

    @Test func forcedOrUnobservedExitCannotPassAsACompletedCommand() throws {
        let command = try command(executable: "/bin/sleep")
        defer { try? FileManager.default.removeItem(at: command.stdout.deletingLastPathComponent()) }
        var result = GlimmerDiagnosticCapture.CommandResult(command: command, started: Date(), ended: Date(),
            exitCode: 0, status: "completed", forcedTermination: true)
        #expect(result.succeeded == false)
        result.forcedTermination = false
        result.childExitObserved = false
        #expect(result.succeeded == false)
    }

    @Test func finalDirectoryMeasurementDoesNotStopAtTheSoftBudget() throws {
        let command = try command(executable: "/bin/sleep")
        let directory = command.stdout.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.createFile(atPath: command.stdout.path, contents: nil))
        let file = try FileHandle(forWritingTo: command.stdout)
        defer { try? file.close() }
        let size: UInt64 = 9 * 1_073_741_824
        try file.truncate(atOffset: size)
        #expect(FileManager.default.createFile(atPath: command.stderr.path, contents: nil))
        let second = try FileHandle(forWritingTo: command.stderr)
        defer { try? second.close() }
        try second.truncate(atOffset: size + 7)
        #expect(GlimmerDiagnosticCapture.captureBytes(directory) == Int64(size) * 2 + 7)
        #expect(GlimmerDiagnosticCapture.captureBytes(directory.appendingPathComponent("missing")) == nil)
    }
}
