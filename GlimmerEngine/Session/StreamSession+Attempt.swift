// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct TakeoverRequired: Error {
    public let appID: Int
}

extension StreamSession {
    package func authorizeTakeover(_ authorized: Bool) { takeoverAuthorized = authorized }

    public func approveReplacement(of appID: Int) {
        approvedOccupant = appID
    }

    public func requireContinuation(previous: ContinuationFormat? = nil) {
        continuationOnly = true
        continuationRecovery = previous
    }

    package func checkAttempt(deadline: Date? = nil) throws {
        guard StreamAttempt.shouldContinue(
            cancelled: Task.isCancelled, streaming: isStreaming, stopping: stopInProgress) else {
            throw CancellationError()
        }
        try StreamAttempt.checkDeadline(deadline)
    }
}

package actor SharedTeardown {
    private var task: Task<Void, Never>?

    package func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let task { await task.value; return }
        let task = Task { await operation() }
        self.task = task
        await task.value
    }
}

/// PC commands serialize their mutations; epochs fence late cleanup from a newer launch.
package actor HostLaunchMutations {
    private var commands: [String: Task<Void, Never>] = [:]
    private var epochs: [String: Int] = [:]

    package func performCommand<Value: Sendable>(
        pc: String, operation: @escaping @Sendable (Bool) async throws -> Value
    ) async throws -> Value {
        let previous = commands[pc]
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await StreamAttempt.run(until: Date().addingTimeInterval(30)) {
                try await operation(previous != nil)
            }
        }
        let completion = Task { _ = await task.result }
        commands[pc] = completion
        defer { if commands[pc] == completion { commands[pc] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private var cancellations: [String: Task<Void, Never>] = [:]

    package func beginLaunch(for pc: String) async throws -> Int {
        while let pending = cancellations[pc] {
            await pending.value
            if cancellations[pc] == pending { cancellations[pc] = nil }
        }
        try Task.checkCancellation()
        epochs[pc, default: 0] += 1
        return epochs[pc, default: 0]
    }

    package func cancelIfCurrent(pc: String, epoch: Int, operation: @escaping @Sendable () async -> Void) async {
        while let pending = cancellations[pc] {
            await pending.value
            if cancellations[pc] == pending { cancellations[pc] = nil }
        }
        guard epochs[pc, default: 0] == epoch else { return }
        // Publish before suspending so a newer launch waits through the whole network request.
        let task = Task { await operation() }
        cancellations[pc] = task
        await task.value
        if cancellations[pc] == task { cancellations[pc] = nil }
    }
}
