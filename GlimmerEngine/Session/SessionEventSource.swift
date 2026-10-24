// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Rare lifecycle events use the existing unbounded FIFO; the lock orders attempt changes and completion.
package final class SessionEventSource: @unchecked Sendable {
    package let id = UUID()
    private var storedStream: AsyncStream<StreamSession.Update>?
    private var continuation: AsyncStream<StreamSession.Update>.Continuation?
    private var termination: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var attempt = UUID()
    private var finished = false

    package init() {}

    package var stream: AsyncStream<StreamSession.Update> {
        lock.withLock {
            if let storedStream { return storedStream }
            let pair = AsyncStream<StreamSession.Update>.makeStream()
            storedStream = pair.stream
            continuation = pair.continuation
            if let termination { continuation?.onTermination = { _ in termination() } }
            if finished { continuation?.finish() }
            return pair.stream
        }
    }

    package var currentAttempt: UUID { lock.withLock { attempt } }

    package func beginAttempt(_ id: UUID) { lock.withLock { attempt = id } }

    package func yield(_ event: StreamEvent, attempt expected: UUID? = nil) {
        lock.withLock {
            guard !finished, expected == nil || expected == attempt else { return }
            continuation?.yield(StreamSession.Update(sessionID: id, attemptID: attempt, event: event))
        }
    }

    package func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            continuation?.finish()
        }
    }

    package func onTermination(_ action: @escaping @Sendable () -> Void) {
        lock.withLock {
            termination = action
            continuation?.onTermination = { _ in action() }
        }
    }
}
