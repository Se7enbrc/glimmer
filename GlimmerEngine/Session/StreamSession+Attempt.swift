// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct TakeoverRequired: Error {
    package let appID: Int
}

extension StreamSession {
    package func authorizeTakeover(_ authorized: Bool) { takeoverAuthorized = authorized }

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

/// Only /cancel is serialized with the next launch; a hung /launch never holds this gate.
package actor HostLaunchMutations {
    private var epochs: [String: Int] = [:]
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
