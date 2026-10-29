// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension VideoDecoder {
    /// Native clients read cached windows only while their overlay is visible.
    public func overlaySnapshot() -> StreamStatsSnapshot {
        var snapshot = statsSnapshot(minWindowSeconds: 1)
        if let rtt = telemetryEstimatedRtt() {
            snapshot.rttMs = rtt.rttMs
            snapshot.rttVarianceMs = rtt.varianceMs
        }
        let jitter = TelemetryCounters.shared.recvJitterMs
        if jitter > 0 { snapshot.jitterMs = jitter }
        return snapshot
    }

    public var overlayVideoSize: CGSize { CGSize(width: Int(streamWidth), height: Int(streamHeight)) }
}
