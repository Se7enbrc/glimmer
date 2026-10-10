// The HUD stays inside the HDR video layer so its scrim never flattens the picture.

import AppKit
import AVFoundation
import QuartzCore

@MainActor
public final class StatsOverlayLayer {
    public let layer: CALayer

    static let padding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let columnGap: CGFloat = 12
    static let labelFont = NSFont.preferredFont(forTextStyle: .caption1, options: [:])
    static let fontSize = NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
    static let normalValueFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    static let emphasizedValueFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    private static let rowHeight = ceil(max(labelFont.ascender - labelFont.descender, fontSize * 1.3)) + 4
    private static let sectionGap: CGFloat = 6

    weak var displayView: NSView?
    var videoSize: CGSize = .zero
    public var corner: StatsOverlayCorner = .topLeft {
        didSet {
            guard oldValue != corner, let host = layer.superlayer else { return }
            layoutInHost(host)
        }
    }

    struct RowSublayers {
        let container: CALayer
        let labelLayer: CATextLayer
        let valueLayer: CATextLayer
        var lastRender: StatsRow?
    }

    private var rowViews: [StatsRow.Kind: RowSublayers] = [:]
    private var orderedKinds: [StatsRow.Kind] = []
    private var enabledRows: Set<StatsRow.Kind> = []
    private var dividerLayers: [CALayer] = []
    private var labelWidth: CGFloat = 0
    private var valueWidth: CGFloat = 0
    private var needsRowLayout = true
    private var contentSize: CGSize = .zero
    private var differentiateWithoutColor = false
    private var reduceTransparency: Bool?

    public init() {
        layer = CALayer()
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        layer.borderWidth = 0.5
        layer.zPosition = 1_000
        layer.actions = Self.disabledActions
        layer.isHidden = true
        layer.opacity = 0
        refreshAccessibility()
    }

    public func attach(to host: CALayer) {
        host.addSublayer(layer)
        layoutInHost(host)
    }

    /// Intersect the picture with the safe area before adding the same inset on every edge.
    static func availableRect(in bounds: CGRect, videoSize: CGSize, safeArea: NSEdgeInsets) -> CGRect {
        let safe = CGRect(
            x: bounds.minX + safeArea.left, y: bounds.minY + safeArea.bottom,
            width: max(0, bounds.width - safeArea.left - safeArea.right),
            height: max(0, bounds.height - safeArea.top - safeArea.bottom))
        let picture = videoSize.width > 0 && videoSize.height > 0
            ? AVMakeRect(aspectRatio: videoSize, insideRect: bounds) : bounds
        let available = picture.intersection(safe)
        return available.isNull ? .zero : available
    }

    /// Fit the whole HUD in a small player instead of cutting off detailed rows.
    static func panelFrame(size: CGSize, in available: CGRect, corner: StatsOverlayCorner) -> CGRect {
        let inset: CGFloat = 16
        let area = available.insetBy(
            dx: min(inset, available.width / 2), dy: min(inset, available.height / 2))
        let scale = min(1, area.width / max(1, size.width), area.height / max(1, size.height))
        let width = size.width * scale
        let height = size.height * scale
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft, .bottomLeft: x = area.minX
        case .topCenter, .bottomCenter: x = area.midX - width / 2
        case .topRight, .bottomRight: x = area.maxX - width
        }
        switch corner {
        case .topLeft, .topCenter, .topRight: y = area.maxY - height
        case .bottomLeft, .bottomCenter, .bottomRight: y = area.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func safeAreaInsets(in bounds: CGRect) -> NSEdgeInsets {
        guard let view = displayView, let window = view.window, let screen = window.screen else {
            return NSEdgeInsets()
        }
        let insets = screen.safeAreaInsets
        let frame = screen.frame
        let safeScreen = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.bottom,
            width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom)
        let safe = view.convert(window.convertFromScreen(safeScreen), from: nil)
        return NSEdgeInsets(
            top: max(0, bounds.maxY - safe.maxY), left: max(0, safe.minX - bounds.minX),
            bottom: max(0, safe.minY - bounds.minY), right: max(0, bounds.maxX - safe.maxX))
    }

    public func layoutInHost(_ host: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if needsRowLayout {
            let rows = orderedKinds.compactMap { rowViews[$0]?.lastRender }
            contentSize = CGSize(
                width: labelWidth + Self.columnGap + valueWidth + 2 * Self.padding,
                height: CGFloat(max(1, rows.count)) * Self.rowHeight
                    + CGFloat(sectionBreaks(in: rows).count) * Self.sectionGap + 2 * Self.verticalPadding)
            layer.bounds = CGRect(origin: .zero, size: contentSize)
            layoutRows(rows, in: contentSize)
            needsRowLayout = false
        }
        let available = Self.availableRect(in: host.bounds, videoSize: videoSize,
                                           safeArea: safeAreaInsets(in: host.bounds))
        let frame = Self.panelFrame(size: contentSize, in: available, corner: corner)
        let scale = frame.width / max(1, contentSize.width)
        let position = CGPoint(x: frame.midX, y: frame.midY)
        if layer.position != position { layer.position = position }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if layer.affineTransform() != transform { layer.setAffineTransform(transform) }
        let contentsScale = displayView?.window?.backingScaleFactor ?? host.contentsScale
        if layer.contentsScale != contentsScale {
            layer.contentsScale = contentsScale
            for sub in rowViews.values {
                sub.labelLayer.contentsScale = contentsScale
                sub.valueLayer.contentsScale = contentsScale
            }
        }
    }

    public func update(
        snapshot: StreamStatsSnapshot,
        enabled: Set<StatsRow.Kind>,
        targetFps: Double,
        thresholds: StatsThresholds = .default
    ) {
        let rows = Self.combinedRows(snapshot.rows(enabled: enabled, targetFps: targetFps, thresholds: thresholds))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let appearanceChanged = refreshAccessibility()
        let kinds = rows.map(\.kind)
        let rowsChanged = kinds != orderedKinds || enabled != enabledRows
        if rowsChanged {
            for (kind, sub) in rowViews where !kinds.contains(kind) {
                sub.container.removeFromSuperlayer()
                rowViews.removeValue(forKey: kind)
            }
            orderedKinds = kinds
            enabledRows = enabled
            labelWidth = 0
            valueWidth = 0
            needsRowLayout = true
        }
        for row in rows {
            if rowViews[row.kind] == nil {
                let sub = makeRow()
                layer.addSublayer(sub.container)
                rowViews[row.kind] = sub
            }
            guard let sub = rowViews[row.kind] else { continue }
            if sub.lastRender != row || appearanceChanged {
                apply(row: row, to: sub)
                rowViews[row.kind]?.lastRender = row
            }
            if sub.lastRender != row || rowsChanged {
                measure(row)
            }
        }
        if let host = layer.superlayer { layoutInHost(host) }
    }

    private func measure(_ row: StatsRow) {
        // Width only grows within a preset, so changing digit counts cannot make the HUD breathe.
        let label = ceil((row.label as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        let value = ceil((row.value as NSString).size(withAttributes: [.font: Self.emphasizedValueFont]).width)
        guard label > labelWidth || value > valueWidth else { return }
        labelWidth = max(labelWidth, label)
        valueWidth = max(valueWidth, value)
        needsRowLayout = true
    }

    @discardableResult
    private func refreshAccessibility() -> Bool {
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency
        if reduceTransparency != opaque {
            // A strong scrim preserves contrast over bright video without a backdrop filter in the HDR tree.
            layer.backgroundColor = NSColor(white: 0.06, alpha: opaque ? 1 : 0.88).cgColor
            reduceTransparency = opaque
        }
        let differentiate = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        let changed = differentiateWithoutColor != differentiate
        differentiateWithoutColor = differentiate
        return changed
    }

    public private(set) var isVisible = false
    private(set) var visibilityGeneration = 0

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        if visible {
            refreshAccessibility()
            if let host = layer.superlayer { layoutInHost(host) }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
        if visible {
            layer.isHidden = false
            layer.opacity = 1
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                self?.finishHide(generation: generation)
            }
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    func finishHide(generation: Int) {
        guard visibilityGeneration == generation else { return }
        layer.isHidden = true
    }

    private func sectionBreaks(in rows: [StatsRow]) -> [Int] {
        guard rows.count > 3 else { return [] }
        return rows.indices.dropFirst().filter { rows[$0].section != rows[$0 - 1].section }
    }

    private func layoutRows(_ rows: [StatsRow], in size: CGSize) {
        let breaks = sectionBreaks(in: rows)
        while dividerLayers.count < breaks.count {
            let divider = CALayer()
            divider.actions = Self.disabledActions
            divider.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
            layer.addSublayer(divider)
            dividerLayers.append(divider)
        }
        while dividerLayers.count > breaks.count {
            dividerLayers.removeLast().removeFromSuperlayer()
        }
        var top = size.height - Self.verticalPadding
        var dividerIndex = 0
        for (index, row) in rows.enumerated() {
            if breaks.contains(index) {
                dividerLayers[dividerIndex].frame = CGRect(
                    x: Self.padding, y: top - Self.sectionGap / 2,
                    width: size.width - 2 * Self.padding, height: 0.5)
                dividerIndex += 1
                top -= Self.sectionGap
            }
            guard let sub = rowViews[row.kind] else { continue }
            top -= Self.rowHeight
            sub.container.frame = CGRect(x: Self.padding, y: top,
                                         width: size.width - 2 * Self.padding, height: Self.rowHeight)
            let baseline: CGFloat = 4
            sub.labelLayer.frame = CGRect(
                x: 0, y: baseline + Self.labelFont.descender,
                width: labelWidth, height: ceil(Self.labelFont.ascender - Self.labelFont.descender))
            sub.valueLayer.frame = CGRect(
                x: labelWidth + Self.columnGap, y: baseline + Self.normalValueFont.descender,
                width: valueWidth, height: ceil(Self.normalValueFont.ascender - Self.normalValueFont.descender))
        }
    }

    static let disabledActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
        "frame": NSNull(), "opacity": NSNull(), "transform": NSNull()
    ]
}

/// Main-actor ownership lets a one-shot observer remove its own token in Swift 6.
@MainActor
final class OneShotObserverBox {
    var token: NSObjectProtocol?
}
