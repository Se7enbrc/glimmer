//
//  AudioDecoder.swift
//
//  Opus → AVAudioEngine. Wraps an OpusMSDecoder and routes the decoded
//  PCM into an AVAudioPlayerNode attached to AVAudioEngine.mainMixerNode.
//  The Swift-native engine drives this through the `NativeAudioSink`
//  conformance below.

import Foundation
import AVFoundation
import CoreAudio
import os
public final class AudioDecoder: @unchecked Sendable {
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Audio")

    /// Serializes the opus decoder + AVAudioEngine lifecycle against the
    /// per-sample decode path. `decodeAndPlay` runs on the native audio
    /// receive thread; `shutdown` can be invoked from the `NativeAudioSink`
    /// cleanup AND from `StreamSession.stop()` on the actor. Without this lock a
    /// decode in flight could call `opus_multistream_decode_float` on a decoder
    /// that `shutdown()` is concurrently destroying (use-after-free), and the
    /// AVAudioEngine could be reconfigured from two threads at once. The class
    /// is `@unchecked Sendable` on the strength of this lock.
    private let stateLock = NSLock()
    private var isShutdown = false

    private var decoder: OpaquePointer?            // OpusMSDecoder*
    private let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    private var inputFormat: AVAudioFormat?
    private var channelCount: Int = 2
    private var samplesPerFrame: Int = 240         // 5ms at 48kHz, common GFE/Sunshine config
    private var streams: Int = 1
    private var coupledStreams: Int = 1
    private var mapping: [UInt8] = [0, 1]

    /// Index from Sunshine/GFE source channel order onto the AVAudioFormat
    /// channel order we picked. nil = identity. See `installChannelLayout`.
    private var outputReorder: [Int]?

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
    /// Media (ms) the drift MICRO-STRETCH has inserted this playout segment to
    /// repay measured clock skew (AudioDecoder+CushionMemory.swift). The drift
    /// gauge stays RAW - each insert credits `driftAnchorFramesPlayed`, the
    /// backfill idiom - so this ledger is what separates skew already repaid
    /// from skew still standing. Reset wherever the drift anchor re-baselines.
    var driftCompAppliedMs: Double = 0
    /// `DispatchTime` ns of the last micro-stretch - its rate limit (the
    /// haywire-gauge bound). Guarded by `audioMeterLock`. 0 = none yet.
    var lastDriftStretchNanos: UInt64 = 0
    /// Mirror of `isShutdown` in the METER lock's domain, raised by `shutdown()`
    /// BEFORE `playerNode.stop()`. Stopping a node with a standing cushion fires
    /// the completion handler of EVERY queued buffer (.dataConsumed semantics:
    /// consumed OR stopped), and the burst's last completion is indistinguishable,
    /// inside `meterCompleteOnePlayout`, from a real starvation drain. That
    /// handler deliberately never touches `stateLock`, so it cannot read
    /// `isShutdown`; this flag is its only honest view of teardown. Guarded by
    /// `audioMeterLock`.
    var meterShutdown = false
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
    // arbitration + the drift micro-stretch in AudioDecoder+CushionMemory.swift.)
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
    /// `DispatchTime` ns anchor of the current under-run-free stretch (drives the
    /// cushion decay). Reset on every under-run edge AND on each decay step, so each
    /// 10ms step back down requires its own full quiet window. Guarded by
    /// `audioMeterLock`.
    var quietSinceNanos: UInt64 = 0

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

    public init() {}

    // MARK: Lifecycle

    /// Shared opus + AVAudioEngine setup, called by the Swift-native path (the
    /// `NativeAudioSink` conformance). Takes plain values, no C types.
    func initDecoderCore(channelCount chCount: Int, sampleRate: Int32,
                         streams strms: Int32, coupledStreams coupled: Int32,
                         samplesPerFrame spf: Int, mapping map: [UInt8]) -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        channelCount = chCount
        samplesPerFrame = spf
        streams = Int(strms)
        coupledStreams = Int(coupled)
        mapping = map

        // P1 AUDIO meter: capture the output sample rate (frames↔ms conversion) and
        // reset the playout accounting for this session. Under the small meter lock,
        // never on the per-packet path. The seed loads BEFORE the lock (UserDefaults
        // + route latch); seeding the target from per-host memory makes the cold
        // pre-roll build last session's learned depth, not re-pay 5-8 startup blips.
        let seed = Self.loadCushionSeed()
        let seedNowNanos = DispatchTime.now().uptimeNanoseconds
        audioMeterLock.lock()
        meterSampleRate = Double(sampleRate)
        framesScheduled = 0; framesPlayed = 0
        driftAnchorNanos = 0; driftAnchorFramesPlayed = 0
        driftCompAppliedMs = 0; lastDriftStretchNanos = 0
        playoutStarted = false; playoutDrained = false; meterShutdown = false
        // Cushion / pre-roll state for this session: start paused (no play() at
        // engine start), at the SEEDED adaptive target, re-prime count reset. (The
        // reset-on-read MIN-fill window lives in TelemetryCounters and is cleared by
        // its own resetForNewSession.) The quiet anchors start NOW: a seeded
        // (elevated) target must earn its first decay window.
        primed = false
        buffersSinceArm = 0
        playoutTargetMs = seed.targetMs
        learnedFloorMs = seed.floorMs
        cushionSeedKey = seed.key
        cushionHostLabel = seed.host
        cushionHadUnderrun = false
        cushionLinkResolved = seed.linkKnown
        cushionLinkResolveDeadlineNanos = seedNowNanos &+ Self.cushionLinkResolveWindowNanos
        // LINK-AWARE caps: seed from the resolved link; `resolveCushionLink`
        // refreshes them if the route lands after bring-up.
        effectiveCushionMaxMs = Self.cushionMaxMs(forLink: seed.link)
        effectiveOverrunCeilingMs = effectiveCushionMaxMs + Self.bufferOverrunCeilingSlackMs
        quietWindowMinFillMs = .infinity
        rePrimeCount = 0
        lastTrimNanos = 0; gateGraceUntilNanos = 0
        quietSinceNanos = seedNowNanos
        floorQuietSinceNanos = seedNowNanos
        rebuildIsReprime = false
        lastUnderrunNoticeNanos = 0; underrunNoticesSuppressed = 0
        audioMeterLock.unlock()
        announceCushionSeed(seed)
        // A/V-skew session edge: the skew store's pair-anchor + accumulator
        // reset here (one audio init per session IS the pair's session edge).
        AudioVideoSkewStore.shared.resetForNewSession()

        var err: Int32 = 0
        decoder = opus_multistream_decoder_create(
            sampleRate,
            Int32(channelCount),
            strms,
            coupled,
            mapping,
            &err
        )
        guard err == OPUS_OK, decoder != nil else {
            log.error("opus_multistream_decoder_create failed: \(err)")
            return -1
        }

        // Sunshine/GFE deliver opus channels in moonlight-common-c's canonical
        // order:  FL, FR, FC, LFE, BL, BR        (5.1)
        //         FL, FR, FC, LFE, BL, BR, SL, SR (7.1)
        // Apple's `kAudioChannelLayoutTag_AudioUnit_5_1` (= MPEG_5_1_A) is
        // L,R,C,LFE,Ls,Rs - that matches the 5.1 order exactly, so no remap.
        // Apple's `kAudioChannelLayoutTag_AudioUnit_7_1` (= MPEG_7_1_C) is
        // L,R,C,LFE,Ls,Rs,Rls,Rrs - channels 4-7 are *paired-swapped*
        // versus Sunshine. Build an explicit reorder table here; the alternative
        // (rewriting `mapping` like moonlight-qt's SLAudio renderer does)
        // bakes assumptions into the opus decoder we don't need.
        outputReorder = nil
        if channelCount == 8 {
            // src index → dst index   (src is Sunshine's order)
            //  0 FL  -> 0 L
            //  1 FR  -> 1 R
            //  2 FC  -> 2 C
            //  3 LFE -> 3 LFE
            //  4 BL  -> 6 Rls
            //  5 BR  -> 7 Rrs
            //  6 SL  -> 4 Ls
            //  7 SR  -> 5 Rs
            outputReorder = [0, 1, 2, 3, 6, 7, 4, 5]
        }

        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag(forChannels: channelCount)) else {
            log.error("AVAudioChannelLayout init failed")
            return -1
        }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(sampleRate),
                                interleaved: false,
                                channelLayout: layout)
        inputFormat = fmt

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: fmt)
        do {
            // Start the engine but DO NOT `play()` the player node yet. Playback is
            // deferred until a `playoutTargetMs` cushion of decoded audio is queued
            // (the pre-roll in `meterRegisterScheduleOrOverrun` / `maybePrime`),
            // so the player starts with headroom instead of on the under-run floor.
            // The node is scheduled-into while paused; `play()` then drains the
            // already-queued cushion gapless.
            try engine.start()
        } catch {
            log.error("AVAudioEngine.start: \(error.localizedDescription)")
            return -1
        }
        // Seed + track the audio OUTPUT route for the under-run breadcrumbs.
        // Installed only after the engine is up, so a failed init never leaves a
        // listener behind; `shutdown()` removes it.
        installAudioRouteListener()
        return 0
    }

    public func shutdown() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown else { return }
        isShutdown = true
        // Quiesce the meter's EVIDENCE machinery BEFORE stopping the node:
        // stop() flushes a completion-handler burst for the standing cushion
        // (6-30 buffers), and un-gated its last completion minted a synthetic
        // under-run on EVERY session end - ratcheting the target +10ms, EWMA-
        // pulling the learned floor, and PERSISTING both per-host, so sub-10-min
        // sessions walked toward the 150ms cap across sessions (the disguised-
        // permanent-pin class). Gate details: `meterCompleteOnePlayout`.
        audioMeterLock.lock()
        meterShutdown = true
        audioMeterLock.unlock()
        playerNode.stop()
        engine.stop()
        removeAudioRouteListener()
        if let decoderPtr = decoder {
            opus_multistream_decoder_destroy(decoderPtr)
            decoder = nil
        }
        // No global to clear here - the StreamBridgeContext holds a weak
        // ref to us; when StreamSession drops its strong reference the bridge
        // sees nil at the next callback (or the bridge itself is released
        // first, which short-circuits earlier).
    }

    // MARK: Per-sample decoding

    // MARK: - ★6 Opus in-band FEC on decode (lossy-link resilience)
    //
    // Opus carries low-bitrate in-band FEC: a frame lost on the wire can be
    // RECONSTRUCTED from the FEC payload the NEXT packet carries, which is
    // higher fidelity than plain PLC (NULL-input concealment) for the same gap.
    // The standard opus PLC-with-FEC pattern is: on a detected gap, when the
    // next real packet arrives, decode it ONCE with `decode_fec=1` at the gap's
    // frame size to recover the missing frame, schedule that, THEN decode the
    // same packet normally with `decode_fec=0` for its own frame.
    //
    // Composition with the existing PLC path: the queue emits a `.lostPlaceholder`
    // per missing data shard, which lands here as `decodeAndPlayPLC()`. Rather
    // than immediately fabricate a NULL-input PLC frame, that call now ARMS a
    // single pending-gap latch (`pendingFecGap`) and produces NO frame yet. The
    // gap frame is then minted EXACTLY ONCE, by whichever resolves first:
    //   • the next REAL packet (`decodeCore`) - FEC recovery (decode_fec=1); if
    //     that packet happens to carry no FEC, opus still returns a concealed
    //     frame for the gap, so we always get one frame, never zero; or
    //   • a SECOND consecutive `decodeAndPlayPLC()` - we can't defer a gap past
    //     one packet without adding latency, so the standing gap is flushed with
    //     a NULL-input PLC frame and the new gap re-arms.
    // Bounded to ONE recovered/concealed frame per gap (no double-count: the
    // latch is cleared the instant the gap frame is scheduled). On a CLEAN link
    // `pendingFecGap` is never armed, so this whole path is inert - `decodeCore`
    // takes the plain `decode_fec=0` branch with zero added work or latency.
    /// True while a wire gap is owed exactly one concealment frame, to be minted
    /// by the next real packet (via opus FEC) or the next PLC. Guarded by
    /// `stateLock` (only ever touched on the decode path, which holds it).
    private var pendingFecGap = false

    /// The shared decode → schedule path for a REAL opus packet. If a wire gap is
    /// pending (`pendingFecGap`), first mint the gap's concealment frame from
    /// THIS packet's opus in-band FEC (`decode_fec=1`) before decoding the packet
    /// itself (`decode_fec=0`) - the standard opus PLC-with-FEC pattern. Used by
    /// the Swift-native `NativeAudioSink` path.
    func decodeCore(input: UnsafePointer<UInt8>?, length: Int32) {
        // Hold the state lock for the whole decode so `shutdown()` can't
        // destroy the opus decoder mid-call. The work is microseconds at
        // 200 Hz on a single audio thread, so the contention cost is nil.
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let decoder, let fmt = inputFormat else { return }

        // `AudioFrame` interval - covers opus decode + scheduleBuffer. One
        // per network-delivered opus packet, on whatever audio receive thread
        // we're called on. Cheap enough at 200 Hz (5 ms packets) that we don't
        // gate it.
        let audioSignpostID = OSSignposter.audio.makeSignpostID()
        let audioIntervalState = OSSignposter.audio.beginInterval(
            "AudioFrame",
            id: audioSignpostID,
            "bytes=\(length, privacy: .public)")
        defer {
            OSSignposter.audio.endInterval("AudioFrame", audioIntervalState)
        }

        // ★6: a gap is owed a frame. Recover it from THIS packet's in-band FEC
        // (decode_fec=1) BEFORE the packet's own frame, so the recovered frame
        // keeps its place in the timeline. One frame per gap; latch cleared
        // either way so it can't double-mint.
        if pendingFecGap {
            pendingFecGap = false
            _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                               input: input, length: length, decodeFec: 1)
        }

        _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                           input: input, length: length, decodeFec: 0)
    }

    /// Decode exactly one opus frame (or conceal one) and, if it produced
    /// samples, demux + meter + schedule it into the player. `decodeFec=1` with a
    /// real `input` recovers the PREVIOUS (lost) frame from this packet's in-band
    /// FEC; `decodeFec=0` decodes the packet's own frame; `input==nil` (length 0)
    /// is NULL-input PLC. Returns true iff a frame was scheduled. Caller holds
    /// `stateLock`.
    @discardableResult
    private func decodeOneFrame(decoder: OpaquePointer, fmt: AVAudioFormat,
                               input: UnsafePointer<UInt8>?, length: Int32,
                               decodeFec: Int32) -> Bool {
        let frameCount = AVAudioFrameCount(samplesPerFrame)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return false }

        // opus_multistream_decode_float writes interleaved float; we declared
        // a non-interleaved format. Use a small interleaved scratch and then
        // demux into channelData[i]. A NULL input + frameSize triggers PLC; a
        // real input with decode_fec=1 reconstructs the prior lost frame.
        var interleaved = [Float](repeating: 0, count: samplesPerFrame * channelCount)
        let decoded = opus_multistream_decode_float(
            decoder, input, length,
            &interleaved, Int32(samplesPerFrame), decodeFec
        )
        guard decoded > 0 else {
            // -1..-7 are recoverable; just drop the packet.
            return false
        }
        pcm.frameLength = AVAudioFrameCount(decoded)

        guard let channelData = pcm.floatChannelData else { return false }
        if let reorder = outputReorder {
            // 7.1 path - swap surround pairs into AVAudio's expected layout.
            for srcChannel in 0..<channelCount {
                let dstChannel = reorder[srcChannel]
                let dst = channelData[dstChannel]
                for i in 0..<Int(decoded) {
                    dst[i] = interleaved[i * channelCount + srcChannel]
                }
            }
        } else {
            for channel in 0..<channelCount {
                let dst = channelData[channel]
                for i in 0..<Int(decoded) {
                    dst[i] = interleaved[i * channelCount + channel]
                }
            }
        }

        // P1 AUDIO meter: account this buffer for the buffer-fill / under-run /
        // over-run / A/V-drift signals. Two backlog guards run first, both dropping
        // this freshly-decoded buffer (which is the NEWEST packet; since an
        // AVAudioPlayerNode buffer can't be pulled once scheduled, declining to queue
        // the incoming packet trims the scheduled-ahead backlog by exactly one 5ms
        // packet - the same net effect as dropping the oldest, with no reschedule
        // churn): (a) the steady-state TRIM-TOWARD-TARGET, which clips the backlog
        // back to the adaptive cushion target so it can't pin high, and (b) the hard
        // OVER-RUN ceiling backstop for genuinely bad links. Both keep latency bounded.
        let decodedFrames = UInt64(decoded)
        if meterRegisterScheduleOrOverrun(frames: decodedFrames) {
            return false  // trimmed/over-run: do not schedule (keeps A/V latency bounded)
        }
        playerNode.scheduleBuffer(pcm, completionHandler: { [weak self] in
            self?.meterCompleteOnePlayout(frames: decodedFrames)
        })
        // PRE-ROLL / RE-PRIME: now that this buffer is queued (into a paused node
        // only before the cold-start prime), decide whether the cushion is deep
        // enough to (re)declare playback primed - and, on a re-prime whose grace
        // expired clumpless, schedule the silence backfill (which needs the node
        // format, hence the parameter). No-op once primed, so this stays one lock
        // + a compare on the steady-state path.
        maybePrime(format: fmt)
        // Deterministic clock-skew repayment (the measured −40ppm drain): DECODE
        // path only - it schedules into the node, which must stay serialized
        // against `shutdown()`. Design + gates: AudioDecoder+CushionMemory.swift.
        driftMicroStretch(format: fmt)
        publishAudioState()
        return true
    }

    /// ★6: a wire gap occurred (the queue emitted a `.lostPlaceholder`). Arm the
    /// pending-gap latch so the NEXT real packet recovers this frame via opus
    /// in-band FEC. If a gap is ALREADY pending (a second consecutive loss), we
    /// can't defer further without adding latency, so flush the standing gap with
    /// a NULL-input PLC frame now and re-arm for this one. Caller is the
    /// `NativeAudioSink` PLC entry point. Holds `stateLock` for the decoder.
    func concealGap() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let decoder, let fmt = inputFormat else { return }
        if pendingFecGap {
            // Two gaps in a row: the first can't wait for FEC any longer. Conceal
            // it with NULL-input PLC, then this new gap takes the pending slot.
            _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                               input: nil, length: 0, decodeFec: 0)
        }
        pendingFecGap = true
    }

    private func layoutTag(forChannels channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1
        default: return kAudioChannelLayoutTag_Stereo
        }
    }
}

// MARK: - NativeAudioSink conformance (Swift-native engine)
//
// Lets RtpAudioReceiver feed the AudioDecoder. `initialize` reuses the shared
// opus/engine setup; `decodeAndPlay([UInt8])` runs the shared decodeCore (with
// opus in-band FEC recovery ahead of the packet when a gap is pending, ★6), and
// `decodeAndPlayPLC()` arms the pending-gap latch (`concealGap`) so the gap's
// concealment frame is minted by FEC or, failing that, by NULL-input PLC.
extension AudioDecoder: NativeAudioSink {
    public func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 {
        let chCount = Int(gl_channel_count_from_audio_configuration(audioConfig))
        // ★5 - NEGOTIATED multistream config. The passed `opus` carries the
        // STEREO defaults (RtspHandshakeResult.defaultOpusConfig); the RTSP
        // SETUP-audio response does NOT send an explicit per-channel opus
        // stream layout. As in moonlight-common-c (AudioStream.c's
        // `opusConfigArray`, indexed by the negotiated AudioConfiguration), the
        // host encodes the opus multistream packets per the channel count it was
        // asked for, and the client derives {streams, coupledStreams, mapping}
        // from that same channel count. Feeding the hardcoded stereo
        // {streams:1, coupled:1, mapping:[0,1]} into a 6/8-channel decoder
        // produces inconsistent surround (the bug). Resolve the real config
        // from `chCount` so a 5.1/7.1 stream decodes coherently; stereo is
        // unchanged (config(forChannels:2) == the stereo default).
        let cfg = Self.opusMultistreamConfig(forChannels: chCount, fallback: opus)
        return initDecoderCore(
            channelCount: chCount,
            sampleRate: opus.sampleRate,
            streams: cfg.streams,
            coupledStreams: cfg.coupledStreams,
            samplesPerFrame: Int(opus.samplesPerFrame),
            mapping: cfg.mapping)
    }

    /// Canonical opus MULTISTREAM config (streams / coupledStreams / channel
    /// mapping) for a channel count, mirroring moonlight-common-c's
    /// `opusConfigArray` (AudioStream.c). The host builds its multistream
    /// encoder from the SAME table keyed by the negotiated AudioConfiguration,
    /// so these MUST match byte-for-byte or surround decodes to garbage:
    ///   2ch stereo : streams 1, coupled 1, mapping [0,1]
    ///   6ch  5.1   : streams 4, coupled 2, mapping [0,4,1,5,2,3]
    ///   8ch  7.1   : streams 5, coupled 3, mapping [0,6,1,7,2,3,4,5]
    /// The mapping is the opus surround mapping (which opus stream feeds which
    /// output channel); the front L/R + back/side reorder onto Apple's layout
    /// is a SEPARATE, later step (`outputReorder` in `initDecoderCore`). An
    /// unrecognized channel count falls back to the passed config (the stereo
    /// default), padded/trimmed to the channel count - the prior behavior.
    static func opusMultistreamConfig(
        forChannels channels: Int, fallback: OpusConfig
    ) -> (streams: Int32, coupledStreams: Int32, mapping: [UInt8]) {
        switch channels {
        case 2: return (1, 1, [0, 1])
        case 6: return (4, 2, [0, 4, 1, 5, 2, 3])
        case 8: return (5, 3, [0, 6, 1, 7, 2, 3, 4, 5])
        default:
            // The opus mapping array carries `channels` valid entries; pad/trim
            // the fallback so the core sees a consistent layout.
            var map = fallback.mapping
            if map.count < channels {
                map += [UInt8](repeating: 0, count: channels - map.count)
            }
            return (fallback.streams, fallback.coupledStreams, Array(map.prefix(channels)))
        }
    }

    public func decodeAndPlay(_ opus: [UInt8]) {
        guard !opus.isEmpty else { decodeAndPlayPLC(); return }
        opus.withUnsafeBufferPointer { buf in
            decodeCore(input: buf.baseAddress, length: Int32(buf.count))
        }
    }

    public func decodeAndPlayPLC() {
        // ★6: arm the pending-gap latch so the next real packet recovers this
        // frame via opus in-band FEC (decode_fec=1). The actual concealment
        // frame is minted there, or by `concealGap` itself on a second
        // consecutive loss (NULL-input PLC) - exactly one frame per gap.
        concealGap()
    }

    public func cleanup() {
        shutdown()
    }
}
