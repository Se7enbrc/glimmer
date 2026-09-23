import Foundation

struct TakeoverRequired: Error {
    let appID: Int
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
