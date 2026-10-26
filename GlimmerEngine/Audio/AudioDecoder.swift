// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// OpusDecoder's PCM into a HAL-driven SPSC ring. Stored state lives here,
// since extensions can't hold it; the machinery lives in the AudioDecoder+*.swift
// siblings by topic: engine, decode, meter, prime, route, cushion memory, resampler.

import Foundation
import AVFoundation
import os
public final class AudioDecoder: @unchecked Sendable {
    // The opus + Core Audio CORE state. Non-private (default internal): the
    // lifecycle/recovery and decode extensions above own every path that touches
    // it, and stored properties can't live in extensions.
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Audio")

    /// Decode holds stateLock; graphChanging excludes it while graphChangeLock serializes maintenance.
    /// Meter state has its own leaf lock. Render callbacks acquire no locks.
    /// These domains protect the class's unchecked Sendable state.
    let stateLock = NSLock()
    let graphChangeLock = NSLock()
    // Admission flag under stateLock; graphChangeLock serializes maintenance while decode admission is closed.
    var graphChanging = false
    var pcmPool: AudioPCMBufferPool?
    var silencePool: AudioPCMBufferPool?
    var spliceLease: AudioPCMBufferPool.Lease?
    var renderMonitor: DispatchSourceTimer?
    var renderProgress = AudioRenderProgress()
    // Decode admission or the graph gate guards health; only consumed PCM counts as progress.
    var outputHealth = AudioOutputHealth()
    var receivedAudioPackets: UInt64 = 0
    var renderedAudioFrames: UInt64 = 0
    var outputRecoveryPending = false
    lazy var maintenanceSource = makeMaintenanceSource()
    lazy var linkResolveSource = makeLinkResolveSource()
    var isShutdown = false
    /// True while the PC plays this stream's sound: the ring renders zeros
    /// and the engine keeps running. Guarded by `stateLock`; see `setOutputMuted`.
    var reconnectFadeIn = false
    var outputMuted = false

    var decoder: OpusDecoder?
    /// Interleaved PCM the decoder writes before the demux, reused for every 5 ms packet.
    /// Guarded by `stateLock`, which already serializes decoding.
    var decodeScratch: [Float] = []
    /// Retains the first skipped block until its join is smoothed, under `stateLock`.
    var packetSplice = AudioPacketSplice()
    // Graph objects are accessed only while decode admission or the graph gate is held.
    let platform: AudioPlatform
    var halOutput: AudioOutput? {
        didSet { outputGeneration &+= 1 }
    }
    // Decode admission or the graph gate protects this revision together with halOutput.
    var outputGeneration: UInt64 = 0
    var outputGraphNeedsReconnect = false
    var inputFormat: AVAudioFormat?
    var observedRingFrames: UInt64 = 0
    var observedRingSilence: UInt64 = 0
    var observedRingUnderruns: UInt64 = 0
    var deviceRecoveryStarted: UInt64 = 0
    // Tests replace the OS operation; production builds and starts the complete graph.
    var startOutput: ((AudioDecoder) -> OSStatus)?
    lazy var schedulePlayout: (AVAudioPCMBuffer, Bool, @escaping @Sendable () -> Void) -> Void = { [weak self] in
        self?.enqueuePCM($0, isSilence: $1, completion: $2)
    }
    var channelCount: Int = 2
    var samplesPerFrame: Int = 240                 // 5ms at 48kHz, common GFE/Sunshine config
    var streams: Int = 1
    var coupledStreams: Int = 1
    var mapping: [UInt8] = [0, 1]

    /// Index from Sunshine/GFE source channel order onto the AVAudioFormat
    /// channel order we picked. nil = identity. See `installChannelLayout`.
    var outputReorder: [Int]?

    // Meter work runs on the worker or monitor, never in HAL's callback. Its leaf lock
    // protects cushion policy and counters; the ring publishes consumption through atomics.
    let audioMeterLock = NSLock()
    /// Total input frames copied into the ring; meter accounting stays in the PC sample rate.
    var framesScheduled: UInt64 = 0
    /// Input frames consumed by the render callback, sampled off-thread.
    /// The difference from framesScheduled is ring fill, including resident silence.
    var framesPlayed: UInt64 = 0
    /// Backfill silence inflates fill without advancing RTP media time. Subtract its resident
    /// frames for A/V skew; ring consumption removes them under audioMeterLock.
    var pendingSilenceFrames: UInt64 = 0
    /// Output sample rate (Hz) - set at init so the meter can convert frames↔ms.
    var meterSampleRate: Double = 48_000
    /// Rebase wall time and consumed frames after every drain. Otherwise dead air becomes
    /// a permanent drift step even after the cushion recovers. Guarded by audioMeterLock.
    var driftAnchorNanos: UInt64 = 0
    /// `framesPlayed` captured at `driftAnchorNanos` - the media-played reference for
    /// the current segment. Drift uses (framesPlayed − this) so a re-baseline after a
    /// drain doesn't double-count media already played in an earlier segment.
    var driftAnchorFramesPlayed: UInt64 = 0
    /// Drift-resampler PI state (the loop lives in `driveResampler`,
    /// AudioDecoder+Resampler.swift). `resamplerIntegralPpm` accumulates the
    /// steady host↔Mac clock offset; the applied `resamplerEpsPpm` slews toward the
    /// PI target so the varispeed rate never steps audibly. Guarded by
    /// `audioMeterLock` (publishAudioState drives it from two threads); HELD
    /// (slow-bled, not zeroed) across disengage since the offset survives a drain.
    var resamplerIntegralPpm: Double = 0
    var resamplerEpsPpm: Double = 0
    /// `DispatchTime` ns of the last PI update - `publishAudioState` (hence
    /// `driveResampler`) fires per decoded packet (~200Hz), so the loop rate-limits
    /// itself to ~4Hz off this; drift is ppm-slow and a fast loop only adds noise.
    var lastResamplerUpdateNanos: UInt64 = 0
    /// Cushion release needs a bounded integral and stable recent drift, even when
    /// a correctly compensated clock has accumulated a large offset from wall time.
    /// Both the verdict and its observation window are guarded by `audioMeterLock`.
    var resamplerSkewConverged = false
    var resamplerDriftWindow = ResamplerDriftWindow()
    /// Drift-resampler PI tuning. Conservative starting values: the SLEW limit and the
    /// BOUND are the safety guards (the varispeed rate can never step audibly nor run
    /// away), so the gains can be tuned up in an A/B with no warble risk. The drift to
    /// correct is tens of ppm (host↔Mac clock offset), so ε settles ppm-scale ⇒ pitch
    /// shift well under a cent.
    static let resamplerUpdateIntervalNanos: UInt64 = 250_000_000  // ~4Hz; drift is ppm-slow
    static let resamplerDeadbandMs = 1.0    // ignore sub-ms fill noise (integral anti-windup)
    static let resamplerKpPpmPerMs = 3.0    // proportional: answers transient fill excursions
    static let resamplerKiPpmPerMs = 0.18   // integral: absorbs the steady ppm clock offset (the rate-limiter on convergence)
    static let resamplerSlewPpm = 4.0       // max ppm change per update; 16ppm/s still well under audible pitch step
    static let resamplerBoundPpm = 1500.0   // skew-correction ceiling; real host skews seen ~450ppm, so 500 railed
    /// Per-disengage HOLD factor on the integral - the clock offset survives a
    /// drain, so keep most of it (slow ×0.97 bleed only while packets flow) and
    /// re-engage with it already learned rather than re-converging from 0.
    static let resamplerIntegralHoldFactor = 0.97
    /// True once the loop has run at least one ENGAGED tick this session. The
    /// disengage hold-bleed applies only after this: a pre-roll must not bleed
    /// a persisted per-device skew seed before the loop ever engages with it.
    var resamplerEverEngaged = false
    /// Skew-save window state (audioMeterLock): the last window close and the
    /// last value written, so the memory writes at most ~1/min.
    var lastResamplerSkewSaveNanos: UInt64 = 0
    var lastSavedResamplerSkewPpm: Double = .nan
    /// Skew memory key ("host|device UID", "" = don't persist) and the save
    /// window's mean accumulator over quiet ticks. Guarded by `audioMeterLock`.
    var resamplerSkewMemoryKey = ""
    var resamplerQuietIntegralSumPpm: Double = 0
    var resamplerQuietTicks = 0
    /// Last cushion target the PI loop steered to and when it moved: a setpoint
    /// move holds integration (it isn't skew). Guarded by `audioMeterLock`.
    var resamplerSetpointMs: Double = 0
    var resamplerSetpointMovedNanos: UInt64 = 0
    /// SHALLOW-RELEASE gate: the |integral ppm| ceiling under which the resampler is
    /// deemed to be CARRYING the skew (not railing), so the wired cushion may converge.
    /// Real host skews seen ~450ppm; above ~500 the loop is at/near its rail and the
    /// deep cushion is load-bearing - leave it. (`resamplerBoundPpm` 1500 is the rate
    /// guard; this lower 500 is the "within real envelope" line.)
    static let cushionReleaseSkewPpm = 500.0
    /// Maximum drift change within one cushion quiet window. A compensated
    /// clock can accumulate unlimited absolute drift while its buffer stays full.
    static let cushionReleaseDriftBoundMs = 60.0
    /// Raise before stopping HAL so discarded PCM cannot teach a deeper cushion.
    /// Guarded by audioMeterLock; callback storage remains alive until units are disposed.
    var meterShutdown = false
    /// Lifecycle mirror for telemetry and decode admission, guarded by audioMeterLock.
    /// No HAL query belongs in the meter or render callback.
    var engineRunning = false
    /// True once at least one buffer has been scheduled (gates under-run detection
    /// so the initial empty state isn't an under-run).
    var playoutStarted = false
    /// Latch actual missing-frame edges, not exact exhaustion at a render boundary.
    /// The next scheduled block re-arms the cushion without pausing the render thread.
    var playoutDrained = false
    // (The OVER-RUN ceiling constants are link-aware cushion-cap policy and live in
    // AudioDecoder+CushionMemory; the runtime gate uses `effectiveOverrunCeilingMs`.)

    // Cold startup pre-roll absorbs delivery jitter; drains rebuild via catch-up or bounded silence.
    // Evidence grows depth, quiet windows release it, and trims prevent a standing latency pin.
    // The unchanged policy and its measurement boundaries are documented in docs/AUDIO.md.

    /// Base playout cushion (ms) pre-rolled before playback starts. ≈6 packets at
    /// 5ms; inaudible for non-critical audio yet >> the worst per-event slip and
    /// ~60× the ~0.5ms/5s drift budget at ~100ppm.
    package static let playoutCushionBaseMs: Double = 30
    /// Step (ms) the cushion grows by on each measured under-run - one extra packet-
    /// pair of headroom per real drain, so the cushion converges on what THIS link
    /// needs rather than guessing.
    package static let playoutCushionStepMs: Double = 10
    /// Adaptive-cushion cap (ms) for the WIRED link + the STATIC-context base
    /// (telemetry). The steady-state backlog is TRIMMED back to this, so it is the
    /// worst-case STANDING audio latency; 150ms covers a wired NIC's gaps with
    /// margin. Depth this deep is evidence-keyed (one under-run per +10ms step) AND
    /// temporary (decays after a quiet minute). The RUNTIME cap is LINK-AWARE
    /// (`effectiveCushionMaxMs`): a wifi/tunnel gap envelope is deeper, so a flat
    /// 150ms cap there is a disguised permanent give-up - the ratchet saturates
    /// below the gap and under-runs cascade. Audio is non-critical, so the deeper
    /// cap on a worse link is right. (Tunnel cap `playoutCushionMaxMsTunnel` +
    /// `cushionMaxMs(forLink:)` live in AudioDecoder+CushionMemory.)
    static let playoutCushionMaxMs: Double = 150
    // (Remaining knobs live beside their machinery: the trim/grace/fallback/
    // NOTICE tunables in AudioDecoder+Meter.swift, the decay clock with its
    // arbitration in AudioDecoder+CushionMemory.swift, the PI gains + skew
    // memory in AudioDecoder+Resampler.swift.)
    /// Current adaptive cushion target (ms). Starts at the per-host SEEDED value
    /// (last session's learning; base when none) and grows by `playoutCushionStepMs`
    /// (capped at `effectiveCushionMaxMs`) on under-runs that aren't dead air.
    /// Exported as the `audio_playout_target_ms` gauge (rides the published `AudioState`): fill vs
    /// target is the cushion judge - base 30 / cap 150 wired or 300 tunnel /
    /// ceiling cap+40 - legible only against the target it steers toward.
    var playoutTargetMs: Double = AudioDecoder.playoutCushionBaseMs
    /// LINK-AWARE runtime cushion cap (ms): `cushionMaxMs(forLink:)` - wired 150 /
    /// tunnel|wifi|unknown 300. Resolved at init, re-resolved by `resolveCushionLink`
    /// if the route lands late. The grow ratchet, loss-floor clamp, and over-run
    /// ceiling key off this so a worse link can deepen past the wired cap instead of
    /// cascading under-runs. Defaults deep (like the seed). Guarded by `audioMeterLock`.
    var effectiveCushionMaxMs: Double = AudioDecoder.playoutCushionMaxMsTunnel
    /// LINK-AWARE runtime over-run ceiling (ms) = cap + `bufferOverrunCeilingSlackMs`,
    /// so the backstop tracks the active cap. Guarded by `audioMeterLock`.
    var effectiveOverrunCeilingMs: Double =
        AudioDecoder.playoutCushionMaxMsTunnel + AudioDecoder.bufferOverrunCeilingSlackMs
    /// Cold startup enables ring reads only once the cushion is ready. Mid-stream drains
    /// keep pulling while the existing grace/backfill policy rebuilds headroom.
    var primed = false
    /// Count of buffers scheduled since the last prime/re-prime - drives the
    /// fallback-prime (COLD START only; a re-prime rebuilds via clump or backfill
    /// instead) so silence can't wedge playback un-started.
    var buffersSinceArm: UInt64 = 0
    /// True while the current un-primed episode is a mid-stream RE-prime (the node
    /// kept playing) rather than the cold start (node paused, pre-rolling). Steers
    /// `maybePrime`: cold start keeps its paused pre-roll + buffer-count fallback;
    /// a re-prime gets the grace-then-backfill rebuild - the fallback at 12 buffers
    /// would otherwise declare the rebuild done at ~15ms standing fill regardless
    /// of target (the under-run-cascade bug). Guarded by `audioMeterLock`.
    var rebuildIsReprime = false
    /// `DispatchTime` ns of the most recent steady-state trim - enforces the trim
    /// rate limit. Guarded by `audioMeterLock`. 0 = no trim yet this session.
    var lastTrimNanos: UInt64 = 0
    /// `DispatchTime` ns deadline of the post-(re)prime gate grace: both backlog
    /// gates stand down until this instant. Guarded by `audioMeterLock`.
    var gateGraceUntilNanos: UInt64 = 0
    /// One-shot flag armed by the link resolve when adopting a deeper target
    /// leaves standing fill a step+ short: the next DECODE-path `maybePrime`
    /// tops the cushion up via the silence backfill instead of letting the
    /// host's paced startup inflow teach the deficit through a drain cascade
    /// (~9 audible blips, 2026-07-05). Guarded by `audioMeterLock`; the AV
    /// work stays on the decode path.
    var pendingResolveTopUp = false
    /// Near-miss dip latch (see AudioDecoder+Meter's near-miss thresholds).
    /// Guarded by `audioMeterLock`.
    var nearMissLatched = false
    /// `DispatchTime` ns deadline of the startup floor-learning gate, armed at
    /// the COLD-START prime: drains in the host's boot-ramp window are pacing
    /// artifacts, not link character - letting them teach the floor welded
    /// 180ms in and blocked decay for a whole session. The target ratchet
    /// still applies; only the floor EWMA waits. Guarded by `audioMeterLock`.
    var floorLearnGateUntilNanos: UInt64 = 0
    /// `DispatchTime` ns anchor of the current under-run-free stretch (drives the
    /// cushion decay). Reset on every under-run edge AND on each decay step, so each
    /// 10ms step back down requires its own full quiet window. Guarded by
    /// `audioMeterLock`.
    var quietSinceNanos: UInt64 = 0
    /// `DispatchTime` ns of the last under-run grow (rate limit). Guarded by
    /// `audioMeterLock`.
    var lastCushionGrowNanos: UInt64 = 0
    /// The target the last under-run failed at, and when. A quiet-window walk-down stays a step
    /// above it for the floor's slow decay window. Guarded by `audioMeterLock`.
    var lastFailedTargetMs: Double = 0
    var lastUnderrunNanos: UInt64 = 0
    /// The failed target and longest arrival gap since scheduling last settled evidence.
    /// Arrival may precede drain observation. Guarded by `audioMeterLock`.
    var pendingUnderrunTargetMs: Double?
    var underrunArrivalGapNanos: UInt64 = 0

    // MARK: - P1 AUDIO playout-stall watchdog (the 2026-08-12 overnight wedge)
    //
    // Design narrative + detection/recovery: AudioDecoder+Meter.swift
    // (`noteDropForStallWatchdogLocked` / `recoverIfPlayoutStalled`). Only the
    // stored words live here; ALL guarded by `audioMeterLock`.
    /// `DispatchTime` ns of the last observed playout PROGRESS: stamped on every
    /// buffer completion and on each (re)arm edge - so a legitimately paused
    /// cold pre-roll (armed = freshly stamped) can never read as a stall.
    var lastPlayoutProgressNanos: UInt64 = 0
    /// Latch set by the meter's DROP branches when scheduled audio has consumed
    /// zero frames past the stall threshold while packets keep arriving: the
    /// node stopped pulling (output device slept/vanished), the backlog pinned
    /// above the gates, and every packet then drops forever - received,
    /// decoded, discarded, silent until reconnect. Cleared on the decode path.
    var playoutStallPending = false
    /// `DispatchTime` ns of the last stall-recovery attempt - bounds the
    /// rebuild cadence so a truly dead output device retries, not thrashes.
    var stallRecoveryLastAttemptNanos: UInt64 = 0
    /// Discarded PCM during graph replacement must not count as an underrun.
    /// This meter-lock latch stays raised until the next schedule re-arms playback.
    var meterRecovering = false

    // MARK: - P1 AUDIO cushion LOSS FLOOR + per-host memory (the limit-cycle fix)
    //
    // Design narrative + persistence/seeding: AudioDecoder+CushionMemory.swift.
    // Only the stored words live here (stored properties cannot live in
    // extensions); ALL guarded by `audioMeterLock`.
    /// Learned LOSS FLOOR (ms): EWMA of the cushion target at each under-run -
    /// the level this link has PROVEN it under-runs at. Decay never steps below
    /// floor + one step; the floor itself decays on a slow (~10min) clock so an
    /// improved link re-earns shallow cushions. 0 = unlearned.
    var learnedFloorMs: Double = 0
    /// `DispatchTime` ns anchor of the FLOOR's own decay window - reset on
    /// every under-run edge and on each floor decay step.
    var floorQuietSinceNanos: UInt64 = 0
    /// MIN buffer fill (ms) at completions within the CURRENT decay quiet
    /// window - the near-miss evidence: a trough within one step of empty
    /// holds depth WITHOUT an audible event. Reset (to +inf) on under-run
    /// edges, decay steps, and near-miss holds.
    var quietWindowMinFillMs: Double = .infinity
    /// True once this session took a real under-run edge - the one-shot
    /// link-resolve merge may then only deepen, never shallow, the cushion.
    var cushionHadUnderrun = false
    /// UserDefaults key ("prefix.host|link") the cushion memory persists
    /// under. Set at init from the seed; rewritten once if the link resolves.
    var cushionSeedKey = ""
    /// Resolved link class ("wired"/"wifi"/"tunnel"/"unknown"), cached under
    /// audioMeterLock at resolve time so the RT completion path reads it WITHOUT
    /// nesting EnvSignal's lock under the meter lock.
    var cushionLinkClass = "unknown"
    /// Host half of the seed key, kept so the one-shot link resolve can rebuild
    /// the key without re-reading the route latch.
    var cushionHostLabel = "unknown"
    /// One-shot latch: true once the stream link is resolved (or the resolve
    /// window expired) - the steady-state resolve cost is then one Bool read
    /// under the lock already held.
    var cushionLinkResolved = false
    /// `DispatchTime` ns deadline for link-resolve attempts (the exporter feeds
    /// the route within seconds when telemetry is on; if it never resolves,
    /// learning simply continues under the init key).
    var cushionLinkResolveDeadlineNanos: UInt64 = 0
    /// Human-readable audio OUTPUT route ("<device> [<transport>]"), seeded at
    /// init and refreshed by the default-output-device listener. Carried on the
    /// under-run NOTICE so a drain's trigger class (BT detach, device switch) is
    /// attributable postmortem WITHOUT any CoreAudio/AV call on the completion
    /// thread - it reads a plain cached String. Guarded by `audioMeterLock`.
    var audioRouteCache = "unknown"
    /// `DispatchTime` ns of the last under-run NOTICE actually emitted, and the
    /// count of edges the rate limit swallowed since - carried on the next line
    /// so a cascade stays countable from the log alone. Guarded by
    /// `audioMeterLock`.
    var lastUnderrunNoticeNanos: UInt64 = 0
    var underrunNoticesSuppressed: UInt64 = 0
    /// The default-output-device listener's HALListener key and the queue its handler runs on. Key guarded by
    /// `stateLock`; the handler touches only meter state and Diag.
    let routeListenerQueue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.route", qos: .userInteractive)
    /// Coalesced opt-in snapshots; guarded by stateLock and invalidated with engineRestartGeneration.
    var outputDiagnosticRequests = AudioOutputDiagnosticRequests()
    /// Bounded retry counter for transient route handoffs; guarded by stateLock.
    /// Internal because the ladder lives in AudioDecoder+Engine.swift.
    var engineRestartRetries = 0
    /// Invalidates queued retries across shutdown and re-init; guarded by stateLock.
    var engineRestartGeneration: UInt64 = 0
    static let maxEngineRestartRetries = 5
    /// Delay failed prime-edge retries so packets cannot repeat HAL starts.
    /// Guarded by stateLock; reset for each session.
    var primeEdgeRetryAtNanos: UInt64 = 0
    var primeEdgeFailureStreak = false

    // MARK: - P1 AUDIO playout MIN-fill telemetry
    //
    // The windowed MIN buffer-fill itself lives in `TelemetryCounters` (a
    // reset-on-read window), fed from each completion's trough via
    // `noteAudioBufferFill`; the 1Hz `bufferFillMs` gauge is last-writer-wins and
    // can miss the instantaneous low that precedes an under-run, so the min is the
    // field that PROVES the cushion holds above 0. Only the re-prime count is kept
    // here (it's part of the published `AudioState` gauge).
    //
    /// RE-PRIME count this session: the number of pre-roll RE-ARM edges - the
    /// state machine dropping back to un-primed after a full drain. NOT a count of
    /// paused wall-time pre-rolls (the node keeps playing across a re-arm; the
    /// cushion rebuilds via the catch-up clump or the grace-expiry silence
    /// backfill). Surfaced as `audio_reprime_total` so a full-drain event is
    /// directly countable alongside `audio_underrun_total`.
    var rePrimeCount: UInt64 = 0

    let defaults: UserDefaults

    public init(platform: AudioPlatform, defaults: UserDefaults = .standard) {
        self.platform = platform
        self.defaults = defaults
    }

    // Lifecycle canary: every session's decoder should log this after it ends.
    deinit {
        Diag.notice("audio decoder \(logID) released", "Stream.Audio")
    }
}
