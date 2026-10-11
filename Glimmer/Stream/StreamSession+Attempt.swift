// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct TakeoverRequired: Error {
    let appID: Int
}

struct ResumeFailed: Error {
    let underlying: Error
}

enum StreamAttempt {
    static func shouldContinue(cancelled: Bool, streaming: Bool, stopping: Bool) -> Bool {
        !cancelled && streaming && !stopping
    }

    static func requiresTakeover(occupied: Bool, owner: String?, client: String?, authorized: Bool) -> Bool {
        guard occupied, !authorized else { return false }
        guard let owner, !owner.isEmpty, let client, !client.isEmpty else { return true }
        return owner.caseInsensitiveCompare(client) != .orderedSame
    }

    static func checkDeadline(_ deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date() >= deadline {
            throw StreamError.hostTimedOut
        }
    }

    static func run<T: Sendable>(
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

extension StreamSession {
    func authorizeTakeover(_ authorized: Bool) { takeoverAuthorized = authorized }

    func checkAttempt(deadline: Date? = nil) throws {
        guard StreamAttempt.shouldContinue(
            cancelled: Task.isCancelled, streaming: isStreaming, stopping: stopInProgress) else {
            throw CancellationError()
        }
        try StreamAttempt.checkDeadline(deadline)
    }
}

actor SharedTeardown {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let task { await task.value; return }
        let task = Task { await operation() }
        self.task = task
        await task.value
    }
}

/// Quit waits up to 22 seconds for pending launches so a late launch cannot restart the app afterward.
/// New launches wait behind the quit.
actor HostLaunchMutations {
    private var epochs: [String: Int] = [:]
    private var cancellations: [String: Task<Void, Error>] = [:]
    private var launches: [String: [Int: Task<LaunchResponse, Error>]] = [:]

    func beginLaunch(for pc: String) async throws -> Int {
        while let pending = cancellations[pc] {
            _ = try? await pending.value
            if cancellations[pc] == pending { cancellations[pc] = nil }
        }
        try Task.checkCancellation()
        epochs[pc, default: 0] += 1
        return epochs[pc, default: 0]
    }

    func launch(pc: String, client: String?, appID: Int, store: RunningAppOwnershipStore = RunningAppOwnershipStore(),
                operation: @escaping @Sendable () async throws -> LaunchResponse) async throws
        -> Task<LaunchResponse, Error> {
        let epoch = try await beginLaunch(for: pc)
        let task = Task {
            defer {
                launches[pc]?[epoch] = nil
                if launches[pc]?.isEmpty == true { launches[pc] = nil }
            }
            let response = try await operation()
            if epochs[pc] == epoch, let client {
                RunningAppOwnership.save(pc: pc, appID: appID, clientID: client, defaults: store.defaults)
            }
            return response
        }
        launches[pc, default: [:]][epoch] = task
        return task
    }

    func cancel(pc: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        while let pending = cancellations[pc] {
            _ = try? await pending.value
            if cancellations[pc] == pending { cancellations[pc] = nil }
        }
        try Task.checkCancellation()
        epochs[pc, default: 0] += 1
        // A disconnected session can still have a launch preparing on the PC.
        // Wait under the gate so quit follows every pending launch and precedes the next one.
        let pending = launches[pc].map { Array($0.values) } ?? []
        let task = Task {
            try await StreamAttempt.run(until: Date().addingTimeInterval(StreamSession.launchOverallDeadlineSeconds)) {
                for launch in pending { _ = await launch.result }
            }
            try await operation()
        }
        cancellations[pc] = task
        defer { if cancellations[pc] == task { cancellations[pc] = nil } }
        try await task.value
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
