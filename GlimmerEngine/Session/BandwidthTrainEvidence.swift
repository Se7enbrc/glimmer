// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// Accepted natural frame trains are a trial hint, never a throughput measurement or permanent cap.
public struct BandwidthTrainEvidence: Sendable, Equatable, Codable {
    public var distinctFrames: Int
    public var firstAt: Double
    public var lastAt: Double
    public var p20IPKbps: Double
    public var maximumToMinimumRatio: Double

    public init(distinctFrames: Int, firstAt: Double, lastAt: Double,
                p20IPKbps: Double, maximumToMinimumRatio: Double) {
        self.distinctFrames = distinctFrames
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.p20IPKbps = p20IPKbps
        self.maximumToMinimumRatio = maximumToMinimumRatio
    }

    public func budgetIPKbps(at now: Double) -> Double? {
        guard distinctFrames >= 3, firstAt.isFinite, lastAt.isFinite, now.isFinite,
              lastAt - firstAt >= 1, now - lastAt >= 0, now - lastAt <= 5,
              p20IPKbps.isFinite, p20IPKbps > 0,
              maximumToMinimumRatio.isFinite, (1...1.5).contains(maximumToMinimumRatio) else { return nil }
        return p20IPKbps * 0.7
    }
}

/// Deltas from mature monotonic counters reject resets and rollover instead of manufacturing loss.
public struct BandwidthCounterSample: Sendable, Equatable {
    public var expected: UInt64
    public var lost: UInt64
    public var generation: UInt64
    public var at: Double

    public init(expected: UInt64, lost: UInt64, generation: UInt64, at: Double) {
        self.expected = expected
        self.lost = lost
        self.generation = generation
        self.at = at
    }

    public func delta(since previous: Self) -> (expected: Int, lost: Int)? {
        guard generation == previous.generation, at.isFinite, previous.at.isFinite, at > previous.at,
              expected >= previous.expected, lost >= previous.lost,
              let expected = Int(exactly: expected - previous.expected),
              let lost = Int(exactly: lost - previous.lost), expected > 0, lost <= expected else { return nil }
        return (expected, lost)
    }
}
