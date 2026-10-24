// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS) || GLIMMER_DIAGNOSTICS

import Foundation
import os
import Synchronization

/// Independent locks keep receive, decode and render observations out of each other's critical sections.
package typealias AudioPipelineInstrumentation = AudioPipelineTelemetry

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
    // Scalar progress only; packet paths never format logs or acquire an additional lock.
    package let receivedDatagrams = Atomic<UInt64>(0)
    package let processedDatagrams = Atomic<UInt64>(0)
    package let decryptOK = Atomic<UInt64>(0)
    package let decryptFailed = Atomic<UInt64>(0)
    package let decodedFrames = Atomic<UInt64>(0)
    package let renderedFrames = Atomic<UInt64>(0)
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
        package var outputProbeResult: Int?
        package var outputProbeInputAudible: Bool?
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
        package var receivedDatagrams: UInt64 = 0
        package var processedDatagrams: UInt64 = 0
        package var decryptOK: UInt64 = 0
        package var decryptFailed: UInt64 = 0
        package var decodedFrames: UInt64 = 0
        package var renderedFrames: UInt64 = 0
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

    package func noteOutputProbe(result: Int, inputAudible: Bool?) {
        window.withLock {
            $0.outputProbeResult = result
            $0.outputProbeInputAudible = inputAudible
        }
    }

    package func noteNearMiss() { window.withLock { $0.nearMisses &+= 1 } }
    package func setRealtime(_ enabled: Bool) { window.withLock { $0.realtime = enabled } }

    package func takeSnapshot() -> Snapshot {
        let captured = window.withLock { value in
            let captured = value
            value.minimumRenderCushionMs = nil
            value.nearMisses = 0
            value.outputProbeResult = nil
            value.outputProbeInputAudible = nil
            return captured
        }
        var snapshot = Snapshot(receiveGap: receiveGap.snapshotValue(), decodeSchedule: decodeSchedule.snapshotValue(),
                        stateLockWait: stateLockWait.snapshotValue(), queueWait: queueWait.snapshotValue(),
                        window: captured, queueOverflow: queueOverflow.value, poolExhausted: poolExhausted.value,
                        reconfigurationDrops: reconfigurationDrops.value)
        snapshot.receivedDatagrams = receivedDatagrams.load(ordering: .relaxed)
        snapshot.processedDatagrams = processedDatagrams.load(ordering: .relaxed)
        snapshot.decryptOK = decryptOK.load(ordering: .relaxed)
        snapshot.decryptFailed = decryptFailed.load(ordering: .relaxed)
        snapshot.decodedFrames = decodedFrames.load(ordering: .relaxed)
        snapshot.renderedFrames = renderedFrames.load(ordering: .relaxed)
        return snapshot
    }

    package func reset() {
        receiveGap.reset(); decodeSchedule.reset(); stateLockWait.reset(); queueWait.reset()
        queueOverflow.reset(); poolExhausted.reset(); reconfigurationDrops.reset()
        receivedDatagrams.store(0, ordering: .relaxed)
        processedDatagrams.store(0, ordering: .relaxed)
        decryptOK.store(0, ordering: .relaxed)
        decryptFailed.store(0, ordering: .relaxed)
        decodedFrames.store(0, ordering: .relaxed)
        renderedFrames.store(0, ordering: .relaxed)
        window.withLock { $0 = Window() }
    }
}

#endif

#if !os(macOS) && !GLIMMER_DIAGNOSTICS
package enum AudioPipelineInstrumentation: Sendable {
    package static var shared: AudioPipelineInstrumentation? { nil }
}
#endif
