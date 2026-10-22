// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  QualityCalculator.swift
//
//  Bitrate / resolution / fps recommendation logic for the manager. Ports
//  Moonlight's `StreamingPreferences::getDefaultBitrate` shape (resolution
//  table × frame-rate factor × preset multiplier) and the smart-defaults
//  display probe (panel-native pixel grid via Core Graphics). Originally
//  inline in `AppModel.swift`.
//

import GlimmerEngine
import AppKit
import Foundation

extension AppModel {

    // MARK: - Display probe

    /// Compute smart defaults from the current display.
    func smartDefaultsForCurrentDisplay() -> (width: Int, height: Int, fps: Int) {
        displayProbe()
    }

    /// The main display's PANEL NATIVE pixel grid, not the scaled framebuffer:
    /// Core Graphics lists the panel's real modes and the native flag marks the
    /// one it wants. Falls back to the framebuffer times the backing scale.
    static func mainDisplayMode() -> (width: Int, height: Int, fps: Int) {
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
        if let displayID = screen.displayID {
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

    static let frameRateExponent = StreamQuality.frameRateExponent
    nonisolated static let maxBitrateKbps = StreamQuality.maxBitrateKbps
    typealias MeasuredBitrateAnchor = StreamQuality.MeasuredBitrateAnchor
    static let measuredBitrateAnchors = StreamQuality.measuredBitrateAnchors

    func bitrateKbps(width: Int, height: Int, fps: Int, preset: QualityPreset) -> Int {
        StreamQuality.bitrateKbps(width: width, height: height, fps: fps, preset: preset)
    }

    static func codecBudgetMultiplier(for formats: VideoFormats) -> Double {
        StreamQuality.codecBudgetMultiplier(for: formats)
    }

    func recommendedBitrateMbps(width: Int, height: Int, fps: Int) -> Int {
        StreamQuality.recommendedBitrateMbps(width: width, height: height, fps: fps)
    }

    // MARK: - Effective config + persistence

    /// Recompute the effective stream config from the current preset + custom
    /// overrides and stash it for the UI to read. Returns true iff any effective
    /// value actually moved, so callers on the hot display-change path can skip
    /// invalidating views when nothing changed.
    @discardableResult
    func persistQualitySettings() -> Bool {
        let resolved = effectiveValuesForPreset(qualityPreset)
        let edrHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue
        let hdr = Self.showsHDR(requested: streamHDR, edrHeadroom: edrHeadroom)
        // Idempotent writes: assign each @Observable property only when it
        // actually moves. A spurious didChangeScreenParameters notification (the
        // launcher gets these on EDR / brightness / refresh changes that don't
        // touch the resolution) would otherwise re-stamp identical values and
        // schedule a needless SwiftUI invalidation every time - exactly the kind
        // of display-cycle layout churn that feeds AttributeGraph instability.
        // Writing an @Observable property always invalidates its readers, even
        // when the value is unchanged, so the guards are load-bearing.
        var changed = false
        if effectiveWidth != resolved.width { effectiveWidth = resolved.width; changed = true }
        if effectiveHeight != resolved.height { effectiveHeight = resolved.height; changed = true }
        if effectiveFPS != resolved.fps { effectiveFPS = resolved.fps; changed = true }
        if effectiveBitrateKbps != resolved.bitrateKbps { effectiveBitrateKbps = resolved.bitrateKbps; changed = true }
        if effectiveHDR != hdr {
            effectiveHDR = hdr
            changed = true
            Diag.info("HDR tag \(hdr ? "shown" : "hidden"): HDR \(streamHDR ? "on" : "off"), "
                + "display EDR headroom \(edrHeadroom.map { "\($0)" } ?? "unknown")", "Stream")
        }
        // The preset itself is deliberately NOT written here. This function runs
        // on paths with no user intent behind them (launch bootstrap, every
        // display-parameter change), and writing the key from them re-stamped it
        // with whatever the load had decoded - which destroyed an unrecognised
        // legacy raw value before it could be migrated. `qualityPreset`'s own
        // didSet persists it, and only a real change reaches that.
        return changed
    }

    /// Snap custom values to the display's native dimensions.
    ///
    /// Writes through the custom properties, so their didSets persist all
    /// three keys - only ever call this behind an explicit user action (the
    /// Quality pane's "Use Native Resolution") or when Custom is already the
    /// live preset. The bitrate needs no seeding: it is derived from the mode
    /// every time the effective config is computed (`recommendedBitrateMbps`).
    func snapCustomToDisplay() {
        let defaults = smartDefaultsForCurrentDisplay()
        customWidth = defaults.width
        customHeight = defaults.height
        customFPS = defaults.fps
    }

    /// What a preset would resolve to right now.
    struct PresetSnapshot {
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int
    }

    /// What (width, height, fps, bitrate) a preset resolves to right now: the
    /// one resolver behind the effective config and the Custom prefill.
    func effectiveValuesForPreset(_ preset: QualityPreset) -> PresetSnapshot {
        let raw = rawValuesForPreset(preset)
        let size = Self.encodableSize(width: raw.width, height: raw.height)
        return PresetSnapshot(width: size.width, height: size.height, fps: raw.fps, bitrateKbps: raw.bitrateKbps)
    }

    /// Encoders need even dimensions for 4:2:0 video. A 16" MacBook Pro halves to 1728x1117, which a
    /// PC that builds its display to order (Apollo) took as asked and then never encoded (issue #110).
    nonisolated static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int) {
        StreamQuality.encodableSize(width: width, height: height)
    }

    private func rawValuesForPreset(_ preset: QualityPreset) -> PresetSnapshot {
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
            // In a window the Hz is capped at the panel's refresh, and the
            // derived bitrate reads that capped value, so a windowed 60 Hz
            // stream does not carry a 120 Hz budget. Full screen is verbatim.
            let fps = streamDisplayMode == .window
                ? StreamDisplayMode.windowedRefresh(customFPS: customFPS, displayMaxHz: display.fps)
                : customFPS
            let kbps = recommendedBitrateMbps(width: customWidth, height: customHeight, fps: fps) * 1000
            return PresetSnapshot(width: customWidth, height: customHeight, fps: fps, bitrateKbps: kbps)
        }
    }

    /// The spec surfaces promise HDR only when it is on and the display can
    /// show it (potential EDR headroom above 1; nil means no screen).
    nonisolated static func showsHDR(requested: Bool, edrHeadroom: CGFloat?) -> Bool {
        StreamQuality.showsHDR(requested: requested, edrHeadroom: edrHeadroom)
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
        let size = StreamQuality.hidpiSize(width: native.width, height: native.height)
        return (size.width, size.height, native.fps)
    }

    /// The names players use for standard modes; anything else, Mac panels included, reads as its size.
    nonisolated static func resolutionLabel(width w: Int, height h: Int) -> String {
        switch (w, h) {
        case (7680, 4320): return "8K"
        case (5120, 2880): return "5K"
        case (3840, 2160): return "4K"
        case (2560, 1440): return "1440p"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return "\(w) × \(h)"
        }
    }
}
