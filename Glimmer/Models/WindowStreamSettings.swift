//
//  WindowStreamSettings.swift
//
//  The "Show the stream" choice (full screen / window) and the Window-mode
//  stream-size request behind it. Pure value types: the persisted keys, the
//  defaults a fresh install lands on, and the derivation from "what the user
//  picked" to "what the host is asked to render" - all testable without an
//  AppModel, an NSScreen, or a window.
//
//  Why the window request has its OWN keys: the fullscreen Custom preset
//  (customWidth/customHeight/customFPS) is a different intent - "override the
//  panel" - and a user who flips between the two modes must find each exactly
//  as they left it. Sharing keys would make picking 1080p for a window silently
//  rewrite their 4K fullscreen override.
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
}

/// The bounds every stream-size field is clamped to, shared by the fullscreen
/// Custom preset, the Window-mode request, and the init-time heal of persisted
/// values. 640x480 is the smallest mode a host will encode; 8K / 240 Hz are
/// Moonlight's upstream ceilings. One home so the three sites can't drift.
enum StreamSizeBounds {
    static let width = 640...7680
    static let height = 480...4320
    static let fps = 30...240

    static func clampWidth(_ value: Int) -> Int { min(max(value, width.lowerBound), width.upperBound) }
    static func clampHeight(_ value: Int) -> Int { min(max(value, height.lowerBound), height.upperBound) }
    static func clampFPS(_ value: Int) -> Int { min(max(value, fps.lowerBound), fps.upperBound) }
}

/// What the host renders while the stream is shown in a window. The curated
/// list is the same one the Custom preset's shortcut menu offers; Custom keeps
/// its own width x height (persisted, remembered across choices).
enum WindowStreamSizeChoice: String, CaseIterable, Sendable {
    case hd720, hd1080, qhd1440, uhd4K, custom

    /// The curated resolution behind a preset choice; nil for Custom.
    var resolution: CommonResolution? {
        switch self {
        case .hd720: return .hd720
        case .hd1080: return .hd1080
        case .qhd1440: return .qhd1440
        case .uhd4K: return .uhd4K
        case .custom: return nil
        }
    }

    /// Picker label: the familiar short name plus the pixel pair, so 4K reads
    /// as 4K without hiding what is actually asked for.
    var displayName: String {
        switch self {
        case .hd720: return "720p (1280 × 720)"
        case .hd1080: return "1080p (1920 × 1080)"
        case .qhd1440: return "1440p (2560 × 1440)"
        case .uhd4K: return "4K (3840 × 2160)"
        case .custom: return "Custom"
        }
    }
}

/// The refresh the window stream asks for. "Display maximum" tracks the panel
/// the launcher is on at session start; the fixed and Custom choices are
/// clamped to it, because asking a 60 Hz panel for 120 buys nothing but
/// dropped frames.
enum WindowStreamRefreshChoice: String, CaseIterable, Sendable {
    case displayMax, hz60, hz120, custom

    func displayName(displayMaxHz: Int) -> String {
        switch self {
        case .displayMax: return "Display maximum (\(displayMaxHz) Hz)"
        case .hz60: return "60 Hz"
        case .hz120: return "120 Hz"
        case .custom: return "Custom"
        }
    }
}

/// The resolved Window-mode request: what the session asks the host for.
struct WindowStreamRequest: Equatable, Sendable {
    let width: Int
    let height: Int
    let fps: Int
}

/// The Window-mode settings as persisted: size choice + custom size, refresh
/// choice + custom Hz. Custom values are kept even while a preset is selected,
/// so switching back to Custom finds the last values entered.
struct WindowStreamSettings: Equatable, Sendable {
    var sizeChoice: WindowStreamSizeChoice = .hd1080
    var customWidth: Int = 1920
    var customHeight: Int = 1080
    var refreshChoice: WindowStreamRefreshChoice = .displayMax
    var customFPS: Int = 60

    /// The persisted keys - deliberately distinct from the fullscreen Custom
    /// preset's `customWidth` / `customHeight` / `customFPS` (see file header).
    enum Keys {
        static let sizeChoice = "windowStreamSizeChoice"
        static let width = "windowStreamWidth"
        static let height = "windowStreamHeight"
        static let refreshChoice = "windowStreamRefreshChoice"
        static let fps = "windowStreamFPS"
    }

    /// The refresh assumed when the display can't report one (a headless or
    /// mid-reconfigure NSScreen answers 0).
    static let fallbackDisplayMaxHz = 60

    /// Load from `defaults`, keeping each field's declared default when its key
    /// is absent or undecodable, and clamping the numeric fields on read so a
    /// value persisted out of range by an older build can't reach the host.
    static func load(from defaults: UserDefaults) -> WindowStreamSettings {
        var settings = WindowStreamSettings()
        if let raw = defaults.string(forKey: Keys.sizeChoice),
           let choice = WindowStreamSizeChoice(rawValue: raw) {
            settings.sizeChoice = choice
        }
        if let raw = defaults.string(forKey: Keys.refreshChoice),
           let choice = WindowStreamRefreshChoice(rawValue: raw) {
            settings.refreshChoice = choice
        }
        let width = defaults.integer(forKey: Keys.width)
        if width > 0 { settings.customWidth = StreamSizeBounds.clampWidth(width) }
        let height = defaults.integer(forKey: Keys.height)
        if height > 0 { settings.customHeight = StreamSizeBounds.clampHeight(height) }
        let fps = defaults.integer(forKey: Keys.fps)
        if fps > 0 { settings.customFPS = StreamSizeBounds.clampFPS(fps) }
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(sizeChoice.rawValue, forKey: Keys.sizeChoice)
        defaults.set(customWidth, forKey: Keys.width)
        defaults.set(customHeight, forKey: Keys.height)
        defaults.set(refreshChoice.rawValue, forKey: Keys.refreshChoice)
        defaults.set(customFPS, forKey: Keys.fps)
    }

    /// Resolve the request against the display the stream will open on.
    /// `displayMaxHz` is `NSScreen.maximumFramesPerSecond` (the panel's CURRENT
    /// refresh, not its capability); 0 or negative means unknown and falls back
    /// to 60. Every refresh choice is capped at it and floored at the host's
    /// 30 Hz minimum; the custom size is clamped to `StreamSizeBounds`.
    func request(displayMaxHz: Int) -> WindowStreamRequest {
        let cap = displayMaxHz > 0 ? displayMaxHz : Self.fallbackDisplayMaxHz
        let width: Int
        let height: Int
        if let res = sizeChoice.resolution {
            width = res.width
            height = res.height
        } else {
            width = StreamSizeBounds.clampWidth(customWidth)
            height = StreamSizeBounds.clampHeight(customHeight)
        }
        let wanted: Int
        switch refreshChoice {
        case .displayMax: wanted = cap
        case .hz60: wanted = 60
        case .hz120: wanted = 120
        case .custom: wanted = StreamSizeBounds.clampFPS(customFPS)
        }
        let fps = max(StreamSizeBounds.fps.lowerBound, min(wanted, cap))
        return WindowStreamRequest(width: width, height: height, fps: fps)
    }
}
