//
//  StreamSession.swift
//
//  Top-level orchestrator for a streaming session. Holds one native-backend
//  connection lifetime, owns the decoder/audio/input/window subsystems, and
//  emits a stream of `StreamEvent` values to the UI.
//
//  Threading model:
//   - Public API is actor-isolated.
//   - Backend callbacks fire on the native backend's receive threads. We
//     marshal each one back into the actor via Task { await self.handle… }.
//   - Video frame submission stays off the actor for latency reasons —
//     VideoDecoder owns its own internal queue.
//
//  Callback bridging — read this before adding callbacks:
//   The native backend calls back into us on its RTP/control receive threads.
//   Rather than maintain three independent "active X" globals — one per
//   subsystem — we route every callback through a single `StreamBridgeContext`
//   instance:
//     * `Unmanaged.passRetained(bridge).toOpaque()` produces the opaque pointer
//       retained for the connection lifetime, so context-aware callbacks
//       dereference it directly.
//     * `StreamBridgeContext.current` is a weak static set on init / cleared
//       on dealloc so context-less callbacks can find the bridge.
//     * The bridge holds *weak* references to the session and each subsystem.
//       If a subsystem is torn down, the weak ref nils out and the callback
//       no-ops — no UAF, no order dependency.
//   The bridge is released in `stop()` only after the backend has stopped
//   (which drains the receive threads), making it impossible for a backend
//   thread to dereference a freed Swift object.

import Foundation
import AppKit
import os
public actor StreamSession {
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Session")

    // Subsystems. VideoDecoder/StreamWindow/InputForwarder are MainActor-bound,
    // so they're lazily created on the main actor in start().
    var videoDecoder: VideoDecoder?
    let audioDecoder = AudioDecoder()
    var window: StreamWindow?

    /// Bring the stream window back from the background. Used by the
    /// launcher UI's "Back to stream" affordance when the user has
    /// Cmd-Tabbed away (which orderOut'd the window) and now wants to
    /// resume.
    public func resumeWindow() async {
        // Capture the StreamWindow reference on the actor first (it lives
        // here, isolated to us), then hop to the main actor to touch
        // AppKit. Reaching into `self.window` from inside MainActor.run
        // would cross actor boundaries.
        let win = self.window
        await MainActor.run {
            // First bring the app forward — makeKeyAndOrderFront only makes a
            // window key if its app is active, and the menubar/launcher click
            // that drives this path may have left a different app frontmost.
            NSApp.activate()
            win?.window.makeKeyAndOrderFront(nil)
            // Then re-engage the foreground state EXPLICITLY. This is the fix
            // for the menubar-return cursor bug: unlike the Cmd-Tab path, this
            // path does not reliably re-fire `didBecomeKey` (the launcher
            // window is already key when the user clicks "Back to stream", and
            // ordering the stream window front from an already-active app can
            // resolve key status synchronously without posting a fresh
            // notification), so the cursor-hide latch that didBecomeKey
            // re-engages was being skipped — leaving the macOS cursor drawn
            // over the fullscreen stream. `reengageForeground()` is the same
            // method the didBecomeKey observer calls, so both return paths are
            // now identical; it is idempotent (the cursor-hide latch is capped
            // at 1) so the extra call is harmless if didBecomeKey DID fire.
            win?.reengageForeground()
        }
    }
    var input: InputForwarder?
    var network: NetworkClient?

    /// The Sunshine server name for this session (the telemetry `host` label),
    /// latched at the connect-start anchor where `serverInfo` is in scope and
    /// read when the exporter is built a few steps later (the exporter's call
    /// site doesn't carry `serverInfo`).
    var telemetryServerName: String = ""

    /// The streaming engine this session drives. Injected at construction
    /// behind the `StreamingBackend` protocol so StreamSession, the decoders,
    /// and the input forwarders only ever talk to `self.backend`. The Swift-
    /// native engine (`NativeBackend`) is the only implementation.
    ///
    /// `var`, not `let`: a SILENT RECONNECT (see StreamSession+Reconnect.swift)
    /// swaps in a FRESH `NativeBackend` after the old one's connection died —
    /// `NativeBackend` carries one-shot connection state (and `interrupt()`
    /// latches permanently), so re-`startConnection` requires a new instance.
    /// The swap is actor-isolated; the InputForwarder + VideoDecoder are
    /// re-pointed at the new backend on the MainActor immediately after, so
    /// nothing keeps sending to the dead one.
    var backend: StreamingBackend

    // The retained session bridge. Created by start(), released by stop()
    // *after* stopConnection() drains the worker threads. See the top-of-file
    // comment for the lifetime contract.
    var bridge: StreamBridgeContext?
    var bridgePtr: UnsafeMutableRawPointer?

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
    nonisolated(unsafe) var statsOverlayTimer: Timer?

    /// 1 Hz watchdog. Gates on `VideoDecoder.secondsSinceLastDecodedFrame()`
    /// — "did the user see a frame?" — NOT byte reception. A host sending
    /// packets we can't decode (corrupt bitstream, missing IDR, AV1-on-
    /// no-AV1-hardware) is the user-reported "black screen, no error"
    /// case; a reception-gated watchdog would silently keep the session
    /// alive because bytes are arriving.
    ///
    /// Two thresholds:
    ///   - frameWatchdogTimeout: decode silent for this long → log + tear
    ///     down (connection is dead from the user's point of view).
    ///   - decodeOnlyStallThreshold: decode silent but reception healthy
    ///     → log a public-privacy diagnostic so the "no frames" symptom
    ///     surfaces in the unified log before teardown.
    ///
    /// The protocol's own keepalive can take 10–30s to declare a dead
    /// connection; this fast-paths "host crashed / network dropped /
    /// Sunshine restarted" so the user gets back to the launcher quickly.
    ///
    /// Same `nonisolated(unsafe)` invariant as `statsOverlayTimer`: the
    /// timer is allocated and invalidated on the main thread only; the
    /// actor schedules those touches via `await MainActor.run { ... }`.
    nonisolated(unsafe) var frameWatchdogTimer: Timer?
    /// Matches moonlight-common-c's `FIRST_FRAME_TIMEOUT_SEC` in
    /// VideoStream.c. We reuse the value mid-stream as well: if decode has
    /// been silent for this long, the host is presumed gone or the bit-
    /// stream is unrecoverable, either way we tear down.
    static let frameWatchdogTimeout: Double = 10.0
    /// "Reception healthy, decode silent" — at this threshold we log a
    /// public-privacy diagnostic line so the user-visible "black screen"
    /// symptom shows up in the unified log with actionable detail
    /// ("bytes received but no decoded output") before the harder
    /// teardown threshold trips.
    static let decodeOnlyStallThreshold: Double = 3.0
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
    nonisolated(unsafe) var didLogDecodeOnlyStall = false

    /// Decode silent for this long → start actively trying to RECOVER (request
    /// an IDR each tick to prompt the host to resume the video stream), instead
    /// of waiting passively for the host to come back on its own. This is the
    /// fix for "stream freezes when the host's desktop switches (Windows
    /// sign-in / secure desktop) and stays frozen until you manually reconnect"
    /// (#20): the host pauses video across the switch and needs a keyframe
    /// request to resume — nothing else fires one when reception simply stops.
    /// We nudge from here up to `frameWatchdogTimeout` (the give-up), matching
    /// moonlight's recover-then-terminate behavior. Below the soft/hard
    /// thresholds so recovery is attempted BEFORE either logs/tears down.
    static let decodeStallRecoveryThreshold: Double = 2.0
    /// Latched once per stall episode so the recovery IDR-request logs once
    /// (the request itself is coalesced on the control channel). Cleared when
    /// decode resumes. Same bare-Bool `nonisolated(unsafe)` rationale as
    /// `didLogDecodeOnlyStall`.
    nonisolated(unsafe) var didAttemptStallRecovery = false

    /// ENet ACK-silence below which the control link is UNAMBIGUOUSLY alive, so
    /// a video stall is the host pausing the encoder (a Windows sign-in /
    /// secure-desktop transition — Sunshine can't capture the secure desktop —
    /// or a mode switch), NOT a dead connection. The control loop pings every
    /// 100ms and the host ACKs each one, so a live link reads single-digit-ms
    /// here; 5s is half ENet's `ackSilenceDeadMs` (10s) dead-peer timeout and
    /// never occurs on a healthy link. When `enetHealth().sinceLastAckMs` is
    /// under this, the frame watchdog HOLDS instead of tearing down: it keeps
    /// requesting IDRs and waits for the desktop to return, matching moonlight,
    /// which terminates on connection loss — not on a video stall alone (#20).
    /// Teardown for a genuinely-gone host is owned by ENet's own dead-peer
    /// detection (`EnetControlChannel+ControlLoop`, `onTerminated(-1)`).
    static let enetAliveHoldThresholdMs: UInt32 = 5000
    /// Latched once per stall episode so the "holding for recovery" notice logs
    /// once rather than every second while we ride out a long sign-in. Cleared
    /// when decode resumes (`clearDecodeOnlyStallLatch`). Same bare-Bool
    /// `nonisolated(unsafe)` rationale as `didLogDecodeOnlyStall`.
    nonisolated(unsafe) var didLogWatchdogHold = false

    // MARK: - Silent reconnect (host closed a live session — see +Reconnect)

    /// The host TERMINATION code that means "the server tore THIS session down"
    /// (NVST_DISCONN_SERVER_TERMINATED_CLOSED). Sunshine sends it when its
    /// process restarts across a Windows lock / secure-desktop transition (it
    /// comes back in ~3s) — and a brief network blip surfaces the same way. When
    /// we'd already reached a LIVE state, this is recoverable: hold the frozen
    /// frame and silently re-establish, rather than bouncing to the launcher.
    /// Stored signed (the inbound parser hands us a signed Int32).
    static let recoverableTerminationCode: Int32 = Int32(bitPattern: 0x80030023)
    /// Bound the reconnect episode: at most this many attempts…
    static let reconnectAttemptCap = 5
    /// …and at most this long wall-clock before we give up and tear down.
    static let reconnectWindowSeconds: TimeInterval = 30.0

    /// True once this session reached a LIVE state (`.connectionEstablished`).
    /// Gates reconnect: a terminate BEFORE we ever went live is a failed connect,
    /// not a recoverable interruption. Set on the established edge; never reset on
    /// a reconnect (only a full `stop()` ends the session).
    var reachedLiveState = false
    /// True while a reconnect episode is being driven. Makes the frame/present
    /// watchdogs go quiet (the episode owns the bounded retry/give-up, not the
    /// watchdog) and makes `handleHostTerminate` ignore re-entrant terminates
    /// fired by the dead/old backend mid-reconnect.
    var isReconnecting = false
    /// Attempt counter + deadline for the current reconnect episode.
    var reconnectAttempts = 0
    /// The inputs needed to rebuild the connection on a reconnect, captured at
    /// `start()`: the original server (for a fresh NetworkClient), the requested
    /// StreamConfig, and the app id. Nil before a session starts.
    var reconnectServer: ServerInfo?
    var reconnectConfig: StreamConfig?
    var reconnectAppID: Int?

    /// Present-path self-heal watchdog. Runs at 20 Hz on the main run loop,
    /// INDEPENDENT of the decode-output watchdog above (which is structurally
    /// blind to a stall downstream of VT — a stopped CADisplayLink or a
    /// latched-false `due` gate — because `recordDecodedFrame()` keeps
    /// advancing while the screen is frozen). This watchdog gates on the
    /// pacer's PRESENT-side liveness (last tick + last release + queue depth)
    /// and escalates recovery so the present path can never hard-freeze.
    ///
    /// Same `nonisolated(unsafe)` invariant as the other timers: allocated and
    /// invalidated on the main thread only; the actor schedules those touches
    /// via `await MainActor.run`.
    nonisolated(unsafe) var presentWatchdogTimer: Timer?
    /// 2 Hz NOTICE-level instrumentation timer: logs the present/decode-path
    /// liveness (pacer tick rate, last-release age, queue depth, decode-output
    /// rate) so a recurrence of the freeze is pinpointed from the log alone.
    nonisolated(unsafe) var presentMetricTimer: Timer?
    /// Opt-in telemetry exporter (all-interfaces /metrics + NDJSON); nil unless
    /// enabled. See StreamSession+Telemetry.swift for gating + safety.
    var telemetryExporter: TelemetryExporter?

    // Present-path watchdog tuning constants live with the watchdog logic in
    // StreamSession+Watchdog.swift; the episode/recovery STATE they gate stays
    // here (main-thread only; stored properties can't live in an extension).
    //
    /// Wall-clock when the present path first looked stalled this episode, so the
    /// give-up threshold measures from stall onset, not from last escalation.
    nonisolated(unsafe) var presentStallSince: CFAbsoluteTime?
    /// Highest recovery stage (0–3) attempted this episode (each runs once).
    nonisolated(unsafe) var lastPresentRecoveryStage = 0
    /// Wall-clock when stage-3 give-up dropped us to direct enqueue (nil while
    /// paced). While set, the watchdog waits for a healthy window before rebuild.
    nonisolated(unsafe) var pacingDisabledSince: CFAbsoluteTime?
    /// Count of stage-3 give-ups this session. DIAGNOSTIC ONLY — no budget, gates
    /// nothing (the watchdog never permanently disables anything).
    nonisolated(unsafe) var pacingGiveUpCount = 0
    /// Wall-clock when the DIRECT (no-pacer) present path first looked frozen
    /// (decode healthy, present clock stalled); nil while healthy or paced.
    /// Latches one recovery per episode — see `tickDirectPresentWatchdog`. The
    /// detector the direct path lacked.
    nonisolated(unsafe) var directPresentStallSince: CFAbsoluteTime?
    /// Wall-clock when the watchdog armed (start, or a re-enable). The startup-
    /// grace window measures from here so it spans the pacer's cadence-lock.
    nonisolated(unsafe) var presentWatchdogStartedAt: CFAbsoluteTime?
    /// Pacer tick count + link-silent flag from the PREVIOUS watchdog evaluation.
    /// Link-dead requires the count UNCHANGED across two consecutive silent 50ms
    /// ticks (a re-priming CADisplayLink advances totalTicks → no false trip).
    nonisolated(unsafe) var lastWatchdogTotalTicks: UInt64 = 0
    nonisolated(unsafe) var sawLinkSilentLastTick = false
    /// Pacer tick/release counts + time at the previous metric tick, so the 2 Hz
    /// instrumentation derives per-second rates.
    nonisolated(unsafe) var prevMetricTotalTicks: UInt64 = 0
    nonisolated(unsafe) var prevMetricTotalReleases: UInt64 = 0
    nonisolated(unsafe) var prevMetricTime: CFAbsoluteTime = 0

    // Event emission: the continuation lives on the StreamBridgeContext so
    // C-thread callbacks can yield directly (FIFO, no actor hop, ordering
    // preserved). The actor reads through `bridge?.eventContinuation` for the
    // few sites that need to yield (frame-watchdog timeout, finish on stop).

    // OSSignpost interval state for the connection-flow timing. We open
    // this right before startConnection and close it from
    // `handleConnectionEdge(.connectionEstablished)` — the first stable-
    // connection callback. If the connection fails before that callback fires,
    // the `stop()` teardown path closes it with an outcome=aborted message so
    // the Instruments timeline never shows a runaway-open interval.
    var connectFlowState: OSSignpostIntervalState?
    let connectFlowSignpostID = OSSignposter.network.makeSignpostID()

    // Power-management + App-Nap-suppression assertion held for the lifetime of
    // a session. Two distinct jobs, both via the one `beginActivity` token:
    //
    //  1) KEEP-AWAKE — `.idleDisplaySleepDisabled` + `.idleSystemSleepDisabled`
    //     keep the Mac (and its display) from dimming/sleeping mid-stream. A game
    //     stream is video the user is watching, but to the OS there's no LOCAL
    //     input/HID activity, so without these the screen dims and sleeps minutes
    //     into a controller-only session.
    //
    //  2) DEFEAT APP NAP — this is the part the two `*SleepDisabled` flags do NOT
    //     do. Per Apple's NSActivityOptions semantics, App Nap is only suppressed
    //     by `.userInitiated` (or `.background` + `.latencyCritical`); the sleep
    //     flags alone keep the screen lit while STILL permitting App Nap to
    //     throttle our timers / run-loop / QoS the moment the stream window is
    //     unfocused, occluded, or on a second display. That throttling slows the
    //     main-run-loop pacing tick (FramePacer.handleTick) so frames back up
    //     faster than they present → backlog overflow → spurious IDR/RFI on a
    //     stream that's perfectly healthy. We add `.userInitiated` to opt the
    //     process out of App Nap and `.latencyCritical` to mark this as the
    //     real-time video work it is, so background / second-monitor streaming
    //     stays at full decode/pace/present priority.
    //
    // `ProcessInfo.beginActivity` is Apple's recommended high-level API (it wraps
    // IOPMAssertion); the returned token must be handed back to `endActivity`
    // exactly once, which `stop()` does. Held as `any` because the concrete type
    // is opaque.
    var powerAssertion: (any NSObjectProtocol)?

    // State. `isStreaming` is written from StreamSession+Lifecycle (teardown) and
    // StreamSession+Callbacks, so it is module-internal rather than private(set);
    // it stays actor-isolated, so external readers still can't race it.
    var isStreaming = false
    // Set the moment stop() begins so re-entrant calls (e.g. quit hotkey +
    // connectionTerminated firing back-to-back, or AsyncStream onTermination
    // racing the explicit stop) early-out before re-entering teardown. The
    // existing `isStreaming` guard is necessary but not sufficient — the
    // first call flips it to false, but the entire teardown is async, so a
    // second call can sneak past it while the backend stop / decoder
    // teardown are still in flight.
    var stopInProgress = false

    /// - Parameter backend: the streaming engine. Defaults to the Swift-native
    ///   engine, the only implementation.
    public init(backend: StreamingBackend = NativeBackend()) {
        self.backend = backend
    }
}
