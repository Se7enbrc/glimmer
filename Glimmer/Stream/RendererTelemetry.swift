// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// AVFoundation performance counters, sampled only by the opt-in exporter.

import AVFoundation
import Foundation
import QuartzCore

struct RendererPerformanceValues: Sendable, Equatable {
    var frames: UInt64
    var dropped: UInt64
    var optimized: UInt64
    var delaySeconds: Double

    func delta(since previous: Self) -> Self? {
        guard frames >= previous.frames, dropped >= previous.dropped,
              optimized >= previous.optimized, delaySeconds >= previous.delaySeconds else { return nil }
        return Self(frames: frames - previous.frames, dropped: dropped - previous.dropped,
                    optimized: optimized - previous.optimized, delaySeconds: delaySeconds - previous.delaySeconds)
    }

    init(frames: UInt64, dropped: UInt64, optimized: UInt64, delaySeconds: Double) {
        self.frames = frames
        self.dropped = dropped
        self.optimized = optimized
        self.delaySeconds = delaySeconds
    }

    init?(_ metrics: AVVideoPerformanceMetrics) {
        guard metrics.totalNumberOfFrames >= 0, metrics.numberOfDroppedFrames >= 0,
              metrics.numberOfFramesDisplayedUsingOptimizedCompositing >= 0 else { return nil }
        self.init(frames: UInt64(metrics.totalNumberOfFrames), dropped: UInt64(metrics.numberOfDroppedFrames),
                  optimized: UInt64(metrics.numberOfFramesDisplayedUsingOptimizedCompositing),
                  delaySeconds: metrics.totalAccumulatedFrameDelay)
    }
}

struct RendererPerformanceSnapshot: Sendable {
    enum Status: String, Sendable {
        case unavailable, pending, baseline, ready
    }

    var status: Status = .unavailable
    var cumulative: RendererPerformanceValues?
    var delta: RendererPerformanceValues?
    var intervalSeconds: Double?
    var ageSeconds: Double?
    var resets: UInt64 = 0
}

/// Immutable references used only on the exporter queue. AVFoundation's metrics
/// request is thread-safe; the retained identity prevents reuse during a request.
struct RendererPerformanceSource: @unchecked Sendable {
    let identity: AnyObject
    let load: (@escaping @Sendable (RendererPerformanceValues?) -> Void) -> Void

    init(identity: AnyObject,
         load: @escaping (@escaping @Sendable (RendererPerformanceValues?) -> Void) -> Void) {
        self.identity = identity
        self.load = load
    }

    init(_ renderer: AVSampleBufferVideoRenderer) {
        identity = renderer
        load = { completion in
            renderer.loadVideoPerformanceMetrics { metrics in
                completion(metrics.flatMap(RendererPerformanceValues.init))
            }
        }
    }
}

/// All mutable state is confined to the exporter's queue. Completions hop there;
/// no timer or per-frame hook exists, and stop invalidates any outstanding reply.
final class RendererTelemetry: @unchecked Sendable {
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

    init(queue: DispatchQueue, probe: @escaping @Sendable () -> RendererPerformanceSource?) {
        self.queue = queue
        self.probe = probe
    }

    /// Return the last completed result and start at most one request per exporter tick.
    /// A slow request remains the sole outstanding request even after a layer swap.
    func sample(now: CFTimeInterval = CACurrentMediaTime()) -> RendererPerformanceSnapshot {
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

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        generation &+= 1
        pending = nil
        current = nil
        baseline = nil
        completedAt = nil
        latest = RendererPerformanceSnapshot()
    }

    private func observe(_ source: RendererPerformanceSource?) {
        let identity = source.map { ObjectIdentifier($0.identity) }
        guard identity != current.map({ ObjectIdentifier($0.identity) }) else { return }
        let resets = latest.resets + (current == nil ? 0 : 1)
        generation &+= 1
        current = source
        baseline = nil
        completedAt = nil
        latest = RendererPerformanceSnapshot(resets: resets)
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
            }
        }
        baseline = (values, now)
        completedAt = now
        latest = result
    }
}
