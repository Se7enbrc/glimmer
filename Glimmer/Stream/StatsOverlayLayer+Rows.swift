//
//  StatsOverlayLayer+Rows.swift
//
//  ROW CONSTRUCTION for the in-stream stats overlay: building a row's
//  icon+text sublayer pair, applying a StatsRow to an existing pair, the
//  attributed-string composition that right-aligns the value column off a
//  single tab stop, the health->color mapping, and the cached SF Symbol
//  rasterisation. Split out of StatsOverlayLayer.swift (pure move) to keep
//  each unit under the length limit; see that file for the panel itself -
//  its stored layers, the layout pass, and the per-tick row diff that calls
//  into here.
//
//  MainActor throughout (CALayer + NSScreen + AppKit drawing), same as the
//  panel: everything here runs on the overlay timer's main-thread tick.
//

import AppKit
import QuartzCore

extension StatsOverlayLayer {

    // MARK: Row construction --------------------------------------------

    /// Build a fresh row sublayer pair for one StatsRow. Called the
    /// first time a kind appears; subsequent ticks reuse the layers via
    /// `apply(row:to:)`. Module-internal (not private) so the per-tick row
    /// diff in StatsOverlayLayer.swift can reach it across the file split.
    func makeRow(for row: StatsRow) -> RowSublayers {
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
    /// sublayer pair. Module-internal (not private) for the same reason
    /// `makeRow` is - the per-tick diff calls it from the panel file.
    func apply(row: StatsRow, to sub: RowSublayers) {
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
}
