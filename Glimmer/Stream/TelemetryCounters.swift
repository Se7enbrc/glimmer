//
//  TelemetryCounters.swift
//
//  The process-global, always-live event counters + activity gauges the opt-in
//  telemetry exporter snapshots. Split out of TelemetryExporter.swift to keep
//  each unit focused; see that file for the exporter, gate, snapshot type, and
//  the gate/safety contract.
//
//  These counters are always-live, not gated - see the `TelemetryCounters` type
//  doc below for why.
//
//  Code map (this type is split across same-module extension files)
//  ----------------------------------------------------------------
//    * TelemetryCounters.swift             - the class decl, the Counter type,
//                                            every stored counter + gauge field,
//                                            init/deinit, and the session reset.
//    * TelemetryCounters+Gauges.swift      - decode / packet-gap / jitter / RTT /
//                                            present-suppression gauge accessors.
//    * TelemetryCounters+AudioGauges.swift - audio playout gauges + cold-start.
//    * TelemetryCounters+InputActivity.swift - input stamp + idle-edge reads.
//    * TelemetrySessionEvents.swift        - the P2 lifecycle state + accessors.
//

import Foundation
import os

// MARK: - Event counters

/// Monotonic, process-global event counters fed from the rare event sites across
/// the engine (IDR/RFI requests, backlog overflow, present stalls, frame loss,
/// unrecoverable frames, pacer give-up) plus the receive-path packet/FEC totals.
/// All `OSAllocatedUnfairLock`-free: each counter is its own atomic so an
/// increment is a single locked add with no cross-counter contention. These are
/// ALWAYS live (not gated) because the increments are unconditional integer adds
/// at already-rare sites - gating them would buy nothing and risk a skew between
/// the gate and the site. The exporter snapshots them; when the exporter is off,
/// nothing reads them and they simply accumulate harmlessly.
///
/// `@unchecked Sendable`: every field is an `Atomic*`-style counter guarded by
/// its own lock, so the type is safe to touch from any thread (receive thread,
/// decode queue, pacing queue, main actor).
final class TelemetryCounters: @unchecked Sendable {
    static let shared = TelemetryCounters()

    /// One monotonic counter. os_unfair_lock-guarded UInt64 - matches the codebase's
    /// existing AtomicCounter style; the few inc/read sites are not a tight inner
    /// loop (per loss event / per frame, never per packet on the hot path).
    final class Counter: @unchecked Sendable {
        private let lock = os_unfair_lock_t.allocate(capacity: 1)
        private var total: UInt64 = 0
        init() { lock.initialize(to: os_unfair_lock_s()) }
        deinit { lock.deallocate() }
        func increment(by amount: UInt64 = 1) {
            os_unfair_lock_lock(lock); total &+= amount; os_unfair_lock_unlock(lock)
        }
        var value: UInt64 {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return total
        }
        func reset() { os_unfair_lock_lock(lock); total = 0; os_unfair_lock_unlock(lock) }
    }

    // ---- Event counters (exposed as glimmer_*_total) ----
    let rfiTotal = Counter()
    let idrRequestedTotal = Counter()
    let backlogOverflowTotal = Counter()
    let presentStallTotal = Counter()
    let frameLossTotal = Counter()
    let unrecoverableFrameTotal = Counter()
    let pacerDisabledTotal = Counter()

    // ---- Receive-path totals (the exporter derives pkts/s + fec rate from
    //      deltas of these monotonic totals; recv-jitter is a live gauge). ----
    let videoPacketsTotal = Counter()
    let videoFramesTotal = Counter()
    let fecRecoveredFramesTotal = Counter()
    let inputEventsTotal = Counter()
    let inputBatchFlushTotal = Counter()
    /// Input flush ticks that early-returned because the LOCAL outbound send count
    /// was over cap (the radio draining slowly) - one cause of the input p99 tail.
    let inputFlushSendBackloggedSkipTotal = Counter()
    /// Input flush ticks that early-returned because the HOST stopped draining our
    /// reliable backlog (ACK silence) - the other cause of the input p99 tail.
    let inputFlushReliableBackloggedSkipTotal = Counter()

    // ---- P1 NETWORK receive-path totals (the exporter derives the per-second
    //      pre-FEC loss / out-of-order / duplicate RATES from deltas of these
    //      monotonic totals against `videoPacketsTotal`). All derived purely from
    //      the RTP sequence numbers of packets WE receive - no host tool. These
    //      are batched into the SAME ~2s receive-metrics window that already feeds
    //      the totals above, so the hot per-datagram path adds only a handful of
    //      integer compares (no lock, no alloc). ----
    /// Packets the host sent that never arrived (gaps in the RTP sequence space,
    /// counted BEFORE FEC recovery). The exporter derives the pre-FEC loss rate as
    /// this delta over the expected-packet delta.
    let videoPacketsLostPreFecTotal = Counter()
    /// Packets that arrived with a sequence number BEHIND the highest already seen
    /// (genuine reorder on the wire).
    let videoPacketsOutOfOrderTotal = Counter()
    /// Packets whose sequence number was already observed (true duplicates).
    let videoPacketsDuplicateTotal = Counter()

    // ---- P1 NETWORK ENet reliable-channel retransmit total. Incremented in
    //      checkRetransmit each time a reliable command's round-trip timeout
    //      elapses and it is resent - the climb that precedes a control-stream
    //      stall (paired with the already-surfaced oldest-unacked trend from
    //      enetHealth()). Always-live integer add at the already-rare retransmit
    //      site (sub-2Hz under a healthy link). ----
    let enetRetransmitTotal = Counter()

    /// ACK-silence near-miss total (P1 NETWORK). Bumped once per EDGE the control
    /// loop's ACK silence crosses a deep RTT multiple short of the dead-peer cutoff
    /// - the near-death blip that recovers and otherwise leaves no trace.
    let ackSilenceNearMissTotal = Counter()

    /// Unknown inbound CONTROL datagrams ignored (already ACKed + decrypted,
    /// then discarded - e.g. SET_RGB_LED 0x5502, advertised on light-bar pads
    /// but unimplemented). The Diag log suppresses repeats per type so a flood
    /// can't evict the diagnostic ring; this total preserves the VOLUME signal
    /// those suppressed lines would have carried. RE-BASELINE NOTE: host rumble
    /// (0x010b) was promoted out of this counter when it grew a dispatch - it
    /// alone ran ~135/s during active rumble, so cross-session comparisons
    /// spanning that change must not read the drop as a host behavior change.
    /// Always-live integer add on the inbound control path.
    let ctrlIgnoredTotal = Counter()

    // ---- Inter-arrival GAP-EVENT counters, PER SOCKET (video / audio / ENet)
    //      × thresholds (20/50/100ms). The honest link-health signal and the
    //      keepalive judge: the recv-jitter EWMA and the windowed gap gauges
    //      are provably blind to rare 40-110ms blips (a 100ms gap is 1/10200
    //      of a 2s window at ~5,100 pkts/s - only the gauge-overwritten max
    //      ever sees it, and a max can't COUNT). PER SOCKET so "all sockets
    //      gapped together" (NIC doze) vs "one path stalled" is one row query.
    //      Source sites fold these off the per-datagram path (video buckets
    //      >20ms gaps per ~2s window; audio compares last-arrival; the ENet
    //      leg counts reliable-ACK DELAYS - idle-proof, sees idle doze). ----
    let videoGapOver20msTotal = Counter()
    let videoGapOver50msTotal = Counter()
    let videoGapOver100msTotal = Counter()
    let audioGapOver20msTotal = Counter()
    let audioGapOver50msTotal = Counter()
    let audioGapOver100msTotal = Counter()
    let enetGapOver20msTotal = Counter()
    let enetGapOver50msTotal = Counter()
    let enetGapOver100msTotal = Counter()

    /// Host RUMBLE (0x010b) events RECEIVED at protocol dispatch, BEFORE any
    /// validity guard (handleRumbleData) - a zero proves the host sent nothing.
    /// ~135/s active; no longer in `ctrlIgnoredTotal` (re-baseline note there).
    let rumbleEventTotal = Counter()
    /// Truncated / slot-out-of-range RUMBLE drops: deposited = events − dropped,
    /// keeping both zeros honest. Always-live (defect path, ~0 in practice).
    let rumbleDroppedInvalidTotal = Counter()

    /// Idle→active input EDGE markers: incremented the first time an input event
    /// arrives after `idleGapSeconds` of input silence. This is the single signal
    /// that makes a "resume controlling after idle" auto-correlatable with the
    /// latency transient - instead of hand-reconstructing it from the events/s
    /// rate. The exporter emits this as a counter; an `increase()` over a
    /// short window marks the exact resume beat. Always-live like the other input
    /// counters (the increment site is the already-rare edge case).
    let inputIdleToActiveTotal = Counter()

    /// "That felt bad" bookmark markers (signal 4): incremented each time the user
    /// presses the client-only bookmark chord during a stream to flag jank. The
    /// exporter surfaces this as `glimmer_bookmark_total`; an `increase()`
    /// over a short window marks the exact instant the user felt the hitch, so a
    /// review jumps straight to it instead of scrubbing the whole capture. The
    /// chord ALSO writes an explicit event line into the NDJSON + the Diag log
    /// (with the connect-relative time) - see TelemetryExporter.recordBookmark.
    /// Always-live like the other counters (the press is a rare, deliberate act).
    let bookmarkTotal = Counter()

    /// CRUISE traversal-boost counters (signal: input, for tuning vKnee against
    /// real traces). `boosted` = batches where the velocity gate applied gain>1;
    /// `identity` = active-motion batches that stayed at gain==1 (below the knee
    /// or stale dt). The ratio is the share of motion that the boost touched.
    /// Always-live integer adds on the already-coalesced mouse-batch path.
    let cruiseBoostedBatchesTotal = Counter()
    let cruiseIdentityBatchesTotal = Counter()

    // ---- P2 SESSION-LIFECYCLE event counters (the lifecycle/recovery/quality
    //      signals). All always-live integer adds at already-rare sites (a
    //      reconnect, an IDR request/arrival, a corrupt-frame heuristic hit) - far
    //      below any hot-path budget; see TelemetrySessionEvents.swift. ----
    //
    /// RECONNECT count (signal: lifecycle): incremented each time a session
    /// re-establishes its connection after a drop within the same run. The
    /// climb-then-recover pattern that a single "connected" gauge can't show.
    let reconnectTotal = Counter()
    /// WAKE count (signal: lifecycle): incremented each time the Mac wakes from
    /// sleep while a stream is live. Run-global (NOT reset per session, like
    /// `reconnectTotal`); a climb here that precedes a reconnect/disconnect marks
    /// the wake-on-different-AP stale-link case.
    let wakeTotal = Counter()
    /// ROUTE-CHANGE count (signal: lifecycle): incremented each time the stream's
    /// egress route/link-class flips (the WiFiTelemetry route-change edge that
    /// already fires an NDJSON event). Run-global (NOT reset per session) so a
    /// wake-on-a-different-AP is visible in Prometheus, not just the NDJSON/Loki.
    let routeChangeTotal = Counter()
    /// EXPLICIT REQUEST_IDR sends that started a round-trip measurement
    /// (signal: IDR-RTT). RE-BASELINE NOTE: RFI sends no longer arm round-trips
    /// (they ride `rfiTotal`) - conflating them made the pair unreadable (RFI
    /// stamps were mostly superseded mid-burst, so a scorecard read far more
    /// requests than matches). Now it pairs with `idrRoundTripMatchedTotal` as a
    /// true did-the-host-honor-us ratio.
    let idrRoundTripRequestTotal = Counter()
    /// Explicit IDR requests matched to an arriving IDR/recovery frame
    /// (signal: IDR-RTT). The numerator of the "did the host honor our request"
    /// view; the round-trip distribution rides the latency histogram.
    let idrRoundTripMatchedTotal = Counter()
    /// CORRUPTION/ARTIFACT heuristic hits (signal: quality). Bumped at the cheap,
    /// already-computed corruption tells - a VT decode-status error / FrameDropped
    /// output, or a depacketizer discontinuity that orphaned the reference chain -
    /// NOT a per-pixel scan. A short-window `increase()` brackets the white/purple
    /// flash class without any hot-path cost beyond an integer add.
    let corruptionHeuristicTotal = Counter()

    // ---- P1 DECODE/PRESENT event counters ----
    //
    /// VTDecompressionSession (re)creates this session (signal: DECODE). Bumped
    /// each time `ensureDecompressionSession` actually builds a fresh session -
    /// the first create plus every mid-stream rebuild (a param-set change:
    /// resolution / codec profile / colorspace switch, or a teardown→recreate).
    /// A short-window `increase()` brackets a decoder reset that correlates with
    /// a present hitch. Always-live integer add at the already-rare create site
    /// (≤ a handful per session under a healthy link).
    let decoderRecreateTotal = Counter()

    /// Decoder (re)creates SPLIT BY CAUSE (signal: DECODE). Same already-rare
    /// create site as `decoderRecreateTotal`; these three sum to it. The split
    /// makes a recreate STORM legible as to cause - a colorspace/HDR flap vs a
    /// real resolution change vs the one-time first create. Cause is read from
    /// the format-description dimensions at the rebuild site (resolution change =
    /// dims changed; otherwise a param-set rebuild that kept dims = colorspace/
    /// profile/HDR-signaling). Always-live integer adds like their parent.
    let decoderRecreateFirstTotal = Counter()
    let decoderRecreateResolutionTotal = Counter()
    let decoderRecreateColorspaceTotal = Counter()

    /// Stale-frame REPEAT count (signal: PRESENT). Bumped on each pacer tick that
    /// fires but presents NO new frame because none was due - the layer re-shows
    /// the last frame. This is the INVISIBLE stutter: at fps<refresh it is the
    /// normal cadence (60-on-120 repeats every other tick), but a SPIKE in the
    /// per-second rate while fps≈refresh is a real micro-judder (the pacer held a
    /// frame, or the buffer starved). The exporter derives a repeats/sec rate from
    /// this monotonic total. Counted ONLY on the pacer's serial queue, so the
    /// increment sees no cross-queue race; always-live (the per-tick add is a
    /// sub-µs integer op, far below the per-vsync budget even at 240Hz).
    let staleFrameRepeatTotal = Counter()

    /// STALE beats where the pacer queue was EMPTY (signal: PRESENT) - the
    /// starvation subset of `staleFrameRepeatTotal`. A stale beat with frames
    /// queued is a benign not-due idle tick (fps<refresh cadence); an EMPTY
    /// queue means content for this beat hadn't arrived - the clump-then-starve
    /// oscillation's visible half. not_due = staleFrameRepeatTotal − this.
    let staleEmptyQueueTotal = Counter()

    /// PERCEIVED-GAP cause split (signal: PRESENT): the DROUGHT subset of
    /// `presentationGaps` - a present landed after a >100ms hold with frames
    /// still arriving (loss storm / decode starvation / pacing wedge). The
    /// remainder (total − this) is the backoff-then-renderer-reject path.
    let presentGapDroughtTotal = Counter()

    /// AUDIO NEAR-MISS (signal: AUDIO) - steady-state playout fill dipped below
    /// ~15ms without fully draining (latched per dip; re-arms above 30ms).
    /// Margin erosion visible BEFORE it becomes an audible under-run: a rising
    /// rate here with zero under-runs means the cushion is thinning toward the
    /// edge (skew, gap texture) and the resampler/ratchet are living close.
    let audioNearMissTotal = Counter()

    /// OVER-TARGET force-release count (signal: PRESENT). Bumped on each pacer tick
    /// where the due gate would have latched not-due against a GENUINE drainable
    /// backlog (one frame above the adaptive jitter-buffer target that survived the
    /// per-tick trim), so the over-target short-circuit forced the head out to keep
    /// the backlog draining. Zero in steady state (clean link rests at depth 1,
    /// passthrough; a grown wifi buffer drains via the normal due logic). A SPIKE in
    /// the per-second rate is the no-network present-stall signature - the depth
    /// controller over-draining then re-growing and the due gate self-oscillating -
    /// caught and broken here instead of decaying to the starvation failsafe. The
    /// exporter derives an over-target/sec rate from this monotonic total. Counted
    /// on the pacer's serial queue, so the increment sees no cross-queue race;
    /// always-live (a sub-µs integer op, far below the per-vsync budget at 240Hz).
    let pacerOverTargetReleaseTotal = Counter()

    /// Present-tick MISS split by ROOT CAUSE (signal: PRESENT, diagnostic). A
    /// stretched present tick (>1.5 vsyncs between successive CADisplayLink
    /// targetTimestamps - the residual ~3.8% present gap) is classified on the
    /// tick path: DESCHEDULED = `handleTick`'s own wall-clock entry stretched the
    /// same amount, so the tick thread didn't get the CPU; COALESCED = entry on
    /// time but the vsync delta jumped, so macOS coalesced the callback delivery.
    /// The two need OPPOSITE fixes, so the split picks which to ship. Bumped on the
    /// tick path (sub-µs integer add, far below the per-vsync budget); per-session
    /// like the sibling present counters.
    let tickMissDescheduledTotal = Counter()
    let tickMissCoalescedTotal = Counter()

    /// Present-tick MISS split by a DIRECT promptness measure (signal: PRESENT,
    /// diagnostic). The descheduled/coalesced pair above tests the wall-clock
    /// entry GAP, which stretches in BOTH thread preemption AND a CADisplayLink
    /// vsync-delivery skip - so it can't tell "RT failed" from "the display server
    /// dropped a vsync". This pair tests the LAG of `handleTick` behind its vsync
    /// instead: PREEMPTED = the callback ran a full frame-or-more late (the thread
    /// was starved - RT not doing its job); LINKSKIP = it ran promptly but the
    /// inter-tick interval still stretched (the link didn't deliver a vsync - RT
    /// working, the residual is the display server). Kept ALONGSIDE the older pair
    /// for an old-vs-new comparison. Bumped on the tick path (one extra clock read +
    /// a subtract + a compare); per-session like the sibling present counters.
    let tickMissPreemptedTotal = Counter()
    let tickMissLinkskipTotal = Counter()

    /// Frames dropped-to-NEWEST while presentation is SUPPRESSED (signal:
    /// PRESENT): the window is backgrounded/occluded, the display link is
    /// deliberately suspended, and the pacer keeps only the newest frame ready
    /// for an instant resume. These are DESIGNED drops - counting them here
    /// keeps `drops_presentation_late` meaning what it says (frames the pacer
    /// genuinely failed to present in time) instead of carrying ~120/s of
    /// suppressed-mode noise. Incremented on the pacer's submit path while the
    /// suppression gauge below is set; always-live like its sibling drop counters.
    let suppressedDropTotal = Counter()

    /// Frames dropped WITHOUT decode while the DECODE GATE is engaged (stage 2
    /// of hidden-window handling: after ~2s of continuous suppression the
    /// decoder stops decoding entirely). Distinct from `suppressedDropTotal`
    /// (decoded, then dropped-to-newest) so a gated span - fps_decoded=0,
    /// drops_suppressed flat - is distinguishable from a genuine decode wedge.
    /// VideoDecoder increments on its quiet-drop path; always-live integer add.
    let decodeGatedDropTotal = Counter()

    /// STREAM-DISCONTINUITY flushes: param-set rebuilds mid-stream that flush the
    /// renderer + clear the pacer queue (a real multi-frame skip). 0 on a healthy
    /// wired link (the byte-equal short-circuit holds); a host that mutates param
    /// sets mid-stream surfaces as a measurable delta. VideoDecoder increments at
    /// the rebuild's flush site; always-live integer add at an already-rare event.
    let discontinuityFlushTotal = Counter()

    // ---- P1 AUDIO receive-path + playout totals (the OTHER stream) ----
    //
    // All derived purely from the audio RTP we receive + the audio output path -
    // no host tool. The RECEIVE totals are folded once per ~1s audio-metrics
    // window by RtpAudioReceiver (off the per-datagram path, exactly like the
    // video receive-quality totals), so the audio recv thread gains only a few
    // integer compares per packet. The PLAYOUT totals are bumped on the audio
    // decode/output path under the lock AudioDecoder already holds for the decode,
    // so they cost nothing extra. The exporter derives per-second rates from the
    // monotonic deltas and reads the gauges at 1Hz.
    //
    /// Audio DATA packets accepted into the queue this session (RtpAudioQueue's
    /// `packetCountAudio`). The exporter derives audio pkts/s + the loss/FEC RATES
    /// from deltas of this against the loss/recovered totals below.
    let audioPacketsTotal = Counter()
    /// Audio packets the host sent that never arrived AND could not be recovered by
    /// FEC - the genuine on-the-wire audio loss the user would hear as a gap
    /// (RtpAudioQueue's `packetCountFecFailed` shards). The exporter derives the
    /// unrecovered-audio-loss rate from this delta over the expected delta.
    let audioPacketsLostTotal = Counter()
    /// Audio packets RECOVERED by Reed-Solomon FEC this session (RtpAudioQueue's
    /// `packetCountFecRecovered`). Paired with the loss total it shows how much of
    /// the on-the-wire loss FEC papered over (the audio analogue of the video FEC
    /// recovery rate) - the known lossy-link audio-quality story.
    let audioFecRecoveredTotal = Counter()
    /// Audio FEC blocks dropped on a BLOCK-SIZE MISMATCH (the parity-keyed and
    /// data-keyed sizes disagree): the block is discarded and COUNTED here
    /// instead of silently (and permanently) latching the incompatible-server
    /// flag - the mismatch stays visible and the next block gets a fresh shot.
    /// Always-live integer add at the already-rare mismatch site.
    let audioFecMismatchTotal = Counter()
    /// Audio output buffer UNDER-RUNs this session: the player drained its
    /// scheduled buffers and had nothing to play (a gap / glitch the user hears).
    /// Bumped on the audio output path when a scheduled buffer completes and the
    /// scheduled-ahead duration has fallen to zero. Always-live integer add.
    let audioUnderrunTotal = Counter()
    /// Audio output buffer OVER-RUNs this session: a decoded buffer was dropped
    /// because the scheduled-ahead backlog already exceeded the safety CEILING
    /// (the worst-case-link backstop). CEILING-BACKSTOP ONLY - the designed
    /// playout-target trims count in `audioTrimTotal` below, so this stays a
    /// pathology signal a regression read can trust. Bumped on the decode path
    /// before scheduling. Always-live integer add.
    let audioOverrunTotal = Counter()
    /// Audio playout TRIMs this session: DESIGNED playout-backlog trims - 5ms
    /// decoded packets chopped on the schedule path to walk the backlog back down
    /// to the playout target (the post-gap catch-up clump). Split from
    /// `audioOverrunTotal` so designed trims and the ceiling backstop can never
    /// be conflated in a cross-session comparison again. Bumped on the decode
    /// path like its sibling. Always-live integer add.
    let audioTrimTotal = Counter()
    /// Audio RECEIVE-start failures (H7): `RtpAudioReceiver.startReceive()` threw,
    /// so this session came up VIDEO-ONLY (the ping keeps the A/V session alive,
    /// but no audio flows). Previously the throw was caught and dropped with no
    /// counter and no user signal - a silent audio-dead session. Bumped from the
    /// pipeline catch alongside the `.audioFailed` event. Always-live integer add.
    let audioReceiveFailedTotal = Counter()

    // ---- Input-activity gauge (last-input instant + idle-edge detection) ----
    //
    // `noteInputEvent()` is called from the SAME already-live increment sites as
    // `inputEventsTotal` (InputBatcher producers). It stamps the monotonic
    // last-input instant (so the exporter can derive `time_since_last_input_ms`)
    // and, when the gap since the previous event exceeds `idleGapSeconds`, counts
    // an idle→active transition. Cost is one lock + a couple of stores per input
    // event - far below the per-input budget, and input is human-rate (≤ ~kHz),
    // not a multi-kHz packet path. Unconditional (not gated) for the same reason
    // the counters are: the increment is cheap and the exporter simply ignores it
    // when off.
    // Module-internal (not private) so the input accessors in
    // TelemetryCounters+InputActivity.swift can reach these.
    let inputLock = os_unfair_lock_t.allocate(capacity: 1)
    /// `DispatchTime.now().uptimeNanoseconds` of the most recent input event, or
    /// 0 if none yet. Read by the exporter to compute time-since-last-input.
    var lastInputNanosValue: UInt64 = 0
    /// Gap (seconds) of input silence after which the next event is an idle→active
    /// edge. 2s comfortably exceeds normal inter-event spacing during active play
    /// (sub-100ms) yet is short enough to catch a genuine "stepped away, came
    /// back" resume - the exact motivating bug.
    static let idleGapSeconds: Double = 2.0

    // Module-internal (not private) so the gauge accessors in
    // TelemetryCounters+Gauges.swift can reach these.
    //
    /// Live smoothed recv-jitter gauge (ms), written by the RTP receive path.
    /// A plain Double behind an unfair lock - last-writer-wins is fine for a
    /// gauge sampled at 1Hz against a multi-kHz writer.
    let jitterLock = os_unfair_lock_t.allocate(capacity: 1)
    var recvJitterMsValue: Double = 0

    // Module-internal (not private) so the gauge accessors in
    // TelemetryCounters+Gauges.swift can reach these.
    //
    /// Live smoothed network RTT gauge (ms), refreshed once per ~1Hz telemetry
    /// tick by the exporter from the ENet ping estimate. Read on the present hot
    /// path by the per-frame glass-to-glass computation as `~RTT/2` for the
    /// network-transit leg - the host doesn't tell us per-frame transit, so the
    /// CURRENT smoothed RTT is the best estimate the inputs allow. A single
    /// `Double` behind an unfair lock: a stale read (the tick that just updated
    /// it vs. a present mid-tick) is harmless for an estimate, and the lock keeps
    /// the read tear-free. 0 = "no RTT yet" (glass-to-glass omits the transit leg
    /// rather than guessing). The lock is on the telemetry path only - when the
    /// gate is off the tracker that reads it doesn't exist, so the present hot
    /// path never touches it.
    let rttLock = os_unfair_lock_t.allocate(capacity: 1)
    var rttMsValue: Double = 0

    // Module-internal (not private) so the gauge accessors in
    // TelemetryCounters+Gauges.swift can reach these.
    //
    /// LATEST VTDecompressionSessionCreate wall-clock cost (ms). HW decoder
    /// bring-up can't run until the first SPS/PPS, so it lands on the critical
    /// first-frame leg - this surfaces that one-shot startup cost. Stamped by the
    /// decode queue at each create (rare); read at 1Hz by the exporter. A plain
    /// Double behind an unfair lock, last-writer-wins like the other gauges.
    let vtSessionCreateLock = os_unfair_lock_t.allocate(capacity: 1)
    var vtSessionCreateMsValue: Double = 0

    // Module-internal (not private) so the gauge accessor in
    // TelemetryCounters+Gauges.swift can reach these.
    //
    /// CRUISE max-gain gauge: the largest traversal-boost gain applied this
    /// session (1.0 = never boosted). Read with the resolution-derived gMax it
    /// tops out at, this proves whether real flicks ever cross vFull. A plain
    /// Double behind an unfair lock; `noteCruiseGain` keeps the running max.
    let cruiseMaxGainLock = os_unfair_lock_t.allocate(capacity: 1)
    var cruiseMaxGainValue: Double = 1.0

    // Module-internal (not private) so the gauge accessors in
    // TelemetryCounters+Gauges.swift can reach these.
    //
    /// PRESENT-SUPPRESSION gauge (0/1): true while presentation is deliberately
    /// suppressed (window backgrounded/occluded → display link suspended). Set/
    /// cleared at the suppression EDGES by the present path - already-rare sites,
    /// never per frame - and read at 1Hz by the exporter, so the per-second
    /// record shows WHICH samples were captured in suppressed mode (the context
    /// `suppressedDropTotal` counts under, and the "silent transition" the
    /// os.Logger-only edges used to hide from the NDJSON). A plain Bool behind an
    /// unfair lock - same last-writer-wins discipline as the other gauges.
    let presentSuppressedLock = os_unfair_lock_t.allocate(capacity: 1)
    var presentSuppressedValue = false

    /// DECODE-GATE gauge (0/1): true while the decode gate is engaged (the
    /// THIRD hidden-window state - after ~2s of continuous suppression decode
    /// stops entirely). Set/cleared at the engage/lift EDGES by VideoDecoder -
    /// already-rare sites, never per frame - and read at 1Hz by the exporter,
    /// so a zero-decode span self-labels as gated (vs wedged) on the same row
    /// that carries `presentSuppressedValue`. Same last-writer-wins discipline
    /// as the suppression gauge it extends.
    let decodeGatedLock = os_unfair_lock_t.allocate(capacity: 1)
    var decodeGatedValue = false

    /// PACER-TICK REALTIME gauge (0/1): 1 once `thread_policy_set` confirmed the
    /// Mach time-constraint (real-time) policy on the present-tick thread, 0 when
    /// it failed OR the flag left the thread at userInteractive. Stamped ONCE at
    /// tick-thread start by PacerTickThread (never per frame) and read at 1Hz by
    /// the exporter - the one-query "are we getting RT priority" yes/no the
    /// `tick_miss_*` split is read against. Last-writer-wins behind its own lock.
    let pacerTickRealtimeLock = os_unfair_lock_t.allocate(capacity: 1)
    var pacerTickRealtimeValue = false

    /// Live inter-packet-gap distribution (microseconds) for the microburst
    /// detector. Written once per ~2s receive-metrics window by the RTP path
    /// (computed there off the per-datagram arrival times it ALREADY reads for
    /// jitter, so the hot path gains only a min/max/running-sum update - no clock
    /// read, no alloc) and read at 1Hz by the exporter. A plain value struct behind
    /// an unfair lock: last-writer-wins is fine for a gauge sampled at 1Hz against
    /// the 2s window writer. p95 is an approximation (a 16-bucket log-spaced
    /// histogram, see the writer) - exact enough to spot a microburst, far cheaper
    /// than a per-packet reservoir on the receive path.
    struct PacketGapSnapshot: Sendable {
        var p50Us: Double
        var p95Us: Double
        var maxUs: Double
    }
    // Module-internal (not private) so the gauge accessors in
    // TelemetryCounters+Gauges.swift can reach these.
    let gapLock = os_unfair_lock_t.allocate(capacity: 1)
    var packetGapValue: PacketGapSnapshot?

    // Live DECODE-side STATE gauge storage; the `DecodeState` value type +
    // its doc live with the accessors in TelemetryCounters+Gauges.swift
    // (moved there to keep this file under the length budget - pure move).
    // Module-internal (not private) so those accessors can reach these.
    let decodeStateLock = os_unfair_lock_t.allocate(capacity: 1)
    var decodeStateValue: DecodeState?

    // Live FEC-HEALTH gauge storage (reorder-hold + headroom axes + per-frame
    // parity headroom); the `FecHealthSnapshot` value type + accessors live in
    // TelemetryCounters+Gauges.swift. Module-internal so those accessors reach it.
    let fecHealthLock = os_unfair_lock_t.allocate(capacity: 1)
    var fecHealthValue: FecHealthSnapshot?

    /// AWDL helper gauge (awdl0 parked + macOS re-raise count). Set by
    /// AWDLHelperManager on the suppress heartbeat; read by the exporter. Self-locked.
    let awdlHelperState = OSAllocatedUnfairLock<AWDLHelperSnapshot?>(initialState: nil)

    /// Host-RUMBLE receipt stamp (the last 0x010b receipt instant) - the detach-
    /// context breadcrumb's rumble-age source (ControllerForwarder.detach).
    /// Self-locked holder (the `P2State` idiom), defined in
    /// TelemetryCounters+InputActivity.swift next to its input-age sibling.
    let rumbleActivity = RumbleActivity()

    /// Live AUDIO playout STATE (signal: AUDIO - the other stream). What the audio
    /// output path is doing right now: how much decoded audio is scheduled ahead of
    /// the playhead (the buffer level / fill), and the A/V SYNC DRIFT - how far the
    /// audio presentation clock has slipped from the video present clock over time.
    /// Published off the hot path (the audio decode path stamps it under the lock it
    /// already holds, ~200Hz at 5ms packets) and read at 1Hz by the exporter. A
    /// plain value struct behind an unfair lock: last-writer-wins is correct for a
    /// 1Hz-sampled state gauge, and the lock keeps the multi-field read tear-free.
    /// nil before the first decoded audio packet.
    struct AudioState: Sendable {
        /// Decoded audio buffered ahead of the playhead (ms): the scheduled-but-
        /// not-yet-played backlog in the AVAudioPlayerNode. A healthy stream holds a
        /// small steady cushion; a climb is latency creep, a fall toward 0 precedes
        /// an under-run (the audio glitch).
        var bufferFillMs: Double
        /// ADAPTIVE PLAYOUT TARGET (ms): the cushion the playout path is
        /// currently steering `bufferFillMs` toward. Fill vs target is the
        /// cushion judge (base 30 / cap 150 / ceiling 190): a fill hugging a
        /// flat ceiling is only legible against this - target re-pinned at the
        /// cap through minutes of calm play = the decay is broken (the old
        /// disguised-permanent-give-up failure mode), target ratcheting up
        /// under gaps then decaying toward base = designed behavior. nil until
        /// the playout path stamps it (AudioDecoder publishes alongside fill).
        var playoutTargetMs: Double?
        /// AUDIO CLOCK DRIFT (ms): the audio playout clock's slip vs WALL CLOCK,
        /// signed and net of the steady buffer cushion. This is audio-clock-vs-
        /// wall-clock drift - NOT a true cross-stream A/V delta (it never compares
        /// against the video present clock). ~0 = the audio device clock is
        /// tracking real time; POSITIVE = audio media has played BEHIND wall time
        /// (the device clock is slow / it's draining late), NEGATIVE = ahead.
        /// Computed as (wall-elapsed − media-played − buffer-cushion) since playout
        /// start, so a steady cushion reads ~0 and only a genuine clock-domain
        /// slip trends over time. nil until audio has begun playing.
        var audioClockDriftMs: Double?
        /// Windowed MINIMUM buffer fill (ms) since the exporter last read it - the
        /// trough of the scheduled-ahead backlog. The 1Hz `bufferFillMs` gauge is
        /// last-writer-wins and can miss the instantaneous low that precedes an
        /// under-run; this min is the field that PROVES the buffer is (or is no
        /// longer) draining toward 0. RESET-ON-READ by the exporter. nil when no
        /// trough was sampled this window.
        var bufferFillMinMs: Double?
        /// RE-PRIME count this session (monotonic): pre-roll RE-ARM edges - the
        /// state machine dropping back to un-primed after a full drain. NOT a
        /// count of paused wall-time pre-rolls: the node keeps playing across a
        /// re-arm and the cushion rebuilds via the post-gap catch-up clump (see
        /// AudioDecoder). Directly countable alongside under-runs.
        var rePrimeTotal: UInt64
        /// RESAMPLER applied rate offset (ppm): the drift-tracking resampler's live
        /// `varispeed.rate − 1` in parts-per-million. 0 when disengaged (pre-roll /
        /// re-prime / drain); when converged it sits at the steady host↔Mac clock
        /// offset (~tens of ppm) - the direct view of the resampler holding the fill
        /// it's steering (vs the av_skew that bounces with video-side timing).
        var resamplerPpm: Double = 0
        /// AVAudioEngine running mirror (1 = up). Set under the audio meter lock at
        /// engine start/stop, so a reconnect that re-inits the decoder but fails to
        /// bring the engine back reads 0 here while packets still flow - the direct
        /// "playout dead" signal. nil before the engine first starts.
        var engineRunning: Bool?
    }
    // Module-internal (not private) so the audio accessors in
    // TelemetryCounters+AudioGauges.swift can reach these (and the min-window
    // field below).
    let audioStateLock = os_unfair_lock_t.allocate(capacity: 1)
    var audioStateValue: AudioState?
    /// Windowed MINIMUM buffer fill (ms) accumulated by the audio playout path
    /// between exporter reads. The audio path lowers this via `noteAudioBufferFill`
    /// on every completion (the trough sampler); the exporter consumes + resets it
    /// via `takeAudioBufferFillMinMs` at 1Hz. A separate min-window from the
    /// last-writer-wins `audioStateValue` gauge so the trough survives the 1Hz
    /// sampling that the gauge misses. `.infinity` = no sample this window.
    var audioBufferFillMinMsValue: Double = .infinity

    // Module-internal (not private) so the audio accessors in
    // TelemetryCounters+AudioGauges.swift can reach these (and the fallback
    // anchor below, which shares this lock).
    //
    /// AUDIO first-packet time (ms): time from SESSION START (the P2 `connectStart`
    /// anchor, stamped at the connect edge and preserved across the exporter reset)
    /// to the first decoded audio packet. The known ~5-7s-on-lossy-link cold-start
    /// metric - surfaced here as a one-shot gauge so a dashboard/report shows it
    /// per session. Written once by the audio receive path; 0 = not yet measured.
    let audioFirstPacketLock = os_unfair_lock_t.allocate(capacity: 1)
    var audioFirstPacketMsValue: Double = 0

    /// P2 SESSION-LIFECYCLE state (handshake timeline + disconnect reason + IDR
    /// round-trip), behind its own lock. Defined in TelemetrySessionEvents.swift;
    /// always-live like the rest of this singleton (the exporter reads it at 1Hz,
    /// nothing reads it when off). Its own lock keeps the rare lifecycle/recovery
    /// writes off every other counter's lock.
    let p2 = P2State()

    /// PROCESS-GLOBAL monotonic disconnect tally by reason - the durable record of
    /// WHY sessions ended (the per-session ordinal is torn down <1ms after a session,
    /// before a scrape sees it). Bumped once per session at GENUINE teardown
    /// (`noteTelemetryDisconnect`); survives `resetForNewSession`.
    let disconnectByReason = DisconnectReasonCounters()
    /// AUDIO-TTF context: warm/cold host-bring-up classification + the
    /// host-idle covariate. Self-locked, defined in
    /// TelemetryCounters+AudioGauges.swift (the P2State idiom); its
    /// last-stream-end stamp DELIBERATELY survives `resetForNewSession`.
    let audioTtf = AudioTtfContext()
    /// Per-TYPE ignored-control tallies (bounded). Self-locked, defined in
    /// TelemetryCounters+Gauges.swift - durable here (the teardown Diag NOTICE
    /// is lossy) so the session scorecard can render the per-type breakdown.
    let ctrlIgnoredPerType = CtrlIgnoredPerType()
    /// FALLBACK monotonic `DispatchTime` anchor (nanoseconds) for the audio
    /// cold-start metric: stamped when the audio receiver opens its socket
    /// (mid-handshake). Used ONLY when the P2 `connectStart` session anchor is
    /// unset - `recordAudioFirstPacket` prefers `connectStart` (the true session
    /// epoch). Historical wart now fixed: `resetForNewSession` used to run at
    /// exporter start, AFTER `startPing`, wiping this into a stale prior-session
    /// value on reconnect; the reset now happens at the CONNECT edge, before any
    /// receiver exists. 0 = not anchored yet. Crosses the receiver-init →
    /// recv-thread boundary, so it lives here behind the measured value's lock.
    var audioStreamStartNanosValue: UInt64 = 0

    init() {
        jitterLock.initialize(to: os_unfair_lock_s())
        inputLock.initialize(to: os_unfair_lock_s())
        rttLock.initialize(to: os_unfair_lock_s())
        vtSessionCreateLock.initialize(to: os_unfair_lock_s())
        cruiseMaxGainLock.initialize(to: os_unfair_lock_s())
        gapLock.initialize(to: os_unfair_lock_s())
        decodeStateLock.initialize(to: os_unfair_lock_s())
        fecHealthLock.initialize(to: os_unfair_lock_s())
        audioStateLock.initialize(to: os_unfair_lock_s())
        audioFirstPacketLock.initialize(to: os_unfair_lock_s())
        presentSuppressedLock.initialize(to: os_unfair_lock_s())
        decodeGatedLock.initialize(to: os_unfair_lock_s())
        pacerTickRealtimeLock.initialize(to: os_unfair_lock_s())
    }
    deinit {
        jitterLock.deallocate(); inputLock.deallocate()
        rttLock.deallocate(); vtSessionCreateLock.deallocate()
        cruiseMaxGainLock.deallocate()
        gapLock.deallocate()
        decodeStateLock.deallocate(); fecHealthLock.deallocate()
        audioStateLock.deallocate(); audioFirstPacketLock.deallocate()
        presentSuppressedLock.deallocate(); decodeGatedLock.deallocate()
        pacerTickRealtimeLock.deallocate()
    }

    // The gauge accessors live in same-module extension files (pure moves to
    // keep this file under the length limit): the decode / packet-gap / jitter /
    // RTT / present-suppression reads + writes in TelemetryCounters+Gauges.swift,
    // the audio playout gauges + cold-start in TelemetryCounters+AudioGauges.swift,
    // and the input stamp / idle-edge reads in
    // TelemetryCounters+InputActivity.swift.

    /// Reset everything. Called at the CONNECT-START edge
    /// (`StreamSession.anchorTelemetryConnectStart`) - BEFORE the receivers spin
    /// up, NOT at exporter start - so a warm host's mid-handshake one-shot
    /// latches (audio TTF/first-packet) can never race the reset and serve a
    /// prior session's values (the chimeric audio_ttf). (Prometheus counters are
    /// nominally never reset, but a per-session diagnostic view wants per-session
    /// totals - a scrape across a session boundary just sees a counter reset,
    /// which Prometheus handles.)
    func resetForNewSession() {
        for counter in [rfiTotal, idrRequestedTotal, backlogOverflowTotal,
                        presentStallTotal, frameLossTotal, unrecoverableFrameTotal,
                        pacerDisabledTotal, videoPacketsTotal, videoFramesTotal,
                        fecRecoveredFramesTotal, inputEventsTotal, inputBatchFlushTotal,
                        inputFlushSendBackloggedSkipTotal, inputFlushReliableBackloggedSkipTotal,
                        inputIdleToActiveTotal, bookmarkTotal,
                        cruiseBoostedBatchesTotal, cruiseIdentityBatchesTotal,
                        videoPacketsLostPreFecTotal, videoPacketsOutOfOrderTotal,
                        videoPacketsDuplicateTotal, enetRetransmitTotal,
                        ackSilenceNearMissTotal, ctrlIgnoredTotal,
                        decoderRecreateTotal, decoderRecreateFirstTotal,
                        decoderRecreateResolutionTotal, decoderRecreateColorspaceTotal,
                        staleFrameRepeatTotal, staleEmptyQueueTotal, audioNearMissTotal,
                        presentGapDroughtTotal,
                        pacerOverTargetReleaseTotal,
                        tickMissDescheduledTotal, tickMissCoalescedTotal,
                        tickMissPreemptedTotal, tickMissLinkskipTotal,
                        suppressedDropTotal, decodeGatedDropTotal,
                        discontinuityFlushTotal,
                        audioPacketsTotal, audioPacketsLostTotal, audioFecRecoveredTotal,
                        audioFecMismatchTotal, audioUnderrunTotal, audioOverrunTotal,
                        audioTrimTotal, audioReceiveFailedTotal,
                        rumbleEventTotal, rumbleDroppedInvalidTotal,
                        // Per-socket gap-event counters.
                        videoGapOver20msTotal, videoGapOver50msTotal, videoGapOver100msTotal,
                        audioGapOver20msTotal, audioGapOver50msTotal, audioGapOver100msTotal,
                        enetGapOver20msTotal, enetGapOver50msTotal, enetGapOver100msTotal,
                        // P2 session-lifecycle counters. reconnectTotal is excluded:
                        // a silent reconnect re-runs this reset mid-run, which would
                        // zero the very count it's about to make (run-global).
                        idrRoundTripRequestTotal, idrRoundTripMatchedTotal,
                        corruptionHeuristicTotal] {
            counter.reset()
        }
        // NOTE: `p2` (the handshake timeline + disconnect reason + IDR round-trip
        // state) is DELIBERATELY NOT reset here: `anchorTelemetryConnectStart`
        // resets it itself, in the right order (reset → anchor), and keeping it
        // out of this method preserves that single-owner discipline (this method
        // and the p2 anchor are called back-to-back at the same connect edge).
        setRecvJitterMs(0)
        setRttMs(0)
        setVtSessionCreateMs(0)
        // Cruise max-gain resets to the unboosted floor (1.0), not 0.
        os_unfair_lock_lock(cruiseMaxGainLock); cruiseMaxGainValue = 1.0; os_unfair_lock_unlock(cruiseMaxGainLock)
        // Present-suppression + decode-gate gauges: a session starts with a
        // visible stream view, and the present/decode paths re-stamp these at
        // the next suppression/gate edge.
        setPresentSuppressed(false)
        setDecodeGated(false)
        // RT gauge is NOT reset here: it's a THREAD-LIFETIME fact, set once when
        // the tick thread starts. The thread is REUSED across reconnects (it never
        // re-applies/re-stamps), so clearing it here would make the gauge lie
        // inversely on every reconnect. Leave it at its thread-set value.
        // Per-type ignored-control tallies are per-session like the aggregate
        // total; the audio-TTF record resets but its last-stream-end stamp
        // survives (it anchors THIS session's host_idle_s).
        ctrlIgnoredPerType.reset()
        audioTtf.resetForNewSession()
        os_unfair_lock_lock(inputLock); lastInputNanosValue = 0; os_unfair_lock_unlock(inputLock)
        rumbleActivity.reset()
        os_unfair_lock_lock(gapLock); packetGapValue = nil; os_unfair_lock_unlock(gapLock)
        os_unfair_lock_lock(decodeStateLock); decodeStateValue = nil; os_unfair_lock_unlock(decodeStateLock)
        os_unfair_lock_lock(fecHealthLock); fecHealthValue = nil; os_unfair_lock_unlock(fecHealthLock)
        awdlHelperState.withLock { $0 = nil }
        os_unfair_lock_lock(audioStateLock)
        audioStateValue = nil; audioBufferFillMinMsValue = .infinity
        os_unfair_lock_unlock(audioStateLock)
        os_unfair_lock_lock(audioFirstPacketLock)
        audioFirstPacketMsValue = 0; audioStreamStartNanosValue = 0
        os_unfair_lock_unlock(audioFirstPacketLock)
    }
}
