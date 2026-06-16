#!/usr/bin/swift
// Generates the Glimmer app icon set in Apple's macOS 26 "Liquid Glass" style.
// Full design notes, usage, and palette/Icon-Composer rationale live in the
// companion `scripts/generate-icons.md`; this header stays terse so the script
// keeps under the file-length guardrail.
//
// Usage (run via `swift scripts/generate-icons.swift [flag]`):
//   (none)      light variant — legacy .appiconset output
//   --dark      dark variant — brighter palette for a dark Dock
//   --layered   the 1024px layered PNGs for macOS 26's Icon Composer bundle

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output configuration

let outputDir = URL(fileURLWithPath: "Glimmer/Assets.xcassets/AppIcon.appiconset")
// The .icon bundle lives NEXT TO Assets.xcassets, not inside it (see the doc):
// Xcode 26 only honors the Icon Composer bundle as a top-level target resource.
let layeredOutputDir = URL(fileURLWithPath: "Glimmer/AppIcon.icon/Assets")

// The standard macOS .appiconset slots: each point-size gets an @1x (NxN) and
// an @2x (2N) PNG.
let sizes: [(name: String, dim: Int)] = [16, 32, 128, 256, 512].flatMap { pt in
    [(name: "icon_\(pt)x\(pt).png", dim: pt),
     (name: "icon_\(pt)x\(pt)@2x.png", dim: pt * 2)]
}

// MARK: - CLI

let isDark = CommandLine.arguments.contains("--dark")
let isLayered = CommandLine.arguments.contains("--layered")
let suffix = isDark ? "-dark" : ""

// MARK: - Color helpers

/// Builds an sRGB CGColor from 8-bit channel values plus optional alpha.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat(r) / 255.0,
        green: CGFloat(g) / 255.0,
        blue: CGFloat(b) / 255.0,
        alpha: a
    )
}

// sRGB is always available on macOS; the device-RGB fallback never triggers, it
// just avoids a force-unwrap.
let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

// Palette — instance-based so light + dark variants swap at CLI time. See the
// companion doc for the per-variant color rationale.
struct Palette {
    let bgTopLeft: CGColor          // background diagonal
    let bgBottomRight: CGColor
    let accent: CGColor             // warm glow, top-right
    let accentFade: CGColor
    let cool: CGColor               // cool counter-glow, bottom-left
    let coolFade: CGColor
    let moonCore: CGColor           // moon body (frosted glass)
    let moonMid: CGColor
    let moonRim: CGColor
    let moonShade: CGColor          // cool shadow side of the moon
    let starCore: CGColor           // sparkle core / fade
    let starHalo: CGColor
    let rimHi: CGColor              // top rim highlight
    let rimLo: CGColor
    let edgeStroke: CGColor         // inner edge stroke (defines the tile)
    let smallBg: CGColor            // small-renderer specifics
    let smallMoon: CGColor
    let smallNotch: CGColor

    static let light = Palette(
        bgTopLeft: rgb(0x1B, 0x1B, 0x4A),
        bgBottomRight: rgb(0x3F, 0x1E, 0x72),
        accent: rgb(0x5E, 0x2E, 0xAA, 0.65),
        accentFade: rgb(0x5E, 0x2E, 0xAA, 0.0),
        cool: rgb(0x12, 0x18, 0x3A, 0.55),
        coolFade: rgb(0x12, 0x18, 0x3A, 0.0),
        moonCore: rgb(0xFF, 0xEE, 0xDD, 0.92),
        moonMid: rgb(0xF6, 0xDD, 0xEE, 0.78),
        moonRim: rgb(0xE8, 0xC9, 0xF0, 0.55),
        moonShade: rgb(0x1B, 0x1B, 0x4A, 0.55),
        starCore: rgb(0xFF, 0xFF, 0xFF, 0.95),
        starHalo: rgb(0xC4, 0xD5, 0xFF, 0.0),
        rimHi: rgb(0xFF, 0xFF, 0xFF, 0.42),
        rimLo: rgb(0xFF, 0xFF, 0xFF, 0.0),
        edgeStroke: rgb(0xFF, 0xFF, 0xFF, 0.10),
        smallBg: rgb(0x2B, 0x1F, 0x6B),
        smallMoon: rgb(0xFF, 0xEE, 0xDD),
        smallNotch: rgb(0x2B, 0x1F, 0x6B)
    )

    // Dark variant — brighter, saturated purple; bottom-right pulls brand
    // accent #8110FE; moon palette unchanged. Rationale in the companion doc.
    static let dark = Palette(
        bgTopLeft: rgb(0x2B, 0x10, 0x6E),   // brighter deep purple
        bgBottomRight: rgb(0x81, 0x10, 0xFE),   // brand accent #8110FE
        accent: rgb(0xA0, 0x4D, 0xFF, 0.70),
        accentFade: rgb(0xA0, 0x4D, 0xFF, 0.0),
        cool: rgb(0x1F, 0x10, 0x55, 0.55),
        coolFade: rgb(0x1F, 0x10, 0x55, 0.0),
        moonCore: rgb(0xFF, 0xEE, 0xDD, 0.92),
        moonMid: rgb(0xF6, 0xDD, 0xEE, 0.78),
        moonRim: rgb(0xE8, 0xC9, 0xF0, 0.55),
        // Picks up the new bg so the lit-from-upper-left illusion stays consistent.
        moonShade: rgb(0x2B, 0x10, 0x6E, 0.55),
        starCore: rgb(0xFF, 0xFF, 0xFF, 0.95),
        starHalo: rgb(0xC4, 0xD5, 0xFF, 0.0),
        rimHi: rgb(0xFF, 0xFF, 0xFF, 0.46),
        rimLo: rgb(0xFF, 0xFF, 0xFF, 0.0),
        edgeStroke: rgb(0xFF, 0xFF, 0xFF, 0.14),
        // Small-renderer violet that holds the silhouette at 16/32pt.
        smallBg: rgb(0x4A, 0x1A, 0xB0),
        smallMoon: rgb(0xFF, 0xEE, 0xDD),
        smallNotch: rgb(0x4A, 0x1A, 0xB0)
    )
}

let palette: Palette = isDark ? .dark : .light

// MARK: - Geometry

/// Squircle path approximating Apple's macOS 26 mask. A rounded rect at ~22.4%
/// of the canvas matches the visual feel of Tahoe app tiles.
func squirclePath(in rect: CGRect) -> CGPath {
    let radius = rect.width * 0.224
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The square rect of side `radius * 2` centered on `center`.
func centeredRect(_ center: CGPoint, radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

// MARK: - Drawing primitives

func linearGradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    let colors = stops.map { $0.1 } as CFArray
    let locations = stops.map { $0.0 }
    // CGGradient is nil only on malformed input (e.g. count mismatch), which the
    // call sites never produce. Fail loudly rather than force-unwrap.
    guard let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: locations) else {
        preconditionFailure("Failed to build CGGradient from \(stops.count) stops")
    }
    return gradient
}

func drawLinear(_ ctx: CGContext,
                gradient: CGGradient,
                start: CGPoint,
                end: CGPoint) {
    ctx.drawLinearGradient(gradient,
                           start: start,
                           end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawRadial(_ ctx: CGContext,
                gradient: CGGradient,
                center: CGPoint,
                radius: CGFloat,
                innerCenter: CGPoint? = nil,
                innerRadius: CGFloat = 0) {
    ctx.drawRadialGradient(gradient,
                           startCenter: innerCenter ?? center,
                           startRadius: innerRadius,
                           endCenter: center,
                           endRadius: radius,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: - Star / sparkle path
// A 4-point asterisk built from two crossing rhombi. The waist is pinched
// (Apple-style sparkle) so the rays have a real twinkle shape, not a plus sign.
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let waist = radius * 0.22       // pinch toward the center
    let cx = center.x
    let cy = center.y
    // Vertical rhombus
    path.move(to: CGPoint(x: cx, y: cy + radius))
    path.addLine(to: CGPoint(x: cx + waist, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy - radius))
    path.addLine(to: CGPoint(x: cx - waist, y: cy))
    path.closeSubpath()
    // Horizontal rhombus
    path.move(to: CGPoint(x: cx + radius, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy + waist))
    path.addLine(to: CGPoint(x: cx - radius, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy - waist))
    path.closeSubpath()
    return path
}

// MARK: - Inner shadow helper
// Standard CG inner-shadow idiom: clip to the path, then fill (bounding-rect
// minus path) with an even-odd shadow so the blur falls inward.
func drawInnerShadow(_ ctx: CGContext,
                     path: CGPath,
                     color: CGColor,
                     offset: CGSize,
                     blur: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Bounding rect minus the target path; filled from outside → inner shadow.
    let bounds = path.boundingBox.insetBy(dx: -blur * 4, dy: -blur * 4)
    let outer = CGMutablePath()
    outer.addRect(bounds)
    outer.addPath(path)
    ctx.addPath(outer)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.setShadow(offset: offset, blur: blur, color: color)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

// MARK: - Sparkle layout
// At small render sizes use fewer sparkles so the silhouette stays readable.
struct Sparkle { let cx: CGFloat; let cy: CGFloat; let r: CGFloat }

func sparkles(for dim: CGFloat) -> [Sparkle] {
    // Normalized 0..1 coords (CG origin bottom-left). Three headline sparkles
    // always present; two tiny extras at larger sizes.
    var arr: [Sparkle] = [
        Sparkle(cx: 0.74, cy: 0.74, r: 0.085),  // big, upper-right of moon
        Sparkle(cx: 0.82, cy: 0.46, r: 0.055),  // medium, far-right lower
        Sparkle(cx: 0.55, cy: 0.86, r: 0.040)   // small, above moon
    ]
    if dim >= 96 {
        arr.append(Sparkle(cx: 0.30, cy: 0.78, r: 0.030)) // tiny, top-left of moon
        arr.append(Sparkle(cx: 0.68, cy: 0.30, r: 0.034)) // tiny, lower-right
    }
    return arr.map { Sparkle(cx: $0.cx * dim, cy: $0.cy * dim, r: $0.r * dim) }
}

// MARK: - Bitmap context

/// Runs `draw` against a square RGBA8 bitmap `CGContext` (canvas dim passed as a
/// `CGFloat`) and returns the PNG encoding, centralising the NSBitmapImageRep +
/// NSGraphicsContext save/restore boilerplate. Nil if the context can't be made.
func withBitmapContext(pixels: Int, _ draw: (_ ctx: CGContext, _ dim: CGFloat) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    draw(ctx, CGFloat(pixels))
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Shared composite layers
//
// The full-size icon and the two layered exports share these drawing recipes;
// the single copy keeps the renderers short and provably identical.

/// Atmospheric glows — warm accent (top-right) + cool counter-glow (bottom-left)
/// for depth, drawn at the caller's current clip/transform.
func drawGlows(_ ctx: CGContext, dim: CGFloat, palette: Palette) {
    let accentGlow = linearGradient([
        (0.0, palette.accent),
        (1.0, palette.accentFade)
    ])
    drawRadial(ctx,
               gradient: accentGlow,
               center: CGPoint(x: dim * 0.78, y: dim * 0.82),
               radius: dim * 0.70)
    let coolGlow = linearGradient([
        (0.0, palette.cool),
        (1.0, palette.coolFade)
    ])
    drawRadial(ctx,
               gradient: coolGlow,
               center: CGPoint(x: dim * 0.18, y: dim * 0.18),
               radius: dim * 0.65)
}

/// Top rim highlight ("lifted glass"): a vertical white→transparent fade clipped
/// to the top ~32% of the canvas.
func drawTopRim(_ ctx: CGContext, dim: CGFloat, palette: Palette) {
    ctx.saveGState()
    let rimClip = CGRect(x: 0, y: dim * 0.68, width: dim, height: dim * 0.32)
    ctx.clip(to: rimClip)
    let rimGrad = linearGradient([
        (0.0, palette.rimHi),
        (1.0, palette.rimLo)
    ])
    drawLinear(ctx,
               gradient: rimGrad,
               start: CGPoint(x: dim * 0.5, y: dim * 1.00),
               end: CGPoint(x: dim * 0.5, y: dim * 0.68))
    ctx.restoreGState()
}

/// Glass moon — atmospheric halo, radial body lit from upper-left, lower-right
/// crescent shading, inset inner shadow, and an upper-left specular highlight.
/// `palette` supplies the moon colors so light + dark share one recipe.
func drawMoon(_ ctx: CGContext, dim: CGFloat, palette: Palette) {
    // Roughly centered, biased down-left so sparkles have room top-right.
    let moonCenter = CGPoint(x: dim * 0.44, y: dim * 0.50)
    let moonRadius = dim * 0.27
    let moonPath = CGPath(ellipseIn: centeredRect(moonCenter, radius: moonRadius), transform: nil)

    // Atmospheric halo
    ctx.saveGState()
    let moonHalo = linearGradient([
        (0.0, rgb(0xFF, 0xEE, 0xDD, 0.22)),
        (1.0, rgb(0xFF, 0xEE, 0xDD, 0.0))
    ])
    drawRadial(ctx,
               gradient: moonHalo,
               center: moonCenter,
               radius: moonRadius * 1.55,
               innerRadius: moonRadius * 0.85)   // innerCenter defaults to center
    ctx.restoreGState()
    // Body — radial gradient, light source offset to the upper-left.
    ctx.saveGState()
    ctx.addPath(moonPath)
    ctx.clip()
    let bodyGrad = linearGradient([
        (0.0, palette.moonCore),
        (0.55, palette.moonMid),
        (1.0, palette.moonRim)
    ])
    drawRadial(ctx,
               gradient: bodyGrad,
               center: moonCenter,
               radius: moonRadius * 1.05,
               innerCenter: CGPoint(x: moonCenter.x - moonRadius * 0.35,
                                    y: moonCenter.y + moonRadius * 0.35),
               innerRadius: moonRadius * 0.08)
    ctx.restoreGState()
    // Crescent shading — cool wash on the lower-right for the 3D read.
    ctx.saveGState()
    ctx.addPath(moonPath)
    ctx.clip()
    let shadeGrad = linearGradient([
        (0.0, rgb(0x1B, 0x1B, 0x4A, 0.0)),
        (1.0, palette.moonShade)
    ])
    drawRadial(ctx,
               gradient: shadeGrad,
               center: CGPoint(x: moonCenter.x + moonRadius * 0.55,
                               y: moonCenter.y - moonRadius * 0.55),
               radius: moonRadius * 1.25,
               innerRadius: moonRadius * 0.05)   // innerCenter defaults to center
    ctx.restoreGState()
    // Inner shadow (glass / inset feel)
    drawInnerShadow(ctx,
                    path: moonPath,
                    color: rgb(0x10, 0x08, 0x2A, 0.85),
                    offset: CGSize(width: -dim / 220, height: -dim / 220),
                    blur: max(1.0, dim / 90))
    // Specular highlight on the upper-left edge
    ctx.saveGState()
    ctx.addPath(moonPath)
    ctx.clip()
    let specGrad = linearGradient([
        (0.0, rgb(0xFF, 0xFF, 0xFF, 0.70)),
        (1.0, rgb(0xFF, 0xFF, 0xFF, 0.0))
    ])
    drawRadial(ctx,
               gradient: specGrad,
               center: CGPoint(x: moonCenter.x - moonRadius * 0.45,
                               y: moonCenter.y + moonRadius * 0.50),
               radius: moonRadius * 0.55,
               innerRadius: 0)   // innerCenter defaults to center
    ctx.restoreGState()
}

/// Sparkles — for each layout point: an outer light halo, a filled twinkle
/// body, and a bright specular pop in the dead center. `starCore`/`starHalo` are
/// the palette's core + outer-fade colors so each variant's tail matches.
func drawSparkles(_ ctx: CGContext, dim: CGFloat, starCore: CGColor, starHalo: CGColor) {
    for sparkle in sparkles(for: dim) {
        let path = sparklePath(center: CGPoint(x: sparkle.cx, y: sparkle.cy), radius: sparkle.r)

        // Outer halo (reads as light, not paint)
        ctx.saveGState()
        let halo = linearGradient([
            (0.0, rgb(0xFF, 0xFF, 0xFF, 0.55)),
            (0.45, rgb(0xC4, 0xD5, 0xFF, 0.18)),
            (1.0, starHalo)
        ])
        drawRadial(ctx,
                   gradient: halo,
                   center: CGPoint(x: sparkle.cx, y: sparkle.cy),
                   radius: sparkle.r * 2.4)
        ctx.restoreGState()
        // Filled twinkle body
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let body = linearGradient([
            (0.0, starCore),
            (0.6, rgb(0xFF, 0xFF, 0xFF, 0.85)),
            (1.0, rgb(0xC4, 0xD5, 0xFF, 0.55))
        ])
        drawRadial(ctx,
                   gradient: body,
                   center: CGPoint(x: sparkle.cx, y: sparkle.cy),
                   radius: sparkle.r * 1.05)
        ctx.restoreGState()
        // Specular pop
        ctx.saveGState()
        let pop = linearGradient([
            (0.0, rgb(0xFF, 0xFF, 0xFF, 1.0)),
            (1.0, rgb(0xFF, 0xFF, 0xFF, 0.0))
        ])
        drawRadial(ctx,
                   gradient: pop,
                   center: CGPoint(x: sparkle.cx, y: sparkle.cy),
                   radius: max(0.5, sparkle.r * 0.32))
        ctx.restoreGState()
    }
}

// MARK: - Small-size render
//
// At 16/32pt the full design collapses into a purple smudge, so anything <=64px
// takes this dedicated low-res pass: flat high-contrast moon silhouette, no
// sparkles/inner-shadow. See the companion doc for the full rationale.
func renderSmallIcon(size: Int) -> Data? {
    withBitmapContext(pixels: size) { ctx, dim in
        let rect = CGRect(x: 0, y: 0, width: dim, height: dim)

        // Clip to squircle, flat midnight fill (a gradient muddies it at 16pt).
        let squircle = squirclePath(in: rect)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        ctx.setFillColor(palette.smallBg)
        ctx.fill(rect)
        // Moon: ~50% canvas, dead center, FLAT fill — obviously a moon, nothing else.
        let moonRadius = dim * 0.30
        let moonCenter = CGPoint(x: dim * 0.5, y: dim * 0.5)
        ctx.setFillColor(palette.smallMoon)
        ctx.fillEllipse(in: centeredRect(moonCenter, radius: moonRadius))
        // Inset notch (overlapping dark circle) on the lower-right so it reads as
        // a moon not a sun; sized so the cut is >=1px even at 16x16.
        let notchRadius = moonRadius * 0.85
        let notchCenter = CGPoint(x: moonCenter.x + moonRadius * 0.55,
                                  y: moonCenter.y - moonRadius * 0.10)
        ctx.setFillColor(palette.smallNotch)
        ctx.fillEllipse(in: centeredRect(notchCenter, radius: notchRadius))
        ctx.restoreGState()

        // Faint edge stroke (>=1pt) so the tile reads as a discrete object.
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(rgb(0xFF, 0xFF, 0xFF, 0.18))
        ctx.setLineWidth(max(1.0, dim / 48))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Main render

func renderIcon(size: Int) -> Data? {
    withBitmapContext(pixels: size) { ctx, dim in
        let rect = CGRect(x: 0, y: 0, width: dim, height: dim)

        // Clip to squircle for everything except the final edge stroke.
        let squircle = squirclePath(in: rect)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        // Layer 1: diagonal midnight gradient (CG origin bottom-left → start
        // hi-y, end lo-y for a top-left→bottom-right diagonal) + glows.
        let bgGradient = linearGradient([
            (0.0, palette.bgTopLeft),
            (1.0, palette.bgBottomRight)
        ])
        drawLinear(ctx,
                   gradient: bgGradient,
                   start: CGPoint(x: 0, y: dim),
                   end: CGPoint(x: dim, y: 0))
        drawGlows(ctx, dim: dim, palette: palette)

        // Layers 2–4: glass moon, sparkles, top rim highlight.
        drawMoon(ctx, dim: dim, palette: palette)
        drawSparkles(ctx, dim: dim, starCore: palette.starCore, starHalo: palette.starHalo)
        drawTopRim(ctx, dim: dim, palette: palette)

        ctx.restoreGState() // end squircle clip

        // Layer 5: faint edge stroke around the tile (outside the clip).
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(palette.edgeStroke)
        ctx.setLineWidth(max(0.75, dim / 360))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Layered rendering (macOS 26 .icon bundle)
//
// Two 1024×1024 raster layers (NO squircle clip — Tahoe masks them) on top of
// icon.json's flat `fill`: glows + rim → background overlay, moon + sparkles →
// foreground. Full bundle layout in the companion doc.

/// Background overlay: atmospheric glows + rim, transparent where the base
/// `fill` gradient should show through (the base gradient is NOT drawn here).
func renderBackgroundOverlay(palette: Palette) -> Data? {
    withBitmapContext(pixels: 1024) { ctx, dim in
        drawGlows(ctx, dim: dim, palette: palette)
        // Rim themes with the bg (lighter in light mode, brighter in dark).
        drawTopRim(ctx, dim: dim, palette: palette)
    }
}

/// Foreground: glass moon + sparkles, transparent elsewhere so the system can
/// mask/glass/tint it. Uses the LIGHT moon/sparkle colors (they read on either
/// appearance; the Liquid Glass shader handles tinted/clear). `fg` = foreground.
func renderForeground() -> Data? {
    let fg = Palette.light
    return withBitmapContext(pixels: 1024) { ctx, dim in
        drawMoon(ctx, dim: dim, palette: fg)
        drawSparkles(ctx, dim: dim, starCore: fg.starCore, starHalo: fg.starHalo)
    }
}

// MARK: - Filename suffix

/// Inserts the variant suffix before the extension:
/// `icon_512x512@2x.png` → `icon_512x512@2x-dark.png`
func suffixed(_ name: String) -> String {
    guard !suffix.isEmpty else { return name }
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    return "\(stem)\(suffix).\(ext)"
}

// MARK: - Run

/// Writes one PNG `data` into `dir` as `filename`, logging success/failure.
/// `sizeLabel` is appended to the success line (e.g. "1024×1024").
func writeLayer(_ data: Data?, named filename: String, sizeLabel: String, into dir: URL) {
    guard let data else {
        print("Failed to render \(filename)")
        return
    }
    try? data.write(to: dir.appendingPathComponent(filename))
    print("rendered \(filename) (\(sizeLabel))")
}

if isLayered {
    // Layered mode: the three PNGs the Tahoe .icon bundle references (see the
    // companion doc for the bundle layout).
    try? FileManager.default.createDirectory(at: layeredOutputDir, withIntermediateDirectories: true)
    print("Generating layered icon assets (1024×1024) into \(layeredOutputDir.path)…")

    let label = "1024×1024"
    writeLayer(renderBackgroundOverlay(palette: .light), named: "Background-Light.png", sizeLabel: label, into: layeredOutputDir)
    writeLayer(renderBackgroundOverlay(palette: .dark), named: "Background-Dark.png", sizeLabel: label, into: layeredOutputDir)
    writeLayer(renderForeground(), named: "Foreground.png", sizeLabel: label, into: layeredOutputDir)

    print("done.")
    exit(0)
}

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

print("Generating \(isDark ? "DARK" : "LIGHT") variant…")
for entry in sizes {
    // <=64px (the 16/32pt @1x/@2x slots) gets the flat small-size renderer;
    // larger sizes get the full design. See the companion doc.
    let png: Data?
    if entry.dim <= 64 {
        png = renderSmallIcon(size: entry.dim)
    } else {
        png = renderIcon(size: entry.dim)
    }
    guard let data = png else {
        print("Failed to render \(entry.name)")
        continue
    }
    let filename = suffixed(entry.name)
    let url = outputDir.appendingPathComponent(filename)
    try? data.write(to: url)
    print("rendered \(filename) (\(entry.dim)x\(entry.dim))")
}
print("done.")
