// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// A probe runs on the same queue as completions and ACKs; the lock protects its outstanding timestamp.
final class InputCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted: UInt64?
    private var lastFinished: UInt64 = 0
    private let now: @Sendable () -> UInt64
    static let freshnessNanos: UInt64 = 2_000_000

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    static func shouldGate(backlogged: Bool, responsiveAge: UInt64?) -> Bool {
        guard backlogged, let responsiveAge else { return false }
        return responsiveAge <= freshnessNanos
    }

    func allowsGate(on queue: DispatchQueue) -> Bool {
        let now = now()
        let state = lock.withLock { () -> (gate: Bool, submit: Bool) in
            let age = lastFinished > 0 && now >= lastFinished ? now - lastFinished : nil
            let gate = Self.shouldGate(backlogged: true, responsiveAge: age)
            guard submitted == nil else { return (gate, false) }
            submitted = now
            return (gate, true)
        }
        if state.submit {
            queue.async { [weak self] in self?.complete() }
        }
        return state.gate
    }

    private func complete() {
        let now = now()
        let start = lock.withLock {
            let start = submitted
            submitted = nil
            lastFinished = now
            return start
        }
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if let start, now >= start {
            FrameTimingTracker.shared?.inputCallbackLatency.observe(Double(now - start) / 1e6)
        }
        #else
        _ = start
        #endif
    }
}
