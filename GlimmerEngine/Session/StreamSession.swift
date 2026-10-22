// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Shared session policy owns attempts and media lifetime; prepared adapters own native presentation.
// Backend callbacks retain their attempt identity. Frame submission stays on the decoder queue,
// and teardown joins backend workers before releasing the callback bridge.

import Foundation
import os
public actor StreamSession {
    public nonisolated let id: UUID
    public nonisolated var events: AsyncStream<Update> { eventSource.stream }
    package nonisolated let eventSource: SessionEventSource
    package let publicMedia: PreparedMedia?
    package let publicInput: StreamInput?
    package let preparedNetwork: NetworkClient?
    package var publicTerminal = false
    package var publicStarted = false
    package var suppliedRouteMTU: Int?
    package var waitingForVideo = false
    package var attemptID = UUID()
    package var telemetryGeneration: UInt64 = 0
    package let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Session")

    /// UserDefaults key: the leave-hint text its show budget was counted
    /// against. A different text (a rebound chord) starts the budget over.
    package static let leaveHintShownKey = "glimmer.leaveHintShown"

    // Prepared media and native presentation/input hooks are adopted on MainActor during startup.
    package var videoDecoder: VideoDecoder?
    package let audioDecoder: AudioDecoder
    package let services: SessionServices
    package var presentation: SessionPresentation?
    package var input: SessionInputHooks?
    package var network: NetworkClient?

    /// The Sunshine server name for this session (the telemetry `host` label),
    /// latched at the connect-start anchor where `serverInfo` is in scope and
    /// read when the exporter is built a few steps later (the exporter's call
    /// site doesn't carry `serverInfo`).
    package var telemetryServerName: String = ""

    /// The streaming engine this session drives. Injected at construction
    /// behind the `StreamingBackend` protocol so StreamSession, the decoders,
    /// and the input forwarders only ever talk to `self.backend`. The Swift-
    /// native engine (`NativeBackend`) is the only implementation.
    ///
    /// `var`, not `let`: a SILENT RECONNECT (see StreamSession+Reconnect.swift)
    /// swaps in a FRESH `NativeBackend` after the old one's connection died -
    /// `NativeBackend` carries one-shot connection state (and `interrupt()`
    /// latches permanently), so re-`startConnection` requires a new instance.
    /// The swap is actor-isolated; the InputForwarder + VideoDecoder are
    /// re-pointed at the new backend on the MainActor immediately after, so
    /// nothing keeps sending to the dead one.
    package var backend: StreamingBackend

    // The retained session bridge. Created by start(), released by stop()
    // *after* stopConnection() drains the worker threads. See the top-of-file
    // comment for the lifetime contract.
    package var bridge: StreamBridgeContext?
    package var bridgePtr: UnsafeMutableRawPointer?

    // 2 Hz timer that pulls a fresh stats snapshot off the decoder, augments
    // it with the backend's RTT estimate (only valid while the connection is
    // up), and pushes the result into the stats overlay layer. MainActor-bound
    // because the overlay lives on the main actor. Started after the connection
    // is up and torn down at the very start of `stop()` so it can never
    // outlive the connection.
    //
    // `nonisolated(unsafe)` because the timer reference is allocated and
    // invalidated on the main actor (the only thread that may touch a
    // Foundation `Timer`), but the *actor* needs to be able to schedule
    // those mutations via `await MainActor.run { ... }` from within
    // `start()` / `stop()`. The actual mutation only ever runs on the main
    // thread; the `nonisolated(unsafe)` just stops Swift 6 strict
    // concurrency from rejecting the cross-isolation write.

    /// 1 Hz watchdog gated on decoded frames, not bytes, so video the Mac can't decode ends in an error, not a black screen.
    /// Recovery starts at 2s; past 10s, recent ACKs defer teardown while recovery continues, and remote paths may downshift.
    /// Main thread only; the actor schedules mutations through `MainActor.run`.
    package nonisolated(unsafe) var frameWatchdogTimer: Timer?
    /// `uptimeSeconds` the first-frame envelope runs from, re-stamped by
    /// each silent reconnect. Main thread only: written by startFrameWatchdog and
    /// the reconnect's MainActor hop, read by the watchdog's timer closure.
    package nonisolated(unsafe) var frameWatchdogArmedAt: Double = 0
    /// Matches moonlight-common-c's `FIRST_FRAME_TIMEOUT_SEC` in VideoStream.c.
    /// The first frame gets no ACK grace; mid-stream, recent ACKs defer teardown
    /// while recovery continues and remote paths may downshift.
    package static let frameWatchdogTimeout: Double = 10.0
    /// "Reception healthy, decode silent" - at this threshold we log a
    /// public-privacy diagnostic line so the user-visible "black screen"
    /// symptom shows up in the unified log with actionable detail
    /// ("bytes received but no decoded output") before the harder
    /// teardown threshold trips.
    package static let decodeOnlyStallThreshold: Double = 3.0
    /// Latched true once we've logged the "decode silent but reception
    /// healthy" diagnostic for the current stall, so the log doesn't spam
    /// once a second while the host continues to send unparseable data.
    /// Cleared the moment decode resumes (or on teardown).
    ///
    /// `nonisolated(unsafe)` because the watchdog timer (which runs on
    /// the main thread) reads/writes this directly to gate the log line,
    /// while the actor mutates it through `handleDecodeOnlyStall` /
    /// `clearDecodeOnlyStallLatch`. A bare-Bool load/store is naturally
    /// atomic on every supported arch; a stale read at worst skips one
    /// diagnostic line or emits one extra, neither of which is a
    /// correctness issue for a rate-limited log.
    package nonisolated(unsafe) var didLogDecodeOnlyStall = false

    /// Decode silent for this long starts the keyframe nudges (DecodeStallNudge): a PC that paused video
    /// across a Windows sign-in or desktop switch resumes only when asked for a keyframe.
    package static let decodeStallRecoveryThreshold: Double = 2.0
    /// Latched once per stall episode so the recovery IDR-request logs once
    /// (the request itself is coalesced on the control channel). Cleared when
    /// decode resumes. Same bare-Bool `nonisolated(unsafe)` rationale as
    /// `didLogDecodeOnlyStall`.
    package nonisolated(unsafe) var didAttemptStallRecovery = false
    /// The current stall's keyframe schedule; a fresh one per stall via `resetStallLatches`.
    package var stallNudge = DecodeStallNudge()
    /// Video packet total and uptime when the current stall was first logged, for the hold line's rate.
    package var stallStartPackets: (total: UInt64, uptime: Double)?
    /// One reconnect per stall for packets that arrive but never decode; cleared once a frame decodes.
    package var didReconnectForDecodeStall = false

    /// ENet ACK-silence below which the control link is UNAMBIGUOUSLY alive, so
    /// a video stall is the host pausing the encoder (a Windows sign-in /
    /// secure-desktop transition - Sunshine can't capture the secure desktop -
    /// or a mode switch), NOT a dead connection. The control loop pings every
    /// 100ms and the host ACKs each one, so a live link reads single-digit-ms
    /// here; 5s is half ENet's `ackSilenceDeadMs` (10s) dead-peer timeout and
    /// never occurs on a healthy link. When `enetHealth().sinceLastAckMs` is
    /// under this, the frame watchdog HOLDS instead of tearing down: it keeps
    /// requesting IDRs and waits for the desktop to return, matching moonlight,
    /// which terminates on connection loss - not on a video stall alone.
    /// Teardown for a genuinely-gone host is owned by ENet's own dead-peer
    /// detection (`EnetControlChannel+ControlLoop`, `onTerminated(-1)`).
    package static let enetAliveHoldThresholdMs: UInt32 = 5000
    /// Latched once per stall episode so the "holding for recovery" notice logs
    /// once rather than every second while we ride out a long sign-in. Cleared
    /// when decode resumes (`clearDecodeOnlyStallLatch`). Same bare-Bool
    /// `nonisolated(unsafe)` rationale as `didLogDecodeOnlyStall`.
    package nonisolated(unsafe) var didLogWatchdogHold = false

    // MARK: - Silent reconnect (host closed a live session - see +Reconnect)

    /// The host TERMINATION code that means "the server tore THIS session down"
    /// (NVST_DISCONN_SERVER_TERMINATED_CLOSED). Sunshine sends it when its
    /// process restarts across a Windows lock / secure-desktop transition (it
    /// comes back in ~3s) - and a brief network blip surfaces the same way. When
    /// we'd already reached a LIVE state, this is recoverable: hold the frozen
    /// frame and silently re-establish, rather than bouncing to the launcher.
    /// Stored signed (the inbound parser hands us a signed Int32).
    package static let recoverableTerminationCode: Int32 = Int32(bitPattern: 0x80030023)
    /// Termination codes recoverable on a LIVE session (silent reconnect, not a
    /// launcher bounce): SERVER_TERMINATED_CLOSED + GRACEFUL_TERMINATION - both come
    /// back in seconds. The dead-peer self-terminate (-1) is handled separately.
    package static let recoverableTerminationCodes: Set<Int32> = [
        Int32(bitPattern: 0x80030023), Int32(bitPattern: 0x80030013)
    ]
    /// Our OWN ENet dead-peer code (declarePeerDead): ACK silence, a failed control socket or receive,
    /// or a host ENet DISCONNECT. Recoverable ONLY after live state (link loss or blip); a -1 before
    /// live is a failed connect and falls through to honest teardown.
    package static let deadPeerTerminationCode: Int32 = -1
    /// Bound the reconnect episode: at most this many attempts...
    package static let reconnectAttemptCap = 5
    /// ...and at most this much awake time before we give up and tear down. A
    /// lid closed mid-episode doesn't spend it (see ReconnectBudget).
    package static let reconnectWindowSeconds: TimeInterval = 30.0
    /// How long a PC-sent terminate waits on /serverinfo to learn whether the PC
    /// ended the session on purpose. No answer in time means reconnect.
    package static let hostEndProbeSeconds: TimeInterval = 1.5
    /// Sunshine's NVST_DISCONN_SERVER_VFP_PROTECTED_CONTENT and
    /// NVST_DISCONN_SERVER_VIDEO_ENCODER_CONVERT_INPUT_FRAME_FAILED (moonlight-common-c ControlStream.c).
    package static let protectedContentTerminationCode = Int32(bitPattern: 0x800E_9302)
    package static let frameConversionTerminationCode = Int32(bitPattern: 0x800E_9403)

    // MARK: - Launch deadline (M6)

    /// Overall wall-clock cap on the initial-connect launch path
    /// (`launchWithBusyRecovery`). Without it the busy-recovery retries stack to
    /// ~55-65s of "Connecting...". 22s leaves room for one full /launch leg
    /// (NetworkClient.launchTimeout = 20s) plus the host-idle poll, but bounds the
    /// stack so the launcher bounces back honestly instead of hanging.
    package static let launchOverallDeadlineSeconds: TimeInterval = 22.0

    /// True once this session reached a LIVE state (`.connectionEstablished`).
    /// Gates reconnect: a terminate BEFORE we ever went live is a failed connect,
    /// not a recoverable interruption. Set on the established edge; never reset on
    /// a reconnect (only a full `stop()` ends the session).
    package var reachedLiveState = false
    /// True while a reconnect episode is being driven. Makes the frame/present
    /// watchdogs go quiet (the episode owns the bounded retry/give-up, not the
    /// watchdog) and makes `handleHostTerminate` ignore re-entrant terminates
    /// fired by the dead/old backend mid-reconnect.
    package var isReconnecting = false
    /// Attempt counter for the current reconnect episode.
    package var reconnectAttempts = 0
    /// The last attempt's classified failure; a give-up hands it to the launcher so the copy names the fix.
    package var lastReconnectError: StreamError?
    /// The inputs needed to rebuild the connection on a reconnect, captured at
    /// `start()`: the original server (for a fresh NetworkClient), the requested
    /// StreamRequest, and the app id. Nil before a session starts.
    package var reconnectServer: ServerInfo?
    package var reconnectConfig: StreamRequest?
    package var reconnectAppID: Int?
    /// The ask for the route the Mac is on now, read by every reconnect so a
    /// route change mid-session re-derives the bitrate. Nil keeps the start's.
    package var routeAskProvider: (@MainActor @Sendable () -> RouteAsk?)?

    package func setRouteAskProvider(_ provider: @escaping @MainActor @Sendable () -> RouteAsk?) {
        routeAskProvider = provider
    }

    // MARK: - Mid-session bitrate downshift (see BitrateDownshiftController)

    /// Whether the connect-time path probe resolved this session to remote.
    /// Latched in `makeBackendConfig` and re-latched on every reconnect, so a
    /// route that moves mid-session (the tunnel-flap case) is re-judged rather
    /// than inherited. Gates the downshift tier - a LAN that can't carry its own
    /// rate is a different fault.
    package var isRemotePathSession = false
    /// Per-session downshift budget + cooldown.
    package var downshift = BitrateDownshiftController()
    /// Latched so the "why we did NOT downshift" reason logs once per stall
    /// episode rather than once a second. Cleared by `clearDecodeOnlyStallLatch`.
    package var didLogDownshiftDecision = false

    // MARK: - Wake resilience (sleep/wake fast-reconnect - see +Wake)

    /// One bounded post-wake probe, actor-owned and cancelled on completion, stop or a new wake.
    /// Native observer tokens remain in the prepared service adapter.
    package var wakeProbeTask: Task<Void, Never>?
    /// Probe budget multiple of RTT, clamped: budget = clamp(N·RTT, 750ms, 2.5s).
    package static let wakeProbeRttMultiple = 4
    package static let wakeProbeFloorMs: UInt64 = 750
    /// Ceiling so a high-RTT link doesn't probe SLOWER than the ~10s dead-peer
    /// envelope this fast-path exists to beat.
    package static let wakeProbeCeilingMs: UInt64 = 2_500

    /// Present-path self-heal watchdog. Runs at 20 Hz on the main run loop,
    /// INDEPENDENT of the decode-output watchdog above (which is structurally
    /// blind to a stall downstream of VT - a stopped CADisplayLink or a
    /// latched-false `due` gate - because `recordDecodedFrame()` keeps
    /// advancing while the screen is frozen). This watchdog gates on the
    /// pacer's PRESENT-side liveness (last tick + last release + queue depth)
    /// and escalates recovery so the present path can never hard-freeze.
    ///
    /// Same `nonisolated(unsafe)` invariant as the other timers: allocated and
    /// invalidated on the main thread only; the actor schedules those touches
    /// via `await MainActor.run`.
    package nonisolated(unsafe) var presentWatchdogTimer: Timer?
    /// Two-second metric timer forwards jitter and records present-path stalls;
    /// healthy ticks stay at debug level between minute heartbeats.
    package nonisolated(unsafe) var presentMetricTimer: Timer?
    /// Opt-in telemetry exporter (all-interfaces /metrics + NDJSON); nil unless
    /// enabled. See StreamSession+Telemetry.swift for gating + safety.
    package var telemetryExporter: TelemetryExporter?

    // Present-path watchdog tuning constants live with the watchdog logic in
    // StreamSession+Watchdog.swift; the episode/recovery STATE they gate stays
    // here (main-thread only; stored properties can't live in an extension).
    //
    /// Wall-clock when the present path first looked stalled this episode, so the
    /// give-up threshold measures from stall onset, not from last escalation.
    package nonisolated(unsafe) var presentStallSince: CFAbsoluteTime?
    /// Highest recovery stage (0-3) attempted this episode (each runs once).
    package nonisolated(unsafe) var lastPresentRecoveryStage = 0
    /// Wall-clock when stage-3 give-up dropped us to direct enqueue (nil while
    /// paced). While set, the watchdog waits for a healthy window before rebuild.
    package nonisolated(unsafe) var pacingDisabledSince: CFAbsoluteTime?
    /// Count of stage-3 give-ups this session. DIAGNOSTIC ONLY - no budget, gates
    /// nothing (the watchdog never permanently disables anything).
    package nonisolated(unsafe) var pacingGiveUpCount = 0
    /// Main-thread-only clocks for direct recovery attempts and fresh decode without a first present.
    package nonisolated(unsafe) var directPresentStallSince: CFAbsoluteTime?
    package nonisolated(unsafe) var directPresentMissingSince: CFAbsoluteTime?
    /// Wall-clock when the watchdog armed (start, or a re-enable). The startup-
    /// grace window measures from here so it spans the pacer's cadence-lock.
    package nonisolated(unsafe) var presentWatchdogStartedAt: CFAbsoluteTime?
    /// Pacer tick count + link-silent flag from the PREVIOUS watchdog evaluation.
    /// Link-dead requires the count UNCHANGED across two consecutive silent 50ms
    /// ticks (a re-priming CADisplayLink advances totalTicks → no false trip).
    package nonisolated(unsafe) var lastWatchdogTotalTicks: UInt64 = 0
    package nonisolated(unsafe) var sawLinkSilentLastTick = false
    /// Pacer tick/release counts and time from the previous two-second metric
    /// tick derive per-second rates.
    package nonisolated(unsafe) var prevMetricTotalTicks: UInt64 = 0
    package nonisolated(unsafe) var prevMetricTotalReleases: UInt64 = 0
    package nonisolated(unsafe) var prevMetricTime: CFAbsoluteTime = 0
    /// Only the MainActor timer reads and writes this slot; the actor schedules
    /// its setup via MainActor.run, as with presentMetricTimer.
    package nonisolated(unsafe) var lastPresentMetricNoticeTime: CFAbsoluteTime = 0

    // Event emission: the continuation lives on the StreamBridgeContext so
    // C-thread callbacks can yield directly (FIFO, no actor hop, ordering
    // preserved). The actor reads through `bridge?.eventContinuation` for the
    // few sites that need to yield (frame-watchdog timeout, finish on stop).

    // `stop()` closes an aborted connection-flow interval when connection
    // setup fails before `nativeConnectionEstablished()`, keeping the
    // Instruments timeline from showing it as still open.
    package var connectFlowState: OSSignpostIntervalState?
    package let connectFlowSignpostID = OSSignposter.network.makeSignpostID()

    // Controller input does not reset display idle time, so a visible stream
    // needs an assertion. Hidden streams still keep system sleep and App Nap
    // off so pacing and audio survive without a reconnect on wake.

    // End each opaque token once, including when visibility swaps it.
    package var activityHeld = false

    // State. `isStreaming` is written from StreamSession+Lifecycle (teardown) and
    // StreamSession+Callbacks, so it is module-internal rather than private(set);
    // it stays actor-isolated, so external readers still can't race it.
    package var isStreaming = false
    // Set before teardown suspends; overlapping callers await the same work.
    package var stopInProgress = false
    // The first stop's cause this session: a failed connect tells the user's
    // stop from the PC's by it.
    package var stopCause: DisconnectReason?
    package var teardown = SharedTeardown()
    package var takeoverAuthorized = false
    package var ownsHostSession = false
    package var hostSessionClientID: String?
    package var hostSessionAppID: Int?
    package var hostLaunchEpoch = 0
    package var mediaPreparation: Task<SessionMedia, Error>?
    package var initialServerInfoTask: Task<ServerInfo, Error>?
    package var launchTask: Task<LaunchResponse, Error>?
    package var pendingLaunch: Task<LaunchResponse, Error>?

    /// Every Sunshine client and every reconnect's fresh engine come from these, so tests can
    /// answer as the PC; production uses the real client and the native engine.
    package let makeNetwork: @Sendable (ServerInfo) -> NetworkClient
    package let makeBackend: @Sendable () -> StreamingBackend
    package let hostDisposition: StreamHostDisposition
    /// Every watchdog, metric and backoff reads time here, so tests can script it.
    package nonisolated let clock: SessionClock

    package init(hostDisposition: StreamHostDisposition, audioDecoder: AudioDecoder, services: SessionServices,
                 backend: any StreamingBackend,
                 makeNetwork: @escaping @Sendable (ServerInfo) -> NetworkClient,
                 makeBackend: @escaping @Sendable () -> any StreamingBackend,
                 clock: SessionClock = SessionClock(), publicMedia: PreparedMedia? = nil,
                 publicInput: StreamInput? = nil, preparedNetwork: NetworkClient? = nil, events: SessionEventSource = SessionEventSource()) {
        self.id = events.id
        self.attemptID = events.currentAttempt
        self.eventSource = events
        self.publicMedia = publicMedia
        self.publicInput = publicInput
        self.preparedNetwork = preparedNetwork
        self.hostDisposition = hostDisposition
        self.audioDecoder = audioDecoder
        self.services = services
        self.backend = backend
        self.makeNetwork = makeNetwork
        self.makeBackend = makeBackend
        self.clock = clock
    }

    /// Uptime in seconds, the timebase `CACurrentMediaTime` and `systemUptime` share.
    package nonisolated var uptimeSeconds: Double { Double(clock.uptimeNanos()) / 1_000_000_000 }
}

/// The session's time sources. The present watchdog keeps its wall-clock stamps; the rest is uptime.
package struct SessionClock: Sendable {
    package var uptimeNanos: @Sendable () -> UInt64
    package var absolute: @Sendable () -> CFAbsoluteTime
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(uptimeNanos: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 absolute: @escaping @Sendable () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() },
                 sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.uptimeNanos = uptimeNanos
        self.absolute = absolute
        self.sleep = sleep
    }
}
