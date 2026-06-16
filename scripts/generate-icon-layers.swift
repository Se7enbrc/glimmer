#!/usr/bin/swift
// Renders the Glimmer icon split into separate Background + Foreground
// PNG layers for the macOS 26 Tahoe `.icon` bundle format. The legacy
// .appiconset's per-appearance variants are inert on Tahoe; the .icon
// bundle (produced by Apple's Icon Composer GUI but also hand-writable)
// lets macOS auto-theme light / dark / tinted / clear from a layered
// source.
//
// Output (run from repo root):
//   Glimmer/Assets.xcassets/AppIcon.icon/Assets/Background-Light.png  (1024)
//   Glimmer/Assets.xcassets/AppIcon.icon/Assets/Background-Dark.png   (1024)
//   Glimmer/Assets.xcassets/AppIcon.icon/Assets/Foreground.png        (1024)

import AppKit
import CoreGraphics
import Foundation

let outputDir = URL(fileURLWithPath: "Glimmer/Assets.xcassets/AppIcon.icon/Assets")
let dim: CGFloat = 1024
let pixels = Int(dim)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat(r) / 255.0,
        green: CGFloat(g) / 255.0,
        blue: CGFloat(b) / 255.0,
        alpha: a
    )
}

struct Palette {
    let bgTopLeft: CGColor
    let bgBottomRight: CGColor
    let accent: CGColor
    let accentFade: CGColor
    let cool: CGColor
    let coolFade: CGColor

    static let light = Palette(
        bgTopLeft: rgb(0x1B, 0x1B, 0x4A),
        bgBottomRight: rgb(0x3F, 0x1E, 0x72),
        accent: rgb(0x5E, 0x2E, 0xAA, 0.65),
        accentFade: rgb(0x5E, 0x2E, 0xAA, 0.0),
        cool: rgb(0x12, 0x18, 0x3A, 0.55),
        coolFade: rgb(0x12, 0x18, 0x3A, 0.0)
    )
    // Dark variant: near-charcoal with a barely-there violet undertone so
    // the icon sits in the same chromatic neighborhood as the surrounding
    // dark-mode Dock tiles instead of
    // shouting with brand color. The moon + sparkles + accent corner glow
    // do the visual work; the background just stays out of the way.
    static let dark = Palette(
        bgTopLeft: rgb(0x16, 0x16, 0x1B),
        bgBottomRight: rgb(0x22, 0x1F, 0x2A),
        accent: rgb(0x50, 0x28, 0x90, 0.32),
        accentFade: rgb(0x50, 0x28, 0x90, 0.0),
        cool: rgb(0x0C, 0x0C, 0x10, 0.50),
        coolFade: rgb(0x0C, 0x0C, 0x10, 0.0)
    )
}

func squirclePath(in rect: CGRect) -> CGPath {
    let radius = rect.width * 0.224
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    let colors = stops.map { $0.1 } as CFArray
    let locations = stops.map { $0.0 }
    return CGGradient(colorsSpace: srgb, colors: colors, locations: locations)!
}

func newCanvas() -> (NSBitmapImageRep, CGContext)? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    return (rep, ctx)
}

// MARK: - Background renderer (gradient + corner glows, squircle-clipped)

func renderBackground(palette: Palette) -> Data? {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let (rep, ctx) = newCanvas() else { return nil }

    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let squircle = squirclePath(in: rect)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Diagonal gradient (top-left → bottom-right)
    let bg = linearGradient([
        (0.0, palette.bgTopLeft),
        (1.0, palette.bgBottomRight)
    ])
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: 0, y: dim),
                           end: CGPoint(x: dim, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Warm accent glow toward the top-right
    let accentGlow = linearGradient([
        (0.0, palette.accent),
        (1.0, palette.accentFade)
    ])
    ctx.drawRadialGradient(accentGlow,
                           startCenter: CGPoint(x: dim * 0.78, y: dim * 0.82),
                           startRadius: 0,
                           endCenter: CGPoint(x: dim * 0.78, y: dim * 0.82),
                           endRadius: dim * 0.70,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Cool counter-glow at bottom-left
    let coolGlow = linearGradient([
        (0.0, palette.cool),
        (1.0, palette.coolFade)
    ])
    ctx.drawRadialGradient(coolGlow,
                           startCenter: CGPoint(x: dim * 0.18, y: dim * 0.18),
                           startRadius: 0,
                           endCenter: CGPoint(x: dim * 0.18, y: dim * 0.18),
                           endRadius: dim * 0.65,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    ctx.restoreGState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Foreground renderer (moon + sparkles + rim, transparent BG)

func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let waist = radius * 0.22
    let cx = center.x, cy = center.y
    path.move(to: CGPoint(x: cx, y: cy + radius))
    path.addLine(to: CGPoint(x: cx + waist, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy - radius))
    path.addLine(to: CGPoint(x: cx - waist, y: cy))
    path.closeSubpath()
    path.move(to: CGPoint(x: cx + radius, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy + waist))
    path.addLine(to: CGPoint(x: cx - radius, y: cy))
    path.addLine(to: CGPoint(x: cx, y: cy - waist))
    path.closeSubpath()
    return path
}

func renderForeground() -> Data? {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let (rep, ctx) = newCanvas() else { return nil }

    // Clip to squircle so the moon halo + rim highlight stay inside the
    // tile shape even when composited on a custom background.
    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let squircle = squirclePath(in: rect)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Moon position + size
    let moonCenter = CGPoint(x: dim * 0.44, y: dim * 0.50)
    let moonRadius = dim * 0.27
    let moonRect = CGRect(x: moonCenter.x - moonRadius,
                          y: moonCenter.y - moonRadius,
                          width: moonRadius * 2,
                          height: moonRadius * 2)
    let moonPath = CGPath(ellipseIn: moonRect, transform: nil)

    // Outer halo
    let halo = linearGradient([
        (0.0, rgb(0xFF, 0xEE, 0xDD, 0.22)),
        (1.0, rgb(0xFF, 0xEE, 0xDD, 0.0))
    ])
    ctx.drawRadialGradient(halo,
                           startCenter: moonCenter, startRadius: moonRadius * 0.85,
                           endCenter: moonCenter, endRadius: moonRadius * 1.55,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Moon body
    ctx.saveGState()
    ctx.addPath(moonPath); ctx.clip()
    let body = linearGradient([
        (0.0, rgb(0xFF, 0xEE, 0xDD, 0.92)),
        (0.55, rgb(0xF6, 0xDD, 0xEE, 0.78)),
        (1.0, rgb(0xE8, 0xC9, 0xF0, 0.55))
    ])
    ctx.drawRadialGradient(body,
                           startCenter: CGPoint(x: moonCenter.x - moonRadius * 0.35,
                                                y: moonCenter.y + moonRadius * 0.35),
                           startRadius: moonRadius * 0.08,
                           endCenter: moonCenter, endRadius: moonRadius * 1.05,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Specular highlight on upper-left edge of moon
    ctx.saveGState()
    ctx.addPath(moonPath); ctx.clip()
    let spec = linearGradient([
        (0.0, rgb(0xFF, 0xFF, 0xFF, 0.70)),
        (1.0, rgb(0xFF, 0xFF, 0xFF, 0.0))
    ])
    let specC = CGPoint(x: moonCenter.x - moonRadius * 0.45,
                        y: moonCenter.y + moonRadius * 0.50)
    ctx.drawRadialGradient(spec,
                           startCenter: specC, startRadius: 0,
                           endCenter: specC, endRadius: moonRadius * 0.55,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Sparkles (full 5-star layout for 1024×1024)
    struct Sparkle { let cx: CGFloat, cy: CGFloat, r: CGFloat }
    let sparkles: [Sparkle] = [
        Sparkle(cx: 0.74 * dim, cy: 0.74 * dim, r: 0.085 * dim),
        Sparkle(cx: 0.82 * dim, cy: 0.46 * dim, r: 0.055 * dim),
        Sparkle(cx: 0.55 * dim, cy: 0.86 * dim, r: 0.040 * dim),
        Sparkle(cx: 0.30 * dim, cy: 0.78 * dim, r: 0.030 * dim),
        Sparkle(cx: 0.68 * dim, cy: 0.30 * dim, r: 0.034 * dim)
    ]
    for s in sparkles {
        // Halo around sparkle
        let haloG = linearGradient([
            (0.0, rgb(0xFF, 0xFF, 0xFF, 0.55)),
            (0.45, rgb(0xC4, 0xD5, 0xFF, 0.18)),
            (1.0, rgb(0xC4, 0xD5, 0xFF, 0.0))
        ])
        ctx.drawRadialGradient(haloG,
                               startCenter: CGPoint(x: s.cx, y: s.cy), startRadius: 0,
                               endCenter: CGPoint(x: s.cx, y: s.cy), endRadius: s.r * 2.4,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Sparkle body
        ctx.saveGState()
        ctx.addPath(sparklePath(center: CGPoint(x: s.cx, y: s.cy), radius: s.r))
        ctx.clip()
        let bodyG = linearGradient([
            (0.0, rgb(0xFF, 0xFF, 0xFF, 0.95)),
            (0.6, rgb(0xFF, 0xFF, 0xFF, 0.85)),
            (1.0, rgb(0xC4, 0xD5, 0xFF, 0.55))
        ])
        ctx.drawRadialGradient(bodyG,
                               startCenter: CGPoint(x: s.cx, y: s.cy), startRadius: 0,
                               endCenter: CGPoint(x: s.cx, y: s.cy), endRadius: s.r * 1.05,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        // Bright specular point
        let pop = linearGradient([
            (0.0, rgb(0xFF, 0xFF, 0xFF, 1.0)),
            (1.0, rgb(0xFF, 0xFF, 0xFF, 0.0))
        ])
        ctx.drawRadialGradient(pop,
                               startCenter: CGPoint(x: s.cx, y: s.cy), startRadius: 0,
                               endCenter: CGPoint(x: s.cx, y: s.cy), endRadius: max(0.5, s.r * 0.32),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // Rim highlight on the top edge
    ctx.saveGState()
    let rimClip = CGRect(x: 0, y: dim * 0.68, width: dim, height: dim * 0.32)
    ctx.clip(to: rimClip)
    let rim = linearGradient([
        (0.0, rgb(0xFF, 0xFF, 0xFF, 0.42)),
        (1.0, rgb(0xFF, 0xFF, 0xFF, 0.0))
    ])
    ctx.drawLinearGradient(rim,
                           start: CGPoint(x: dim * 0.5, y: dim * 1.00),
                           end: CGPoint(x: dim * 0.5, y: dim * 0.68),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.restoreGState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Run

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

if let data = renderBackground(palette: .light) {
    try? data.write(to: outputDir.appendingPathComponent("Background-Light.png"))
    print("rendered Background-Light.png")
}
if let data = renderBackground(palette: .dark) {
    try? data.write(to: outputDir.appendingPathComponent("Background-Dark.png"))
    print("rendered Background-Dark.png")
}
if let data = renderForeground() {
    try? data.write(to: outputDir.appendingPathComponent("Foreground.png"))
    print("rendered Foreground.png")
}
print("done.")
