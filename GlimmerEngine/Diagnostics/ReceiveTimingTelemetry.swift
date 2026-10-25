// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS) || GLIMMER_DIAGNOSTICS

import os

package final class ReceiveTimingTelemetry: Sendable {

    package init() {}

    package static let video = ReceiveTimingTelemetry()
    package static let audio = ReceiveTimingTelemetry()
    private let state = OSAllocatedUnfairLock(initialState: Window())

    package struct Distribution: Sendable {

        package init(
            sampleCount: UInt64 = 0,
            maximum: Double = 0
        ) {
            self.sampleCount = sampleCount
            self.maximum = maximum
        }

        package var buckets = SIMD64<UInt32>(repeating: 0)
        package var sampleCount: UInt64 = 0
        package var maximum: Double = 0

        @inlinable package mutating func observe(_ milliseconds: Double) {
            let index: Int
            switch milliseconds {
            case ...4: index = max(0, Int((milliseconds * 4).rounded(.up)) - 1)
            case ...20: index = 16 + Int((milliseconds - 4).rounded(.up)) - 1
            case ...100: index = 32 + Int(((milliseconds - 20) / 5).rounded(.up)) - 1
            default: index = min(63, 48 + Int(min(16, ((milliseconds - 100) / 25).rounded(.up))) - 1)
            }
            buckets[index] &+= 1
            sampleCount &+= 1
            maximum = max(maximum, milliseconds)
        }

        package var p99: Double? { quantile(0.99) }

        /// Upper bucket bound at `fraction`; 0.25 ms resolution below 4 ms.
        package func quantile(_ fraction: Double) -> Double? {
            guard sampleCount > 0 else { return nil }
            let target = max(1, UInt64((Double(sampleCount) * fraction).rounded(.up)))
            var cumulative: UInt64 = 0
            for index in 0..<64 {
                cumulative += UInt64(buckets[index])
                guard cumulative >= target else { continue }
                let bound: Double
                switch index {
                case 0..<16: bound = Double(index + 1) / 4
                case 16..<32: bound = 4 + Double(index - 15)
                case 32..<48: bound = 20 + Double(index - 31) * 5
                default: bound = index == 63 ? maximum : 100 + Double(index - 47) * 25
                }
                return min(maximum, bound)
            }
            return maximum
        }
    }

    package struct Window: Sendable {

        package init(
            delay: Distribution = Distribution(),
            gap: Distribution = Distribution(),
            missing: UInt64 = 0,
            policyDelay: Distribution = Distribution(),
            policyJitter: Distribution = Distribution()
        ) {
            self.delay = delay
            self.gap = gap
            self.missing = missing
            self.policyDelay = policyDelay
            self.policyJitter = policyJitter
        }

        package var delay = Distribution()
        package var gap = Distribution()
        package var missing: UInt64 = 0
        /// The bandwidth policy's own one-second view; the exporter's snapshot never drains it.
        package var policyDelay = Distribution()
        package var policyJitter = Distribution()
    }

    /// Median kernel-to-read queue delay and p95 frame-delivery jitter since the last call.
    package struct PolicyWindow: Sendable, Equatable {
        package var queueDelayP50Ms: Double?
        package var jitterP95Ms: Double?

        package init(queueDelayP50Ms: Double? = nil, jitterP95Ms: Double? = nil) {
            self.queueDelayP50Ms = queueDelayP50Ms
            self.jitterP95Ms = jitterP95Ms
        }
    }

    package struct Snapshot: Sendable {

        package init(
            samples: UInt64 = 0,
            missing: UInt64 = 0,
            delayMaxMs: Double? = nil,
            delayP99Ms: Double? = nil,
            gapMaxMs: Double? = nil,
            gapP99Ms: Double? = nil
        ) {
            self.samples = samples
            self.missing = missing
            self.delayMaxMs = delayMaxMs
            self.delayP99Ms = delayP99Ms
            self.gapMaxMs = gapMaxMs
            self.gapP99Ms = gapP99Ms
        }

        package var samples: UInt64 = 0
        package var missing: UInt64 = 0
        package var delayMaxMs: Double?
        package var delayP99Ms: Double?
        package var gapMaxMs: Double?
        package var gapP99Ms: Double?
    }

    @inlinable package func observe(delayMs: Double?, gapMs: Double?) {
        state.withLock {
            if let delayMs { $0.delay.observe(delayMs); $0.policyDelay.observe(delayMs) } else { $0.missing &+= 1 }
            if let gapMs { $0.gap.observe(gapMs) }
        }
    }

    package func takeSnapshot() -> Snapshot {
        state.withLock {
            let result = Snapshot(samples: $0.delay.sampleCount, missing: $0.missing,
                                  delayMaxMs: $0.delay.sampleCount > 0 ? $0.delay.maximum : nil,
                                  delayP99Ms: $0.delay.p99,
                                  gapMaxMs: $0.gap.sampleCount > 0 ? $0.gap.maximum : nil,
                                  gapP99Ms: $0.gap.p99)
            $0 = Window(policyDelay: $0.policyDelay, policyJitter: $0.policyJitter)
            return result
        }
    }

    /// One sample per new video frame: |arrival spacing − RTP timestamp spacing| in ms (RFC 3550 D).
    package func observeFrameJitter(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        state.withLock { $0.policyJitter.observe(milliseconds) }
    }

    package func takePolicyWindow() -> PolicyWindow {
        state.withLock {
            defer { $0.policyDelay = Distribution(); $0.policyJitter = Distribution() }
            return PolicyWindow(queueDelayP50Ms: $0.policyDelay.quantile(0.5), jitterP95Ms: $0.policyJitter.quantile(0.95))
        }
    }

    package func reset() { state.withLock { $0 = Window() } }
}

#endif
