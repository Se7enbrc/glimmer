// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import os

final class ReceiveTimingTelemetry: Sendable {
    static let video = ReceiveTimingTelemetry()
    static let audio = ReceiveTimingTelemetry()
    private let state = OSAllocatedUnfairLock(initialState: Window())

    struct Distribution {
        var buckets = SIMD64<UInt32>(repeating: 0)
        var sampleCount: UInt64 = 0
        var maximum: Double = 0

        mutating func observe(_ milliseconds: Double) {
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

        var p99: Double? {
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

    struct Window {
        var delay = Distribution()
        var gap = Distribution()
        var missing: UInt64 = 0
    }

    struct Snapshot: Sendable {
        var samples: UInt64 = 0
        var missing: UInt64 = 0
        var delayMaxMs: Double?
        var delayP99Ms: Double?
        var gapMaxMs: Double?
        var gapP99Ms: Double?
    }

    func observe(delayMs: Double?, gapMs: Double?) {
        state.withLock {
            if let delayMs { $0.delay.observe(delayMs) } else { $0.missing &+= 1 }
            if let gapMs { $0.gap.observe(gapMs) }
        }
    }

    func takeSnapshot() -> Snapshot {
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

    func reset() { state.withLock { $0 = Window() } }
}
