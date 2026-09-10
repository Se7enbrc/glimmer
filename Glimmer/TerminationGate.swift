//
//  TerminationGate.swift
//
//  The quit-time rule for a live stream: the process must not exit before the
//  session's `/cancel` reaches the host, and a hung host must not be able to
//  pin Cmd-Q. `applicationShouldTerminate` answers `.terminateLater` while a
//  session is up, runs the stop under `runBounded`, then replies - so a host
//  that answers in 80 ms costs 80 ms and one that never answers costs the
//  bound. Pure and testable: no AppKit beyond the reply enum.
//
//  The bug this closes (issue #84): quitting mid-stream returned
//  `.terminateNow` after kicking off an async stop, so the process exited
//  before `/cancel` was sent and Sunshine kept a phantom session that blocked
//  the next `/launch`.
//

import AppKit
import Foundation

enum TerminationGate {
    /// How long a quit waits for the session stop (`backend.stopConnection` +
    /// `/cancel`) before exiting anyway. Two seconds covers a LAN round trip
    /// with a wide margin and is short enough that a dead host doesn't make
    /// Cmd-Q feel broken.
    static let stopBoundSeconds: TimeInterval = 2.0

    /// The reply to `applicationShouldTerminate`: defer while a session is
    /// live OR connecting (`isStreaming` flips at stream() entry, and a launch
    /// already in flight has told the host to start), else quit now.
    static func reply(isStreaming: Bool) -> NSApplication.TerminateReply {
        isStreaming ? .terminateLater : .terminateNow
    }

    /// Run `operation` and return true if it finished within `seconds`, false
    /// if the deadline won. Deliberately NOT a task group: a group scope waits
    /// for every child before returning, so a stop wedged on a dead host would
    /// pin the caller past the bound - the exact thing this exists to prevent.
    /// The loser is cancelled best-effort; a stop that is still running when
    /// the process exits is fine (the host times the session out on its own).
    static func runBounded(
        seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let finisher = FirstFinisher()
        let work = Task { await operation(); await finisher.finish(completed: true) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await finisher.finish(completed: false)
        }
        let completed = await finisher.outcome
        work.cancel()
        timer.cancel()
        return completed
    }
}

/// First-writer-wins latch: the first `finish` resumes the single pending
/// `outcome` read; later finishes are dropped. Actor-isolated so the two racing
/// tasks can't both resume the continuation.
private actor FirstFinisher {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func finish(completed: Bool) {
        guard result == nil else { return }
        result = completed
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: completed)
        }
    }

    var outcome: Bool {
        get async {
            if let result { return result }
            return await withCheckedContinuation { continuation in waiter = continuation }
        }
    }
}
