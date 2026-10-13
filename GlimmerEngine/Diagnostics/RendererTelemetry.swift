// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// AVFoundation performance counters, sampled only by the opt-in exporter.

import AVFoundation
import Foundation
import QuartzCore

@usableFromInline package struct RendererPerformanceValues: Sendable, Equatable {
    @usableFromInline package var frames: UInt64
    @usableFromInline package var dropped: UInt64
    @usableFromInline package var optimized: UInt64
    @usableFromInline package var delaySeconds: Double

    @usableFromInline package func delta(since previous: Self) -> Self? {
        guard frames >= previous.frames, dropped >= previous.dropped,
              optimized >= previous.optimized, delaySeconds >= previous.delaySeconds else { return nil }
        return Self(frames: frames - previous.frames, dropped: dropped - previous.dropped,
                    optimized: optimized - previous.optimized, delaySeconds: delaySeconds - previous.delaySeconds)
    }

    @usableFromInline package init(frames: UInt64, dropped: UInt64, optimized: UInt64, delaySeconds: Double) {
        self.frames = frames
        self.dropped = dropped
        self.optimized = optimized
        self.delaySeconds = delaySeconds
    }

    @usableFromInline package init?(_ metrics: AVVideoPerformanceMetrics) {
        guard metrics.totalNumberOfFrames >= 0, metrics.numberOfDroppedFrames >= 0,
              metrics.numberOfFramesDisplayedUsingOptimizedCompositing >= 0 else { return nil }
        self.init(frames: UInt64(metrics.totalNumberOfFrames), dropped: UInt64(metrics.numberOfDroppedFrames),
                  optimized: UInt64(metrics.numberOfFramesDisplayedUsingOptimizedCompositing),
                  delaySeconds: metrics.totalAccumulatedFrameDelay)
    }
}

@usableFromInline package struct RendererPerformanceSnapshot: Sendable {

    @usableFromInline package init(
        status: Status = .unavailable,
        cumulative: RendererPerformanceValues? = nil,
        delta: RendererPerformanceValues? = nil,
        intervalSeconds: Double? = nil,
        ageSeconds: Double? = nil,
        resets: UInt64 = 0
    ) {
        self.status = status
        self.cumulative = cumulative
        self.delta = delta
        self.intervalSeconds = intervalSeconds
        self.ageSeconds = ageSeconds
        self.resets = resets
    }

    @usableFromInline package enum Status: String, Sendable {
        case unavailable, pending, baseline, ready
    }

    @usableFromInline package var status: Status = .unavailable
    @usableFromInline package var cumulative: RendererPerformanceValues?
    @usableFromInline package var delta: RendererPerformanceValues?
    @usableFromInline package var intervalSeconds: Double?
    @usableFromInline package var ageSeconds: Double?
    @usableFromInline package var resets: UInt64 = 0
}

/// Immutable references used only on the exporter queue. AVFoundation's metrics
/// request is thread-safe; the retained identity prevents reuse during a request.
@usableFromInline package struct RendererPerformanceSource: @unchecked Sendable {
    @usableFromInline package let identity: AnyObject
    @usableFromInline package let presentation: RendererPresentationState
    @usableFromInline package let load: (@escaping @Sendable (RendererPerformanceValues?) -> Void) -> Void
    @usableFromInline package let reportTransition: @Sendable (RendererPathTransition) -> Void

    @usableFromInline package init(
        identity: AnyObject, presentation: RendererPresentationState = .init(),
        reportTransition: @escaping @Sendable (RendererPathTransition) -> Void = { _ in },
        load: @escaping (@escaping @Sendable (RendererPerformanceValues?) -> Void) -> Void
    ) {
        self.identity = identity
        self.presentation = presentation
        self.load = load
        self.reportTransition = reportTransition
    }

    @usableFromInline
    package init(_ renderer: AVSampleBufferVideoRenderer, presentation: RendererPresentationState = .init(),
                 reportTransition: @escaping @Sendable (RendererPathTransition) -> Void = { _ in }) {
        identity = renderer
        self.presentation = presentation
        self.reportTransition = reportTransition
        load = { completion in
            renderer.loadVideoPerformanceMetrics { metrics in
                completion(metrics.flatMap(RendererPerformanceValues.init))
            }
        }
    }
}

/// All mutable state is confined to the exporter's queue. Completions hop there;
/// no timer or per-frame hook exists, and stop invalidates any outstanding reply.
@usableFromInline package final class RendererTelemetry: @unchecked Sendable {
    private struct Request {
        let token: UInt64
        let generation: UInt64
        let source: RendererPerformanceSource
    }

    private let queue: DispatchQueue
    private let probe: @Sendable () -> RendererPerformanceSource?
    private var current: RendererPerformanceSource?
    private var pending: Request?
    private var generation: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var stopped = false
    private var baseline: (values: RendererPerformanceValues, time: CFTimeInterval)?
    private var latest = RendererPerformanceSnapshot()
    private var completedAt: CFTimeInterval?
    private var pathTracker = RendererPathTracker()

    @usableFromInline package init(queue: DispatchQueue, probe: @escaping @Sendable () -> RendererPerformanceSource?) {
        self.queue = queue
        self.probe = probe
    }

    /// Return the last completed result and start at most one request per exporter tick.
    /// A slow request remains the sole outstanding request even after a layer swap.
    @usableFromInline package func sample(now: CFTimeInterval = CACurrentMediaTime()) -> RendererPerformanceSnapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return RendererPerformanceSnapshot() }
        observe(probe())
        var result = latest
        result.ageSeconds = completedAt.map { max(0, now - $0) }
        if pending != nil {
            result.status = .pending
            result.delta = nil
            result.intervalSeconds = nil
        }
        if pending == nil, let current {
            nextToken &+= 1
            let request = Request(token: nextToken, generation: generation, source: current)
            pending = request
            let token = request.token
            current.load { [weak self] values in
                let completedAt = CACurrentMediaTime()
                self?.queue.async { [weak self] in
                    self?.complete(token: token, values: values, now: completedAt)
                }
            }
        }
        return result
    }

    @usableFromInline package func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        generation &+= 1
        pending = nil
        current = nil
        baseline = nil
        completedAt = nil
        latest = RendererPerformanceSnapshot()
        pathTracker = RendererPathTracker()
    }

    private func observe(_ source: RendererPerformanceSource?) {
        let identity = source.map { ObjectIdentifier($0.identity) }
        let replaced = identity != current.map { ObjectIdentifier($0.identity) }
        let presentationChanged = current != nil && source?.presentation != current?.presentation
        guard replaced || presentationChanged else { return }
        let resumes = presentationChanged && source?.presentation.suppressed == false
        let resets = latest.resets + (replaced && current != nil ? 1 : 0)
        generation &+= 1
        current = source
        baseline = nil
        completedAt = nil
        latest = RendererPerformanceSnapshot(resets: resets)
        pathTracker.rebaseline(reportResume: resumes)
    }

    private func complete(token: UInt64, values: RendererPerformanceValues?, now: CFTimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, let request = pending, request.token == token else { return }
        pending = nil
        // The layer may have changed after the last capture, while the API was working.
        observe(probe())
        guard request.generation == generation,
              current?.identity === request.source.identity else { return }
        guard let values, values.delaySeconds.isFinite, values.delaySeconds >= 0 else {
            latest = RendererPerformanceSnapshot(resets: latest.resets)
            completedAt = nil
            return
        }
        var result = RendererPerformanceSnapshot(status: .baseline, cumulative: values, resets: latest.resets)
        if let baseline {
            if let delta = values.delta(since: baseline.values), now > baseline.time {
                result.status = .ready
                result.delta = delta
                result.intervalSeconds = now - baseline.time
            } else {
                result.resets &+= 1
                pathTracker.rebaseline()
            }
        }
        baseline = (values, now)
        completedAt = now
        latest = result
        if current?.presentation.suppressed == false,
           let delta = result.delta, let transition = pathTracker.observe(delta, now: now) {
            current?.reportTransition(transition)
        }
    }
}
