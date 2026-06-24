//
//  QualityCalculator.swift
//
//  Bitrate / resolution / fps recommendation logic for the manager. Ports
//  Moonlight's `StreamingPreferences::getDefaultBitrate` shape (resolution
//  table × frame-rate factor × preset multiplier) and the smart-defaults
//  display probe (panel-native pixel grid via Core Graphics). Originally
//  inline in `MoonlightManager.swift`.
//

import AppKit
import Foundation

extension MoonlightManager {

    // MARK: - Display probe

    /// Compute smart defaults from the current display.
    ///
    /// Returns the PANEL NATIVE resolution - the actual pixel grid the display
    /// hardware has, not the framebuffer the user is currently rendering at.
    ///
    /// We get panel native by querying CGDisplayCopyAllDisplayModes with no
    /// options. Without `kCGDisplayShowDuplicateLowResolutionModes`, macOS only
    /// returns modes the panel really supports - it omits the synthetic
    /// upscaled HiDPI virtual modes (the "Looks like Larger Text" frame sizes
    /// that render above panel native and downsample). The largest pixelWidth
    /// from that list is panel native.
    func smartDefaultsForCurrentDisplay() -> (width: Int, height: Int, fps: Int) {
        guard let screen = NSScreen.main else { return (1920, 1080, 60) }
        let fps = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60

        // Send the panel's actual pixel-native dimensions verbatim. The
        // host is responsible for being able to accept them - modern
        // Sunshine + VDD setups (e.g. MTT's VDD) can register the Mac
        // panel modes (3024×1964 for 14" MBP, 3456×2234 for 16" MBP,
        // 2880×1864 for 15" MBA, etc.) as supported display modes, and
        // QRes / Windows OS will then accept them. A previous round here
        // tried to snap to a 16:9/16:10 standard preset on the assumption
        // that the host would reject non-standard modes - that turned out
        // to make the host think a 14" MBP was a 13" MBA (snapped to
        // 2560×1600). The honest answer is: send what the user is
        // actually running. If a stricter host rejects, that's a host-
        // side config nudge, not a client-side workaround.
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            // Ask Core Graphics for ALL display modes, including the
            // duplicate-low-resolution ones macOS hides by default. We
            // need the full list because the panel-native mode isn't
            // always the same as the user's current scaled mode (e.g.
            // a user in "More Space" / "Larger Text" zoom is rendering
            // at a different framebuffer res than the panel actually has).
            let options: CFDictionary = [
                kCGDisplayShowDuplicateLowResolutionModes: true as CFBoolean
            ] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
                let usable = modes.filter { $0.isUsableForDesktopGUI() }
                // Apple marks the panel's true native mode with
                // `kDisplayModeNativeFlag` in IOKit
                // (IOKit/graphics/IOGraphicsTypesPrivate.h). The flag is
                // declared "private" but has been stable since macOS 10.6
                // - moonlight-qt and most third-party display utilities
                // (Lunar, BetterDisplay, etc.) use it. This is the only
                // public-ish way to ask Core Graphics "what mode does the
                // panel actually want to run at." Picking by max pixel
                // area lands on whatever zoomed framebuffer the user
                // happens to be in, which is wrong - that mode upscales
                // / downscales against the panel.
                let kDisplayModeNativeFlag: UInt32 = 0x02000000
                let nativeMatches = usable.filter { ($0.ioFlags & kDisplayModeNativeFlag) != 0 }
                if let native = nativeMatches.max(by: { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }) {
                    return (native.pixelWidth, native.pixelHeight, fps)
                }
                // No native flag found (older OS / external panel without
                // EDID-derived preferred-mode info). Fall back to the
                // smallest 2x retina mode - that's typically the panel's
                // default "looks like" preset on a Mac.
                let retinaModes = usable.filter { $0.pixelWidth == $0.width * 2 }
                if let smallest = retinaModes.min(by: { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }),
                   smallest.pixelWidth >= 1920 {
                    return (smallest.pixelWidth, smallest.pixelHeight, fps)
                }
            }
        }

        // Final fallback: current framebuffer × backing scale. Not panel-
        // native if the user is in a zoomed mode, but it's the best we
        // have when Core Graphics returns nothing usable.
        let w = Int((screen.frame.width  * screen.backingScaleFactor).rounded())
        let h = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        return (w, h, fps)
    }

    // MARK: - Bitrate formula

    /// Port of Moonlight's StreamingPreferences::getDefaultBitrate.
    /// Resolution table × frame-rate factor (sub-linear above 60 fps).
    func bitrateKbps(width: Int, height: Int, fps: Int, preset: QualityPreset) -> Int {
        let pixels = width * height

        let table: [(Int, Double)] = [
            (640 * 360, 1),
            (854 * 480, 2),
            (1280 * 720, 5),
            (1920 * 1080, 10),
            (2560 * 1440, 20),
            (3840 * 2160, 40)
        ]
        // `table` is a non-empty literal; the guard pins `first`/`last` without
        // force-unwrapping and degrades to the min-bitrate clamp if it ever isn't.
        guard let firstEntry = table.first, let lastEntry = table.last else {
            return 5_000
        }
        var resolutionFactor: Double = firstEntry.1
        if pixels >= lastEntry.0 {
            // Above 4K (5K/6K Apple panels): extrapolate off the 4K anchor by
            // pixel ratio, mildly discounted (^0.9) for codec efficiency at
            // higher resolution - mirroring the sub-linear fps curve below.
            // Clamping flat at the 4K factor gave a 5K (14.7 Mpx) or 6K (20 Mpx)
            // stream the same budget as 4K (8.3 Mpx) - roughly half the bits per
            // pixel, which reads as smeared detail and banding on exactly the
            // high-end Macs most likely to drive these resolutions. The 200 Mbps
            // clamp at the end of this function still bounds the largest panels.
            let fourKPixels = Double(lastEntry.0)
            resolutionFactor = lastEntry.1 * pow(Double(pixels) / fourKPixels, 0.9)
        } else {
            for i in 0..<table.count {
                if pixels == table[i].0 {
                    resolutionFactor = table[i].1
                    break
                } else if pixels < table[i].0 {
                    if i == 0 { resolutionFactor = table[i].1 } else {
                        let prev = table[i - 1]
                        let next = table[i]
                        let lerp = Double(pixels - prev.0) / Double(next.0 - prev.0)
                        resolutionFactor = lerp * (next.1 - prev.1) + prev.1
                    }
                    break
                }
            }
        }

        // Frame-rate factor: sub-linear past 60 fps (sqrt scaling).
        let fpsValue = Double(fps)
        let frameRateFactor = (fpsValue <= 60 ? fpsValue : (sqrt(fpsValue / 60.0) * 60.0)) / 30.0

        // Preset multiplier: the surviving presets all stream at the formula's
        // reference bits-per-pixel and differ by RESOLUTION instead (HiDPI sends
        // a quarter of the pixels, so the resolution factor already discounts it).
        // Kept as an explicit switch so a future preset has to make a choice.
        let presetMultiplier: Double
        switch preset {
        case .matchDisplay, .hidpi, .custom: presetMultiplier = 1.0
        }

        let kbps = Int((resolutionFactor * frameRateFactor * presetMultiplier).rounded() * 1000)
        return min(max(kbps, 5_000), 200_000)
    }

    /// Public surface for the UI: what bitrate would the Moonlight formula
    /// recommend for the given res/fps? Used as the suggested cap in Custom mode.
    func suggestedBitrateMbps(width: Int, height: Int, fps: Int) -> Int {
        bitrateKbps(width: width, height: height, fps: fps, preset: .matchDisplay) / 1000
    }

    // MARK: - Codec-aware budget

    /// Discount on the H.264-anchored `bitrateKbps` budget for the intended top
    /// codec (HEVC ~25% / AV1 more bits cheaper at equal quality). Conservative so
    /// heavy scenes keep headroom; the 5 Mbps floor bounds the low end. Field-tunable.
    static func codecBudgetMultiplier(for formats: VideoFormats) -> Double {
        switch formats.topCodec {
        case .av1:  return 0.80
        case .hevc: return 0.80
        case .h264: return 1.0
        }
    }

    // MARK: - Measured bitrate guidance (Tier 1: baked-in)

    /// One mode our harness actually measured, and the wire bitrate we
    /// recommend for it: measured demand plus ~20% headroom.
    struct MeasuredBitrateAnchor {
        let width: Int
        let height: Int
        let fps: Int
        let recommendedMbps: Int
    }

    /// Harness-measured recommendation anchors. Provenance (wired
    /// measurements, telemetry NDJSON):
    ///   * 3024×1964@120 (MBP 14″ panel) - measured p95 66 Mbps of the 67.2
    ///     encoder budget (84 wire × 0.8). The 84 default is correct;
    ///     recommend 85.
    ///   * 4K@120 - measured ~66 Mbps avg / 86 p95 → +20% headroom ≈ 100.
    ///   * 4K@240 - measured p95 ~87 Mbps → +20% headroom ≈ 105.
    /// Modes between/outside the anchors scale by the Moonlight formula
    /// curve (`bitrateKbps`) re-anchored to these measured points - see
    /// `recommendedBitrateMbps`. Sorted ascending by pixel-rate.
    static let measuredBitrateAnchors: [MeasuredBitrateAnchor] = [
        MeasuredBitrateAnchor(width: 3024, height: 1964, fps: 120, recommendedMbps: 85),
        MeasuredBitrateAnchor(width: 3840, height: 2160, fps: 120, recommendedMbps: 100),
        MeasuredBitrateAnchor(width: 3840, height: 2160, fps: 240, recommendedMbps: 105)
    ]

    /// Tier-1 recommendation for an arbitrary mode: the Moonlight formula
    /// value rescaled by a measured-over-formula ratio, interpolated
    /// linearly in pixel-rate (pixels × fps) between the anchors above. At
    /// the anchors this reproduces the measured recommendations exactly
    /// (85 / 100 / 105); below the smallest anchor the formula already
    /// matches measurement (ratio ≈ 1), and above the largest we hold the
    /// last ratio rather than extrapolate a trend we never measured.
    /// Snapped to a 5 Mbps grid - these read as "~105", not false precision.
    func recommendedBitrateMbps(width: Int, height: Int, fps: Int) -> Int {
        let formulaMbps = Double(bitrateKbps(width: width, height: height, fps: fps, preset: .matchDisplay)) / 1000.0
        let points = Self.measuredBitrateAnchors.map { anchor -> (pixelRate: Double, ratio: Double) in
            let anchorFormula = Double(bitrateKbps(
                width: anchor.width, height: anchor.height, fps: anchor.fps, preset: .matchDisplay)) / 1000.0
            return (Double(anchor.width * anchor.height) * Double(anchor.fps),
                    Double(anchor.recommendedMbps) / anchorFormula)
        }
        let ratio = Self.interpolatedRatio(
            at: Double(width * height) * Double(fps), points: points)
        let mbps = (formulaMbps * ratio / 5.0).rounded() * 5.0
        return max(5, Int(mbps))
    }

    /// Piecewise-linear interpolation of the measured/formula ratio over
    /// pixel-rate, clamped flat outside the anchored range. `points` must be
    /// sorted ascending by pixel-rate (the anchor table is).
    private static func interpolatedRatio(
        at pixelRate: Double, points: [(pixelRate: Double, ratio: Double)]
    ) -> Double {
        guard let first = points.first, let last = points.last else { return 1.0 }
        if pixelRate <= first.pixelRate { return first.ratio }
        if pixelRate >= last.pixelRate { return last.ratio }
        for (lower, upper) in zip(points, points.dropFirst()) where pixelRate <= upper.pixelRate {
            let fraction = (pixelRate - lower.pixelRate) / (upper.pixelRate - lower.pixelRate)
            return lower.ratio + fraction * (upper.ratio - lower.ratio)
        }
        return last.ratio
    }

    // MARK: - Learned bitrate guidance (Tier 2)

    /// The honest learned sentence for the bitrate control, or nil when
    /// there is nothing worth saying. Rides the end-of-stream receipt the
    /// main window stashes per host+mode (`SessionReceiptStore` - ALWAYS-LIVE
    /// surfaces only, no telemetry-exporter dependency). Speaks ONLY when a
    /// ≥5-minute session's average goodput pressed the encoder budget -
    /// ≥ ~90% of wire × 0.8 (the FEC share never reaches the encoder). The
    /// receipt carries the session average, not a p95, and the average
    /// includes menu/idle time - so an average at the ceiling is an even
    /// stronger "raise it" signal. A session comfortably under budget proves
    /// nothing about the ceiling, so it stays silent rather than imply the
    /// current setting is "right".
    ///
    /// `wireBudgetMbps` is the budget the user is configuring right now (the
    /// slider value the sentence renders under), not the one the session ran
    /// with - the receipt doesn't carry its bitrate, and "does my last
    /// session fit the budget I'm looking at" is the question being asked.
    func learnedBitrateAdvice(
        hostID: String?, width: Int, height: Int, fps: Int, wireBudgetMbps: Int
    ) -> String? {
        guard let hostID,
              let receipt = SessionReceiptStore.load(
                  hostId: hostID, width: width, height: height, refreshHz: fps),
              receipt.durationSeconds >= SessionReceiptStore.minimumSessionSeconds,
              let avgMbps = receipt.avgGoodputMbps else { return nil }
        let encoderBudgetMbps = Double(wireBudgetMbps) * 0.8
        guard encoderBudgetMbps > 0, avgMbps >= encoderBudgetMbps * 0.9 else { return nil }
        let mode = "\(Self.resolutionLabel(width: width, height: height))·\(fps)"
        return "Your recent \(mode) sessions used all of the \(Int(encoderBudgetMbps.rounded())) Mbps "
            + "budget - raising it will improve heavy scenes."
    }

    // MARK: - Effective config + persistence

    /// Recompute the effective stream config from the current preset + custom
    /// overrides and stash it for the UI to read. Returns true iff any effective
    /// value actually moved, so callers on the hot display-change path can skip
    /// invalidating views when nothing changed.
    @discardableResult
    func persistQualitySettings() -> Bool {
        let display = smartDefaultsForCurrentDisplay()

        let width: Int, height: Int, fps: Int, bitrate: Int, hdr: Bool
        switch qualityPreset {
        case .matchDisplay:
            width = display.width
            height = display.height
            fps = display.fps
            bitrate = bitrateKbps(width: width, height: height, fps: fps, preset: .matchDisplay)
            hdr = true
        case .hidpi:
            let hd = hidpiDefaultsForCurrentDisplay()
            width = hd.width
            height = hd.height
            fps = hd.fps
            bitrate = bitrateKbps(width: width, height: height, fps: fps, preset: .hidpi)
            hdr = true
        case .custom:
            width = customWidth
            height = customHeight
            fps = customFPS
            bitrate = customBitrateMbps * 1000
            hdr = customHDR
        }
        // Idempotent writes: assign each @Observable property only when it
        // actually moves. A spurious didChangeScreenParameters notification (the
        // launcher gets these on EDR / brightness / refresh changes that don't
        // touch the resolution) would otherwise re-stamp identical values and
        // schedule a needless SwiftUI invalidation every time - exactly the kind
        // of display-cycle layout churn that feeds AttributeGraph instability.
        // Writing an @Observable property always invalidates its readers, even
        // when the value is unchanged, so the guards are load-bearing.
        var changed = false
        if effectiveWidth != width { effectiveWidth = width; changed = true }
        if effectiveHeight != height { effectiveHeight = height; changed = true }
        if effectiveFPS != fps { effectiveFPS = fps; changed = true }
        if effectiveBitrateKbps != bitrate { effectiveBitrateKbps = bitrate; changed = true }
        if effectiveHDR != hdr { effectiveHDR = hdr; changed = true }
        UserDefaults.standard.set(qualityPreset.rawValue, forKey: "qualityPreset")
        return changed
    }

    /// Snap custom values to the display's native dimensions.
    func snapCustomToDisplay() {
        let defaults = smartDefaultsForCurrentDisplay()
        customWidth = defaults.width
        customHeight = defaults.height
        customFPS = defaults.fps
        let kbps = bitrateKbps(width: defaults.width, height: defaults.height, fps: defaults.fps, preset: .matchDisplay)
        customBitrateMbps = kbps / 1000
    }

    /// What a preset would resolve to right now.
    struct PresetSnapshot {
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int
    }

    /// What (width, height, fps, bitrate) a preset would resolve to right now.
    func effectiveValuesForPreset(_ preset: QualityPreset) -> PresetSnapshot {
        let display = smartDefaultsForCurrentDisplay()
        switch preset {
        case .matchDisplay:
            let kbps = bitrateKbps(width: display.width, height: display.height, fps: display.fps, preset: .matchDisplay)
            return PresetSnapshot(width: display.width, height: display.height, fps: display.fps, bitrateKbps: kbps)
        case .hidpi:
            let hd = hidpiDefaultsForCurrentDisplay()
            let kbps = bitrateKbps(width: hd.width, height: hd.height, fps: hd.fps, preset: .hidpi)
            return PresetSnapshot(width: hd.width, height: hd.height, fps: hd.fps, bitrateKbps: kbps)
        case .custom:
            return PresetSnapshot(width: customWidth, height: customHeight, fps: customFPS, bitrateKbps: customBitrateMbps * 1000)
        }
    }

    /// HiDPI preset target: the display's DEFAULT "looks like" logical
    /// resolution. Apple ships every built-in Retina panel at a default scale
    /// of exactly 2x, so the panel-native pixel grid halved IS the point grid
    /// the macOS UI is laid out in (3024x1964 -> 1512x982 on a 14" MBP, etc.).
    /// Streaming at this size and letting the panel integer-upscale 2x stays
    /// crisp while carrying ~1/4 the pixels of native - the bandwidth win. fps
    /// tracks the panel max, same as matchDisplay. Falls back to native for a
    /// degenerately small panel where halving would drop below 720p-ish.
    func hidpiDefaultsForCurrentDisplay() -> (width: Int, height: Int, fps: Int) {
        let native = smartDefaultsForCurrentDisplay()
        let w = native.width / 2
        let h = native.height / 2
        guard w >= 1280, h >= 720 else { return native }
        return (w, h, native.fps)
    }

    /// Friendly label for common Mac and external panel native resolutions.
    static func resolutionLabel(width w: Int, height h: Int) -> String {
        switch (w, h) {
        case (7680, 4320): return "8K"
        case (5120, 2880): return "5K"
        case (3840, 2160): return "4K"
        case (3456, 2234): return "MBP 16″"
        case (3024, 1964): return "MBP 14″"
        case (2880, 1864): return "MBA 15″"
        case (2560, 1664): return "MBA 13″"  // M3+ Air variant
        case (2560, 1600): return "MBA 13″"
        case (2560, 1440): return "1440p"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return "\(w)×\(h)"
        }
    }
}
