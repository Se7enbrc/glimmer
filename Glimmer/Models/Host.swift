//
//  Host.swift
//
//  Persisted-host and live-status model types shared across the UI and
//  manager.
//

import Foundation

// MARK: - Persisted host model

/// A paired Sunshine/GeForce Experience host known to Glimmer. Mirrors the
/// shape of the moonlight-qt-persisted host blob so the one-shot migration
/// in `HostsStore.migrateFromMoonlightQtIfNeeded` can copy values verbatim.
struct MoonlightHost: Identifiable, Hashable {
    let id: String  // uuid from Moonlight, or hostname fallback
    let name: String
    let customName: String?
    let localAddress: String?
    let manualAddress: String?
    let apps: [MoonlightApp]
    let lastConnected: Date?
    let serverCertPEM: String?    // pinned from moonlight-qt's hosts.N.srvcert (migration)
    let appVersion: String?
    let gfeVersion: String?

    // Future: populate from /serverinfo's `<mac>` field when present.
    // Sunshine exposes the host's primary NIC MAC; GFE 3.x exposes it
    // as `<mac>` too. Wiring this through HostsStore + the discovery /
    // serverinfo paths is out of scope for the UX polish pass — the
    // field is here so the ConnectBanner's "Wake on LAN" affordance
    // can ship conditional today and light up automatically when the
    // backend populates this.
    let macAddress: String?

    var displayName: String { customName ?? name }

    var lastPlayedDescription: String? {
        guard let last = lastConnected else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // Lowercased — macOS HIG sentence-case convention for
        // relative-time strings in secondary/footnote contexts. Apple's
        // own Time Machine and Photos do "last opened 2 hours ago", not
        // "Last opened 2 Hours Ago". Producing it lowercase at the source
        // keeps every call site consistent.
        return "last played \(formatter.localizedString(for: last, relativeTo: .now))"
    }
}

/// One launchable app on a paired host (Sunshine's "applist" entries).
struct MoonlightApp: Identifiable, Hashable {
    let id: Int
    let name: String
    let hdr: Bool
    let hidden: Bool

    var systemImage: String {
        switch name.lowercased() {
        case "desktop": return "macwindow"
        case let lowered where lowered.contains("steam"): return "gamecontroller.fill"
        case let lowered where lowered.contains("big picture"): return "tv"
        default: return "app"
        }
    }
}

// MARK: - Quality preset

enum QualityPreset: String, CaseIterable, Identifiable {
    // Declaration order drives `allCases`, which drives the picker order.
    // Match-my-display is the default and sits at the top.
    case matchDisplay  // host-native fps + display res, balanced
    case smooth      // 60 fps, conservative bitrate
    case maximum     // host-native fps, peak bitrate
    case custom      // user-defined width/height/fps/bitrate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smooth: return "Smooth"
        case .matchDisplay: return "Match my display"
        case .maximum: return "Maximum"
        case .custom: return "Custom"
        }
    }

    // Outcome-first subtitles: what each preset feels like, with the
    // tradeoff in the parenthetical. Mechanism numbers live in the Quality
    // pane's "Your next stream" summary.
    var subtitle: String {
        switch self {
        case .smooth: return "Always fluid, even on Wi-Fi (caps sharpness at 1440p 60)"
        case .matchDisplay: return "Looks like this Mac's own display (wants a solid network)"
        case .maximum: return "Sharpest picture in heavy scenes (uses the most bandwidth)"
        case .custom: return "Pick your own resolution, refresh, and bitrate"
        }
    }
}

// MARK: - Hotkey model

/// A single user-configurable in-stream hotkey: modifier flags + one character
/// key. One type covers every chord-shaped intercept Glimmer fires at the
/// SwiftUI layer (currently: quit-stream, toggle-stats-overlay). The JSON
/// shape is identical to the legacy `QuitHotkey` blob persisted in
/// UserDefaults under `"quitHotkey"`, so the typealias round-trips without
/// a migration step.
public struct HotkeyChord: Codable, Equatable, Sendable {
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    public var cmd: Bool
    public var keyChar: String  // single character, e.g. "q"

    public init(ctrl: Bool, alt: Bool, shift: Bool, cmd: Bool, keyChar: String) {
        self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.cmd = cmd
        self.keyChar = keyChar
    }

    /// Default quit chord: ⌃⌥Q. Cmd is deliberately not in the default
    /// because ⌃⌘Q is macOS's system-reserved Lock Screen shortcut — the
    /// OS intercepts it before any app sees the keyDown. ⌃⌥Q is short,
    /// memorable, not OS-reserved, and carries no `.command` flag so the
    /// `captureSysKeys` gate (which only strips Cmd-bearing keystrokes)
    /// doesn't affect it.
    public static let defaultQuit = HotkeyChord(ctrl: true, alt: true, shift: false, cmd: false, keyChar: "q")

    /// Default stats-overlay chord: ⌃⌥S. Chosen because:
    ///   * It doesn't collide with `defaultQuit` (⌃⌘Q).
    ///   * It carries no `.command` modifier, so it's intercepted BEFORE the
    ///     sys-keys-capture gate in InputForwarder — which means it fires
    ///     whether or not the user has enabled the ⌘-forwarding toggle in
    ///     Shortcuts ("Use ⌘ shortcuts inside the game"). A Cmd-bearing
    ///     default would silently fail when capture was off.
    ///   * No Shift, to dodge the common Win+Shift+S screenshot binding on
    ///     the host side that some users have muscle memory for.
    public static let defaultStats = HotkeyChord(ctrl: true, alt: true, shift: false, cmd: false, keyChar: "s")

    /// Default telemetry-bookmark chord: ⌃B ("B" for Bookmark). Client-only —
    /// NEVER forwarded to the host. Pressed during a stream to flag "that felt
    /// bad" (signal 4): writes a timestamped jank marker into the telemetry so a
    /// review jumps straight to the moment. Deliberately the SIMPLE two-key ⌃B
    /// (dropped the ⌥ from the old ⌃⌥B) — the moment to mark is mid-jank, when a
    /// fumbled three-key chord is exactly what you don't want:
    ///   * No `.command`, so it's intercepted BEFORE the sys-keys-capture gate
    ///     and fires whether or not the user forwards macOS shortcuts.
    ///   * No Shift, dodging common host-side ⇧ bindings.
    ///   * "B" collides with neither quit ("q") nor stats ("s"). ⌃B is not a
    ///     macOS-reserved chord; it CAN collide with an in-game Ctrl+B, but the
    ///     chord is client-only + telemetry-gated, so it only matters during an
    ///     opt-in diagnostic session.
    public static let defaultBookmark = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "b")

    /// Source-compat shim: existing call sites that read `.default` still
    /// resolve to the quit chord. New code should prefer the explicit name.
    public static let `default` = defaultQuit

    var displayString: String {
        var parts: [String] = []
        if ctrl { parts.append("⌃") }
        if alt { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if cmd { parts.append("⌘") }
        parts.append(keyChar.uppercased())
        return parts.joined()
    }

    var serialized: String {
        var parts: [String] = []
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        if cmd { parts.append("cmd") }
        parts.append(keyChar.lowercased())
        return parts.joined(separator: "+")
    }
}

/// Legacy spelling preserved as a typealias so the persisted JSON blob's
/// type identity (and any pre-existing callers we miss) keeps working
/// without a forced migration. New code should refer to `HotkeyChord`.
public typealias QuitHotkey = HotkeyChord

/// A single capturable controller button, used for the user-recorded custom
/// quit chord. Covers everything ControllerForwarder can read (GameController
/// face/dpad/shoulders/sticks + the DualSense raw-HID center buttons).
public enum ControllerButton: String, CaseIterable, Codable, Sendable {
    case faceDown, faceRight, faceLeft, faceUp   // ✕ ○ □ △  (Xbox A B X Y)
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case options, create, ps, mute, touchpad

    public var label: String {
        switch self {
        case .faceDown: return "✕"
        case .faceRight: return "○"
        case .faceLeft: return "□"
        case .faceUp: return "△"
        case .dpadUp: return "↑"
        case .dpadDown: return "↓"
        case .dpadLeft: return "←"
        case .dpadRight: return "→"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .options: return "Options"
        case .create: return "Create"
        case .ps: return "PS"
        case .mute: return "Mute"
        case .touchpad: return "Touchpad"
        }
    }

    /// Format a set as a stable, readable chord string ("✕ + L1 + R1"),
    /// ordered by the declaration order above.
    public static func describe(_ buttons: Set<ControllerButton>) -> String {
        guard !buttons.isEmpty else { return "Not set" }
        return allCases.filter(buttons.contains).map(\.label).joined(separator: " + ")
    }
}

/// Controller-side quit chord. `.custom` is a user-recorded set of buttons
/// (press the buttons, we store them); the presets cover the common pad
/// layouts. ControllerForwarder consults this every input event and fires the
/// same quit path as the keyboard hotkey when all the chord's buttons are held.
public enum ControllerQuitChord: String, CaseIterable, Codable, Sendable {
    case none
    case startSelectL1R1
    case l1r1
    case l1r1l2r2
    case l3r3
    case home
    case custom

    public var displayName: String {
        switch self {
        case .none: return "None (keyboard only)"
        case .startSelectL1R1: return "Start + Select + L1 + R1 (Moonlight default)"
        case .l1r1: return "L1 + R1"
        case .l1r1l2r2: return "L1 + R1 + L2 + R2"
        case .l3r3: return "L3 + R3 (stick clicks)"
        case .home: return "Home / Guide"
        case .custom: return "Custom (recorded)"
        }
    }
}

// MARK: - Deterministic hashing
//
// Swift's `String.hashValue` is intentionally randomized per process (it's
// seeded from a per-launch nonce as a defence against hash-flooding attacks
// on dictionaries). Anything we use for stable visual identity — per-host
// tint colour, monogram chip background, anywhere we'd want "Tower" to read
// as the same blue every time the user opens the app — has to use a
// deterministic hash instead.
//
// FNV-1a-64 chosen because:
//   * Short to implement (~10 lines, no SipHash table or external dep).
//   * Determinism is the only requirement — we don't need cryptographic
//     hashing or even strong avalanche; we just need "same input → same
//     output across launches".
//   * 64-bit output is wider than we need (we mod by colors.count, ~12),
//     but the extra width is free and avoids per-process collisions
//     between similarly-named hosts ("Tower" vs "Tower 2").
extension String {
    /// FNV-1a 64-bit hash of this string's UTF-8 bytes. Deterministic
    /// across process launches — unlike `hashValue`, which Swift seeds
    /// from a per-process nonce.
    func deterministicHash() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV offset basis
        for b in self.utf8 {
            h ^= UInt64(b)
            h &*= 0x0000_0100_0000_01b3        // FNV prime
        }
        return h
    }
}

// MARK: - Host live status

/// What we know about the selected host between streams. Surfaced on the
/// HostHero readiness chip. Refreshed by a low-frequency poller that runs
/// only while the main window is foreground, a host is selected, and we're
/// NOT actively streaming (during a stream the engine's own RTT estimator
/// drives the stats overlay — polling /serverinfo on top of that is noise).
struct HostLiveStatus: Equatable {
    enum State: Equatable {
        /// First poll hasn't completed yet; chip shows the generic
        /// "Ready" / "No PC" text it had pre-feature.
        case unknown
        /// Host answered /serverinfo and reports no active session.
        case idle
        /// Host is busy streaming an app we know the name of.
        case streamingApp(name: String)
        /// Host is busy streaming an app whose ID isn't in our cached
        /// applist (uncommon — usually means the user added a new game
        /// on the host and hasn't refreshed the pairing).
        case streamingUnknownApp(id: Int)
        /// /serverinfo failed AND the TCP probe failed. The PC is most
        /// likely powered off or asleep.
        case asleep
        /// HTTPS-only mode, cert pin failed. We deliberately do NOT
        /// downgrade this to "asleep" — the existing error UI handles it
        /// with a "trust new cert" path; we just stay quiet on the chip.
        case certMismatch
    }

    /// UUID of the host this snapshot belongs to. Lets us discard stale
    /// results that land after the user has switched PCs.
    var hostID: String
    var state: State
    /// Time-to-TCP-ready in ms. Only meaningful when `state` resolved via
    /// the TCP probe — i.e. anything other than `.unknown` / `.certMismatch`.
    var rttMs: Int?
    /// Host's reported version (Sunshine/GFE). Surfaced opt-in as a footnote.
    var sunshineVersion: String?
    /// When this snapshot was captured. Used to age out a stale
    /// "Streaming X" reading if the host stops answering — we don't want
    /// the chip lying about a half-hour-old session.
    var capturedAt: Date

    static let stale: TimeInterval = 60
}
