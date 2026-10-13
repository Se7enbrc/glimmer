// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum StreamAttempt {
    package static func shouldContinue(cancelled: Bool, streaming: Bool, stopping: Bool) -> Bool {
        !cancelled && streaming && !stopping
    }

    package static func requiresTakeover(occupied: Bool, owner: String?, client: String?, authorized: Bool) -> Bool {
        guard occupied, !authorized else { return false }
        guard let owner, !owner.isEmpty, let client, !client.isEmpty else { return true }
        return owner.caseInsensitiveCompare(client) != .orderedSame
    }

    package static func checkDeadline(_ deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date() >= deadline {
            throw StreamError.hostTimedOut
        }
    }

    package static func run<T: Sendable>(
        until deadline: Date, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try checkDeadline(deadline)
        let box = AttemptResult<T>()
        let work = Task {
            do {
                try Task.checkCancellation()
                await box.offer(.success(try await operation()))
            } catch {
                await box.offer(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch {
                return
            }
            work.cancel()
            await box.offer(.failure(StreamError.hostTimedOut))
        }
        let result = await withTaskCancellationHandler {
            await box.value
        } onCancel: {
            work.cancel()
            Task { await box.offer(.failure(CancellationError())) }
        }
        timer.cancel()
        work.cancel()
        try checkDeadline(deadline)
        return try result.get()
    }
}

private actor AttemptResult<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var waiter: CheckedContinuation<Result<Value, Error>, Never>?

    func offer(_ value: Result<Value, Error>) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    var value: Result<Value, Error> {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}
