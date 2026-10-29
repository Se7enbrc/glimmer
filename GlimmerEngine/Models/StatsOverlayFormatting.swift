// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum StatsOverlayFormatting {
    public static let coreKinds: [StatsRow.Kind] = [.renderFps, .latency, .bitrate]

    /// Combine only when both metrics are enabled; Custom can still show either alone.
    public static func combinedRows(_ rows: [StatsRow]) -> [StatsRow] {
        guard let codec = rows.first(where: { $0.kind == .codec }),
              rows.contains(where: { $0.kind == .bitrate }) else { return rows }
        return rows.compactMap { row in
            if row.kind == .codec { return nil }
            guard row.kind == .bitrate else { return row }
            return StatsRow(kind: row.kind, label: row.label, value: "\(row.value) · \(codec.value)",
                            symbolName: nil, health: row.health, section: row.section)
        }
    }

    public static func displayRows(snapshot: StreamStatsSnapshot, enabled: Set<StatsRow.Kind>,
                                   targetFps: Double, thresholds: StatsThresholds) -> [StatsRow] {
        let rows = snapshot.rows(enabled: enabled, targetFps: targetFps, thresholds: thresholds).map { row in
            let value: String
            switch row.kind {
            case .bitrate: value = formatted(snapshot.measuredBitrateMbps, format: "%.1f Mbps")
            case .latency: value = formatted(snapshot.rttMs, format: "%.2f ms")
            default: value = row.value.replacingOccurrences(of: "\u{2014}", with: "-")
            }
            return StatsRow(kind: row.kind, label: row.label, value: value,
                            symbolName: row.symbolName, health: row.health, section: row.section)
        }
        let combined = combinedRows(rows)
        return coreKinds.compactMap { kind in combined.first { $0.kind == kind } }
            + combined.filter { !coreKinds.contains($0.kind) }
    }

    private static func formatted(_ value: Double?, format: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "-" }
        return String(format: format, value)
    }
}
