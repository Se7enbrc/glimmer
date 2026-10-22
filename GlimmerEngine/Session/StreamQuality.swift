// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation

/// Shared measured quality math; native display probing and saved preferences belong to the shell.
public enum StreamQuality {

    /// Preserve the measured high-refresh curve and the wire budget before codec/FEC discounts.
    package static let frameRateExponent = 0.75

    package static let maxBitrateKbps = 300_000

    package static func bitrateKbps(width: Int, height: Int, fps: Int, preset: QualityPreset) -> Int {
        let pixels = width * height

        let table: [(Int, Double)] = [
            (640 * 360, 1),
            (854 * 480, 2),
            (1280 * 720, 5),
            (1920 * 1080, 10),
            (2560 * 1440, 20),
            (3840 * 2160, 40)
        ]
        guard let firstEntry = table.first, let lastEntry = table.last else {
            return 5_000
        }
        var resolutionFactor: Double = firstEntry.1
        if pixels >= lastEntry.0 {
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

        let fpsValue = Double(fps)
        let frameRateFactor = (fpsValue <= 60
            ? fpsValue
            : (pow(fpsValue / 60.0, Self.frameRateExponent) * 60.0)) / 30.0

        let presetMultiplier: Double
        switch preset {
        case .matchDisplay, .hidpi, .custom: presetMultiplier = 1.0
        }

        let kbps = Int((resolutionFactor * frameRateFactor * presetMultiplier).rounded() * 1000)
        return min(max(kbps, 5_000), Self.maxBitrateKbps)
    }

    package static func videoFormats(_ formats: VideoFormats, hdr: Bool) -> VideoFormats {
        hdr ? formats : formats.subtracting(VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_MASK_10BIT))
    }

    package static func codecBudgetMultiplier(for formats: VideoFormats) -> Double {
        switch formats.topCodec {
        case .av1:  return 0.80
        case .hevc: return 0.80
        case .h264: return 1.0
        }
    }

    package struct MeasuredBitrateAnchor: Sendable {
        package let width: Int
        package let height: Int
        package let fps: Int
        package let recommendedMbps: Int
    }

    /// Wired harness measurements plus headroom: 3024×1964/120, 4K/120 and 4K/240.
    /// Interpolation follows pixel rate; values outside the range hold the nearest measured ratio.
    package static let measuredBitrateAnchors: [MeasuredBitrateAnchor] = [
        MeasuredBitrateAnchor(width: 3024, height: 1964, fps: 120, recommendedMbps: 85),
        MeasuredBitrateAnchor(width: 3840, height: 2160, fps: 120, recommendedMbps: 100),
        MeasuredBitrateAnchor(width: 3840, height: 2160, fps: 240, recommendedMbps: 105)
    ]

    package static func recommendedBitrateMbps(width: Int, height: Int, fps: Int) -> Int {
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

    /// Encoders need even dimensions; round down without exceeding the requested size.
    public static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (width & ~1, height & ~1)
    }

    package static func showsHDR(requested: Bool, edrHeadroom: CGFloat?) -> Bool {
        requested && (edrHeadroom ?? 1) > 1
    }

    package static func hidpiSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let half = (width / 2, height / 2)
        return half.0 >= 1280 && half.1 >= 720 ? half : (width, height)
    }
}
