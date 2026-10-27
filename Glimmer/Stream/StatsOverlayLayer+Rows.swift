// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Reused text layers keep the HUD's refresh independent of video presentation.

import GlimmerEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import QuartzCore

extension StatsOverlayLayer {
    #if os(macOS)
    func updateAccessibleRows(_ rows: [StatsRow], cap: String) {
        guard let view = displayView else { return }
        guard isVisible else {
            view.setAccessibilityChildren([])
            return
        }
        let kinds = Set(rows.map(\.kind))
        accessibleRows = accessibleRows.filter { kinds.contains($0.key) }
        let children = rows.map { row in
            let element = accessibleRows[row.kind] ?? NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(view)
            element.setAccessibilityLabel(row.label)
            element.setAccessibilityValue(row.value)
            accessibleRows[row.kind] = element
            return element
        }
        if !cap.isEmpty {
            accessibleCap.setAccessibilityRole(.staticText)
            accessibleCap.setAccessibilityParent(view)
            accessibleCap.setAccessibilityLabel(cap)
        }
        view.setAccessibilityChildren(children + (cap.isEmpty ? [] : [accessibleCap]))
        updateAccessibilityFrames()
    }

    func updateAccessibilityFrames() {
        guard let root = layer.superlayer else { return }
        for (kind, element) in accessibleRows {
            guard let row = rowViews[kind] else { continue }
            element.setAccessibilityFrameInParentSpace(row.container.convert(row.container.bounds, to: root))
        }
        accessibleCap.setAccessibilityFrameInParentSpace(layer.convert(
            CGRect(x: 0, y: 0, width: layer.bounds.width, height: 12), to: root))
    }

    #endif

    static func combinedRows(_ rows: [StatsRow]) -> [StatsRow] {
        StatsOverlayFormatting.combinedRows(rows)
    }

    static func displayRows(snapshot: StreamStatsSnapshot, enabled: Set<StatsRow.Kind>,
                            targetFps: Double, thresholds: StatsThresholds) -> [StatsRow] {
        StatsOverlayFormatting.displayRows(snapshot: snapshot, enabled: enabled,
                                           targetFps: targetFps, thresholds: thresholds)
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

    var primaryInk: StatsColor {
        usesDarkInk ? StatsColor(red: 0.11, green: 0.21, blue: 0.26, alpha: 1)
            : StatsColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
    }

    var secondaryInk: StatsColor { primaryInk.withAlphaComponent(reduceTransparency ? 1 : 0.76) }

    private var cautionInk: StatsColor {
        usesDarkInk ? StatsColor(red: 0.70, green: 0.35, blue: 0, alpha: 1) : .systemOrange
    }

    private var criticalInk: StatsColor {
        usesDarkInk ? StatsColor(red: 0.72, green: 0.10, blue: 0.08, alpha: 1) : .systemRed
    }

    func applyShadow(to target: CALayer) {
        target.shadowColor = (usesDarkInk ? StatsColor.white : StatsColor.black).cgColor
        target.shadowOpacity = reduceTransparency ? 0.8 : 0.48
        target.shadowRadius = reduceTransparency ? 0.5 : 1.5
        target.shadowOffset = CGSize(width: 0, height: -0.5)
    }

    func apply(row: StatsRow, to sub: RowSublayers) {
        sub.labelLayer.string = NSAttributedString(string: row.label, attributes: [
            .font: resolvedLabelFont, .foregroundColor: secondaryInk
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
        let emphasized = Self.differentiateWithoutColorEnabled && (row.health == .warning || row.health == .critical)
        let font = resolvedValueFont(bold: emphasized)
        let text = NSMutableAttributedString(string: row.value, attributes: [
            .font: core ? font : resolvedDetailFont, .foregroundColor: primaryInk
        ])
        if core, let space = row.value.firstIndex(of: " ") {
            let suffix = NSRange(space..<row.value.endIndex, in: row.value)
            text.addAttributes([.font: resolvedLabelFont, .foregroundColor: secondaryInk], range: suffix)
        } else if !core, row.health == .warning || row.health == .critical {
            text.addAttribute(.foregroundColor, value: cautionInk, range: NSRange(location: 0, length: text.length))
            if Self.differentiateWithoutColorEnabled {
                text.addAttribute(.font, value: StatsFont.monospacedDigitSystemFont(
                    ofSize: resolvedDetailFont.pointSize, weight: .bold), range: NSRange(location: 0, length: text.length))
            }
        }
        return text
    }

    static func valueFont(for health: StatsRow.Health, differentiateWithoutColor: Bool) -> StatsFont {
        if differentiateWithoutColor, health == .warning || health == .critical {
            return emphasizedValueFont
        }
        return normalValueFont
    }
}
