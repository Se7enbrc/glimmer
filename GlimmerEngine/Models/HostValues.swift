// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// One launchable app on a paired host (Sunshine's "applist" entries).
package struct LibraryApp: Identifiable, Hashable, Sendable {

    package init(
        id: Int,
        name: String,
        hdr: Bool,
        hidden: Bool
    ) {
        self.id = id
        self.name = name
        self.hdr = hdr
        self.hidden = hidden
    }

    package let id: Int
    package let name: String
    package let hdr: Bool
    package let hidden: Bool

    package var isDesktop: Bool { name.lowercased() == "desktop" }
}

package enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    // Declaration order drives `allCases`, which drives the picker order.
    // Native Retina is the default and sits at the top.
    //
    // Smooth/Maximum were dropped: their 16:9 caps looked poor on the 16:10
    // Retina panels these run on, and the bitrate-multiplier axis they rode
    // was redundant once presets differ by RESOLUTION instead. The two that
    // remain are the two real choices - full native, or the Mac's own default
    // Retina scale at a quarter of the pixels - plus Custom.
    case matchDisplay  // panel-native pixel grid + host-native fps (sharpest)
    case hidpi         // default "looks like" scale (native ÷ 2), 2x-crisp, ~¼ the bitrate
    case custom        // user-defined width/height/fps

    package var id: String { rawValue }

    /// What "no usable choice on record" resolves to: a fresh install, and any
    /// persisted raw value we can't make sense of. One source of truth so the
    /// `AppModel.qualityPreset` declared default and the legacy remap below
    /// can't drift apart.
    package static let defaultPreset: QualityPreset = .matchDisplay

    /// Resolve a persisted `qualityPreset` raw value to a live case, remapping
    /// the two cases the preset rework deleted.
    ///
    /// The failure this closes: `QualityPreset(rawValue:)` answers nil for
    /// "smooth" / "maximum", so the load fell through to the DEFAULT - Native
    /// Retina, the panel-native, top-of-the-bitrate-curve preset - and the next
    /// `persistQualitySettings()` rewrote the key, destroying the evidence. A
    /// user who deliberately picked Smooth for a thin Wi-Fi link came back from
    /// an update on the most demanding preset in the app with no way to tell
    /// what had happened.
    ///
    /// The remap preserves each dropped case's INTENT rather than its numbers:
    /// Smooth was "stay fluid, spend fewer bits", which is exactly what HiDPI is
    /// now (a quarter of the pixels); Maximum was "sharpest picture, spend the
    /// bandwidth", which is Native Retina. Anything else unrecognised (a
    /// downgrade from a build carrying a preset this one has never heard of)
    /// lands on the default rather than guessing.
    ///
    /// Idempotent by construction: every value this returns maps to itself on a
    /// second pass, so re-running the migration is a no-op.
    package static func migrated(fromPersistedRawValue raw: String) -> QualityPreset {
        if let known = QualityPreset(rawValue: raw) { return known }
        switch raw {
        case "smooth":  return .hidpi
        case "maximum": return .matchDisplay
        default:        return defaultPreset
        }
    }

    /// Named by outcome, not mechanism: a player picks how it looks, and the
    /// numbers live in the Quality pane's "Your next stream" summary.
    package var displayName: String {
        switch self {
        case .matchDisplay: return "Sharpest"
        case .hidpi: return "Balanced"
        case .custom: return "Custom"
        }
    }
}

/// A remappable in-stream chord. Its JSON shape preserves saved keyboard shortcuts.
package struct HotkeyChord: Codable, Equatable, Sendable {
    package var ctrl: Bool
    package var alt: Bool
    package var shift: Bool
    package var cmd: Bool
    package var keyChar: String  // single character, e.g. "q"

    package init(ctrl: Bool, alt: Bool, shift: Bool, cmd: Bool, keyChar: String) {
        self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.cmd = cmd
        self.keyChar = keyChar
    }

    // Every default is ⌃ plus one letter: two keys, one family. No ⌘, so they fire
    // whether or not ⌘ is forwarded to the PC. Players can remap game conflicts.

    /// ⌃Q. ⌃⌘Q is macOS's Lock Screen and never reaches an app.
    package static let defaultQuit = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "q")

    /// ⌃Z, remappable. Glimmer consumes the chord; a game binding ⌃Z does not receive it.
    package static let defaultStats = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "z")

    /// ⌃B, client-only and telemetry-gated: it only means anything in a diagnostic session.
    package static let defaultBookmark = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "b")

    /// ⌃P for the pointer toggle, not ⌃R: ⌃R is crouch plus reload. Window mode only;
    /// in full screen capture follows key status, so the chord reaches the PC.
    package static let defaultReleasePointer = HotkeyChord(
        ctrl: true, alt: false, shift: false, cmd: false, keyChar: "p")

    /// ⌃M toggles the mini player and the full presentation.
    package static let defaultMiniPlayer = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "m")

    package var displayString: String {
        var parts: [String] = []
        if ctrl { parts.append("⌃") }
        if alt { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if cmd { parts.append("⌘") }
        parts.append(keyChar.uppercased())
        return parts.joined()
    }

    package var serialized: String {
        var parts: [String] = []
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        if cmd { parts.append("cmd") }
        parts.append(keyChar.lowercased())
        return parts.joined(separator: "+")
    }
}

/// A single capturable controller button, used for the user-recorded custom
/// quit chord. Covers everything ControllerForwarder can read (GameController
/// face/dpad/shoulders/sticks + the DualSense raw-HID center buttons).
package enum ControllerButton: String, CaseIterable, Codable, Sendable {
    case faceDown, faceRight, faceLeft, faceUp   // ✕ ○ □ △  (Xbox A B X Y)
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case options, create, ps, mute, touchpad

    package var label: String {
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
    package static func describe(_ buttons: Set<ControllerButton>) -> String {
        guard !buttons.isEmpty else { return "Not set" }
        return allCases.filter(buttons.contains).map(\.label).joined(separator: " + ")
    }
}

/// Controller-side quit chord. `.custom` is a user-recorded set of buttons
/// (press the buttons, we store them); the presets cover the common pad
/// layouts. ControllerForwarder consults this every input event and fires the
/// same quit path as the keyboard hotkey when all the chord's buttons are held.
package enum ControllerQuitChord: String, CaseIterable, Codable, Sendable {
    case none
    case startSelectL1R1
    case l1r1
    case l1r1l2r2
    case l3r3
    case custom
    // NOTE: `.home` (the PS / Guide / "menu" button) was removed - macOS
    // gamecontrollerd reserves that button for system gestures, so it never
    // reliably reached the app as a quit chord. A persisted `.home` decodes to
    // nil and falls back to the default (see AppModel load), so this is
    // a clean removal with no migration step.

    package var displayName: String {
        switch self {
        case .none: return "None (keyboard only)"
        case .startSelectL1R1: return "Start + Select + L1 + R1"
        case .l1r1: return "L1 + R1"
        case .l1r1l2r2: return "L1 + R1 + L2 + R2"
        case .l3r3: return "L3 + R3 (stick clicks)"
        case .custom: return "Custom (recorded)"
        }
    }
}

/// What we know about the selected host between streams. Surfaced on the
/// launcher's readiness chip. Refreshed by a low-frequency poller that runs
/// only while the main window is foreground, a host is selected, and we're
/// NOT actively streaming (during a stream the engine's own RTT estimator
/// drives the stats overlay - polling /serverinfo on top of that is noise).
package struct HostLiveStatus: Equatable {

    package init(
        hostID: String,
        state: State,
        rttMs: Int? = nil,
        sunshineVersion: String? = nil,
        capturedAt: Date,
        runningAppID: Int? = nil
    ) {
        self.hostID = hostID
        self.state = state
        self.rttMs = rttMs
        self.sunshineVersion = sunshineVersion
        self.capturedAt = capturedAt
        self.runningAppID = runningAppID
    }

    package enum State: Equatable {
        /// First poll hasn't completed yet; chip shows the generic
        /// "Ready" / "No PC" text it had pre-feature.
        case unknown
        /// Host answered /serverinfo and reports no active session.
        case idle
        /// Host is busy streaming an app we know the name of.
        case streamingApp(name: String)
        /// Host is busy streaming an app whose ID isn't in our cached
        /// applist (uncommon - usually means the user added a new game
        /// on the host and hasn't refreshed the pairing).
        case streamingUnknownApp(id: Int)
        /// /serverinfo failed AND the TCP probe failed. The PC is most
        /// likely powered off or asleep.
        case asleep
        /// HTTPS-only mode, cert pin failed. We deliberately do NOT
        /// downgrade this to "asleep" - the readiness chip renders this as a
        /// distinct amber "Trust needed" state whose tap re-pairs (re-pinning
        /// the new cert).
        case certMismatch
    }

    /// UUID of the host this snapshot belongs to. Lets us discard stale
    /// results that land after the user has switched PCs.
    package var hostID: String
    package var state: State
    /// Time-to-TCP-ready in ms. Only meaningful when `state` resolved via
    /// the TCP probe - i.e. anything other than `.unknown` / `.certMismatch`.
    package var rttMs: Int?
    /// Host's reported version (Sunshine/GFE). Surfaced opt-in as a footnote.
    package var sunshineVersion: String?
    /// When this snapshot was captured. Used to age out a stale
    /// "Streaming X" reading if the host stops answering - we don't want
    /// the chip lying about a half-hour-old session.
    package var capturedAt: Date
    /// Names need not be unique, so automation keeps the PC's reported app ID.
    package var runningAppID: Int?

    package static let stale: TimeInterval = 60

    /// A sample of `hostID` young enough to act on; an unknown state never is.
    package static func isFresh(_ live: HostLiveStatus?, for hostID: String, at now: Date = Date()) -> Bool {
        guard let live, live.hostID == hostID, live.state != .unknown else { return false }
        return now.timeIntervalSince(live.capturedAt) <= stale
    }
}
