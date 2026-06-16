//
//  MoonlightManager.swift
//
//  ObservableObject that owns the UI's view of paired hosts, quality
//  settings, pairing state, and stream lifecycle. This file is the class
//  core (published properties + orchestration). The split is:
//
//    * Models/Host.swift      - MoonlightHost, MoonlightApp, QualityPreset,
//                               HotkeyChord, HostLiveStatus
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
final class MoonlightManager {

    @ObservationIgnored let log = Logger(
        subsystem: "io.ugfugl.Glimmer", category: "MoonlightManager")

    // Hosts
    var hosts: [MoonlightHost] = []
    var selectedHost: MoonlightHost?

    // Stream lifecycle
    var isStreaming = false
    /// Active native session, retained while streaming.
    @ObservationIgnored var nativeSession: StreamSession?

    // Quality
    // Default `.matchDisplay` (panel-native resolution + refresh) - the option
    // shown at the top of the preset list. Users on constrained links can drop
    // to Smooth; an explicit choice is persisted in init() and honored.
    var qualityPreset: QualityPreset = .matchDisplay {
        willSet {
            // When the user switches from a preset to Custom, prefill the custom
            // values with the preset's effective numbers so they're not surprised
            // by a sudden 1920x1080 reset.
            if newValue == .custom && qualityPreset != .custom {
                let snapshot = effectiveValuesForPreset(qualityPreset)
                customWidth = snapshot.width
                customHeight = snapshot.height
                customFPS = snapshot.fps
                customBitrateMbps = max(5, snapshot.bitrateKbps / 1000)
            }
        }
        didSet { persistQualitySettings() }
    }

    // Custom overrides (used only when qualityPreset == .custom)
    var customWidth: Int = 1920 {
        didSet {
            UserDefaults.standard.set(customWidth, forKey: "customWidth")
            autoUpdateCustomBitrate()
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customHeight: Int = 1080 {
        didSet {
            UserDefaults.standard.set(customHeight, forKey: "customHeight")
            autoUpdateCustomBitrate()
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customFPS: Int = 60 {
        didSet {
            UserDefaults.standard.set(customFPS, forKey: "customFPS")
            autoUpdateCustomBitrate()
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customBitrateAuto: Bool = true {
        didSet {
            UserDefaults.standard.set(customBitrateAuto, forKey: "customBitrateAuto")
            if customBitrateAuto { autoUpdateCustomBitrate() }
        }
    }
    var customBitrateMbps: Int = 50 {
        didSet {
            UserDefaults.standard.set(customBitrateMbps, forKey: "customBitrateMbps")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
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
    /// transitional state. See `StreamPhase` for the case set;
    /// `nativeStreamPhase` is a string-typed read shim for UI code that
    /// hasn't migrated to switching on the enum.
    var streamPhase: StreamPhase = .idle

    /// String-typed read shim for code that hasn't migrated to switching
    /// on `streamPhase`. Read-only; writers go through `streamPhase`.
    var nativeStreamPhase: String? {
        switch streamPhase {
        case .idle:                       return nil
        case .connecting(let stage):      return stage
        case .streaming:                  return "Streaming"
        case .disconnecting:              return nil
        case .error:                      return nil
        }
    }

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
    /// line. Persistence contract: MoonlightManager+SessionReceipt.swift.
    var lastSessionReceipt: SessionReceipt?

    /// Always-on route monitor for the SELECTED host (the readiness chip's
    /// quiet bolt / Wi-Fi glyph). Deliberately independent of the gate-on
    /// telemetry probe - see MoonlightManager+HostRoute.swift. Re-pointed by
    /// the launcher via `refreshHostRoute()` as the selection changes.
    let hostRoute = HostRouteMonitor()

    /// Latest reachability + activity snapshot for the selected host. Drives
    /// the HostHero readiness chip ("Ready · 12 ms", "Streaming Helldivers 2",
    /// "Asleep"). `nil` until the first poll completes after selection. Always
    /// keyed by the selected host's id - see `liveStatusForSelected` for the
    /// safe read accessor used by the UI.
    var hostLiveStatus: HostLiveStatus?
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
            // UserDefaults key matches the legacy QuitHotkey typealias so
            // previously-stored chords still decode.
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
    /// Controller-side quit chord - fires the same path as `quitHotkey`
    /// from the keyboard, but driven by a multi-button hold on the
    /// gamepad. Defaults to Options (≡) + L1 + R1 - the menu button isn't held
    /// during action play, so it's awkward to trip mid-game, and (unlike
    /// Moonlight's Start+Select+L1+R1) it needs no Share/Create button, which
    /// macOS doesn't expose on a DualSense. Users who prefer keyboard-only can
    /// pick "None" in Settings.
    var controllerQuitChord: ControllerQuitChord = .startSelectL1R1 {
        didSet {
            UserDefaults.standard.set(controllerQuitChord.rawValue, forKey: "controllerQuitChord")
        }
    }

    /// User-recorded buttons backing the `.custom` quit chord (press the buttons,
    /// we store them - issue #9). Persisted as JSON.
    var customControllerChord: Set<ControllerButton> = MoonlightManager.loadCustomChord() {
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

    /// Shared up-front explanation shown before macOS's Input Monitoring prompt
    /// (both the auto-offer on DualSense connect and the Settings toggle).
    static let rawHIDExplanation =
        "Glimmer will read your DualSense's raw input to access the Options, "
        + "Create/Share, and Mute buttons.\n\nmacOS will then ask for "
        + "\u{201C}Input Monitoring\u{201D} permission. Its dialog says "
        + "\u{201C}keystrokes\u{201D} because that's the same system permission "
        + "- but Glimmer only reads the controller, never your keyboard."

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

    /// Offer the raw-HID feature if a DualSense is connected and the user
    /// hasn't enabled it or been asked. Never interrupts a live stream.
    func maybeOfferRawHID() {
        guard !rawHIDControllerEnabled, !rawHIDPromptAnswered, !isStreaming, !showRawHIDPrompt else { return }
        let hasDualSense = GCController.controllers().contains { $0.productCategory == GCProductCategoryDualSense }
        if hasDualSense { showRawHIDPrompt = true }
    }

    /// "Enable" from the auto-offer: turn it on and mark answered. We do NOT
    /// request the Input Monitoring permission or open System Settings here:
    ///   * `IOHIDRequestAccess` is SYNCHRONOUS and blocks the main thread for
    ///     ~2s while presenting/resolving the TCC prompt; on a live stream that
    ///     stalls the present path and trips the present-stall watchdog (which
    ///     disables the pacer). See DualSenseHID.start()'s note.
    ///   * `NSWorkspace.open(Privacy_ListenEvent)` flashes a System Settings
    ///     window - jarring mid-game.
    /// Both belong only behind an explicit user action in Settings (the
    /// Troubleshooting "Open Settings" button, `RawHIDControl.registerAndOpen`),
    /// off the main thread. Flipping the flag is enough: if the permission is
    /// already granted the raw-HID reader attaches silently via
    /// `ControllerForwarder` (mid-stream) / the input test; if it isn't, the
    /// Troubleshooting pane's permission card guides the user there on their own
    /// schedule. The proactive offer itself is `!isStreaming`-gated
    /// (`maybeOfferRawHID`), so this only runs from the launcher anyway - but we
    /// keep it side-effect-free so it can never block or pop a window.
    func enableRawHIDFromPrompt() {
        rawHIDControllerEnabled = true
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }

    /// "Cancel" from the auto-offer: don't ask again proactively.
    func declineRawHIDPrompt() {
        rawHIDPromptAnswered = true
        showRawHIDPrompt = false
    }

    // Pairing
    var pairingInFlight = false

    /// Typed phase of the in-flight pairing handshake. Drives the PairSheet
    /// banner colour, spinner, and result text. `pairingMessage` is the
    /// String-typed read shim for UI code that hasn't migrated.
    var pairingPhase: PairingPhase = .idle

    // `pairingMessage` (the String shim over `pairingPhase`) lives in MoonlightManager+Pairing.swift.

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
        qualityPreset = Self.persistedRawValue("qualityPreset", QualityPreset.self) ?? qualityPreset
        // Width/height/fps are clamped on read: builds whose Quality pane
        // clamped on Return only could persist out-of-range values via a
        // focus-loss commit (0 self-heals via persistedPositiveInt; 1000 Hz
        // did not). Bounds mirror QualityPane's clamp helpers.
        customWidth = min(max(Self.persistedPositiveInt("customWidth") ?? customWidth, 640), 7680)
        customHeight = min(max(Self.persistedPositiveInt("customHeight") ?? customHeight, 480), 4320)
        customFPS = min(max(Self.persistedPositiveInt("customFPS") ?? customFPS, 30), 240)
        customBitrateMbps = Self.persistedPositiveInt("customBitrateMbps") ?? customBitrateMbps
        customHDR = Self.persistedBool("customHDR") ?? customHDR
        customBitrateAuto = Self.persistedBool("customBitrateAuto") ?? customBitrateAuto
        captureSysKeys = Self.persistedBool("captureSysKeys") ?? captureSysKeys
        streamCoversNotch = Self.persistedBool("streamCoversNotch") ?? streamCoversNotch
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

    // MARK: - Persisted-setting decode helpers
    //
    // Small typed wrappers around UserDefaults so `init()` reads as a flat list
    // of assignments instead of a branch per key. Each returns nil when the key
    // is absent / out of range / undecodable, so the caller keeps the property's
    // declared default - identical to the prior inline `if let` / `if x > 0`.

    /// A positive `Int`, or nil when the key is absent (`integer(forKey:)`
    /// returns 0) or non-positive.
    private static func persistedPositiveInt(_ key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }

    /// A `Bool`, or nil when the key was never written (so the default holds).
    private static func persistedBool(_ key: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Decode a string-backed `RawRepresentable` from its persisted raw value.
    private static func persistedRawValue<T: RawRepresentable>(
        _ key: String, _ type: T.Type
    ) -> T? where T.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    /// JSON-decode a `Codable` from its persisted data blob.
    private static func persistedDecoded<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Decode the persisted stats-overlay custom-row set, or nil when the key is
    /// absent or decodes to an empty set (so the default initial set holds).
    private static func persistedCustomRows() -> Set<StatsRow.Kind>? {
        guard let raw = UserDefaults.standard.array(forKey: "statsOverlayCustomRows") as? [String] else {
            return nil
        }
        let decoded = raw.compactMap(StatsRow.Kind.init(rawValue:))
        return decoded.isEmpty ? nil : Set(decoded)
    }

    // MARK: Mute/restore Mac audio

    /// Pre-mute capture of the system output level. Non-nil doubles as the
    /// did-mute LATCH: the stream-end restore keys off THIS, never the live
    /// toggle - see MoonlightManager+Audio.swift for the full contract.
    @ObservationIgnored var prePausedMacVolume: Float?
}
