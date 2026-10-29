// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

// MARK: - Stream stats overlay

/// One row of the in-stream stats overlay's compact HUD: an SF Symbol icon, a short left-aligned label, and a
/// right-aligned color-coded value.
public struct StatsRow: Sendable, Equatable {
    /// Stable identifier per row type. Used as the persistence key for the
    /// Custom preset's per-row toggles AND as the de-duplication key when
    /// the overlay diffs rows between ticks.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case hostFps, networkFps, decodeFps, renderFps
        case latency, jitter, networkDrops
        case decoderDrops, bitrate, decodeTime, hostProcessing
        case smoothness
        case codec, audio
        case macBattery, macCpu, macRam
        case controllerBattery
    }

    /// Color state of the value text.
    public enum Health: Sendable { case healthy, warning, critical, neutral }

    /// Section the row belongs to. Rows in the same section render
    /// adjacent; section changes emit a hairline divider. The raw value
    /// dictates display order (frameRates first, audio last).
    public enum Section: Int, Comparable, Sendable {
        case frameRates = 0, network = 1, pipeline = 2, mac = 3, config = 4
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let kind: Kind
    /// Short, sentence-case label rendered on the left. "PC", "Latency",
    /// "Drop rate" - not full prose. SF Pro Text in the overlay.
    public let label: String
    /// Pre-formatted value string ("59.9 FPS", "12 ms ±3", "0.00 %",
    /// "Surround 5.1"). SF Mono in the overlay so digit widths align and
    /// the trailing digit doesn't jitter when the value changes.
    public let value: String
    /// SF Symbol name (e.g. "display", "network", "bolt.horizontal").
    public let symbolName: String?
    public let health: Health
    public let section: Section

    public init(
        kind: Kind, label: String, value: String,
        symbolName: String?, health: Health, section: Section
    ) {
        self.kind = kind
        self.label = label
        self.value = value
        self.symbolName = symbolName
        self.health = health
        self.section = section
    }
}
// MARK: - Stats overlay preset

/// Which curated row set the stats overlay shows.
public enum StatsOverlayPreset: String, CaseIterable, Codable, Sendable {
    case minimal, micro, extended, custom

    /// Human-readable label for the Settings picker. Subtitle (the
    /// "N metrics - ..." hint) lives in the SettingsView alongside the
    /// picker so the description and the picker line up.
    public var displayName: String {
        switch self {
        case .minimal:  return "Minimal"
        // Display name only; rawValue stays "micro" so saved choices survive.
        case .micro:    return "Standard"
        case .extended: return "Extended"
        case .custom:   return "Custom"
        }
    }
}

/// The curated row sets behind the overlay presets. Defined as static
/// constants so AppModel and the SettingsView subtitle / checkbox
/// code all reach the same values without duplicating the literals.
public enum StatsOverlayDefaults {
    /// The stream's frame rate, latency, bitrate and negotiated codec.
    public static let minimalRows: Set<StatsRow.Kind> = [
        .renderFps, .latency, .bitrate, .codec
    ]
    /// Micro preset - framerate + network + bitrate, the "what matters
    /// at a glance" diagnostic subset.
    public static let microRows: Set<StatsRow.Kind> = [
        .hostFps, .renderFps, .networkFps,
        .latency, .jitter, .networkDrops,
        .bitrate, .codec
    ]
    /// Every stream-side row. Mac vitals and audio are NOT in Extended -
    /// they're host-Mac sidebar metrics rather than the game-streaming
    /// numbers Extended is for. Custom is the path to opt those in.
    public static let extendedRows: Set<StatsRow.Kind> =
        Set(StatsRow.Kind.allCases).subtracting([
            .audio, .macBattery, .macCpu, .macRam
        ])
    /// Initial Custom row set on first toggle into Custom.
    public static let initialCustomRows: Set<StatsRow.Kind> = microRows
}

// MARK: - Stats overlay color thresholds

/// User-configurable row health colors. Low game frame rates are informational
/// by default; players can opt into absolute FPS warning thresholds.
public struct StatsThresholds: Sendable, Equatable, Codable {
    /// Zero disables the corresponding frame-rate warning.
    public var fpsWarningBelow: Int
    public var fpsCriticalBelow: Int

    /// Round-trip latency in milliseconds. Warn above the lower number,
    /// critical above the higher one. 50ms is the bar where most players
    /// can feel input lag in twitch games; >100ms is unplayable.
    public var latencyWarningAbove: UInt32
    public var latencyCriticalAbove: UInt32

    /// Jitter (RTT variance) in milliseconds.
    public var jitterWarningAbove: UInt32
    public var jitterCriticalAbove: UInt32

    /// Drop rate, as a percent of frames (0.0 - 100.0). 0.5% is the
    /// noticeable-stutter line; >2% is "the stream is breaking up".
    public var dropsWarningAbove: Double
    public var dropsCriticalAbove: Double

    public init(
        fpsWarningBelow: Int = 0,
        fpsCriticalBelow: Int = 0,
        latencyWarningAbove: UInt32 = 50,
        latencyCriticalAbove: UInt32 = 100,
        jitterWarningAbove: UInt32 = 10,
        jitterCriticalAbove: UInt32 = 25,
        dropsWarningAbove: Double = 0.5,
        dropsCriticalAbove: Double = 2.0
    ) {
        self.fpsWarningBelow = fpsWarningBelow
        self.fpsCriticalBelow = fpsCriticalBelow
        self.latencyWarningAbove = latencyWarningAbove
        self.latencyCriticalAbove = latencyCriticalAbove
        self.jitterWarningAbove = jitterWarningAbove
        self.jitterCriticalAbove = jitterCriticalAbove
        self.dropsWarningAbove = dropsWarningAbove
        self.dropsCriticalAbove = dropsCriticalAbove
    }

    public static let `default` = StatsThresholds()
}

// MARK: - Stats overlay corner

/// The HUD position persists as a raw string; existing center positions remain valid.
public enum StatsOverlayCorner: String, CaseIterable, Sendable {
    // "Corner" by history; now also carries the two edge-centers. Top-center
    // sits clear of the camera notch; bottom-center rides the bottom edge.
    // rawValues are the case names, so adding cases mid-list is persistence-safe.
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    public static func persisted(defaults: UserDefaults = PersistentStorage.defaults) -> Self {
        defaults.string(forKey: "streamStatsCorner").flatMap(Self.init(rawValue:)) ?? .topLeft
    }

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .topLeft:      return "Top left"
        case .topCenter:    return "Top center"
        case .topRight:     return "Top right"
        case .bottomLeft:   return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight:  return "Bottom right"
        }
    }
}
