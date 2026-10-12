// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct RendererPathTransition: Sendable, Equatable {
    let fromOptimized: Bool
    let toOptimized: Bool
    let frames: UInt64
    let optimized: UInt64
    let suppressed: UInt64

    var summary: String {
        let from = fromOptimized ? "optimized" : "composited"
        let to = toOptimized ? "optimized" : "composited"
        return "\(from)->\(to) frames=\(frames) optimized=\(optimized) suppressed=\(suppressed)"
    }
}

struct RendererPathTracker {
    private var optimized: Bool?
    private var lastNotice: TimeInterval?
    private var suppressed: UInt64 = 0

    mutating func rebaseline() {
        optimized = nil
    }

    mutating func observe(_ delta: RendererPerformanceValues, now: TimeInterval) -> RendererPathTransition? {
        guard delta.frames > 0, delta.optimized <= delta.frames, now.isFinite else { return nil }
        let next = delta.optimized > delta.frames / 2
        let previous = optimized
        optimized = next
        guard let previous, previous != next else { return nil }
        // Remember every flip, including throttled ones, so the next direction is truthful.
        if let lastNotice, now - lastNotice < 5 {
            suppressed += 1
            return nil
        }
        let transition = RendererPathTransition(
            fromOptimized: previous, toOptimized: next, frames: delta.frames,
            optimized: delta.optimized, suppressed: suppressed)
        lastNotice = now
        suppressed = 0
        return transition
    }
}
