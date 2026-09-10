//
//  StreamDisplayMode.swift
//
//  How the stream is shown (full screen / window) and the pure rules around
//  it: the persisted default, which preset the choice applies to, and the
//  refresh cap a windowed stream takes. Window is part of the CUSTOM preset -
//  Native Retina and HiDPI are panel-native by definition, so they are always
//  full screen; a window uses Custom's own resolution, refresh, bitrate and
//  HDR. Testable without an AppModel, an NSScreen, or a window.
//

import Foundation

/// How the stream is presented on this Mac. Snapshotted into `StreamConfig`
/// at session start (like `coversNotch`), so a Settings change applies to the
/// next stream. The one mid-stream flip is a user-driven exit from a
/// full-screen Space, which lands the same window in `.window` (see
/// StreamWindow+Windowed.swift) rather than leaving a vanished window behind.
public enum StreamDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case fullScreen
    case window

    public var id: String { rawValue }

    /// A fresh install streams full screen - the product's default stance.
    public static let defaultMode: StreamDisplayMode = .fullScreen

    /// UserDefaults key. Registered (never written) with `defaultMode` in
    /// GlimmerApp so the raw read agrees with the declared default.
    public static let defaultsKey = "streamDisplayMode"

    public var displayName: String {
        switch self {
        case .fullScreen: return "Full screen"
        case .window: return "Window"
        }
    }

    /// Resolve a persisted raw value. Absent or unrecognised (a downgrade from
    /// a build with a mode this one doesn't know) lands on the default rather
    /// than guessing.
    public static func persisted(rawValue: String?) -> StreamDisplayMode {
        rawValue.flatMap(StreamDisplayMode.init(rawValue:)) ?? defaultMode
    }

    /// The mode a session actually gets: the user's choice under Custom, full
    /// screen under every other preset. The persisted choice is left alone
    /// while a panel-native preset is selected, so switching back to Custom
    /// finds the window toggle where it was.
    static func effective(chosen: StreamDisplayMode, preset: QualityPreset) -> StreamDisplayMode {
        preset == .custom ? chosen : .fullScreen
    }

    /// The refresh a WINDOWED stream asks for: Custom's Hz capped at the
    /// display's current maximum (a 60 Hz panel can't show 120 - asking would
    /// only drop frames) and floored at the host's 30 Hz minimum. 0 or a
    /// negative display value means unknown and falls back to 60. Full screen
    /// keeps Custom's Hz verbatim, as before.
    static func windowedRefresh(customFPS: Int, displayMaxHz: Int) -> Int {
        let cap = displayMaxHz > 0 ? displayMaxHz : fallbackDisplayMaxHz
        return max(StreamSizeBounds.fps.lowerBound, min(StreamSizeBounds.clampFPS(customFPS), cap))
    }

    /// The refresh assumed when the display can't report one (a headless or
    /// mid-reconfigure NSScreen answers 0).
    static let fallbackDisplayMaxHz = 60
}

/// The bounds every stream-size field is clamped to, shared by the Custom
/// preset's fields and the init-time heal of persisted values. 640x480 is the
/// smallest mode a host will encode; 8K / 240 Hz are Moonlight's upstream
/// ceilings. One home so the sites can't drift.
enum StreamSizeBounds {
    static let width = 640...7680
    static let height = 480...4320
    static let fps = 30...240

    static func clampWidth(_ value: Int) -> Int { min(max(value, width.lowerBound), width.upperBound) }
    static func clampHeight(_ value: Int) -> Int { min(max(value, height.lowerBound), height.upperBound) }
    static func clampFPS(_ value: Int) -> Int { min(max(value, fps.lowerBound), fps.upperBound) }
}
