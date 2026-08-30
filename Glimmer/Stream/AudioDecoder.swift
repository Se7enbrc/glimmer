//
//  AudioDecoder.swift
//
//  Opus → AVAudioEngine. Wraps an OpusMSDecoder and routes the decoded
//  PCM into an AVAudioPlayerNode attached to AVAudioEngine.mainMixerNode.
//  The Swift-native engine drives this through the `NativeAudioSink`
//  conformance (AudioDecoder+Decode.swift).
//
//  This file is the STORED STATE plus its design narrative - stored properties
//  can't live in extensions, so every word the machinery keeps lives here while
//  the machinery itself is split by topic across siblings: the opus/engine
//  lifecycle + mid-stream recovery in AudioDecoder+Engine.swift, the per-packet
//  decode + NativeAudioSink entry points in AudioDecoder+Decode.swift, the
//  playout meter in AudioDecoder+Meter.swift, its pre-roll arbiter in
//  AudioDecoder+Prime.swift, the output-route sampler in AudioDecoder+Route.swift,
//  the cushion loss floor + per-host memory in AudioDecoder+CushionMemory.swift,
//  and the drift-tracking resampler in AudioDecoder+Resampler.swift.

import Foundation
import AVFoundation
import CoreAudio
import os
public final class AudioDecoder: @unchecked Sendable {
    // The opus + AVAudioEngine CORE state. Non-private (default internal): the
    // lifecycle/recovery and decode extensions above own every path that touches
    // it, and stored properties can't live in extensions.
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Audio")

    /// Serializes the opus decoder + AVAudioEngine lifecycle against the
    /// per-sample decode path. `decodeAndPlay` runs on the native audio
    /// receive thread; `shutdown` can be invoked from the `NativeAudioSink`
    /// cleanup AND from `StreamSession.stop()` on the actor. Without this lock a
    /// decode in flight could call `opus_multistream_decode_float` on a decoder
    /// that `shutdown()` is concurrently destroying (use-after-free), and the
    /// AVAudioEngine could be reconfigured from two threads at once. The class
    /// is `@unchecked Sendable` on the strength of this lock.
    let stateLock = NSLock()
    var isShutdown = false

    var decoder: OpaquePointer?                    // OpusMSDecoder*
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    /// Drift-tracking resampler, inserted between `playerNode` and the mixer. A
    /// slew-limited PI loop (`driveResampler`, driven ~1Hz from `publishAudioState`)
    /// steers `rate = 1+ε` to hold buffer fill at the cushion setpoint, cancelling
    /// the steady host↔Mac clock drift continuously - replacing the old
    /// one-directional/clicky silence micro-stretch. ε is ppm-scale (the bound is
    /// ±500ppm = ±0.5 cents, inaudible; the slew limit keeps the pitch from stepping).
    let varispeed = AVAudioUnitVarispeed()
    /// Serial queue for `varispeed.rate` writes — keeps the write (which takes
    /// AVAudio's engine lock) OFF the completion handler, which holds the messenger
    /// lock and would deadlock against teardown's `playerNode.stop()`. Non-private:
    /// `applyVarispeedRate` (the resampler extension) writes through it.
    let varispeedRateQueue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.varispeed-rate")
    var inputFormat: AVAudioFormat?
    /// Last-known engine OUTPUT (hardware) format, captured when the engine
    /// starts. The config-change handler (H3) compares against this to decide
    /// whether the output route's format actually moved (so it reconnects
    /// `varispeed -> mainMixer` only on a real change). Guarded by `stateLock`.
    var lastOutputFormat: AVAudioFormat?
    var channelCount: Int = 2
    var samplesPerFrame: Int = 240                 // 5ms at 48kHz, common GFE/Sunshine config
    var streams: Int = 1
    var coupledStreams: Int = 1
    var mapping: [UInt8] = [0, 1]

    /// Index from Sunshine/GFE source channel order onto the AVAudioFormat
    /// channel order we picked. nil = identity. See `installChannelLayout`.
    var outputReorder: [Int]?

    // MARK: - P1 AUDIO playout telemetry (opt-in; zero-overhead when off)
    //
    // The audio OUTPUT-side signals: buffer level / fill, under-runs, trims,
    // over-runs, and A/V sync drift. All accounting is a handful of integer/double
    // updates per 5ms packet behind a tiny dedicated lock (`audioMeterLock`) - NEVER
    // the decoder's `stateLock` - so the off-thread `scheduleBuffer` completion handler
    // can update the playhead without contending the decode/shutdown path. The
    // published gauge (`TelemetryCounters.setAudioState`) and the always-live
    // under-run/trim/over-run counters are READ only by the exporter when telemetry is
    // on; the per-packet adds are unconditional but sub-microsecond, far below the
    // 5ms audio budget. No allocation, no clock storm on the hot path.
    let audioMeterLock = NSLock()
    /// Total decoded audio frames (samples-per-channel) handed to the player this
    /// session. Incremented on the decode path as each buffer is scheduled.
    var framesScheduled: UInt64 = 0
    /// Total decoded audio frames the player has finished playing this session,
    /// incremented in the scheduleBuffer completion handler (off-thread). The
    /// scheduled-ahead backlog = framesScheduled − framesPlayed.
    var framesPlayed: UInt64 = 0
    /// Corrector-inserted silence frames currently RESIDENT in the buffer
    /// (scheduled but not yet played): the running sum of micro-stretch + backfill
    /// silence, += at each silence schedule and -= at each silence completion.
    /// Subtracted from buffer fill before deriving `av_skew_ms` so the audio
    /// playhead reflects REAL media - inserted silence inflates fill without
    /// advancing the audio RTP position, which otherwise biases the skew toward
    /// "audio late" by exactly the resident silence. Guarded by `audioMeterLock`.
    var pendingSilenceFrames: UInt64 = 0
    /// Output sample rate (Hz) - set at init so the meter can convert frames↔ms.
    var meterSampleRate: Double = 48_000
    /// Wall-clock (`DispatchTime` ns) anchor for the audio-clock-drift metric: the
    /// start of the CURRENT continuous-playout SEGMENT. RE-BASELINED whenever
    /// playout (re)starts after a drain - see `driftAnchorFramesPlayed`. 0 = audio
    /// playout not started yet.
    ///
    /// Why per-segment, not session-monotonic: drift = wall-elapsed − media-played
    /// − buffer-cushion. On an under-run the player drains to empty, so `framesPlayed`
    /// STALLS (no completions fire) while wall time keeps advancing AND the cushion
    /// is 0 - the drain gap would otherwise be folded permanently into drift (a
    /// multi-second step-jump that then pins). Re-baselining both the wall
    /// anchor and the media-played reference at each playout restart makes drift
    /// reflect the CURRENT playout segment's clock slip, not the cumulative drain
    /// gap. (Measurement-only; the drain itself is still counted as an under-run.)
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
    /// METER-LOCK MIRROR of "the resampler is carrying the skew within its real
    /// envelope" - |integral ppm| <= bound AND clock drift bounded. The resampler PI
    /// state lives lockless on the publish path, so the cushion SHALLOW-RELEASE (the
    /// wired floor/target drop) can't read it directly off the completion thread;
    /// `publishAudioState` snapshots this Bool under the lock. False (railing skew) ⇒
    /// the deep cushion is LOAD-BEARING ⇒ leave it alone. Guarded by `audioMeterLock`.
    var resamplerSkewConverged = false
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
    /// a persisted per-host skew seed before the loop ever engages with it.
    var resamplerEverEngaged = false
    /// Skew-save throttle state (audioMeterLock): the last opportunistic
    /// per-host persist, so a stable integral writes at most ~1/min.
    var lastResamplerSkewSaveNanos: UInt64 = 0
    var lastSavedResamplerSkewPpm: Double = .nan
    /// SHALLOW-RELEASE gate: the |integral ppm| ceiling under which the resampler is
    /// deemed to be CARRYING the skew (not railing), so the wired cushion may converge.
    /// Real host skews seen ~450ppm; above ~500 the loop is at/near its rail and the
    /// deep cushion is load-bearing - leave it. (`resamplerBoundPpm` 1500 is the rate
    /// guard; this lower 500 is the "within real envelope" line.)
    static let cushionReleaseSkewPpm = 500.0
    /// SHALLOW-RELEASE gate: the |audio clock drift ms| ceiling under which drift is
    /// "bounded". A converged link reads ~0; a railing resampler sawtooths to -90..-140ms
    /// extremes. 60ms sits clear of converged noise yet well under the rail. Drift
    /// UNKNOWN (pre-anchor) counts as bounded - the ppm gate alone then governs.
    static let cushionReleaseDriftBoundMs = 60.0
    /// Mirror of `isShutdown` in the METER lock's domain, raised by `shutdown()`
    /// BEFORE `playerNode.stop()`. Stopping a node with a standing cushion fires
    /// the completion handler of EVERY queued buffer (.dataConsumed semantics:
    /// consumed OR stopped), and the burst's last completion is indistinguishable,
    /// inside `meterCompleteOnePlayout`, from a real starvation drain. That
    /// handler deliberately never touches `stateLock`, so it cannot read
    /// `isShutdown`; this flag is its only honest view of teardown. Guarded by
    /// `audioMeterLock`.
    var meterShutdown = false
    /// Mirror of `engine.isRunning` for the `glimmer_audio_engine_running` gauge,
    /// set under `audioMeterLock` at engine start (initDecoderCore) and cleared in
    /// shutdown() - so the meter thread reads engine state without touching AVAudio
    /// off-thread. Proves "packets arriving but playout dead" at a glance.
    var engineRunning = false
    /// True once at least one buffer has been scheduled (gates under-run detection
    /// so the initial empty state isn't an under-run).
    var playoutStarted = false
    /// Latch: true while the playout backlog is at zero, so an under-run is counted
    /// once on the EDGE into empty (a true drain) rather than on every completion
    /// that happens to find the queue empty - which at a 1-deep steady queue would
    /// massively over-count. Cleared the next time a buffer is scheduled.
    var playoutDrained = false
    // (The OVER-RUN ceiling constants are link-aware cushion-cap policy and live in
    // AudioDecoder+CushionMemory; the runtime gate uses `effectiveOverrunCeilingMs`.)

    // MARK: - P1 AUDIO playout CUSHION (the under-run fix)
    //
    // Root cause of the under-run cluster: there was NO playout cushion.
    // Each 5ms opus packet was decoded and immediately `play()`ed, so the
    // scheduled-ahead depth sat at ~0-5ms - ON the under-run floor. Any momentary
    // slip (host-vs-Mac clock drift on a ~5s cadence; per-event scheduling jitter
    // under peak high-bitrate video load - NOT CPU saturation) drained it to empty → an
    // audible gap. 0 over-runs / only-ever-drains was the tell.
    //
    // The fix holds a small playout cushion BEFORE starting playback, then lets it
    // run gapless: defer `play()` until a target of decoded audio is queued
    // (a PRE-ROLL), so drift + jitter drain into headroom instead of into a
    // gap. This is audio-only - the latency-critical video path is untouched - and
    // the cushion (~30ms up to the link-aware cap: 150ms wired / 300ms tunnel) is
    // within the non-critical audio budget and under the over-run ceiling (cap+40ms),
    // so audio cannot drift seconds behind. The cushion
    // ADAPTS like the video pacer's jitter buffer: it starts at the base target and
    // grows one step per measured under-run (a full drain), so a link whose delivery
    // gaps outpace the base cushion deepens itself instead of glitching repeatedly.
    // It only grows on real evidence (an under-run), never blanket-deep - and it
    // DECAYS one step per sustained under-run-free window, so depth is a temporary,
    // evidence-keyed state that recovers toward the base, never a permanent pin.
    //
    // The paused pre-roll exists at COLD START only. After a mid-stream drain the
    // node keeps playing - the scheduleBuffer completion path deliberately makes
    // ZERO AV-node calls (it runs unserialized against `shutdown()`; every AV call
    // lives on paths the state lock or the meter-lock-then-call discipline covers)
    // - and the cushion rebuilds via whichever of TWO paths the link offers:
    //   (1) the post-gap CATCH-UP CLUMP - a jittery link delivers the gap's
    //       packets in a burst, and the 250ms gate grace shields that clump from
    //       the trim and the ceiling so it can stack back up to target; or
    //   (2) the grace-expiry SILENCE BACKFILL - on a STEADY link (host-side audio
    //       outage, playback-side drain) packets resume at exactly real-time rate,
    //       no clump ever forms, and standing fill would pin at ~0 while the
    //       target ratchet climbed uselessly (the under-run cascade). When the
    //       grace expires with fill still a step short of
    //       target, the decode path schedules ONE zeroed buffer of (target − fill)
    //       ms so the cushion reaches target immediately (`backfillCushion`): one
    //       deliberate, bounded quiet stretch right behind an already-audible gap
    //       buys the headroom that ends the cascade.
    // The re-prime is a state-machine re-arm, not a wall-time pause.
    //
    // The cap, though, governs only PRE-ROLL - so once steady-state backlog grew (an
    // early under-run deepening the cushion, or receive briefly outrunning playout) it
    // had no trim/decay and PINNED deep (~235ms measured = ~235ms pure A/V lag). The
    // companion fix is a steady-state TRIM-TOWARD-TARGET on the schedule path
    // (`meterRegisterScheduleOrOverrun`): once primed, packets that would hold the
    // backlog a hysteresis band past the cushion target are dropped - rate-limited,
    // and standing down briefly after a re-prime so the post-gap catch-up clump
    // (the cushion rebuild itself) isn't chopped - walking the queue back DOWN to
    // the target. Net: backlog rests near the target (~30ms typical on a clean
    // link; deeper only while gaps recur, decaying back once they stop).
    //
    /// Base playout cushion (ms) pre-rolled before playback starts. ≈6 packets at
    /// 5ms; inaudible for non-critical audio yet >> the worst per-event slip and
    /// ~60× the ~0.5ms/5s drift budget at ~100ppm.
    static let playoutCushionBaseMs: Double = 30
    /// Step (ms) the cushion grows by on each measured under-run - one extra packet-
    /// pair of headroom per real drain, so the cushion converges on what THIS link
    /// needs rather than guessing.
    static let playoutCushionStepMs: Double = 10
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
    /// (capped at `effectiveCushionMaxMs`) on each under-run. Exported as the
    /// `audio_playout_target_ms` gauge (rides the published `AudioState`): fill vs
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
    /// True once `playerNode.play()` has been called (the cold-start pre-roll
    /// fired). Until then buffers are scheduled but the player is paused, building
    /// the cushion. Re-armed (set false) on a full drain - a STATE-MACHINE edge
    /// only: the node keeps playing (the completion path makes no AV calls), so the
    /// re-prime's `play()` is a no-op and the cushion rebuilds via the post-gap
    /// catch-up clump under the gate grace - or, when no clump arrives by grace
    /// expiry, via the one-shot silence backfill - not via a paused pre-roll.
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
    /// True from the recovery's `playerNode.stop()` until the next (re)arm
    /// edge: the completion handler's EVIDENCE gate treats it like
    /// `meterShutdown`, so the stop()-fired completion burst can't mint a
    /// synthetic under-run (ratchet + persisted floor - the
    /// disguised-permanent-pin class).
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
    /// Default-output-device listener block (held so `shutdown()` can remove it -
    /// the HAL requires the same address/queue/block triple) and the utility
    /// queue it fires on. Lifecycle-guarded by `stateLock` (installed at init,
    /// removed at shutdown); the block body touches only `audioMeterLock` state
    /// and Diag, so it can never contend the decode/teardown path.
    var routeListenerBlock: AudioObjectPropertyListenerBlock?
    let routeListenerQueue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.route", qos: .utility)
    /// Bounded retry counter for an engine restart that threw because the new
    /// output device wasn't ready that instant (route handoff). stateLock-guarded.
    /// Non-private with its ceiling: the retry ladder lives in
    /// AudioDecoder+Engine.swift.
    var engineRestartRetries = 0
    static let maxEngineRestartRetries = 5

    /// `AVAudioEngineConfigurationChange` observer token (held so `shutdown()`
    /// can remove it). On a mid-stream output-device/format change AVAudioEngine
    /// STOPS its outputNode; without this, playout goes silent for the rest of
    /// the session. The handler re-resolves + reconnects + restarts the engine on
    /// the `stateLock`-serialized path. Fires on a NOTIFICATION (not a player-node
    /// completion handler), so a node-prop change there is safe - see `handle
    /// EngineConfigurationChange`. Lifecycle-guarded by `stateLock`. Non-private:
    /// the install/remove pair lives in AudioDecoder+Engine.swift.
    var configChangeObserver: NSObjectProtocol?

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

    // MARK: - ★6 Opus in-band FEC on decode (lossy-link resilience)
    //
    // Design narrative + the decode path itself: AudioDecoder+Decode.swift.
    // Only the stored latch lives here (stored properties can't live in
    // extensions).
    /// True while a wire gap is owed exactly one concealment frame, to be minted
    /// by the next real packet (via opus FEC) or the next PLC. Guarded by
    /// `stateLock` (only ever touched on the decode path, which holds it).
    var pendingFecGap = false

    public init() {}
}
