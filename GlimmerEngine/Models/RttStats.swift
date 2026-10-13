// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct RttStats: Sendable, Equatable {
    package var minMs: Double
    package var steadyMs: Double
    package var p50Ms: Double
    package var p95Ms: Double
    package var count: Int

    /// Nil for an empty sample set - absent knowledge stays absent.
    package init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func percentile(_ quantile: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * quantile).rounded())
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        minMs = sorted[0]
        steadyMs = percentile(0.25)
        p50Ms = percentile(0.50)
        p95Ms = percentile(0.95)
        count = sorted.count
    }

    /// How much worse the tail is than the floor. >2x on a path whose floor is
    /// already high is the bufferbloat signature.
    package var tailRatio: Double { minMs > 0 ? p95Ms / minMs : 1 }
}
