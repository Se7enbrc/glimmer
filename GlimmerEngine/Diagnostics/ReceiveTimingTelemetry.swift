// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

        package var p99: Double? {
            guard sampleCount > 0 else { return nil }
            let target = sampleCount - sampleCount / 100
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
            missing: UInt64 = 0
        ) {
            self.delay = delay
            self.gap = gap
            self.missing = missing
        }

        package var delay = Distribution()
        package var gap = Distribution()
        package var missing: UInt64 = 0
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
            if let delayMs { $0.delay.observe(delayMs) } else { $0.missing &+= 1 }
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
            $0 = Window()
            return result
        }
    }

    package func reset() { state.withLock { $0 = Window() } }
}
