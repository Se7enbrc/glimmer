// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@usableFromInline package struct RendererPresentationState: Sendable, Equatable {

    @usableFromInline package init(
        generation: UInt64 = 0,
        suppressed: Bool = false
    ) {
        self.generation = generation
        self.suppressed = suppressed
    }

    @usableFromInline package var generation: UInt64 = 0
    @usableFromInline package var suppressed = false
}

@usableFromInline package struct RendererPathTransition: Sendable, Equatable {

    @usableFromInline package init(
        fromOptimized: Bool,
        toOptimized: Bool,
        frames: UInt64,
        optimized: UInt64,
        suppressed: UInt64,
        isResume: Bool = false
    ) {
        self.fromOptimized = fromOptimized
        self.toOptimized = toOptimized
        self.frames = frames
        self.optimized = optimized
        self.suppressed = suppressed
        self.isResume = isResume
    }

    @usableFromInline package let fromOptimized: Bool
    @usableFromInline package let toOptimized: Bool
    @usableFromInline package let frames: UInt64
    @usableFromInline package let optimized: UInt64
    @usableFromInline package let suppressed: UInt64
    @usableFromInline package var isResume = false

    @usableFromInline package var summary: String {
        let from = isResume ? "resume" : (fromOptimized ? "optimized" : "composited")
        let to = toOptimized ? "optimized" : "composited"
        return "\(from)->\(to) frames=\(frames) optimized=\(optimized) suppressed=\(suppressed)"
    }
}

@usableFromInline package struct RendererPathTracker {

    @usableFromInline package init() {}

    private var optimized: Bool?
    private var lastNotice: TimeInterval?
    private var suppressed: UInt64 = 0
    private var resumePending = false

    @usableFromInline package mutating func rebaseline(reportResume: Bool = false) {
        optimized = nil
        resumePending = resumePending || reportResume
    }

    @usableFromInline
    package mutating func observe(_ delta: RendererPerformanceValues, now: TimeInterval) -> RendererPathTransition? {
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
