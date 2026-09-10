//
//  AppModel.swift
//
//  ObservableObject that owns the UI's view of paired hosts, quality
//  settings, pairing state, and stream lifecycle. This file is the class
//  core (published properties + orchestration). The split is:
//
//    * Models/Host.swift      - Host, LibraryApp, QualityPreset,
//                               HotkeyChord, HostLiveStatus
//    * AppModel+Defaults.swift - the typed UserDefaults read helpers `init()`
//                               loads settings through
//    * HostsStore.swift       - UserDefaults read/write of the host list,
//                               moonlight-qt migration, unpair/retrust
//    * QualityCalculator.swift - bitrate/resolution/fps recommendation logic
//    * HostStatusPoller.swift - periodic readiness-chip polling Task
//

import Foundation
import AppKit
import AudioToolbox
import CoreAudio
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

// MARK: - Observation
//
// `@Observable`'s tracking is property-granular: SwiftUI only rebuilds the
// views that actually read a changed property. There is no manager-wide
// `objectWillChange.send()` hammer; views that compute off non-observed
// global state (e.g. NSScreen.main) hook the `displayInfoRevision`
// sentinel below, which ticks when the screen-parameter notification
// fires.
@MainActor
@Observable
final class AppModel {

    @ObservationIgnored let log = Logger(
        subsystem: "io.ugfugl.Glimmer", category: "AppModel")

    // Hosts
    var hosts: [Host] = []
    var selectedHost: Host?

    // Stream lifecycle
    var isStreaming = false
    /// Active native session, retained while streaming.
    @ObservationIgnored var nativeSession: StreamSession?

    // Quality
    // Default `.matchDisplay` (panel-native resolution + refresh) - the option
    // shown at the top of the preset list. Users on constrained links can drop
    // to HiDPI; an explicit choice is persisted by the didSet below and read
    // back (with the legacy-preset remap) in init().
    var qualityPreset: QualityPreset = QualityPreset.defaultPreset {
        willSet {
            // When the user switches from a preset to Custom, prefill the custom
            // values with the preset's effective numbers so they're not surprised
            // by a sudden 1920x1080 reset.
            if newValue == .custom && qualityPreset != .custom {
                let snapshot = effectiveValuesForPreset(qualityPreset)
                customWidth = snapshot.width
                customHeight = snapshot.height
                customFPS = snapshot.fps
            }
        }
        didSet {
            // The preset's OWN persistence lives here, not in
            // persistQualitySettings(). That recompute runs on paths the user
            // never touched - launch bootstrap, every display-parameter change -
            // and its unconditional write re-stamped the key with whatever the
            // load had decoded, so a raw value the decoder didn't recognise was
            // overwritten before it could ever be migrated (see
            // `QualityPreset.migrated(fromPersistedRawValue:)`). A didSet is
            // suppressed during init(), so only a real change - which is only
            // ever the Settings picker - reaches UserDefaults now.
            UserDefaults.standard.set(qualityPreset.rawValue, forKey: "qualityPreset")
            persistQualitySettings()
        }
    }

    // Custom overrides (used only when qualityPreset == .custom)
    var customWidth: Int = 1920 {
        didSet {
            UserDefaults.standard.set(customWidth, forKey: "customWidth")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customHeight: Int = 1080 {
        didSet {
            UserDefaults.standard.set(customHeight, forKey: "customHeight")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customFPS: Int = 60 {
        didSet {
            UserDefaults.standard.set(customFPS, forKey: "customFPS")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    // No bitrate knob, by design. A bitrate is a wire budget the app can
    // derive better than a person can guess: `recommendedBitrateMbps` rescales
    // the Moonlight formula onto anchors MEASURED on real hardware, so the
    // number follows resolution and refresh (and, in a window, the capped
    // refresh) on its own. Nothing to persist and nothing to ask - the result
    // is visible in the next-stream summary. See QualityCalculator.
    var customHDR: Bool = true {
        didSet {
            UserDefaults.standard.set(customHDR, forKey: "customHDR")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }

    // Defaults
    var defaultLaunchApp: String = "Desktop" {
        didSet { UserDefaults.standard.set(defaultLaunchApp, forKey: "defaultLaunchApp") }
    }
    var muteMacWhileStreaming: Bool = false {
        didSet {
            UserDefaults.standard.set(muteMacWhileStreaming, forKey: "muteMacWhileStreaming")
            // Mid-stream flips act immediately - doc on applyMutePreferenceMidStream().
            applyMutePreferenceMidStream()
        }
    }

    /// Connection lifecycle published from the native engine. Drives the
    /// connect-banner, the StreamButton role, and the ReadinessChip's
    /// transitional state. See `StreamPhase` for the case set.
    var streamPhase: StreamPhase = .idle

    /// True when a stream is running but its window has been orderOut'd
    /// because the user Cmd-Tabbed away. The launcher UI shows a "Back to
    /// stream" affordance while this is true. Set by the StreamWindow's
    /// resign/become-key observers via callbacks on this manager.
    var nativeStreamBackgrounded: Bool = false

    /// Bring the stream window back from the background. Called by the
    /// launcher's "Back to stream" CTA when nativeStreamBackgrounded is true.
    public func resumeStreamWindow() {
        Task { [weak self] in
            await self?.nativeSession?.resumeWindow()
        }
    }
    var nativeStreamError: String?

    /// Effective HDR-active state from the native engine. True only when the
    /// host signalled HDR mode AND the bitstream is 10-bit AND the Metal
    /// layer is fully configured for PQ/HLG EDR output. Drives the "HDR"
    /// chip in the stream UI.
    var nativeHDRActive: Bool = false

    /// Brief "Stream ended" toast on the launcher. Flipped on whenever a
    /// stream session ends cleanly (regardless of whether the user quit
    /// via hotkey, the host disconnected, or an error occurred); the
    /// ContentView toast auto-dismisses after ~2s by clearing this back
    /// to false on its own timer. Lives here so any view in the launcher
    /// can react to it - the stream window itself fades independently
    /// (see StreamWindow.close()).
    var streamEndedToastVisible: Bool = false

    /// Receipt for the most recently ENDED session - nil when the last
    /// attempt never went live or ran under the stash threshold. Assigned in
    /// the teardown cleanup right before `streamEndedToastVisible` flips so
    /// the toast's first render already carries its "2h 12m · 12 ms median"
    /// line. Persistence contract: AppModel+SessionReceipt.swift.
    var lastSessionReceipt: SessionReceipt?

    /// Always-on route monitor for the SELECTED host (the readiness chip's
    /// quiet bolt / Wi-Fi glyph). Deliberately independent of the gate-on
    /// telemetry probe - see AppModel+HostRoute.swift. Re-pointed by
    /// the launcher via `refreshHostRoute()` as the selection changes.
    let hostRoute = HostRouteMonitor()

    /// Latest reachability + activity snapshot for the selected host. Drives
    /// the HostHero readiness chip ("Ready · 12 ms", "Streaming Helldivers 2",
    /// "Asleep"). `nil` until the first poll completes after selection. Always
    /// keyed by the selected host's id - see `liveStatusForSelected` for the
    /// safe read accessor used by the UI.
    var hostLiveStatus: HostLiveStatus?

    /// Set when a launch would TAKE OVER a session already running on the host
    /// (someone else streaming, not ours). The launcher binds a confirmation
    /// dialog to this; confirming calls `stream(app:on:)`, cancelling clears it.
    /// nil = no takeover pending (the common case streams straight through).
    var pendingTakeover: PendingTakeover?
    struct PendingTakeover: Equatable {
        let app: LibraryApp
        let host: Host
        let occupantApp: String
    }

    var showStreamStats: Bool = false {
        didSet { UserDefaults.standard.set(showStreamStats, forKey: "showStreamStats") }
    }

    /// Which screen corner the in-stream stats overlay anchors to.
    /// Persisted to UserDefaults so the choice survives launches and is
    /// applied from frame zero of the next stream. The default of
    /// `.topLeft` matches the historical hardcoded position so existing
    /// users don't see the panel jump on first launch with this field.
    var streamStatsCorner: StatsOverlayCorner = .topLeft {
        didSet {
            UserDefaults.standard.set(streamStatsCorner.rawValue, forKey: "streamStatsCorner")
        }
    }

    /// Curated row set for the stats overlay. Fresh installs default to
    /// `.minimal` (render fps / latency / bitrate - the three-row
    /// "is my stream OK" check). UserDefaults persistence happens in didSet.
    var statsOverlayPreset: StatsOverlayPreset = .minimal {
        didSet {
            UserDefaults.standard.set(
                statsOverlayPreset.rawValue, forKey: "statsOverlayPreset")
        }
    }

    /// Per-row visibility set used only when `statsOverlayPreset == .custom`.
    /// Persisted as the array of `StatsRow.Kind.rawValue` strings - Codable
    /// + JSON would work but a `[String]` is what
    /// `UserDefaults.set(_:forKey:)` natively handles, so we stay on the
    /// stringly-typed path used by every other preference here.
    var statsOverlayCustomRows: Set<StatsRow.Kind> = StatsOverlayDefaults.initialCustomRows {
        didSet {
            let raw = statsOverlayCustomRows.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "statsOverlayCustomRows")
        }
    }

    /// The row set the overlay should actually render, resolved against
    /// the current preset. Custom mode reaches into `statsOverlayCustomRows`;
    /// the curated presets resolve to their static sets in
    /// `StatsOverlayDefaults`. Computed property so the resolution is
    /// always in sync with the preset - no caching, no invalidation.
    var effectiveStatsRows: Set<StatsRow.Kind> {
        switch statsOverlayPreset {
        case .minimal:  return StatsOverlayDefaults.minimalRows
        case .micro:    return StatsOverlayDefaults.microRows
        case .extended: return StatsOverlayDefaults.extendedRows
        case .custom:   return statsOverlayCustomRows
        }
    }

    /// User-tunable warn / critical thresholds for the stats overlay's
    /// row health colors. Persisted as JSON because the struct has 8
    /// fields and a single Data blob beats 8 separate UserDefaults keys
    /// for atomicity (a partial write under a crash leaves the prefs in
    /// a coherent state - either old defaults or fully new values).
    var statsThresholds: StatsThresholds = .default {
        didSet {
            if let data = try? JSONEncoder().encode(statsThresholds) {
                UserDefaults.standard.set(data, forKey: "statsThresholds")
            }
        }
    }

    var quitHotkey: HotkeyChord = .defaultQuit {
        didSet {
            // Historical UserDefaults key - previously-stored chords still decode.
            if let data = try? JSONEncoder().encode(quitHotkey) {
                UserDefaults.standard.set(data, forKey: "quitHotkey")
            }
        }
    }
    var statsHotkey: HotkeyChord = .defaultStats {
        didSet {
            // The in-stream toggle of `showStreamStats` deliberately does
            // NOT round-trip back to UserDefaults - the hotkey is a
            // session-scope override, the defaults checkbox is the
            // persistent surface.
            if let data = try? JSONEncoder().encode(statsHotkey) {
                UserDefaults.standard.set(data, forKey: "statsHotkey")
            }
        }
    }

    var captureSysKeys: Bool = false {
        didSet { UserDefaults.standard.set(captureSysKeys, forKey: "captureSysKeys") }
    }
    var streamCoversNotch: Bool = true {
        didSet { UserDefaults.standard.set(streamCoversNotch, forKey: "streamCoversNotch") }
    }
    /// The Custom preset's "Show the stream in a window" choice: full screen
    /// (the default) or a normal titled window at Custom's own resolution,
    /// refresh, bitrate and HDR. Only in force under Custom (see
    /// `effectiveDisplayMode`); snapshotted into the StreamConfig at session
    /// start, like `streamCoversNotch`. A windowed stream caps the refresh at
    /// the display, so a flip recomputes the "Your next stream" summary.
    var streamDisplayMode: StreamDisplayMode = StreamDisplayMode.defaultMode {
        didSet {
            UserDefaults.standard.set(streamDisplayMode.rawValue, forKey: StreamDisplayMode.defaultsKey)
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    /// Window-mode pointer chord (default ⌃⌥R): a TOGGLE - hands the mouse to
    /// the game for mouselook, and takes it back. The pointer is normally
    /// grabbed by being over the window and freed by a held Esc; this is how
    /// you re-grab without moving the mouse off and back, and how you release
    /// without reaching for Esc. Read live via a provider, like the quit/stats
    /// chords. The persisted key keeps its original name.
    var releasePointerHotkey: HotkeyChord = .defaultReleasePointer {
        didSet {
            if let data = try? JSONEncoder().encode(releasePointerHotkey) {
                UserDefaults.standard.set(data, forKey: "releasePointerHotkey")
            }
        }
    }
    /// Controller-side quit chord - fires the same path as `quitHotkey`
    /// from the keyboard, but driven by a multi-button hold on the
    /// gamepad. Defaults to L3 + R3 (click both sticks): native on every pad (no
    /// Create/Share/Mute, which macOS drops on a DualSense), and - unlike a
    /// shoulder+trigger chord - its partials don't leak a host combo as you press
    /// in (L1+R1+L2+R2 assembles through LB+RB+LT, which Steam Big Picture reads
    /// as Show-Keyboard). The 400ms dwell guards a mid-game trip; "None" disables.
    var controllerQuitChord: ControllerQuitChord = .l3r3 {
        didSet {
            UserDefaults.standard.set(controllerQuitChord.rawValue, forKey: "controllerQuitChord")
        }
    }

    /// User-recorded buttons backing the `.custom` quit chord (press the buttons,
    /// we store them - issue #9). Persisted as JSON.
    var customControllerChord: Set<ControllerButton> = AppModel.loadCustomChord() {
        didSet {
            if let data = try? JSONEncoder().encode(customControllerChord) {
                UserDefaults.standard.set(data, forKey: "customControllerChord")
            }
        }
    }

    private static func loadCustomChord() -> Set<ControllerButton> {
        guard let data = UserDefaults.standard.data(forKey: "customControllerChord"),
              let set = try? JSONDecoder().decode(Set<ControllerButton>.self, from: data) else { return [] }
        return set
    }

    /// Live "is any game controller connected" flag, driven by the
    /// `GCControllerDidConnect` / `GCControllerDidDisconnect` observers in
    /// `startLiveRefresh()` and seeded at launch. Because it's an `@Observable`
    /// stored property, SwiftUI views that read it rebuild as controllers come
    /// and go - used to show/hide the controller-permission UI without polling.
    var controllerConnected: Bool = !GCController.controllers().isEmpty

    /// Opt-in raw-HID DualSense reading (Options / Create / Mute buttons that
    /// macOS's GameController framework hides). Requires the Input Monitoring
    /// permission, so it's OFF by default and only enabled explicitly from
    /// Settings ▸ Troubleshooting after an up-front explanation. The key is
    /// also read directly by `DualSenseHID.isEnabled` from non-UI code.
    var rawHIDControllerEnabled: Bool = UserDefaults.standard.bool(forKey: "rawHIDControllerEnabled") {
        didSet {
            UserDefaults.standard.set(rawHIDControllerEnabled, forKey: "rawHIDControllerEnabled")
        }
    }

    /// Reveals the Settings ▸ Diagnostics pane (the single hideable home for the
    /// debug/tuning wires: the Telemetry toggle, the bookmark chord, and the
    /// log/telemetry status line). HIDDEN by default - a normal user never sees it. It's
    /// unhidden by a deliberate option-click on the version line in About (the
    /// Telemetry toggle lives INSIDE this pane, so it can't gate its own reveal -
    /// hence a separate, plainly-debug-only UserDefault). Persisted so a power
    /// user who revealed it keeps it across launches.
    var showDiagnostics: Bool = UserDefaults.standard.bool(forKey: "showDiagnostics") {
        didSet {
            UserDefaults.standard.set(showDiagnostics, forKey: "showDiagnostics")
        }
    }

    /// Opt-in performance telemetry (the gate read by `TelemetryGate.isEnabled`
    /// at stream start). OFF by default; surfaced only in the hidden Diagnostics
    /// pane. Changing it applies on the NEXT stream - the exporter snapshots the
    /// gate when a session starts. Mirrors the raw key `TelemetryGate` reads so
    /// the UI toggle and the engine agree.
    var telemetryEnabled: Bool = UserDefaults.standard.bool(forKey: "telemetryEnabled") {
        didSet {
            UserDefaults.standard.set(telemetryEnabled, forKey: "telemetryEnabled")
        }
    }

    /// Drives the one-time auto-offer alert (on the launcher) when a DualSense
    /// is seen and the user hasn't decided yet. Transient.
    var showRawHIDPrompt = false

    /// Whether the user has answered the auto-offer (Enable or Cancel) - so we
    /// only proactively ask once. They can still flip the Settings toggle.
    var rawHIDPromptAnswered: Bool = UserDefaults.standard.bool(forKey: "rawHIDPromptAnswered") {
        didSet {
            UserDefaults.standard.set(rawHIDPromptAnswered, forKey: "rawHIDPromptAnswered")
        }
    }

    // The raw-HID offer's entry points (maybeOfferRawHID / enableRawHIDFromPrompt /
    // declineRawHIDPrompt) and its explanation copy live in AppModel+RawHID.swift.

    // Pairing
    var pairingInFlight = false

    /// Typed phase of the in-flight pairing handshake. Drives the PairSheet
    /// banner colour, spinner, and result text. `pairingMessage` is the
    /// String-typed read shim for UI code that hasn't migrated.
    var pairingPhase: PairingPhase = .idle

    // `pairingMessage` (the String shim over `pairingPhase`) lives in AppModel+Pairing.swift.

    // Persisted stream config - held here so the UI's "Your next stream"
    // summary stays truthful without depending on moonlight-qt's UserDefaults
    // domain. Internal (not private) so the QualityCalculator extension
    // in QualityCalculator.swift can write them.
    var effectiveWidth: Int = 1920
    var effectiveHeight: Int = 1080
    var effectiveFPS: Int = 60
    var effectiveBitrateKbps: Int = 20_000
    var effectiveHDR: Bool = true

    // Bookkeeping
    @ObservationIgnored weak var appDelegate: AppDelegate?

    /// All NotificationCenter observer tokens we've registered with the
    /// closure form (`addObserver(forName:object:queue:using:)`). Drained
    /// in `deinit` so the manager doesn't leak observer registrations into
    /// NotificationCenter's global table.
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []

    /// Background poller for the host readiness chip. Cancelled and
    /// re-spawned on every lifecycle edge (host change, app activation,
    /// stream start/end) - callers go through `restartHostStatusPolling()`
    /// which owns the cancel+respawn dance. Internal so
    /// HostStatusPoller.swift can drive it.
    @ObservationIgnored var hostStatusTask: Task<Void, Never>?

    /// True between NSWorkspace's willSleep and didWake. The chip poller must
    /// not run across a nap: a poll caught mid-exchange when the Mac goes dark
    /// leaves a half-open TLS connection on the host, and Sunshine's single
    /// HTTPS thread blocks on it forever (2026-09-02: 47984 refused for 14h
    /// until a Sunshine restart). `restartHostStatusPolling` is a no-op while
    /// this is set; didWake clears it and re-arms.
    @ObservationIgnored var hostPollingPausedForSleep = false

    /// Observer tokens registered on `NSWorkspace.shared.notificationCenter`
    /// (sleep/wake live there, not on the default center), kept apart from
    /// `notificationTokens` so each is removed from the center that owns it.
    @ObservationIgnored var workspaceTokens: [NSObjectProtocol] = []

    /// Consecutive unreachable TCP probes for the currently-polled host. A
    /// SINGLE timed-out probe degrades the chip to `.unknown` ("Checking...")
    /// rather than asserting `.asleep`; only TWO misses in a row publish
    /// `.asleep`. This is the guard against the post-stream false negative:
    /// right after a session ends the app sends the host `/cancel`, and
    /// Sunshine's HTTP front-end is briefly unresponsive in that window, so a
    /// single probe through that blip would otherwise slander an awake host
    /// (that was streaming <6s ago) as "asleep". Reset to 0 on any reachable
    /// probe. Keyed implicitly to the active poll loop - `restartHostStatusPolling`
    /// resets it when re-arming for a (possibly different) host.
    @ObservationIgnored var hostUnreachableStreak = 0

    /// Number of consecutive unreachable probes required before the chip
    /// asserts `.asleep`. Sub-threshold misses publish NOTHING (the chip holds
    /// its last-good status - see `publishUnreachable`), so this is purely the
    /// confidence bar for declaring a host down: 3 consecutive 2 s misses
    /// (~30 s) ride out Wi-Fi double-blips and a momentarily busy host without
    /// a false "Asleep", while a genuinely-off box still resolves cleanly.
    static let asleepProbeThreshold = 3

    /// Settle delay before the FIRST chip probe when the poller is re-armed
    /// right after a stream ended. Lets the host's `/cancel`-induced HTTP blip
    /// clear before we probe, so the post-stream poll doesn't race it and
    /// publish a false `.asleep`. Only applied on the stream-end re-arm path
    /// (`restartHostStatusPolling(afterStream: true)`); host-switch / activation
    /// re-arms probe immediately as before.
    static let postStreamPollSettle: TimeInterval = 2.0

    /// Poll interval between /serverinfo refreshes for the selected host's
    /// readiness chip. 10 s is the load-bearing knob from the spec - it's
    /// frequent enough to feel live without hammering the host (Sunshine logs
    /// every /serverinfo) and cheaper than the connection stats overlay's own
    /// per-second cadence.
    static let hostStatusPollSeconds: TimeInterval = 10

    // MARK: Init / lifecycle

    /// Sentinel that `currentDisplayDescription` reads at the top of its
    /// body. `@Observable` can only auto-track stored-property reads - it
    /// can't see through `NSScreen.main` (a global API we don't own), so
    /// the screen-parameter-change notification bumps this revision to
    /// force any view watching `currentDisplayDescription` to recompute.
    var displayInfoRevision: Int = 0

    isolated deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        // Drain NotificationCenter observer tokens we registered with the
        // closure form - without this they outlive the manager and keep the
        // closures (and any captured state) alive in NC's global table.
        // `isolated deinit` keeps the deinit on MainActor (the class's
        // isolation) so we can safely read the MainActor-isolated
        // `notificationTokens` array; Swift 6's default nonisolated deinit
        // refuses that read. NotificationCenter.removeObserver itself is
        // documented thread-safe so the hop is purely a compile-time
        // requirement.
        let tokens = notificationTokens
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        hostStatusTask?.cancel()
    }

    init() {
        // Every line below is a DIRECT property write inside the initializer, so
        // the properties' `didSet`/`willSet` observers do NOT fire (Swift
        // suppresses observers during init) - this logic stays in `init` for
        // exactly that reason. The `?? <currentValue>` form keeps the property's
        // declared default whenever the persisted key is absent / out of range /
        // undecodable, which is identical to the prior inline `if let` /
        // `if x > 0` checks but without a branch per key (so the initializer
        // stays under the complexity bar). The persisted-key set is unchanged.
        muteMacWhileStreaming = UserDefaults.standard.bool(forKey: "muteMacWhileStreaming")
        defaultLaunchApp = UserDefaults.standard.string(forKey: "defaultLaunchApp") ?? defaultLaunchApp
        qualityPreset = Self.persistedQualityPreset() ?? qualityPreset
        // Width/height/fps are clamped on read: builds whose Quality pane
        // clamped on Return only could persist out-of-range values via a
        // focus-loss commit (0 self-heals via persistedPositiveInt; 1000 Hz
        // did not). Bounds mirror QualityPane's clamp helpers.
        customWidth = min(max(Self.persistedPositiveInt("customWidth") ?? customWidth, 640), 7680)
        customHeight = min(max(Self.persistedPositiveInt("customHeight") ?? customHeight, 480), 4320)
        customFPS = min(max(Self.persistedPositiveInt("customFPS") ?? customFPS, 30), 240)
        customHDR = Self.persistedBool("customHDR") ?? customHDR
        captureSysKeys = Self.persistedBool("captureSysKeys") ?? captureSysKeys
        streamCoversNotch = Self.persistedBool("streamCoversNotch") ?? streamCoversNotch
        // Registered default (GlimmerApp) answers the absent-key case; an
        // unrecognised raw value lands on the default rather than guessing.
        streamDisplayMode = StreamDisplayMode.persisted(
            rawValue: UserDefaults.standard.string(forKey: StreamDisplayMode.defaultsKey))
        releasePointerHotkey = Self.persistedDecoded("releasePointerHotkey", HotkeyChord.self) ?? releasePointerHotkey
        showStreamStats = Self.persistedBool("showStreamStats") ?? showStreamStats
        streamStatsCorner = Self.persistedRawValue("streamStatsCorner", StatsOverlayCorner.self) ?? streamStatsCorner
        // Stats overlay preset. Key-absence means the user never touched
        // the Settings picker (didSet is suppressed here and the picker is
        // the only post-init writer), so absent keeps the .minimal default
        // declared above - deliberately no migration shim. Existing
        // installs decode their saved choice; an unrecognised raw value
        // (downgrade from a build that added a preset) falls back to
        // .minimal silently.
        statsOverlayPreset = Self.persistedRawValue("statsOverlayPreset", StatsOverlayPreset.self) ?? statsOverlayPreset
        // Custom-row set. Decode each persisted string back to a
        // StatsRow.Kind; an unknown kind (downgrade from a future build)
        // gets silently dropped rather than aborting the load. Empty /
        // missing → keep the default initial set already set on the
        // property.
        statsOverlayCustomRows = Self.persistedCustomRows() ?? statsOverlayCustomRows
        statsThresholds = Self.persistedDecoded("statsThresholds", StatsThresholds.self) ?? statsThresholds
        quitHotkey = Self.persistedDecoded("quitHotkey", HotkeyChord.self) ?? quitHotkey
        statsHotkey = Self.persistedDecoded("statsHotkey", HotkeyChord.self) ?? statsHotkey
        controllerQuitChord = Self.persistedRawValue("controllerQuitChord", ControllerQuitChord.self) ?? controllerQuitChord
    }

    // MARK: Mute/restore Mac audio

    /// Pre-mute capture of the system output level. Non-nil doubles as the
    /// did-mute LATCH: the stream-end restore keys off THIS, never the live
    /// toggle - see AppModel+Audio.swift for the full contract.
    @ObservationIgnored var prePausedMacVolume: Float?
}
