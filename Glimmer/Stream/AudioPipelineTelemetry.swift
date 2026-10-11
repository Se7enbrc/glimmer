// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

/// Independent locks keep receive, decode and render observations out of each other's critical sections.
final class AudioPipelineTelemetry: Sendable {
    static let shared = AudioPipelineTelemetry()
    let receiveGap = LatencyHistograms.Stage()
    let decodeSchedule = LatencyHistograms.Stage()
    let stateLockWait = LatencyHistograms.Stage()
    let queueWait = LatencyHistograms.Stage()
    let queueOverflow = TelemetryCounters.Counter()
    let poolExhausted = TelemetryCounters.Counter()
    let reconfigurationDrops = TelemetryCounters.Counter()
    private let window = OSAllocatedUnfairLock(initialState: Window())

    struct Window: Sendable {
        var minimumRenderCushionMs: Double?
        var renderUnderruns: UInt64 = 0
        var nearMisses: UInt64 = 0
        var realtime = false
    }

    struct Snapshot: Sendable {
        var receiveGap: LatencyHistogramSnapshot.Stage
        var decodeSchedule: LatencyHistogramSnapshot.Stage
        var stateLockWait: LatencyHistogramSnapshot.Stage
        var queueWait: LatencyHistogramSnapshot.Stage
        var window: Window
        var queueOverflow: UInt64
        var poolExhausted: UInt64
        var reconfigurationDrops: UInt64
    }

    func noteRender(cushionMs: Double, underrun: Bool) {
        guard cushionMs.isFinite else { return }
        window.withLock {
            $0.minimumRenderCushionMs = min($0.minimumRenderCushionMs ?? cushionMs, cushionMs)
            if underrun { $0.renderUnderruns &+= 1 }
        }
    }

    func noteNearMiss() { window.withLock { $0.nearMisses &+= 1 } }
    func setRealtime(_ enabled: Bool) { window.withLock { $0.realtime = enabled } }

    func takeSnapshot() -> Snapshot {
        let captured = window.withLock { value in
            let captured = value
            value.minimumRenderCushionMs = nil
            value.nearMisses = 0
            return captured
        }
        return Snapshot(receiveGap: receiveGap.snapshotValue(), decodeSchedule: decodeSchedule.snapshotValue(),
                        stateLockWait: stateLockWait.snapshotValue(), queueWait: queueWait.snapshotValue(),
                        window: captured, queueOverflow: queueOverflow.value, poolExhausted: poolExhausted.value,
                        reconfigurationDrops: reconfigurationDrops.value)
    }

    func reset() {
        receiveGap.reset(); decodeSchedule.reset(); stateLockWait.reset(); queueWait.reset()
        queueOverflow.reset(); poolExhausted.reset(); reconfigurationDrops.reset()
        window.withLock { $0 = Window() }
    }
}

/// Uses the player's sample clock, never completion counts. A stopped/replaced graph resets its epoch.
struct AudioRenderTimeline {
    private(set) var scheduledEnd: Int64 = 0
    private var lastRender: Int64?
    private var drained = false
    var renderQuantum: Int64 = 512

    mutating func reset() {
        scheduledEnd = 0
        lastRender = nil
        drained = false
    }

    mutating func scheduled(frames: Int64, at renderSample: Int64?) {
        scheduledEnd = max(scheduledEnd, renderSample ?? 0) + frames
        drained = false
    }

    mutating func observe(sample: Int64, rate: Double) -> (cushionMs: Double, underrun: Bool)? {
        guard rate > 0, scheduledEnd > 0 else { return nil }
        defer { lastRender = sample }
        guard let lastRender, sample > lastRender else { return nil }
        // Last-render timestamps describe a quantum's start. A full device quantum beyond the
        // scheduled end confirms starvation without relying on dataConsumed callback delivery.
        let empty = sample > scheduledEnd + renderQuantum
        let edge = empty && !drained
        if empty { drained = true }
        return (max(0, Double(scheduledEnd - sample) / rate * 1000), edge)
    }
}
