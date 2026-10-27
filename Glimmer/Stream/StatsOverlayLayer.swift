// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Text and traces stay inside the HDR video layer without a panel over the picture.

import GlimmerEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import QuartzCore

@MainActor
public final class StatsOverlayLayer {
    public let layer: CALayer

    static var labelFont: StatsFont { platformLabelFont }
    static var normalValueFont: StatsFont { platformValueFont(bold: false) }
    static var emphasizedValueFont: StatsFont { platformValueFont(bold: true) }
    static var detailFont: StatsFont { platformDetailFont }
    static let coreKinds = StatsOverlayFormatting.coreKinds

    weak var displayView: StatsView?
    var placementBounds: CGRect?
    var compactRows = false {
        didSet { if oldValue != compactRows { needsRowLayout = true } }
    }
    #if os(macOS)
    var accessibleRows: [StatsRow.Kind: NSAccessibilityElement] = [:]
    let accessibleCap = NSAccessibilityElement()
    #endif
    var videoSize: CGSize = .zero {
        didSet {
            if oldValue != videoSize, let host = layer.superlayer { layoutInHost(host) }
        }
    }
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
    private var compactLabelWidth: CGFloat = 0
    private var rowWidth: CGFloat { contentWidth + (compactRows ? compactLabelWidth + 12 * resolvedTextScale : 0) }
    private var columns = 1
    private var needsRowLayout = true
    private var contentSize: CGSize = .zero
    private var differentiateWithoutColor = false
    private var currentTextScale: CGFloat = 1
    private let capLayer = CATextLayer()
    private var capText = ""

    public init() {
        layer = CALayer()
        #if os(iOS)
        layer.isGeometryFlipped = true
        #endif
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
        let picture = pictureRect(in: host.bounds)
        let rect = layer.frame.intersection(picture)
        guard !rect.isNull, picture.width > 0, picture.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - picture.minX) / picture.width,
                      y: sampleOrigin(rect: rect, picture: picture),
                      width: rect.width / picture.width, height: rect.height / picture.height)
    }

    nonisolated public static func shouldUseDarkInk(luminance: Double, currentlyDark: Bool) -> Bool {
        guard luminance.isFinite, (0...1).contains(luminance) else { return currentlyDark }
        // Compare perceived brightness, not linear light: diffuse HDR scenes must also turn the ink dark.
        let brightness = pow(luminance, 1 / 2.4)
        return currentlyDark ? brightness >= 0.48 : brightness > 0.62
    }

    public func updateBackdropLuminance(_ value: Double) {
        let dark = Self.shouldUseDarkInk(luminance: value, currentlyDark: usesDarkInk)
        guard dark != usesDarkInk else { return }
        usesDarkInk = dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
            .font: resolvedLabelFont, .foregroundColor: secondaryInk
        ])
        applyShadow(to: capLayer)
    }

    public func attach(to host: CALayer) {
        host.addSublayer(layer)
        layoutInHost(host)
    }

    /// Intersect the picture with the safe area before adding the same inset on every edge.
    static func availableRect(in bounds: CGRect, videoSize: CGSize, safeArea: StatsInsets) -> CGRect {
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
    static func panelFrame(size: CGSize, in available: CGRect, corner: StatsOverlayCorner,
                           preferredScale: CGFloat = 1, inset: CGFloat = 16) -> CGRect {
        let area = available.insetBy(
            dx: min(inset, available.width / 2), dy: min(inset, available.height / 2))
        let scale = min(preferredScale, area.width / max(1, size.width), area.height / max(1, size.height))
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

    private func safeAreaInsets(in bounds: CGRect) -> StatsInsets {
        #if os(macOS)
        guard let view = displayView, let window = view.window, let screen = window.screen else {
            return StatsInsets()
        }
        let insets = screen.safeAreaInsets
        let frame = screen.frame
        let safeScreen = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.bottom,
            width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom)
        let safe = view.convert(window.convertFromScreen(safeScreen), from: nil)
        return StatsInsets(
            top: max(0, bounds.maxY - safe.maxY), left: max(0, safe.minX - bounds.minX),
            bottom: max(0, safe.minY - bounds.minY), right: max(0, bounds.maxX - safe.maxX))
        #else
        return displayView?.safeAreaInsets ?? .zero
        #endif
    }

    public func layoutInHost(_ host: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var available = Self.availableRect(in: host.bounds, videoSize: layoutVideoSize,
                                           safeArea: safeAreaInsets(in: host.bounds))
        let preferredScale = Self.viewportScale(in: available.size)
        if let placementBounds {
            let clipped = available.intersection(placementBounds)
            available = clipped.isNull ? CGRect(origin: available.origin, size: .zero) : clipped
        }
        let rows = orderedKinds.compactMap { rowViews[$0]?.lastRender }
        let rowsHeight = rows.reduce(CGFloat.zero) { $0 + rowBands(for: $1.kind).height + 3 }
        let columnArea = CGRect(origin: .zero, size: CGSize(width: available.width / preferredScale,
                                                          height: available.height / preferredScale))
        let columnCount = Self.columnCount(height: rowsHeight, width: rowWidth, available: columnArea)
        if columns != columnCount { columns = columnCount; needsRowLayout = true }
        if needsRowLayout {
            let count = max(1, (rows.count + columns - 1) / columns)
            let heights = stride(from: 0, to: rows.count, by: count).map { start in
                rows[start..<min(start + count, rows.count)].reduce(CGFloat.zero) {
                    $0 + rowBands(for: $1.kind).height + 3
                }
            }
            contentSize = CGSize(width: rowWidth * CGFloat(columns) + CGFloat(columns - 1) * 24,
                                 height: max(0, (heights.max() ?? 0) - 3) + (capText.isEmpty ? 0 : 12 * resolvedTextScale))
            layer.bounds = CGRect(origin: .zero, size: contentSize)
            layoutRows(rows, in: contentSize)
            needsRowLayout = false
        }
        let frame = Self.panelFrame(size: contentSize, in: available, corner: corner,
                                    preferredScale: preferredScale, inset: compactRows ? 8 : 16)
        let scale = frame.width / max(1, contentSize.width)
        let position = hostPosition(frame: frame, bounds: host.bounds)
        if layer.position != position { layer.position = position }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if layer.affineTransform() != transform { layer.setAffineTransform(transform) }
        updateAccessibilityFrames()
        let contentsScale = (displayScale ?? host.contentsScale) * max(1, scale)
        if layer.contentsScale != contentsScale {
            layer.contentsScale = contentsScale
            capLayer.contentsScale = contentsScale
            for sub in rowViews.values {
                sub.labelLayer.contentsScale = contentsScale
                sub.valueLayer.contentsScale = contentsScale
            }
        }
    }

    func update(
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
            contentWidth = 160 * resolvedTextScale
            compactLabelWidth = 0
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
        updateAccessibleRows(rows, cap: capText)
    }

    private func measure(_ row: StatsRow) {
        // Width only grows within a preset, so digit changes cannot make the HUD breathe.
        let label = ceil(NSAttributedString(string: row.label, attributes: [.font: resolvedLabelFont]).size().width)
        if label > compactLabelWidth { compactLabelWidth = label; needsRowLayout = true }
        let value = ceil(attributedValue(row).size().width)
        guard value > contentWidth else { return }
        contentWidth = value
        needsRowLayout = true
    }

    @discardableResult
    private func refreshAccessibility() -> Bool {
        let opaque = Self.reduceTransparencyEnabled
        let differentiate = Self.differentiateWithoutColorEnabled
        let scale = resolvedTextScale
        let changed = reduceTransparency != opaque || differentiateWithoutColor != differentiate
            || currentTextScale != scale
        if currentTextScale != scale {
            needsRowLayout = true
            contentWidth = 160 * scale
            compactLabelWidth = 0
            currentTextScale = scale
        }
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
        updateAccessibleRows(orderedKinds.compactMap { rowViews[$0]?.lastRender }, cap: capText)
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        if visible {
            refreshAccessibility()
            if let host = layer.superlayer { layoutInHost(host) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = visible ? 1 : 0
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if visible {
            layer.isHidden = false
            layer.opacity = 1
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                self?.finishHide(generation: generation)
            }
            layer.opacity = 0
        }
        layer.add(fade, forKey: "visibility")
        CATransaction.commit()
    }

    func finishHide(generation: Int) {
        guard visibilityGeneration == generation else { return }
        // The opacity fade already finished; an implicit order-out transition would retain its snapshot.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }

    /// Row height plus the value and trace bands inside it. Core rows carry the large
    /// value; other traced rows a smaller value over a shorter trace; the rest are text.
    static func rowBands(for kind: StatsRow.Kind, scale: CGFloat = 1)
        -> (height: CGFloat, value: CGFloat, trace: CGFloat) {
        if coreKinds.contains(kind) { return (54 * scale, 24 * scale, 17 * scale) }
        return StatsTrace.Metric(kind: kind) == nil
            ? (32 * scale, 19 * scale, 0) : (46 * scale, 19 * scale, 14 * scale)
    }

    private func rowBands(for kind: StatsRow.Kind) -> (height: CGFloat, value: CGFloat, trace: CGFloat) {
        let bands = Self.rowBands(for: kind, scale: resolvedTextScale)
        let compactHeight = max(resolvedValueFont(bold: true).pointSize, resolvedDetailFont.pointSize) * 1.2 + 2
        return compactRows ? (compactHeight, compactHeight, 0) : bands
    }

    private func layoutRows(_ rows: [StatsRow], in size: CGSize) {
        var top = size.height
        let count = max(1, (rows.count + columns - 1) / columns)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: count) { top = size.height }
            let x = CGFloat(index / count) * (rowWidth + 24)
            guard let sub = rowViews[row.kind] else { continue }
            let bands = rowBands(for: row.kind)
            top -= bands.height
            sub.container.frame = CGRect(x: x, y: top, width: rowWidth, height: bands.height)
            let labelY = compactRows ? (bands.height - 13 * resolvedTextScale) / 2
                : bands.height - 13 * resolvedTextScale
            sub.labelLayer.frame = CGRect(x: 0, y: labelY,
                                           width: compactRows ? compactLabelWidth : contentWidth,
                                           height: 13 * resolvedTextScale)
            sub.valueLayer.frame = CGRect(x: compactRows ? compactLabelWidth + 12 * resolvedTextScale : 0,
                                           y: bands.trace, width: contentWidth, height: bands.value)
            sub.trace?.layer.isHidden = compactRows
            sub.trace?.layer.frame = CGRect(x: 0, y: 0, width: contentWidth, height: bands.trace)
            top -= 3
        }
        capLayer.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 12 * resolvedTextScale)
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
