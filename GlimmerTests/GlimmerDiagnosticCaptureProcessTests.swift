// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
import Darwin
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
}
