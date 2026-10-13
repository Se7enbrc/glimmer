// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

/// Independent locks keep receive, decode and render observations out of each other's critical sections.
@usableFromInline package final class AudioPipelineTelemetry: Sendable {

    @inlinable package init() {}

    @usableFromInline package static let shared = AudioPipelineTelemetry()
    @usableFromInline package let receiveGap = LatencyHistograms.Stage()
    @usableFromInline package let decodeSchedule = LatencyHistograms.Stage()
    @usableFromInline package let stateLockWait = LatencyHistograms.Stage()
    @usableFromInline package let queueWait = LatencyHistograms.Stage()
    @usableFromInline package let queueOverflow = TelemetryCounters.Counter()
    @usableFromInline package let poolExhausted = TelemetryCounters.Counter()
    @usableFromInline package let reconfigurationDrops = TelemetryCounters.Counter()
    @usableFromInline internal let window = OSAllocatedUnfairLock(initialState: Window())

    @usableFromInline package struct Window: Sendable {

        @inlinable package init(
            minimumRenderCushionMs: Double? = nil,
            renderUnderruns: UInt64 = 0,
            nearMisses: UInt64 = 0,
            realtime: Bool = false,
            outputSilentSeconds: Double = 0,
            outputLatencyMs: Double? = nil,
            deviceRecoveryMs: Double? = nil
        ) {
            self.minimumRenderCushionMs = minimumRenderCushionMs
            self.renderUnderruns = renderUnderruns
            self.nearMisses = nearMisses
            self.realtime = realtime
            self.outputSilentSeconds = outputSilentSeconds
            self.outputLatencyMs = outputLatencyMs
            self.deviceRecoveryMs = deviceRecoveryMs
        }

        @usableFromInline package var minimumRenderCushionMs: Double?
        @usableFromInline package var renderUnderruns: UInt64 = 0
        @usableFromInline package var nearMisses: UInt64 = 0
        @usableFromInline package var realtime = false
        @usableFromInline package var outputSilentSeconds: Double = 0
        @usableFromInline package var outputLatencyMs: Double?
        @usableFromInline package var deviceRecoveryMs: Double?
    }

    @usableFromInline package struct Snapshot: Sendable {

        @inlinable package init(
            receiveGap: LatencyHistogramSnapshot.Stage,
            decodeSchedule: LatencyHistogramSnapshot.Stage,
            stateLockWait: LatencyHistogramSnapshot.Stage,
            queueWait: LatencyHistogramSnapshot.Stage,
            window: Window,
            queueOverflow: UInt64,
            poolExhausted: UInt64,
            reconfigurationDrops: UInt64
        ) {
            self.receiveGap = receiveGap
            self.decodeSchedule = decodeSchedule
            self.stateLockWait = stateLockWait
            self.queueWait = queueWait
            self.window = window
            self.queueOverflow = queueOverflow
            self.poolExhausted = poolExhausted
            self.reconfigurationDrops = reconfigurationDrops
        }

        @usableFromInline package var receiveGap: LatencyHistogramSnapshot.Stage
        @usableFromInline package var decodeSchedule: LatencyHistogramSnapshot.Stage
        @usableFromInline package var stateLockWait: LatencyHistogramSnapshot.Stage
        @usableFromInline package var queueWait: LatencyHistogramSnapshot.Stage
        @usableFromInline package var window: Window
        @usableFromInline package var queueOverflow: UInt64
        @usableFromInline package var poolExhausted: UInt64
        @usableFromInline package var reconfigurationDrops: UInt64
    }

    @inlinable package func noteRender(cushionMs: Double, underrun: Bool) {
        guard cushionMs.isFinite else { return }
        window.withLock {
            $0.minimumRenderCushionMs = min($0.minimumRenderCushionMs ?? cushionMs, cushionMs)
            if underrun { $0.renderUnderruns &+= 1 }
        }
    }

    @inlinable package func noteOutput(latencyMs: Double, recoveryMs: Double? = nil) {
        window.withLock {
            $0.outputLatencyMs = latencyMs
            if let recoveryMs { $0.deviceRecoveryMs = recoveryMs }
        }
    }

    @inlinable package func noteOutputSilence(seconds: Double) { window.withLock { $0.outputSilentSeconds = seconds } }

    @inlinable package func noteNearMiss() { window.withLock { $0.nearMisses &+= 1 } }
    @inlinable package func setRealtime(_ enabled: Bool) { window.withLock { $0.realtime = enabled } }

    @inlinable package func takeSnapshot() -> Snapshot {
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

    @inlinable package func reset() {
        receiveGap.reset(); decodeSchedule.reset(); stateLockWait.reset(); queueWait.reset()
        queueOverflow.reset(); poolExhausted.reset(); reconfigurationDrops.reset()
        window.withLock { $0 = Window() }
    }
}
