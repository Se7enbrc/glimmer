// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum SessionDeadline {
    package static let stopBoundSeconds: TimeInterval = 2.0
    package static func runBounded(
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
