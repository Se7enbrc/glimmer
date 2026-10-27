// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
import CryptoKit
import Foundation

// MARK: - Renderer

package enum TelemetryRenderer {

    /// A PC or Mac name as 8 hex digits, keyed by a random per-install salt: stable
    /// across sessions, but no one without the salt can match it to a name.
    package static func pseudonym(_ name: String, salt: SymmetricKey = installSalt) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: salt)
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    package static let installSalt: SymmetricKey = {
        let key = "telemetryNameSalt"
        if let stored = PersistentStorage.defaults.data(forKey: key), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let salt = SymmetricKey(size: .bits256)
        PersistentStorage.defaults.set(salt.withUnsafeBytes { Data($0) }, forKey: key)
        return salt
    }()

    /// Estimate an NDJSON percentile by interpolating cumulative histogram buckets.
    /// Empty histograms have no percentile; overflow clamps to the last finite bound.
    package static func histogramQuantile(
        _ quantile: Double, stage: LatencyHistogramSnapshot.Stage
    ) -> Double? {
        guard stage.hasObservations, !stage.buckets.isEmpty else { return nil }
        let rank = quantile * Double(stage.observationCount)
        // Find the first cumulative bucket whose count ≥ rank. Uses the stage's
        // OWN bounds so the composite (coarse) and sub-stage (fine) histograms
        // each interpolate against their matching edges.
        var lowerBound = 0.0
        var lowerCount = 0.0
        for (index, bound) in stage.boundsMs.enumerated() where index < stage.buckets.count {
            let cumulative = Double(stage.buckets[index])
            if cumulative >= rank {
                // Linear interpolation between (lowerBound, lowerCount) and
                // (bound, cumulative) for the fractional rank position.
                let span = cumulative - lowerCount
                let frac = span > 0 ? (rank - lowerCount) / span : 0
                return lowerBound + (bound - lowerBound) * frac
            }
            lowerBound = bound
            lowerCount = cumulative
        }
        // Past the last finite bound: clamp to the top bound (the +Inf bucket has
        // no upper edge to interpolate toward).
        return stage.boundsMs.last
    }
}

#endif
