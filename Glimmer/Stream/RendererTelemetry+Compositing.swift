// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct RendererPresentationState: Sendable, Equatable {
    var generation: UInt64 = 0
    var suppressed = false
}

extension VideoDecoder {
    nonisolated var rendererPresentationState: RendererPresentationState {
        presentSuppressedLock.lock()
        defer { presentSuppressedLock.unlock() }
        return RendererPresentationState(generation: presentationGeneration, suppressed: _presentSuppressed)
    }
}

struct RendererPathTransition: Sendable, Equatable {
    let fromOptimized: Bool
    let toOptimized: Bool
    let frames: UInt64
    let optimized: UInt64
    let suppressed: UInt64
    var isResume = false

    var summary: String {
        let from = isResume ? "resume" : (fromOptimized ? "optimized" : "composited")
        let to = toOptimized ? "optimized" : "composited"
        return "\(from)->\(to) frames=\(frames) optimized=\(optimized) suppressed=\(suppressed)"
    }
}

struct RendererPathTracker {
    private var optimized: Bool?
    private var lastNotice: TimeInterval?
    private var suppressed: UInt64 = 0
    private var resumePending = false

    mutating func rebaseline(reportResume: Bool = false) {
        optimized = nil
        resumePending = resumePending || reportResume
    }

    mutating func observe(_ delta: RendererPerformanceValues, now: TimeInterval) -> RendererPathTransition? {
        guard delta.frames > 0, delta.optimized <= delta.frames, now.isFinite else { return nil }
        let next = delta.optimized > delta.frames / 2
        let previous = optimized
        optimized = next
        let changed = previous.map { $0 != next } ?? false
        guard changed || resumePending else { return nil }
        // Remember every flip, including throttled ones, so the next direction is truthful.
        if let lastNotice, now - lastNotice < 5 {
            if changed { suppressed += 1 }
            return nil
        }
        let transition = RendererPathTransition(
            fromOptimized: previous ?? next, toOptimized: next, frames: delta.frames,
            optimized: delta.optimized, suppressed: suppressed, isResume: resumePending)
        lastNotice = now
        suppressed = 0
        resumePending = false
        return transition
    }
}
