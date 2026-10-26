// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Observable app state; feature extensions own persistence, input and session orchestration.

import GlimmerEngine
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
    var selectedHost: Host? { didSet { selectionChanged(from: oldValue) } }

    // Stream lifecycle
    var isStreaming = false {
        didSet { launcherController.streamingChanged(isStreaming) }
    }
    @ObservationIgnored let launcherController = LauncherController()
    @ObservationIgnored lazy var launcherArtCache = LauncherArtCache(base: supportBase)
    /// Active native session, retained while streaming.
    @ObservationIgnored var nativeSession: StreamSession?
    /// A command-line launch waiting for its route, before a session exists.
    @ObservationIgnored var pendingCommandStream: PendingCommandStream?
    /// The panel's native mode; tests stand in a display of their own.
    @ObservationIgnored var displayProbe: @MainActor () -> (width: Int, height: Int, fps: Int) = AppModel.mainDisplayMode

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
            // Persist explicit preset changes here. Recomputing for a display
            // change must not rewrite the saved choice.
            settingsDefaults.set(qualityPreset.rawValue, forKey: "qualityPreset")
            persistQualitySettings()
        }
    }

    // Custom overrides (used only when qualityPreset == .custom)
    var customWidth: Int = 1920 {
        didSet {
            settingsDefaults.set(customWidth, forKey: "customWidth")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customHeight: Int = 1080 {
        didSet {
            settingsDefaults.set(customHeight, forKey: "customHeight")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    var customFPS: Int = 60 {
        didSet {
            settingsDefaults.set(customFPS, forKey: "customFPS")
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    // No bitrate knob, by design. A bitrate is a wire budget the app can
    // derive better than a person can guess: `recommendedBitrateMbps` rescales
    // the Moonlight formula onto anchors MEASURED on real hardware, so the
    // number follows resolution and refresh (and, in a window, the capped
    // refresh) on its own. Nothing to persist and nothing to ask - the result
    // is visible in the next-stream summary. See QualityCalculator.
    /// HDR under every preset, on by default; off offers no 10-bit format (SDR).
    var streamHDR: Bool = true {
        didSet {
            settingsDefaults.set(streamHDR, forKey: "streamHDR")
            persistQualitySettings()
        }
    }

    // Defaults
    var leaveGamesRunning = false {
        didSet { settingsDefaults.set(leaveGamesRunning, forKey: "leaveGamesRunning") }
    }
    var activeContinuationFormat: ContinuationFormat?
    var pictureTrial: PictureTrial?
    var endedContinuation: EndedContinuation?
    var nativeStreamTask: Task<Void, Never>?

    var defaultLaunchApp: String = "Desktop" {
        didSet { settingsDefaults.set(defaultLaunchApp, forKey: "defaultLaunchApp") }
    }
    /// Play the stream's sound on the PC instead of this Mac. Read at stream
    /// start (localAudioPlayMode), so a change applies to the next stream.
    var muteMacWhileStreaming: Bool = false {
        didSet { settingsDefaults.set(muteMacWhileStreaming, forKey: "muteMacWhileStreaming") }
    }

    /// Connection lifecycle published from the native engine. Drives the
    /// connect-banner, the StreamButton role, and the ReadinessChip's
    /// transitional state. See `StreamPhase` for the case set.
    var streamPhase: StreamPhase = .idle

    /// Window focus callbacks keep the launcher available while a stream is hidden.
    var nativeStreamBackgrounded: Bool = false

    var nativeStreamError: String?

    /// Coarse kind for the last connect failure, set alongside
    /// `nativeStreamError` so the banner and menu bar can offer a
    /// matching action instead of parsing the message text.
    var nativeStreamErrorKind: StreamErrorKind = .other

    /// The PC the error is about, which a mid-connect switch can leave unselected.
    var nativeStreamErrorHostID: String?

    typealias StreamErrorKind = StreamFailure.Category

    /// Effective HDR-active state from the native engine. True only when the
    /// host signalled HDR mode AND the bitstream is 10-bit AND the Metal
    /// layer is fully configured for PQ (HDR10) EDR output. Drives the "HDR"
    /// chip in the stream UI.
    var nativeHDRActive: Bool = false

    /// The launcher's brief "Stream ended" toast: set by the teardown for a quit, a
    /// PC-side end or a failure, never a cancelled connect, and cleared by the
    /// ContentView toast's own timer. The stream window fades on its own.
    var streamEndedToastVisible: Bool = false

    /// Receipt for the most recently ENDED session - nil when the last
    /// attempt never went live or ran under the stash threshold. Assigned in
    /// the teardown cleanup right before `streamEndedToastVisible` flips so
    /// the toast's first render already carries its "2h 12m · 12 ms median"
    /// line. Persistence contract: AppModel+SessionReceipt.swift.
    var lastSessionReceipt: SessionReceipt?

    /// Always-on route monitor for the SELECTED host (the readiness chip's quiet bolt
    /// or Wi-Fi glyph), independent of the gate-on telemetry probe. Re-pointed from
    /// `selectedHost`'s didSet whenever the route address changes.
    let hostRoute = HostRouteMonitor()
    let streamRoute = HostRouteMonitor(samplingWiFi: false)

    /// Latest reachability + activity snapshot for the selected host. Drives
    /// the launcher's readiness chip ("Ready · 12 ms", "Streaming Helldivers 2",
    /// "Asleep"). `nil` until the first poll completes after selection. Always
    /// keyed by the selected host's id - see `liveStatusForSelected` for the
    /// safe read accessor used by the UI.
    var hostLiveStatus: HostLiveStatus?

    /// Set when a launch would TAKE OVER a session already running on the host
    /// (someone else streaming, not ours). The launcher binds a confirmation
    /// dialog to this; confirming calls `stream(app:on:)`, cancelling clears it.
    /// nil = no takeover pending (the common case streams straight through).
    var pendingTakeover: PendingTakeover?
    @ObservationIgnored var postCommandReply: ([String: String]) -> Void = {
        CommandChannel.post(CommandChannel.reply, $0)
    }
    struct PendingTakeover: Equatable {
        let app: LibraryApp
        let host: Host
        /// nil when the PC runs an app it didn't name.
        let occupantApp: String?
        var occupantID: Int?
        var useScreenSize = false
    }

    // Menu bar (see AppModel+MenuBar): reconnect edge, Stop latch, overlay mirror,
    // Connection Details, the pads, and the launcher's pair sheet (a nil PC pairs a new one).
    var isReconnecting = false
    var menuStopInProgress = false
    var statsOverlayShown = false
    var menuDetails: StreamStatsSnapshot?
    var menuResolution: (width: Int, height: Int)?
    var menuBarControllers: [MenuBarController] = []
    var pairSheetShown = false
    var pairSheetOwner: PairingPresentationOwner?
    @ObservationIgnored weak var pairSheetWindow: NSWindow?
    var launcherMenuAppID: Int?
    /// True from a controller's first launcher command until focus clears.
    var launcherControllerNavigating = false
    var pairSheetHost: Host?
    @ObservationIgnored var menuRefreshTimer: Timer?

    var showStreamStats: Bool = false {
        didSet { settingsDefaults.set(showStreamStats, forKey: "showStreamStats") }
    }

    /// Persist the HUD position and apply it to an active stream.
    var streamStatsCorner: StatsOverlayCorner = .topLeft {
        didSet {
            settingsDefaults.set(streamStatsCorner.rawValue, forKey: "streamStatsCorner")
            if let session = nativeSession {
                let corner = streamStatsCorner
                Task { await session.setStatsOverlayCorner(corner) }
            }
        }
    }

    /// Curated row set for the stats overlay. Fresh installs default to
    /// `.minimal`: frame rate, latency, bitrate and codec.
    /// UserDefaults persistence happens in didSet.
    var statsOverlayPreset: StatsOverlayPreset = .minimal {
        didSet {
            settingsDefaults.set(
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
            settingsDefaults.set(raw, forKey: "statsOverlayCustomRows")
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
                settingsDefaults.set(data, forKey: "statsThresholds")
            }
        }
    }

    var quitHotkey: HotkeyChord = .defaultQuit {
        didSet {
            // Historical UserDefaults key - previously-stored chords still decode.
            if let data = try? JSONEncoder().encode(quitHotkey) {
                settingsDefaults.set(data, forKey: "quitHotkey")
            }
        }
    }
    var statsHotkey: HotkeyChord = .defaultStats {
        didSet { statsHotkey.persistStats(defaults: settingsDefaults) }
    }

    var captureSysKeys: Bool = false {
        didSet { settingsDefaults.set(captureSysKeys, forKey: "captureSysKeys") }
    }
    var streamCoversNotch: Bool = true {
        didSet { settingsDefaults.set(streamCoversNotch, forKey: "streamCoversNotch") }
    }
    var streamUsesFullScreenSpace: Bool = false {
        didSet { settingsDefaults.set(streamUsesFullScreenSpace, forKey: "streamUsesFullScreenSpace") }
    }
    /// The Custom preset's "Show the stream in a window" choice: full screen
    /// (the default) or a normal titled window at Custom's own resolution,
    /// refresh, bitrate and HDR. Only in force under Custom (see
    /// `effectiveDisplayMode`); snapshotted into the StreamConfig at session
    /// start, like `streamCoversNotch`. A windowed stream caps the refresh at
    /// the display, so a flip recomputes the "Your next stream" summary.
    var streamDisplayMode: StreamDisplayMode = StreamDisplayMode.defaultMode {
        didSet {
            settingsDefaults.set(streamDisplayMode.rawValue, forKey: StreamDisplayMode.defaultsKey)
            if qualityPreset == .custom { persistQualitySettings() }
        }
    }
    /// Highest quality (the default) takes the route and radio boosts;
    /// Bandwidth saver keeps the lighter ask. Read at session start.
    var bitrateMode: BitrateMode = BitrateMode.defaultMode {
        didSet { settingsDefaults.set(bitrateMode.rawValue, forKey: BitrateMode.defaultsKey) }
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
                settingsDefaults.set(data, forKey: "releasePointerHotkey")
            }
        }
    }
    /// Mini player chord (default ⌃M): the stream as a small floating panel
    /// over other apps, and back. Read live via a provider like the others.
    var miniPlayerHotkey: HotkeyChord = .defaultMiniPlayer {
        didSet {
            if let data = try? JSONEncoder().encode(miniPlayerHotkey) {
                settingsDefaults.set(data, forKey: "miniPlayerHotkey")
            }
        }
    }
    /// The running stream is showing as the mini player.
    var isMiniPlayer = false
    var controllerQuitChord: ControllerQuitChord { .startSelectL1R1 }
    var customControllerChord: Set<ControllerButton> { [] }

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
    var rawHIDControllerEnabled: Bool = false {
        didSet {
            settingsDefaults.set(rawHIDControllerEnabled, forKey: "rawHIDControllerEnabled")
        }
    }

    /// Reveals the Settings ▸ Diagnostics pane (the single hideable home for the
    /// debug/tuning wires: the Telemetry toggle, the bookmark chord, and the
    /// log/telemetry status line). HIDDEN by default - a normal user never sees it. It's
    /// unhidden by a deliberate option-click on the version line in About (the
    /// Telemetry toggle lives INSIDE this pane, so it can't gate its own reveal -
    /// hence a separate, plainly-debug-only UserDefault). Persisted so a power
    /// user who revealed it keeps it across launches.
    var showDiagnostics: Bool = false {
        didSet {
            settingsDefaults.set(showDiagnostics, forKey: "showDiagnostics")
        }
    }

    /// Opt-in performance telemetry (the gate read by `TelemetryGate.isEnabled`
    /// at stream start). OFF by default; surfaced only in the hidden Diagnostics
    /// pane. Changing it applies on the NEXT stream - the exporter snapshots the
    /// gate when a session starts. Mirrors the raw key `TelemetryGate` reads so
    /// the UI toggle and the engine agree.
    var telemetryEnabled: Bool = false {
        didSet {
            settingsDefaults.set(telemetryEnabled, forKey: "telemetryEnabled")
        }
    }

    /// Drives the one-time auto-offer alert (on the launcher) when a DualSense
    /// is seen and the user hasn't decided yet. Transient.
    var showRawHIDPrompt = false

    /// The generic HID pad waiting for Input Monitoring, and the launcher's
    /// offer for it. Transient (see AppModel+RawHID).
    var hidPermissionPad: HIDGamepadDevice?
    var showHIDPermissionPrompt = false

    /// Whether the user has answered the auto-offer (Enable or Cancel) - so we
    /// only proactively ask once. They can still flip the Settings toggle.
    var rawHIDPromptAnswered: Bool = false {
        didSet {
            settingsDefaults.set(rawHIDPromptAnswered, forKey: "rawHIDPromptAnswered")
        }
    }

    // The raw-HID offer's entry points (maybeOfferRawHID / enableRawHIDFromPrompt /
    // declineRawHIDPrompt) and its explanation copy live in AppModel+RawHID.swift.

    // Pairing
    var pairingAttempt: PairingAttempt?

    /// Typed phase of the in-flight pairing handshake. Drives the PairSheet
    /// banner icon, spinner, and result text.
    var pairingPhase: PairingPhase = .idle

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

    /// Lifecycle changes replace the chip poll through restartHostStatusPolling(),
    /// so every loop observes the sleep pause and any outstanding settle deadline.
    @ObservationIgnored var hostStatusTask: Task<Void, Never>?

    /// Sleep must close control requests before Sunshine inherits a half-open TLS exchange.
    @ObservationIgnored var hostPolling = HostPollingState()
    @ObservationIgnored var wakeWork = WakeWork()
    var hostPollingPausedForSleep: Bool { hostPolling.systemSleeping || hostPolling.displaysSleeping }

    /// Observer tokens registered on `NSWorkspace.shared.notificationCenter`
    /// (sleep/wake live there, not on the default center), kept apart from
    /// `notificationTokens` so each is removed from the center that owns it.
    @ObservationIgnored var workspaceTokens: [NSObjectProtocol] = []

    /// Recent answers hold through two misses; a third publishes Asleep. Selection,
    /// stream teardown and reachable answers reset the streak; activation preserves it.
    @ObservationIgnored var hostUnreachableStreak = 0

    /// Consecutive missed probes before the chip shows Asleep while it holds a fresh
    /// last good status (see `publishUnreachable`). Three ride out a Wi-Fi double blip
    /// or a momentarily busy PC without a false Asleep.
    nonisolated static let asleepProbeThreshold = 3

    /// Wait out Sunshine's /cancel blip and Wi-Fi reassociation after waking.
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
        streamRoute.monitor(address: nil)
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
        for task in hostPolling.readinessTasks.values { task.cancel() }
    }

    init(defaults: UserDefaults = .standard) {
        settingsDefaults = defaults
        hostsDefaults = defaults
        _rawHIDControllerEnabled = defaults.bool(forKey: "rawHIDControllerEnabled")
        _rawHIDPromptAnswered = defaults.bool(forKey: "rawHIDPromptAnswered")
        _telemetryEnabled = defaults.bool(forKey: "telemetryEnabled")
        _showDiagnostics = TelemetryGate.diagnosticsVisible(defaults: defaults)
        // Observation setters can run during initialization. Restore quality's
        // backing storage so entering Custom cannot overwrite saved dimensions
        // before they are read, or persist defaults the user never chose.
        _leaveGamesRunning = defaults.bool(forKey: "leaveGamesRunning")
        _muteMacWhileStreaming = settingsDefaults.bool(forKey: "muteMacWhileStreaming")
        _defaultLaunchApp = settingsDefaults.string(forKey: "defaultLaunchApp") ?? defaultLaunchApp
        _qualityPreset = Self.persistedQualityPreset(defaults: defaults) ?? _qualityPreset
        // Clamp legacy custom values to the bounds used by QualityPane.
        _customWidth = min(max(Self.persistedPositiveInt("customWidth", defaults: defaults) ?? _customWidth, 640), 7680)
        _customHeight = min(max(Self.persistedPositiveInt("customHeight", defaults: defaults) ?? _customHeight, 480), 4320)
        _customFPS = min(max(Self.persistedPositiveInt("customFPS", defaults: defaults) ?? _customFPS, 30), 240)
        _streamHDR = Self.persistedBool("streamHDR", defaults: defaults) ?? streamHDR
        _captureSysKeys = Self.persistedBool("captureSysKeys", defaults: defaults) ?? captureSysKeys
        _streamCoversNotch = Self.persistedBool("streamCoversNotch", defaults: defaults) ?? streamCoversNotch
        _streamUsesFullScreenSpace = Self.persistedBool("streamUsesFullScreenSpace",
            defaults: defaults) ?? streamUsesFullScreenSpace
        // Registered default (GlimmerApp) answers the absent-key case; an
        // unrecognised raw value lands on the default rather than guessing.
        _streamDisplayMode = StreamDisplayMode.persisted(
            rawValue: settingsDefaults.string(forKey: StreamDisplayMode.defaultsKey))
        _bitrateMode = BitrateMode.persisted(rawValue: settingsDefaults.string(forKey: BitrateMode.defaultsKey))
        _releasePointerHotkey = Self.persistedDecoded("releasePointerHotkey", HotkeyChord.self,
            defaults: defaults) ?? releasePointerHotkey
        _miniPlayerHotkey = Self.persistedDecoded("miniPlayerHotkey", HotkeyChord.self,
            defaults: defaults) ?? miniPlayerHotkey
        _showStreamStats = Self.persistedBool("showStreamStats", defaults: defaults) ?? showStreamStats
        _streamStatsCorner = .persisted(defaults: defaults)
        // Missing or unknown overlay preferences keep their declared defaults.
        _statsOverlayPreset = Self.persistedRawValue("statsOverlayPreset", StatsOverlayPreset.self,
            defaults: defaults) ?? statsOverlayPreset
        _statsOverlayCustomRows = Self.persistedCustomRows(defaults: defaults) ?? statsOverlayCustomRows
        _statsThresholds = Self.persistedStatsThresholds(defaults: defaults)
        _quitHotkey = Self.persistedDecoded("quitHotkey", HotkeyChord.self, defaults: defaults) ?? quitHotkey
        _statsHotkey = Self.persistedStatsHotkey(defaults: defaults)
        hostRoute.onLeftWired = { [weak self] in self?.parkAWDLIfStreaming() }
        persistQualitySettings()
    }

    /// How the model reaches a PC and where it keeps paired PCs and their pins.
    /// Production uses the real client, probe and store; tests answer as the PC.
    @ObservationIgnored var makeNetwork: @Sendable (ServerInfo) -> NetworkClient = { NetworkClient(server: $0) }
    @ObservationIgnored var measureRTT: @Sendable (String, Int, Int) async -> HostReachability.Outcome =
        HostReachability.measureRTT
    @ObservationIgnored let settingsDefaults: UserDefaults
    @ObservationIgnored var hostsDefaults: UserDefaults
    @ObservationIgnored var supportBase: URL?

    /// The launch the user last asked for, so Retry repeats exactly that.
    @ObservationIgnored var lastLaunchAttempt: (app: LibraryApp, host: Host)?

    /// Wake on LAN in flight for this PC, and the PC whose last wake failed.
    var wakingHostID: String?
    var wakeFailedHostID: String?

    /// Why the last wake attempt failed, alongside `wakeFailedHostID`.
    var wakeFailureReason: WakeFailureReason?

    enum WakeFailureReason {
        case noAnswer, couldNotSend
    }
}
