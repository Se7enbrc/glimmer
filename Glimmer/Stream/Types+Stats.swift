//
//  Types+Stats.swift
//
//  The stream stats overlay model: per-row kinds plus the overlay preset /
//  defaults / color thresholds / corner. The large per-frame snapshot value
//  type lives in Types+StatsSnapshot.swift. Split out of Types.swift to keep
//  each unit focused.
//

import Foundation

// MARK: - Stream stats overlay

/// One row of the in-stream stats overlay's compact HUD: an SF Symbol icon,
/// a short left-aligned label, and a right-aligned color-coded value. The
/// overlay layer renders an ordered array of these per tick, grouping
/// adjacent rows of the same `Section` together with hairline dividers
/// between sections.
///
/// Health is computed against the negotiated stream FPS / latency
/// thresholds - see `StreamStatsSnapshot.rows(enabled:targetFps:)`. A row
/// whose underlying data is missing (`nil` in the snapshot) still emits a
/// neutral row with an em-dash value so the user sees that the metric
/// exists but isn't measurable right now (e.g. RTT pre-ENet-connect).
public struct StatsRow: Sendable, Equatable {
    /// Stable identifier per row type. Used as the persistence key for the
    /// Custom preset's per-row toggles AND as the de-duplication key when
    /// the overlay diffs rows between ticks.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case hostFps, networkFps, decodeFps, renderFps
        case latency, jitter, networkDrops
        case decoderDrops, bitrate, decodeTime, hostProcessing
        case smoothness
        case audio
        case macBattery, macCpu, macRam
        case controllerBattery
    }

    /// Color state of the value text. `neutral` is "no threshold -
    /// informational" (host FPS, bitrate, audio config) and renders
    /// identically to `healthy` today, but stays its own case so a future
    /// dim-treatment for purely-informational rows is a one-line change.
    public enum Health: Sendable { case healthy, warning, critical, neutral }

    /// Section the row belongs to. Rows in the same section render
    /// adjacent; section changes emit a hairline divider. The raw value
    /// dictates display order (frameRates first, audio last).
    public enum Section: Int, Comparable, Sendable {
        case frameRates = 0, network = 1, pipeline = 2, mac = 3, config = 4
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let kind: Kind
    /// Short, sentence-case label rendered on the left. "Host", "Latency",
    /// "Drop rate" - not full prose. SF Pro Text in the overlay.
    public let label: String
    /// Pre-formatted value string ("59.9 FPS", "12 ms ±3", "0.00 %",
    /// "Surround 5.1"). SF Mono in the overlay so digit widths align and
    /// the trailing digit doesn't jitter when the value changes.
    public let value: String
    /// SF Symbol name (e.g. "display", "network", "bolt.horizontal").
    /// Rendered as a 12pt monochrome white CGImage and parked as the row's
    /// icon-slot layer contents. `nil` leaves the icon slot empty - for
    /// rows whose only honest glyph would mislead (no battery reading must
    /// not draw `battery.0`, which reads as battery-empty).
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

/// Which curated row set the stats overlay shows. `.minimal` is the
/// at-a-glance default for fresh installs - the three numbers that answer
/// "is my stream OK" (render fps / latency / bitrate) without covering
/// gameplay. `.micro` adds the full framerate + network breakdown;
/// `.extended` shows the pipeline-plus-network row set minus audio;
/// `.custom` honours `statsOverlayCustomRows`.
///
/// Persisted to UserDefaults as the rawValue string so the choice survives
/// launches. New installs default to `.minimal`. Case order is the
/// Settings picker order - smallest set first.
public enum StatsOverlayPreset: String, CaseIterable, Codable, Sendable {
    case minimal, micro, extended, custom

    /// Human-readable label for the Settings picker. Subtitle (the
    /// "N metrics - ..." hint) lives in the SettingsView alongside the
    /// picker so the description and the picker line up.
    public var displayName: String {
        switch self {
        case .minimal:  return "Minimal"
        case .micro:    return "Micro"
        case .extended: return "Extended"
        case .custom:   return "Custom"
        }
    }
}

/// The curated row sets behind the overlay presets. Defined as static
/// constants so MoonlightManager and the SettingsView subtitle / checkbox
/// code all reach the same values without duplicating the literals.
public enum StatsOverlayDefaults {
    /// Minimal preset - exactly three rows: am I getting frames (render
    /// FPS), how late (latency), how heavy (bitrate). The fresh-install
    /// default; everything beyond these three is diagnostics, which
    /// Micro / Extended / Custom exist for.
    public static let minimalRows: Set<StatsRow.Kind> = [
        .renderFps, .latency, .bitrate
    ]
    /// Micro preset - framerate + network + bitrate, the "what matters
    /// at a glance" diagnostic subset.
    public static let microRows: Set<StatsRow.Kind> = [
        .hostFps, .renderFps, .networkFps,
        .latency, .jitter, .networkDrops,
        .bitrate
    ]
    /// Every stream-side row. Mac vitals and audio are NOT in Extended -
    /// they're host-Mac sidebar metrics rather than the game-streaming
    /// numbers Extended is for. Custom is the path to opt those in.
    public static let extendedRows: Set<StatsRow.Kind> =
        Set(StatsRow.Kind.allCases).subtracting([
            .audio, .macBattery, .macCpu, .macRam
        ])
    /// Initial Custom row set on first toggle into Custom. Same as the
    /// Micro set so the user sees a familiar starting point, rather
    /// than an empty overlay that requires them to figure out which
    /// rows exist.
    public static let initialCustomRows: Set<StatsRow.Kind> = microRows
}

// MARK: - Stats overlay color thresholds

/// User-configurable thresholds that drive the row health colors (white →
/// yellow → red). Persisted to UserDefaults via MoonlightManager. Defaults
/// are calibrated to "when does this actually start to feel bad" rather
/// than to rounding noise above a target - a 60Hz stream measuring 58fps
/// is fine, a 60Hz stream measuring 29fps is unplayable.
public struct StatsThresholds: Sendable, Equatable, Codable {
    /// Frame rate (FPS). Warn below the higher number, critical below the
    /// lower one. Absolute values, NOT relative to target FPS - a user
    /// streaming a 30fps title still wants the same "below 30 = bad" line.
    public var fpsWarningBelow: Int
    public var fpsCriticalBelow: Int

    /// Round-trip latency in milliseconds. Warn above the lower number,
    /// critical above the higher one. 50ms is the bar where most players
    /// can feel input lag in twitch games; >100ms is unplayable.
    public var latencyWarningAbove: UInt32
    public var latencyCriticalAbove: UInt32

    /// Jitter (RTT variance) in milliseconds. Warn / critical thresholds
    /// for noticeable stutter. Slightly more permissive than the previous
    /// 5/15 since real LAN streams routinely show ~5ms variance under
    /// load without visible problems.
    public var jitterWarningAbove: UInt32
    public var jitterCriticalAbove: UInt32

    /// Drop rate, as a percent of frames (0.0 - 100.0). 0.5% is the
    /// noticeable-stutter line; >2% is "the stream is breaking up".
    public var dropsWarningAbove: Double
    public var dropsCriticalAbove: Double

    public init(
        fpsWarningBelow: Int = 60,
        fpsCriticalBelow: Int = 30,
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

/// Where the in-stream stats overlay anchors itself, with a 20pt inset
/// from the chosen corner. Persisted to UserDefaults under
/// "streamStatsCorner" via MoonlightManager. A right-click context menu
/// on the overlay layer isn't viable because mouse events during a
/// stream are claimed by InputForwarder and forwarded to the host (the
/// cursor is hidden, right-click is a game input, not a launcher
/// gesture), so the positional preference lives in Settings.
public enum StatsOverlayCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}
