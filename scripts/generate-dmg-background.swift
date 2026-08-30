#!/usr/bin/swift
// Renders the DMG window background: a dark neutral gradient with a thin arrow
// pointing from where Finder draws Glimmer.app to where it draws the
// /Applications alias. The app icon is deliberately NOT painted here - Finder
// shows the real icon on top, and a painted copy would double up.
//
// Palette is the dark variant from scripts/generate-icon-layers.swift, so the
// installer window reads as the same product as the icon.
//
// Output (run from repo root):
//   scripts/dmg/background.png     660x400  (1x)
//   scripts/dmg/background@2x.png  1320x800 (Retina)
//
// The two are combined into a HiDPI background.tiff at DMG-build time by
// scripts/make-dmg.sh (tiffutil -cathidpicheck); only the PNGs are committed.
//
// Geometry must stay in step with scripts/make-dmg.sh: the window is 660x400
// and Finder's icon positions are in the same top-left-origin coordinates used
// for ICON_Y / APP_X / APPS_X below.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Geometry (points; must match scripts/make-dmg.sh)

let winW: CGFloat = 660
let winH: CGFloat = 400
let appX: CGFloat = 165 // centre of the Glimmer.app icon
let appsX: CGFloat = 495 // centre of the Applications alias
let iconY: CGFloat = 200 // shared icon centre, from the TOP of the window
let iconSize: CGFloat = 128
/// The gradient layers are rendered at 1/this and resampled up - see render().
let gradientDivisor: CGFloat = 4

let outputDir = URL(fileURLWithPath: "scripts/dmg")

// MARK: - Palette (dark variant, scripts/generate-icon-layers.swift)

guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("sRGB color space unavailable")
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat(r) / 255.0,
        green: CGFloat(g) / 255.0,
        blue: CGFloat(b) / 255.0,
        alpha: a
    )
}

let bgTopLeft = rgb(0x16, 0x16, 0x1B)
let bgBottomRight = rgb(0x22, 0x1F, 0x2A)
let accent = rgb(0x50, 0x28, 0x90, 0.32) // warm purple glow
let accentFade = rgb(0x50, 0x28, 0x90, 0.0)
let cool = rgb(0x0C, 0x0C, 0x10, 0.50) // cool counter-glow
let coolFade = rgb(0x0C, 0x0C, 0x10, 0.0)
let arrowColor = rgb(0xFF, 0xEE, 0xDD, 0.34) // moon cream, kept faint
let captionColor = rgb(0xFF, 0xEE, 0xDD, 0.38)

func linearGradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    let colors = stops.map { $0.1 } as CFArray
    let locations = stops.map { $0.0 }
    guard let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: locations) else {
        fatalError("CGGradient rejected the stop list")
    }
    return gradient
}

// MARK: - Renderer

/// Draws the background at `scale`x into a fresh bitmap and returns PNG data.
/// All geometry below is in points; the context is scaled once, so the 1x and
/// 2x images are the same drawing at different resolutions.
func render(scale: CGFloat) -> Data? {
    let pxW = Int(winW * scale)
    let pxH = Int(winH * scale)
    // Opaque context (alpha skipped): the image fills the whole window, and an
    // unused alpha plane roughly doubles the PNG a dithered gradient produces.
    guard let ctx = CGContext(
        data: nil,
        width: pxW, height: pxH,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.scaleBy(x: scale, y: scale)

    // CoreGraphics is bottom-left origin; the geometry above is top-left, as
    // Finder reports it. Convert once, here.
    func y(_ fromTop: CGFloat) -> CGFloat { winH - fromTop }

    // Gradients, drawn small and scaled up. CoreGraphics dithers gradients, and
    // that per-pixel noise is what makes an otherwise near-empty image compress
    // to megabytes; rendering the three smooth layers at 1/GRADIENT_DIVISOR and
    // resampling keeps the look and cuts the PNG by an order of magnitude.
    if let bgCtx = CGContext(
        data: nil,
        width: Int(winW / gradientDivisor), height: Int(winH / gradientDivisor),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) {
        bgCtx.scaleBy(x: 1 / gradientDivisor, y: 1 / gradientDivisor)

        // Diagonal base gradient (top-left → bottom-right).
        bgCtx.drawLinearGradient(
            linearGradient([(0.0, bgTopLeft), (1.0, bgBottomRight)]),
            start: CGPoint(x: 0, y: winH),
            end: CGPoint(x: winW, y: 0),
            options: []
        )
        // Warm glow behind the Applications side, cool counter-glow behind the app.
        bgCtx.drawRadialGradient(
            linearGradient([(0.0, accent), (1.0, accentFade)]),
            startCenter: CGPoint(x: appsX, y: y(iconY)), startRadius: 0,
            endCenter: CGPoint(x: appsX, y: y(iconY)), endRadius: winW * 0.52,
            options: []
        )
        bgCtx.drawRadialGradient(
            linearGradient([(0.0, cool), (1.0, coolFade)]),
            startCenter: CGPoint(x: appX, y: y(winH * 0.92)), startRadius: 0,
            endCenter: CGPoint(x: appX, y: y(winH * 0.92)), endRadius: winW * 0.55,
            options: []
        )
        if let bgImage = bgCtx.makeImage() {
            ctx.interpolationQuality = .high
            ctx.draw(bgImage, in: CGRect(x: 0, y: 0, width: winW, height: winH))
        }
    }

    // Thin arrow, in the gap between the two icons.
    let gapStart = appX + iconSize / 2 + 22
    let gapEnd = appsX - iconSize / 2 - 22
    let shaftY = y(iconY)
    let head: CGFloat = 11

    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: gapStart, y: shaftY))
    ctx.addLine(to: CGPoint(x: gapEnd - head * 0.7, y: shaftY))
    ctx.strokePath()

    ctx.beginPath()
    ctx.move(to: CGPoint(x: gapEnd - head, y: shaftY + head * 0.62))
    ctx.addLine(to: CGPoint(x: gapEnd, y: shaftY))
    ctx.addLine(to: CGPoint(x: gapEnd - head, y: shaftY - head * 0.62))
    ctx.strokePath()

    // Caption, centred below the icons. The only text in the image.
    let caption = "Drag Glimmer to Applications"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(cgColor: captionColor) ?? .white,
        .kern: 0.4
    ]
    let size = (caption as NSString).size(withAttributes: attrs)
    (caption as NSString).draw(
        at: CGPoint(x: (winW - size.width) / 2, y: y(332)),
        withAttributes: attrs
    )

    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - Write

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let data = render(scale: scale) else {
        FileHandle.standardError.write(Data("ERR: could not render \(name)\n".utf8))
        exit(1)
    }
    let url = outputDir.appendingPathComponent(name)
    do {
        try data.write(to: url)
        print("  ✓ \(url.path) (\(Int(winW * scale))x\(Int(winH * scale)), \(data.count) bytes)")
    } catch {
        FileHandle.standardError.write(Data("ERR: \(url.path): \(error)\n".utf8))
        exit(1)
    }
}
