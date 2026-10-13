// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os

/// Independent locks keep receive, decode and render observations out of each other's critical sections.
package final class AudioPipelineTelemetry: Sendable {

    package init() {}

    package static let shared = AudioPipelineTelemetry()
    package let receiveGap = LatencyHistograms.Stage()
    package let decodeSchedule = LatencyHistograms.Stage()
    package let stateLockWait = LatencyHistograms.Stage()
    package let queueWait = LatencyHistograms.Stage()
    package let queueOverflow = TelemetryCounters.Counter()
    package let poolExhausted = TelemetryCounters.Counter()
    package let reconfigurationDrops = TelemetryCounters.Counter()
    private let window = OSAllocatedUnfairLock(initialState: Window())

    package struct Window: Sendable {

        package init(
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

        package var minimumRenderCushionMs: Double?
        package var renderUnderruns: UInt64 = 0
        package var nearMisses: UInt64 = 0
        package var realtime = false
        package var outputSilentSeconds: Double = 0
        package var outputLatencyMs: Double?
        package var deviceRecoveryMs: Double?
    }

    package struct Snapshot: Sendable {

        package init(
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

        package var receiveGap: LatencyHistogramSnapshot.Stage
        package var decodeSchedule: LatencyHistogramSnapshot.Stage
        package var stateLockWait: LatencyHistogramSnapshot.Stage
        package var queueWait: LatencyHistogramSnapshot.Stage
        package var window: Window
        package var queueOverflow: UInt64
        package var poolExhausted: UInt64
        package var reconfigurationDrops: UInt64
    }

    package func noteRender(cushionMs: Double, underrun: Bool) {
        guard cushionMs.isFinite else { return }
        window.withLock {
            $0.minimumRenderCushionMs = min($0.minimumRenderCushionMs ?? cushionMs, cushionMs)
            if underrun { $0.renderUnderruns &+= 1 }
        }
    }

    package func noteOutput(latencyMs: Double, recoveryMs: Double? = nil) {
        window.withLock {
            $0.outputLatencyMs = latencyMs
            if let recoveryMs { $0.deviceRecoveryMs = recoveryMs }
        }
    }

    package func noteOutputSilence(seconds: Double) { window.withLock { $0.outputSilentSeconds = seconds } }

    package func noteNearMiss() { window.withLock { $0.nearMisses &+= 1 } }
    package func setRealtime(_ enabled: Bool) { window.withLock { $0.realtime = enabled } }

    package func takeSnapshot() -> Snapshot {
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

    package func reset() {
        receiveGap.reset(); decodeSchedule.reset(); stateLockWait.reset(); queueWait.reset()
        queueOverflow.reset(); poolExhausted.reset(); reconfigurationDrops.reset()
        window.withLock { $0 = Window() }
    }
}
