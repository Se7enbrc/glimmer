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

    func makeRow() -> RowSublayers {
        let container = CALayer()
        container.actions = Self.disabledActions
        let label = makeTextLayer()
        let value = makeTextLayer()
        value.alignmentMode = .right
        container.addSublayer(label)
        container.addSublayer(value)
        return RowSublayers(container: container, labelLayer: label, valueLayer: value, lastRender: nil)
    }

    private func makeTextLayer() -> CATextLayer {
        let text = CATextLayer()
        text.contentsScale = layer.contentsScale
        text.isWrapped = false
        text.truncationMode = .end
        text.actions = Self.disabledActions
        return text
    }

    func apply(row: StatsRow, to sub: RowSublayers) {
        if sub.lastRender?.label != row.label {
            sub.labelLayer.string = NSAttributedString(string: row.label, attributes: [
                .font: Self.labelFont, .foregroundColor: NSColor(white: 1, alpha: 0.72)
            ])
        }
        sub.valueLayer.string = NSAttributedString(string: row.value, attributes: [
            .font: Self.valueFont(for: row.health,
                                 differentiateWithoutColor:
                                    NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor),
            .foregroundColor: healthColor(row.health)
        ])
    }

    static func valueFont(for health: StatsRow.Health, differentiateWithoutColor: Bool) -> NSFont {
        if differentiateWithoutColor, health == .warning || health == .critical {
            return emphasizedValueFont
        }
        return normalValueFont
    }

    private func healthColor(_ health: StatsRow.Health) -> NSColor {
        switch health {
        case .healthy, .neutral: return .white
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }
}
