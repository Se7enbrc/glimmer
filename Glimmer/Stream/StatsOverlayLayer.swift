// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Text and traces stay inside the HDR video layer without a panel over the picture.

import AppKit
import AVFoundation
import QuartzCore

@MainActor
public final class StatsOverlayLayer {
    public let layer: CALayer

    static let labelFont = NSFont.preferredFont(forTextStyle: .caption2, options: [:])
    static let normalValueFont = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
    static let emphasizedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
    static let detailFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize, weight: .medium)
    static let coreKinds: [StatsRow.Kind] = [.renderFps, .latency, .bitrate]

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
        let trace: StatsTrace?
        var lastRender: StatsRow?
    }

    private(set) var rowViews: [StatsRow.Kind: RowSublayers] = [:]
    private(set) var usesDarkInk = false
    private(set) var reduceTransparency = false
    private var orderedKinds: [StatsRow.Kind] = []
    private var enabledRows: Set<StatsRow.Kind> = []
    private var contentWidth: CGFloat = 160
    private var needsRowLayout = true
    private var contentSize: CGSize = .zero
    private var differentiateWithoutColor = false
    private let capLayer = CATextLayer()
    private var capText = ""

    public init() {
        layer = CALayer()
        layer.zPosition = 1_000
        layer.actions = Self.disabledActions
        layer.isHidden = true
        layer.opacity = 0
        capLayer.actions = Self.disabledActions
        layer.addSublayer(capLayer)
        refreshAccessibility()
    }

    /// The sampler uses decoded-picture coordinates, independent of letterboxing and HUD scaling.
    public var backdropSampleRect: CGRect {
        guard let host = layer.superlayer, videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let picture = AVMakeRect(aspectRatio: videoSize, insideRect: host.bounds)
        let rect = layer.frame.intersection(picture)
        guard !rect.isNull, picture.width > 0, picture.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - picture.minX) / picture.width,
                      y: (picture.maxY - rect.maxY) / picture.height,
                      width: rect.width / picture.width, height: rect.height / picture.height)
    }

    nonisolated public static func shouldUseDarkInk(luminance: Double, currentlyDark: Bool) -> Bool {
        guard luminance.isFinite, (0...1).contains(luminance) else { return currentlyDark }
        return currentlyDark ? luminance >= 0.48 : luminance > 0.62
    }

    public func updateBackdropLuminance(_ value: Double) {
        let dark = Self.shouldUseDarkInk(luminance: value, currentlyDark: usesDarkInk)
        guard dark != usesDarkInk else { return }
        usesDarkInk = dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            layer.add(fade, forKey: "ink")
        } else {
            layer.removeAnimation(forKey: "ink")
        }
        refreshInk()
        CATransaction.commit()
    }

    private func refreshInk() {
        for sub in rowViews.values {
            if let row = sub.lastRender { apply(row: row, to: sub) }
        }
        applyCap()
    }

    private func applyCap() {
        capLayer.string = NSAttributedString(string: capText, attributes: [
            .font: Self.labelFont, .foregroundColor: secondaryInk
        ])
        applyShadow(to: capLayer)
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
            let rowsHeight = rows.reduce(CGFloat.zero) { $0 + Self.rowHeight(for: $1.kind) + 3 }
            contentSize = CGSize(width: contentWidth,
                                 height: max(0, rowsHeight - 3) + (capText.isEmpty ? 0 : 12))
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
            capLayer.contentsScale = contentsScale
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
        let rows = Self.displayRows(snapshot: snapshot, enabled: enabled, targetFps: targetFps, thresholds: thresholds)
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
            contentWidth = 160
            needsRowLayout = true
        }
        let cap = enabled.contains(.bitrate) ? snapshot.negotiatedBitrateMbps : nil
        let newCap = cap.flatMap { $0.isFinite ? String(format: "Cap %.0f Mbps", $0) : nil } ?? ""
        if newCap != capText {
            needsRowLayout = needsRowLayout || capText.isEmpty != newCap.isEmpty
            capText = newCap
            applyCap()
        }
        for row in rows {
            if rowViews[row.kind] == nil {
                let sub = makeRow(kind: row.kind)
                layer.addSublayer(sub.container)
                rowViews[row.kind] = sub
            }
            guard let sub = rowViews[row.kind] else { continue }
            sub.trace?.append(snapshot: snapshot, targetFps: targetFps, thresholds: thresholds)
            if sub.lastRender != row || appearanceChanged {
                apply(row: row, to: sub)
                rowViews[row.kind]?.lastRender = row
            }
            if sub.lastRender != row || rowsChanged || appearanceChanged {
                measure(row)
            }
        }
        if let host = layer.superlayer { layoutInHost(host) }
        for sub in rowViews.values { sub.trace?.draw() }
    }

    private func measure(_ row: StatsRow) {
        // Width only grows within a preset, so digit changes cannot make the HUD breathe.
        let value = ceil(attributedValue(row).size().width)
        guard value > contentWidth else { return }
        contentWidth = value
        needsRowLayout = true
    }

    @discardableResult
    private func refreshAccessibility() -> Bool {
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency
        let differentiate = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        let changed = reduceTransparency != opaque || differentiateWithoutColor != differentiate
        reduceTransparency = opaque
        differentiateWithoutColor = differentiate
        if changed { refreshInk() }
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

    /// Row height plus the value and trace bands inside it. Core rows carry the large
    /// value; other traced rows a smaller value over a shorter trace; the rest are text.
    static func rowBands(for kind: StatsRow.Kind) -> (height: CGFloat, value: CGFloat, trace: CGFloat) {
        if coreKinds.contains(kind) { return (54, 24, 17) }
        return StatsTrace.Metric(kind: kind) == nil ? (32, 19, 0) : (46, 19, 14)
    }

    private static func rowHeight(for kind: StatsRow.Kind) -> CGFloat { rowBands(for: kind).height }

    private func layoutRows(_ rows: [StatsRow], in size: CGSize) {
        var top = size.height
        for row in rows {
            guard let sub = rowViews[row.kind] else { continue }
            let bands = Self.rowBands(for: row.kind)
            top -= bands.height
            sub.container.frame = CGRect(x: 0, y: top, width: size.width, height: bands.height)
            sub.labelLayer.frame = CGRect(x: 0, y: bands.height - 13, width: size.width, height: 13)
            sub.valueLayer.frame = CGRect(x: 0, y: bands.trace, width: size.width, height: bands.value)
            sub.trace?.layer.frame = CGRect(x: 0, y: 0, width: size.width, height: bands.trace)
            top -= 3
        }
        capLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: 12)
    }

    static let disabledActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "string": NSNull(), "foregroundColor": NSNull(), "backgroundColor": NSNull(),
        "frame": NSNull(), "opacity": NSNull(), "transform": NSNull(),
        "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(),
        "shadowColor": NSNull(), "shadowOpacity": NSNull(), "shadowRadius": NSNull()
    ]
}

/// Main-actor ownership lets a one-shot observer remove its own token in Swift 6.
@MainActor
final class OneShotObserverBox {
    var token: NSObjectProtocol?
}
