//
//  StatsOverlayLayer.swift
//
//  The in-stream stats overlay compositor: a CALayer stack that renders the
//  StreamStatsSnapshot rows (icon + attributed text + health color + dividers)
//  over the AVSampleBufferDisplayLayer, plus the OneShotObserverBox helper.
//  Split out of StreamWindow.swift to keep each unit focused.
//

import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import os.log

// MARK: - StatsOverlayLayer

/// Compact-HUD stats panel rendered above the AVSampleBufferDisplayLayer.
///
/// Hierarchy:
///   displayLayer (AVSampleBufferDisplayLayer, view's root)
///     └─ StatsOverlayLayer container (CALayer) - rounded translucent panel
///        ├─ row 0: icon (CALayer.contents = SF Symbol CGImage)
///        │         + text (CATextLayer with NSAttributedString -
///        │           SF Pro Text label on the left, SF Mono value on
///        │           the right with health color)
///        ├─ row 1: same shape
///        ├─ divider (1pt CALayer at 8% white) - only between sections
///        ├─ row 2 ...
///        └─ row N
///
/// Why a row-per-sublayer-pair architecture and not one big newlined
/// CATextLayer:
///   * Per-row icons require their own CALayer.contents anyway - once
///     we have a sublayer per row to host the icon, packing the text
///     into the same row's text sublayer keeps the icon and its row's
///     baseline aligned naturally (one CATextLayer line height, one
///     icon, one frame).
///   * Per-row health colors are easier to express as
///     NSAttributedString attributes on a single-row text layer than
///     on a multi-line block (CATextLayer respects per-range
///     foregroundColor only via NSAttributedString, so the multi-line
///     path also pays the attributed-string cost).
///   * Diffing rows is cheaper: when only the value of one row changes
///     (the common case), we update one CATextLayer.string and skip
///     the rest. Newline-joined CATextLayer.string requires re-rendering
///     the whole block on any line change.
///
/// Sizing: a fixed 360pt panel width with the height growing to fit the
/// current number of rows + dividers. The panel never shrinks below
/// `padding * 2 + rowHeight` so a zero-rows state still renders a small
/// visible chip (rather than collapsing to a glyph-less rectangle, which
/// would surprise a user who toggled all checkboxes off in Custom).
@MainActor
public final class StatsOverlayLayer {
    /// The root layer that holds the background + rows. Public so a
    /// future caller could re-parent it, but in practice the only
    /// attachment is in `StreamWindow.init` via `attach(to:)`.
    public let layer: CALayer

    // Layout constants - tuned to match the Liquid Glass aesthetic Apple
    // ships in macOS 26 for floating in-stream overlays.
    private static let inset: CGFloat = 20
    private static let padding: CGFloat = 12
    private static let maxWidth: CGFloat = 360
    private static let cornerRadius: CGFloat = 14
    /// SF Pro Text + SF Mono row text size. 11pt fits ~30 chars across
    /// the value column at 360pt panel width with the icon + label
    /// columns reserved.
    private static let fontSize: CGFloat = 11
    /// Icon slot width (16pt). SF Symbols at 12pt ascender+descender land
    /// well under this with a small horizontal breathing margin.
    private static let iconSlotWidth: CGFloat = 16
    /// Gap between icon and label.
    private static let iconLabelGap: CGFloat = 6
    /// Per-row height: 11pt text + 7pt line spacing = 18pt slot.
    private static let rowHeight: CGFloat = 18
    /// Section divider: 1pt hairline with 4pt of breathing room above
    /// and below.
    private static let dividerHeight: CGFloat = 1
    private static let dividerVerticalPadding: CGFloat = 4

    /// Which screen corner the overlay anchors to. Defaults to the
    /// historical top-left position; the session owner re-sets this from
    /// `MoonlightManager.streamStatsCorner` at stream-start time. The
    /// setter re-flows the layout immediately if we're already attached
    /// to a host layer.
    public var corner: StatsOverlayCorner = .topLeft {
        didSet {
            guard oldValue != corner else { return }
            if let host = layer.superlayer {
                layoutInHost(host)
            }
        }
    }

    /// Per-row sublayer pair (icon + text). One of these per visible row;
    /// the layer holds them in `rowViews` keyed by `StatsRow.Kind` so the
    /// diff path can reuse layers across ticks instead of tearing them
    /// down and re-creating them every snapshot.
    private struct RowSublayers {
        let container: CALayer       // owns the icon + text, sized to one row
        let iconLayer: CALayer       // contents = SF Symbol CGImage
        let textLayer: CATextLayer   // attributed string: label + value
        /// Last rendered row to skip CATransaction churn when nothing
        /// actually changed (value strings tick once per second; labels
        /// never change for a given Kind, and icons change only for the
        /// battery row's level glyph).
        var lastRender: StatsRow?
    }

    /// Live row sublayers keyed by kind. We diff against the new rows[]
    /// each tick: kinds that appear in both keep their layers; new kinds
    /// allocate fresh sublayers; kinds that disappeared get pulled from
    /// the parent and dropped here.
    private var rowViews: [StatsRow.Kind: RowSublayers] = [:]

    /// Active section-divider layers, top-down. Recycled across ticks
    /// when the number of dividers doesn't change (the common case once
    /// the user picks a preset).
    private var dividerLayers: [CALayer] = []

    /// Cached SF Symbol CGImages keyed by SF Symbol name. The icons are
    /// rendered once per (name, scale) combo and reused - the alternative
    /// (NSImage(systemSymbolName:) → CGImage every tick) would re-render
    /// the symbol bitmap 12 times per snapshot.
    ///
    /// We don't bound the cache because the set of icons is closed: one
    /// static name per `StatsRow.Kind` plus the small `battery.*` level
    /// family the battery row cycles through. No risk of unbounded growth
    /// from runtime input.
    private var iconCache: [String: CGImage] = [:]

    public init() {
        // Container layer - the background rounded rectangle.
        let bg = CALayer()
        bg.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.42)
        bg.cornerRadius = StatsOverlayLayer.cornerRadius
        // 1 pt inner rim - a hairline at the top edge fakes the rim
        // highlight Liquid Glass surfaces get from real refraction.
        // Without this the panel reads as a flat dark rectangle against
        // bright HDR content. We can't use a real backdrop blur here
        // (would break EDR composition - see StreamWindow.init), so the
        // rim is doing the work of communicating "floating material".
        bg.borderColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
        bg.borderWidth = 1
        bg.zPosition = 1_000  // above any future sublayers of displayLayer.
        bg.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        bg.actions = StatsOverlayLayer.disabledActions

        self.layer = bg
    }

    /// Attach the overlay as a sublayer of the host video layer. Called
    /// once at construction time from `StreamWindow.init`.
    public func attach(to host: CALayer) {
        host.addSublayer(layer)
        layoutInHost(host)
    }

    /// Re-flow the panel against the host's current bounds. Cheap; safe
    /// to call from layout passes (the host view's `layout` doesn't fire
    /// during a stream because the window covers a fixed screen frame).
    public func layoutInHost(_ host: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let inset = StatsOverlayLayer.inset
        let pad = StatsOverlayLayer.padding
        let maxW = StatsOverlayLayer.maxWidth
        let boxWidth = maxW
        let contentHeight = currentContentHeight()
        let boxHeight = max(contentHeight, StatsOverlayLayer.rowHeight) + 2 * pad

        let hostWidth = host.bounds.width
        let hostHeight = host.bounds.height
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:
            x = inset
            y = hostHeight - inset - boxHeight
        case .topRight:
            x = hostWidth - inset - boxWidth
            y = hostHeight - inset - boxHeight
        case .bottomLeft:
            x = inset
            y = inset
        case .bottomRight:
            x = hostWidth - inset - boxWidth
            y = inset
        }
        layer.frame = CGRect(x: x, y: y, width: boxWidth, height: boxHeight)
        layoutRowsAndDividers(inWidth: boxWidth, height: boxHeight)
    }

    /// Push a new snapshot into the overlay. Builds the row list,
    /// diffs against the live sublayers, and updates only what changed.
    /// At the 4 Hz overlay cadence the diff overhead is negligible - and the
    /// diff is exactly what makes the faster tick free: most ticks only the
    /// live latency rows (RTT / jitter) change, so we update one
    /// CATextLayer.string and leave the FPS / bitrate rows (still on their ~1s
    /// average) untouched - no churn on the steady rows.
    public func update(
        snapshot: StreamStatsSnapshot,
        enabled: Set<StatsRow.Kind>,
        targetFps: Double,
        thresholds: StatsThresholds = .default
    ) {
        let rows = snapshot.rows(enabled: enabled, targetFps: targetFps, thresholds: thresholds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // 1) Reconcile sublayer set against the new row list.
        let newKinds = Set(rows.map(\.kind))
        // Remove rows that dropped out (user toggled them off).
        for (kind, view) in rowViews where !newKinds.contains(kind) {
            view.container.removeFromSuperlayer()
            rowViews.removeValue(forKey: kind)
        }
        // Add rows that newly appeared, and update content for all of them.
        for row in rows {
            if let existing = rowViews[row.kind] {
                if existing.lastRender != row {
                    apply(row: row, to: existing)
                    rowViews[row.kind]?.lastRender = row
                }
            } else {
                let sub = makeRow(for: row)
                layer.addSublayer(sub.container)
                rowViews[row.kind] = sub
            }
        }

        // 2) Re-flow positions - the row count may have changed (preset
        //    flip, audio toggled in/out via custom checkboxes), which
        //    changes the panel height and the per-row Y origins.
        if let host = layer.superlayer {
            layoutInHost(host)
        } else {
            // No host yet (very early init) - still size ourselves
            // against the cached width so the next attach() has the
            // right geometry.
            layoutRowsAndDividers(inWidth: layer.bounds.width, height: layer.bounds.height)
        }
    }

    /// Show or hide the overlay. Uses a 120 ms crossfade so a hotkey-driven
    /// toggle feels snappy without being abrupt, matching the design spec.
    public func setVisible(_ visible: Bool) {
        if visible == !layer.isHidden { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if visible {
            layer.isHidden = false
            layer.opacity = 1.0
        } else {
            CATransaction.setCompletionBlock { [weak layer] in
                layer?.isHidden = true
            }
            layer.opacity = 0.0
        }
        CATransaction.commit()
    }

    // MARK: Row construction --------------------------------------------

    /// Build a fresh row sublayer pair for one StatsRow. Called the
    /// first time a kind appears; subsequent ticks reuse the layers via
    /// `apply(row:to:)`.
    private func makeRow(for row: StatsRow) -> RowSublayers {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        let container = CALayer()
        container.actions = StatsOverlayLayer.disabledActions
        container.contentsScale = scale

        let icon = CALayer()
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = scale
        icon.actions = StatsOverlayLayer.disabledActions
        // Contents are populated by the apply() call below - icon
        // reconciliation lives there so first render and later symbol
        // changes share one code path.
        container.addSublayer(icon)

        let text = CATextLayer()
        text.contentsScale = scale
        text.isWrapped = false
        text.truncationMode = .end
        text.alignmentMode = .left
        text.actions = StatsOverlayLayer.disabledActions
        // The attributed string carries the per-range fonts + colors so
        // the layer doesn't need its own font/foregroundColor - both
        // are ignored when the `string` is an NSAttributedString.
        container.addSublayer(text)

        var sub = RowSublayers(
            container: container, iconLayer: icon, textLayer: text,
            lastRender: nil)
        apply(row: row, to: sub)
        sub.lastRender = row
        return sub
    }

    /// Apply a row's label / value / health / icon to an existing
    /// sublayer pair.
    private func apply(row: StatsRow, to sub: RowSublayers) {
        // Icons are per-Kind and usually static, but not always: the
        // battery row picks a level glyph (battery.0/25/.../bolt) that
        // moves with the charge, and goes nil when there's no battery to
        // read (desktop Macs) - an empty icon slot, never a misleading
        // battery-empty glyph. Reconcile only on change so the static
        // rows skip the bitmap lookup on every tick.
        if sub.lastRender?.symbolName != row.symbolName {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            sub.iconLayer.contents = row.symbolName.flatMap { iconImage(for: $0, scale: scale) }
        }
        // Right-align the value: NSAttributedString lets us tag the
        // label and value with separate paragraph styles + fonts +
        // colors. The text layer's frame spans the icon's right edge to
        // the row's right edge; we use a tab stop at the far right so
        // the value visually right-aligns inside that frame.
        //
        // Why a tab stop and not two separate text layers: the layout
        // math for two layers (measure label width, place value layer
        // at trailing edge minus value width) is fiddly with mixed
        // fonts (SF Pro Text and SF Mono have different metrics per
        // character class). A single CATextLayer with one tab stop at
        // the right edge defers the alignment to CoreText which gets
        // the metrics correct by construction.
        sub.textLayer.string = buildAttributedString(for: row)
    }

    /// Construct the per-row attributed string: label in SF Pro Text
    /// (white at 80% alpha) then a tab, then the value in SF Mono
    /// (white / yellow / red per health). The tab stops at the right
    /// edge of the text frame, so the value column right-aligns.
    private func buildAttributedString(for row: StatsRow) -> NSAttributedString {
        let pad = StatsOverlayLayer.padding
        let icon = StatsOverlayLayer.iconSlotWidth
        let gap = StatsOverlayLayer.iconLabelGap
        let textWidth = StatsOverlayLayer.maxWidth - 2 * pad - icon - gap

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        // Right tab at the trailing edge. NSAttributedString + a tab
        // character + a right tab stop is the canonical way to right-
        // align a single span inside an otherwise left-aligned line.
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: textWidth, options: [:])
        ]

        let labelFont = NSFont.systemFont(
            ofSize: StatsOverlayLayer.fontSize, weight: .regular)
        let valueFont = NSFont(
            name: "SFMono-Regular", size: StatsOverlayLayer.fontSize)
            ?? NSFont.monospacedSystemFont(
                ofSize: StatsOverlayLayer.fontSize, weight: .regular)

        // 80% alpha de-emphasises labels so the value reads as the
        // primary content. The HIG-respecting alternative is the
        // semantic NSColor.secondaryLabelColor, but the panel composites
        // against arbitrary HDR video - that color resolves to a system
        // gray that disappears against bright content. Fixed-alpha white
        // works at every backdrop.
        let labelColor = NSColor(white: 1.0, alpha: 0.80)
        let valueColor = healthColor(row.health)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: row.label,
            attributes: [
                .font: labelFont,
                .foregroundColor: labelColor,
                .paragraphStyle: paragraph
            ]))
        result.append(NSAttributedString(
            string: "\t",
            attributes: [.paragraphStyle: paragraph]))
        result.append(NSAttributedString(
            string: row.value,
            attributes: [
                .font: valueFont,
                .foregroundColor: valueColor,
                .paragraphStyle: paragraph
            ]))
        return result
    }

    /// Map row health → NSColor for the value text.
    ///
    /// Healthy and neutral both render at full white today. We could
    /// dim neutral further to read as "informational, not a signal",
    /// but in practice the labels on neutral rows ("Host", "Bitrate",
    /// "Host encode", "Audio") already telegraph that they're
    /// informational, and dimming would make the bitrate row hard to
    /// read at a glance - which is exactly when the user looks at it.
    private func healthColor(_ h: StatsRow.Health) -> NSColor {
        switch h {
        case .healthy, .neutral: return NSColor(white: 1.0, alpha: 1.0)
        case .warning:           return NSColor.systemYellow
        case .critical:          return NSColor.systemRed
        }
    }

    /// Render an SF Symbol to a CGImage at the icon slot size.
    /// Cached by symbol name; cache key folds in the screen scale so a
    /// later display change doesn't serve a stale low-DPI image.
    private func iconImage(for name: String, scale: CGFloat) -> CGImage? {
        let cacheKey = "\(name)@\(scale)"
        if let cg = iconCache[cacheKey] { return cg }
        // 12pt symbol fits inside the 16pt icon slot with breathing
        // room. Weight .regular matches SF Pro Text's regular weight so
        // the icon and label have the same visual density.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }
        // Force rasterise to a CGImage at the screen scale so the
        // CALayer.contents path doesn't pay the NSImage → CGImage
        // conversion every recomposite.
        let size = NSSize(width: StatsOverlayLayer.iconSlotWidth,
                          height: StatsOverlayLayer.iconSlotWidth)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size),
                 from: .zero, operation: .sourceOver,
                 fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        let cg = rep.cgImage
        if let cg { iconCache[cacheKey] = cg }
        return cg
    }

    // MARK: Layout ------------------------------------------------------

    /// Position every row + divider sublayer inside the current panel
    /// bounds. Called from `layoutInHost` and from `update` after row
    /// reconciliation. Top-down ordering ignores Core Animation's
    /// bottom-left coordinate origin by translating the cursor through
    /// `boxHeight - cursorY`.
    private func layoutRowsAndDividers(inWidth boxWidth: CGFloat, height boxHeight: CGFloat) {
        let pad = StatsOverlayLayer.padding
        let rowHeight = StatsOverlayLayer.rowHeight
        let dividerH = StatsOverlayLayer.dividerHeight
        let dividerPadV = StatsOverlayLayer.dividerVerticalPadding
        let icon = StatsOverlayLayer.iconSlotWidth
        let gap = StatsOverlayLayer.iconLabelGap

        // We iterate rows in catalogue order (the order returned by
        // StreamStatsSnapshot.rows). Section changes between adjacent
        // rows emit a divider. We don't track Section explicitly here;
        // instead we look up each row's section from its last-render
        // payload - the apply() path always sets lastRender, and a
        // freshly-created row has its own section in lastRender from
        // makeRow's apply() call.
        let ordered: [StatsRow.Kind] = StatsRow.Kind.allCases
        var visibleRows: [(StatsRow.Kind, StatsRow)] = []
        for kind in ordered {
            if let sub = rowViews[kind], let last = sub.lastRender {
                visibleRows.append((kind, last))
            }
        }

        // Decide where the dividers go: between any two adjacent
        // visible rows whose sections differ.
        var needsDividerAfter: [Bool] = Array(repeating: false, count: visibleRows.count)
        for i in 0..<max(0, visibleRows.count - 1)
            where visibleRows[i].1.section != visibleRows[i + 1].1.section {
            needsDividerAfter[i] = true
        }

        // Reuse / create / drop divider sublayers to match the count.
        let dividerCount = needsDividerAfter.filter { $0 }.count
        while dividerLayers.count < dividerCount {
            let divider = CALayer()
            divider.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.08)
            divider.actions = StatsOverlayLayer.disabledActions
            layer.addSublayer(divider)
            dividerLayers.append(divider)
        }
        while dividerLayers.count > dividerCount {
            dividerLayers.removeLast().removeFromSuperlayer()
        }

        // Lay out rows top-down. CALayer origin is bottom-left, so we
        // compute a "from-top" Y for clarity and flip to bottom-left at
        // assignment time.
        var fromTop: CGFloat = pad
        var dividerIndex = 0
        for (i, (_, payload)) in visibleRows.enumerated() {
            guard let sub = rowViews[payload.kind] else { continue }
            // Row container: full content-width band of rowHeight.
            let rowY = boxHeight - fromTop - rowHeight
            sub.container.frame = CGRect(
                x: pad, y: rowY,
                width: boxWidth - 2 * pad, height: rowHeight)
            // Icon: left edge of the row.
            sub.iconLayer.frame = CGRect(
                x: 0, y: (rowHeight - StatsOverlayLayer.iconSlotWidth) / 2,
                width: StatsOverlayLayer.iconSlotWidth,
                height: StatsOverlayLayer.iconSlotWidth)
            // Text: right of the icon, filling the remaining width. The
            // tab stop in the attributed string places the value at the
            // text frame's trailing edge.
            sub.textLayer.frame = CGRect(
                x: icon + gap, y: 0,
                width: sub.container.bounds.width - icon - gap,
                height: rowHeight)
            fromTop += rowHeight
            if i < needsDividerAfter.count, needsDividerAfter[i] {
                let dY = boxHeight - fromTop - dividerPadV - dividerH
                dividerLayers[dividerIndex].frame = CGRect(
                    x: pad, y: dY,
                    width: boxWidth - 2 * pad, height: dividerH)
                dividerIndex += 1
                fromTop += dividerPadV * 2 + dividerH
            }
        }
    }

    /// Sum of row heights + section dividers for the current visible
    /// set. Used to size the panel.
    private func currentContentHeight() -> CGFloat {
        let rowHeight = StatsOverlayLayer.rowHeight
        let dividerBlock = StatsOverlayLayer.dividerHeight + 2 * StatsOverlayLayer.dividerVerticalPadding

        let ordered: [StatsRow.Kind] = StatsRow.Kind.allCases
        var visibleSections: [StatsRow.Section] = []
        var rowCount = 0
        for kind in ordered {
            if let sub = rowViews[kind], let last = sub.lastRender {
                visibleSections.append(last.section)
                rowCount += 1
            }
        }
        // Count section transitions: a divider between every adjacent
        // pair of differing sections.
        var dividerCount = 0
        for i in 0..<max(0, visibleSections.count - 1)
            where visibleSections[i] != visibleSections[i + 1] {
            dividerCount += 1
        }
        return CGFloat(rowCount) * rowHeight + CGFloat(dividerCount) * dividerBlock
    }

    /// Disable all implicit CAAction animations on a layer. CALayer's
    /// default actions crossfade contents/position/bounds changes,
    /// which we don't want here - the overlay should snap to its new
    /// value every tick. Reused across the background, the row
    /// containers, the icon + text sublayers, and the dividers.
    private static let disabledActions: [String: CAAction] = [
        "contents": NSNull(),
        "position": NSNull(),
        "bounds": NSNull(),
        "string": NSNull(),
        "foregroundColor": NSNull(),
        "backgroundColor": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull()
    ]
}

/// Heap-allocated single-slot container for a one-shot NotificationCenter
/// observer token. The observer's closure needs to know its OWN token so it can
/// remove itself after firing - but `var token: NSObjectProtocol?` captured by
/// a `@Sendable` closure is rejected in Swift 6 strict mode (the `var` cannot
/// be safely shared). Holding the token in a small class lets the closure
/// capture a reference to the class instead of mutating an in-scope var. We
/// constrain the box to MainActor because the only call sites set/clear the
/// token from within MainActor-isolated closures.
@MainActor
final class OneShotObserverBox {
    var token: NSObjectProtocol?
}
