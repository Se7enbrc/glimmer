// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Reused text layers keep the HUD's refresh independent of video presentation.

import AppKit
import QuartzCore

extension StatsOverlayLayer {
    /// Combine only when both metrics are enabled; Custom can still show either alone.
    static func combinedRows(_ rows: [StatsRow]) -> [StatsRow] {
        guard let codec = rows.first(where: { $0.kind == .codec }),
              rows.contains(where: { $0.kind == .bitrate }) else { return rows }
        return rows.compactMap { row in
            if row.kind == .codec { return nil }
            guard row.kind == .bitrate else { return row }
            return StatsRow(kind: row.kind, label: row.label, value: "\(row.value) · \(codec.value)",
                            symbolName: nil, health: row.health, section: row.section)
        }
    }

    static func displayRows(snapshot: StreamStatsSnapshot, enabled: Set<StatsRow.Kind>,
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

    func makeRow(kind: StatsRow.Kind) -> RowSublayers {
        let container = CALayer()
        container.actions = Self.disabledActions
        let label = makeTextLayer()
        let value = makeTextLayer()
        container.addSublayer(label)
        container.addSublayer(value)
        let trace = StatsTrace.Metric(kind: kind).map { StatsTrace(metric: $0) }
        if let trace { container.addSublayer(trace.layer) }
        return RowSublayers(container: container, labelLayer: label, valueLayer: value, trace: trace, lastRender: nil)
    }

    private func makeTextLayer() -> CATextLayer {
        let text = CATextLayer()
        text.contentsScale = layer.contentsScale
        text.isWrapped = false
        text.truncationMode = .end
        text.actions = Self.disabledActions
        return text
    }

    var primaryInk: NSColor {
        usesDarkInk ? NSColor(red: 0.11, green: 0.21, blue: 0.26, alpha: 1)
            : NSColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
    }

    var secondaryInk: NSColor { primaryInk.withAlphaComponent(reduceTransparency ? 1 : 0.76) }

    private var cautionInk: NSColor {
        usesDarkInk ? NSColor(red: 0.70, green: 0.35, blue: 0, alpha: 1) : .systemOrange
    }

    private var criticalInk: NSColor {
        usesDarkInk ? NSColor(red: 0.72, green: 0.10, blue: 0.08, alpha: 1) : .systemRed
    }

    func applyShadow(to target: CALayer) {
        target.shadowColor = (usesDarkInk ? NSColor.white : NSColor.black).cgColor
        target.shadowOpacity = reduceTransparency ? 0.8 : 0.48
        target.shadowRadius = reduceTransparency ? 0.5 : 1.5
        target.shadowOffset = CGSize(width: 0, height: -0.5)
    }

    func apply(row: StatsRow, to sub: RowSublayers) {
        sub.labelLayer.string = NSAttributedString(string: row.label, attributes: [
            .font: Self.labelFont, .foregroundColor: secondaryInk
        ])
        sub.valueLayer.string = attributedValue(row)
        applyShadow(to: sub.labelLayer)
        applyShadow(to: sub.valueLayer)
        if let trace = sub.trace {
            trace.applyInk(primary: primaryInk, caution: cautionInk, critical: criticalInk, opaque: reduceTransparency)
            applyShadow(to: trace.layer)
        }
    }

    func attributedValue(_ row: StatsRow) -> NSAttributedString {
        let core = Self.coreKinds.contains(row.kind)
        let font = Self.valueFont(for: row.health, differentiateWithoutColor:
                                    NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)
        let text = NSMutableAttributedString(string: row.value, attributes: [
            .font: core ? font : Self.detailFont, .foregroundColor: primaryInk
        ])
        if core, let space = row.value.firstIndex(of: " ") {
            let suffix = NSRange(space..<row.value.endIndex, in: row.value)
            text.addAttributes([.font: Self.labelFont, .foregroundColor: secondaryInk], range: suffix)
        } else if !core, row.health == .warning || row.health == .critical {
            text.addAttribute(.foregroundColor, value: cautionInk, range: NSRange(location: 0, length: text.length))
            if NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor {
                text.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(
                    ofSize: Self.detailFont.pointSize, weight: .bold), range: NSRange(location: 0, length: text.length))
            }
        }
        return text
    }

    static func valueFont(for health: StatsRow.Health, differentiateWithoutColor: Bool) -> NSFont {
        if differentiateWithoutColor, health == .warning || health == .critical {
            return emphasizedValueFont
        }
        return normalValueFont
    }
}
