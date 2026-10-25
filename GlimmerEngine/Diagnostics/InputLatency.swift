// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

package struct InputEventTiming: Sendable {
    package enum Source: String, CaseIterable, Sendable { case keyboard, mouse, controller, rawHID = "raw_hid" }
    package let source: Source
    package let capture: UInt64
    package let handler: UInt64
    package var batcher: UInt64 = 0

    package init(
        source: Source,
        timestamp: TimeInterval,
        handler: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.source = source
        self.handler = handler
        let captured = timestamp.isFinite && timestamp > 0 && timestamp < Double(UInt64.max) / 1e9
            ? UInt64(timestamp * 1e9) : 0
        capture = captured <= handler ? captured : 0
    }
}

#if os(macOS) || GLIMMER_DIAGNOSTICS
/// Each TLS cell belongs to one OS thread. Scopes clear it before returning to the event loop.
package final class InputTimingContext: @unchecked Sendable {

    package init() {}

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { pointer in
            Unmanaged<InputTimingContext>.fromOpaque(pointer).release()
        }
        return key
    }()
    private var timings = [InputEventTiming?](repeating: nil, count: 4096)
    private var used = 0
    private var consumed = false
    private enum ReleaseTarget {
        case input(InputReleaseLedger.Release), modifiers

        func matches(_ release: InputReleaseLedger.Release) -> Bool {
            switch self {
            case .input(let target): return release == target
            case .modifiers:
                guard case .key(let key) = release else { return false }
                return (0xA0...0xA5).contains(key.vk) || key.vk == 0x5B || key.vk == 0x5C || key.vk == 0x14
            }
        }
    }
    private var releaseTarget: ReleaseTarget?

    package struct Capture: Sendable {

        package init(
            context: InputTimingContext,
            batcher: UInt64
        ) {
            self.context = context
            self.batcher = batcher
        }

        package let context: InputTimingContext
        package let batcher: UInt64

        // The producer waits for its sender request before ending or reusing this thread-local scope.
        package func samples() -> [InputEventTiming] {
            (0..<context.used).compactMap { index in
                var timing = context.timings[index]
                timing?.batcher = batcher
                return timing
            }
        }
    }

    package static func begin(source: InputEventTiming.Source, timestamp: TimeInterval,
                              handler: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard FrameTimingTracker.shared != nil else { return }
        let cell: InputTimingContext
        if let pointer = pthread_getspecific(key) {
            cell = Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue()
        } else {
            cell = InputTimingContext()
            pthread_setspecific(key, Unmanaged.passRetained(cell).toOpaque())
        }
        cell.timings[0] = InputEventTiming(source: source, timestamp: timestamp, handler: handler)
        cell.used = 1
        cell.consumed = false
        cell.releaseTarget = nil
    }

    package static func begin(samples: [InputEventTiming]) {
        guard let first = samples.first else { return }
        begin(source: first.source, timestamp: Double(first.capture) / 1e9, handler: first.handler)
        guard let pointer = pthread_getspecific(key) else { return }
        let cell = Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue()
        cell.used = min(samples.count, cell.timings.count)
        for index in 0..<cell.used { cell.timings[index] = samples[index] }
    }

    package static func end() {
        guard let pointer = pthread_getspecific(key) else { return }
        Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue().used = 0
    }

    package struct Pause {

        package init(
            context: InputTimingContext,
            used: Int,
            consumed: Bool
        ) {
            self.context = context
            self.used = used
            self.consumed = consumed
        }

        package let context: InputTimingContext
        package let used: Int
        package let consumed: Bool
        package func restore() { context.used = used; context.consumed = consumed }
    }

    package static func allowRelease(_ release: InputReleaseLedger.Release) {
        guard let pointer = pthread_getspecific(key) else { return }
        Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue().releaseTarget = .input(release)
    }

    package static func allowModifierReleases() {
        guard let pointer = pthread_getspecific(key) else { return }
        Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue().releaseTarget = .modifiers
    }

    package static func suspend(except release: InputReleaseLedger.Release? = nil) -> Pause? {
        guard let pointer = pthread_getspecific(key) else { return nil }
        let cell = Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue()
        if let release, cell.releaseTarget?.matches(release) == true { return nil }
        let pause = Pause(context: cell, used: cell.used, consumed: cell.consumed)
        cell.used = 0
        return pause
    }

    package static func coalesced(timestamp: TimeInterval) {
        guard let pointer = pthread_getspecific(key) else { return }
        let cell = Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue()
        guard cell.used > 0, !cell.consumed else { return }
        guard cell.used < cell.timings.count else {
            FrameTimingTracker.shared?.inputTimingDropped.increment()
            return
        }
        cell.timings[cell.used] = InputEventTiming(source: .mouse, timestamp: timestamp)
        cell.used += 1
    }

    package static func take() -> Capture? {
        guard let pointer = pthread_getspecific(key) else { return nil }
        let cell = Unmanaged<InputTimingContext>.fromOpaque(pointer).takeUnretainedValue()
        guard cell.used > 0, !cell.consumed else { return nil }
        cell.consumed = true
        return Capture(context: cell, batcher: DispatchTime.now().uptimeNanoseconds)
    }
}

package struct InputTimingBatch: Sendable {
    package let samples: [InputEventTiming]
    package let flushed: UInt64
    package let latency: InputLatency

    package init?(_ samples: [InputEventTiming], tracker: FrameTimingTracker?) {
        guard !samples.isEmpty, let tracker else { return nil }
        self.samples = samples
        flushed = DispatchTime.now().uptimeNanoseconds
        latency = tracker.inputLatency
    }

    package func submitted(at sent: UInt64) {
        for sample in samples {
            latency.observe(sample, flushed: flushed, sent: sent)
        }
    }

    package func completed(sent: UInt64, at completed: UInt64) {
        for sample in samples {
            latency.observe(source: sample.source, stage: .sendCompletion, from: sent, to: completed)
            latency.observe(source: sample.source, stage: .captureCompletion, from: sample.capture, to: completed)
        }
    }
}

/// Histogram storage is allocated once; one lock guards counts, buckets and exact maxima together.
package final class InputLatency: @unchecked Sendable {

    package init() {}

    package enum Stage: String, CaseIterable, Sendable {
        case captureHandler = "capture_handler", handlerBatcher = "handler_batcher"
        case batcherFlush = "batcher_flush", flushSend = "flush_send"
        case captureSend = "capture_send", sendCompletion = "send_completion", captureCompletion = "capture_completion"
    }
    package struct Row: Sendable {

        package init(
            source: InputEventTiming.Source,
            stage: Stage,
            histogram: LatencyHistogramSnapshot.Stage,
            maxMs: Double = 0,
            over10: UInt64 = 0,
            over20: UInt64 = 0,
            over50: UInt64 = 0
        ) {
            self.source = source
            self.stage = stage
            self.histogram = histogram
            self.maxMs = maxMs
            self.over10 = over10
            self.over20 = over20
            self.over50 = over50
        }

        package let source: InputEventTiming.Source
        package let stage: Stage
        package var histogram: LatencyHistogramSnapshot.Stage
        package var maxMs: Double = 0
        package var over10: UInt64 = 0
        package var over20: UInt64 = 0
        package var over50: UInt64 = 0
    }
    package static let bounds: [Double] = [0.1, 0.25, 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 100, 250, 1000]
    private let lock = NSLock()
    private var rows = InputEventTiming.Source.allCases.flatMap { source in
        Stage.allCases.map { stage in
            Row(source: source, stage: stage, histogram: .init(
                buckets: Array(repeating: 0, count: bounds.count), boundsMs: bounds, sumMs: 0, observationCount: 0))
        }
    }

    @inlinable package func observe(_ sample: InputEventTiming, flushed: UInt64, sent: UInt64) {
        observe(source: sample.source, stage: .captureHandler, from: sample.capture, to: sample.handler)
        observe(source: sample.source, stage: .handlerBatcher, from: sample.handler, to: sample.batcher)
        observe(source: sample.source, stage: .batcherFlush, from: sample.batcher, to: flushed)
        observe(source: sample.source, stage: .flushSend, from: flushed, to: sent)
        observe(source: sample.source, stage: .captureSend, from: sample.capture, to: sent)
    }

    @inlinable package func observe(source: InputEventTiming.Source, stage: Stage, from: UInt64, to: UInt64) {
        guard from > 0, to >= from else { return }
        let ms = Double(to - from) / 1e6
        lock.lock(); defer { lock.unlock() }
        guard let index = rows.firstIndex(where: { $0.source == source && $0.stage == stage }) else { return }
        for bucket in Self.bounds.indices where ms <= Self.bounds[bucket] {
            rows[index].histogram.buckets[bucket] &+= 1
        }
        rows[index].histogram.sumMs += ms
        rows[index].histogram.observationCount &+= 1
        rows[index].maxMs = max(rows[index].maxMs, ms)
        if ms > 10 { rows[index].over10 &+= 1 }
        if ms > 20 { rows[index].over20 &+= 1 }
        if ms > 50 { rows[index].over50 &+= 1 }
    }

    package func snapshot() -> [Row] { lock.withLock { rows } }
}

#else
package enum InputTimingContext {
    package struct Capture: Sendable {
        package func samples() -> [InputEventTiming] { [] }
    }
    package struct Pause {
        package func restore() {}
    }
    @inlinable package static func begin(source: InputEventTiming.Source, timestamp: TimeInterval,
                                         handler: UInt64 = 0) {}
    @inlinable package static func begin(samples: [InputEventTiming]) {}
    @inlinable package static func end() {}
    @inlinable package static func allowRelease(_ release: InputReleaseLedger.Release) {}
    @inlinable package static func allowModifierReleases() {}
    @inlinable package static func suspend(except release: InputReleaseLedger.Release? = nil) -> Pause? { nil }
    @inlinable package static func coalesced(timestamp: TimeInterval) {}
    @inlinable package static func take() -> Capture? { nil }
}

package struct InputTimingBatch: Sendable {
    @inlinable package init?(_ samples: [InputEventTiming], tracker: FrameInstrumentation?) { nil }
    @inlinable package func submitted(at sent: UInt64) {}
    @inlinable package func completed(sent: UInt64, at completed: UInt64) {}
}
#endif
