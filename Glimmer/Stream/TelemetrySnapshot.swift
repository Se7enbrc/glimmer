//
//  TelemetrySnapshot.swift
//
//  The value types the opt-in telemetry exporter assembles + renders: the
//  per-second `TelemetrySnapshot` (every field a performance number - nothing
//  that could carry a secret/host identity) and the `TelemetrySource` Sendable
//  reader closures the session wires from the live engine. Split out of
//  TelemetryExporter.swift to keep that unit focused on the listener/timer/file
//  lifecycle; see that file for the exporter, gate, and the gate/safety contract.
//

import Foundation

// MARK: - Snapshot

/// One fully-resolved 1Hz telemetry sample. Plain value type: built on the
/// exporter's serial queue, rendered to both Prometheus text and NDJSON. Every
/// field is a performance number - there is intentionally nothing here that
/// could carry a secret/host identity.
struct TelemetrySnapshot: Sendable {
    /// Opaque per-session id (random hex), so a scraper can tell sessions apart.
    var sessionId: String = ""
    /// Seconds since stream connect - makes the INITIAL-CONNECTION phase visible
    /// (the first samples land at sub-second offsets before frames flow).
    var sinceConnectSeconds: Double = 0
    /// Wall-clock at capture (ISO8601), for the NDJSON timeline.
    var wallClockISO8601: String = ""

    // fps
    var receivedFps: Double?
    var decodedFps: Double?
    var renderedFps: Double?

    // decode time: EMA of decode wall-clock (StatsCollector tracks no per-frame
    // histogram). True quantiles live in glimmer_decode_time_p_ms / _idr_ms.
    var decodeEmaMs: Double?

    // present cadence
    var presentCadenceErrorMs: Double?
    var presentOnTimeCount: UInt64?
    var presentLateCount: UInt64?
    /// % of NEW-frame presents that landed on-cadence (on-time / (on-time+late)).
    /// Excludes structural stale fills, so it reads smoothness independent of
    /// content-fps vs refresh - the clean judder signal.
    var presentOnTimePercent: Double?

    // P1 DECODE/VT state + counters.
    /// VTDecompressionSession (re)creates this session (monotonic). The first
    /// create plus every mid-stream param-rebuild; a short-window `increase()`
    /// brackets a decoder reset that correlates with a present hitch.
    var decoderRecreateTotal: UInt64 = 0
    /// Stream-discontinuity flushes this session (monotonic): param-set rebuilds
    /// that flushed the renderer + cleared the pacer queue. 0 on a healthy wired
    /// link; a nonzero delta is a real mid-stream format change / multi-frame skip.
    var discontinuityFlushTotal: UInt64 = 0
    /// Live DECODE state: HW-decode confirmation + pixel format + bit depth +
    /// colorspace key. Emitted as a Prometheus info-gauge (labels carry the
    /// state) + NDJSON fields. nil before the first decoded frame.
    var decodeState: TelemetryCounters.DecodeState?
    /// Latest VTDecompressionSessionCreate wall-clock cost (ms): the HW-decoder
    /// bring-up that lands on the first-frame leg. 0 before the first create.
    var vtSessionCreateMs: Double = 0
    /// Largest Cruise traversal-boost gain applied this session (1.0 = unboosted).
    var cruiseMaxGain: Double = 1.0
    /// Decoder (re)creates split by cause (monotonic; sum = decoderRecreateTotal):
    /// the one-time first create, real resolution changes, and colorspace/HDR/
    /// profile param-rebuilds that kept dims - so a recreate storm names its cause.
    var decoderRecreateFirstTotal: UInt64 = 0
    var decoderRecreateResolutionTotal: UInt64 = 0
    var decoderRecreateColorspaceTotal: UInt64 = 0

    // P1 PRESENT stale-frame REPEAT (the invisible stutter: the layer re-showing
    // the last frame when no new frame was due this vsync).
    /// Monotonic stale-frame repeat total (one per running pacer tick that
    /// presented no new frame). The exporter derives `staleRepeatsPerSecond`.
    var staleFrameRepeatTotal: UInt64 = 0
    /// Stale-frame repeats per second this window - a SPIKE while fps≈refresh is a
    /// real micro-judder (at fps<refresh a steady rate is the normal cadence).
    var staleRepeatsPerSecond: Double?
    /// Present-tick MISS totals split by root cause (DESCHEDULED = the tick thread
    /// didn't get the CPU; COALESCED = macOS delayed the CADisplayLink callback).
    /// The split picks which of two opposite fixes the residual present gap needs.
    var tickMissDescheduledTotal: UInt64 = 0
    var tickMissCoalescedTotal: UInt64 = 0
    /// Present-tick MISS split by a DIRECT promptness measure (PREEMPTED = the
    /// callback ran a full frame-or-more behind its vsync, so the thread was
    /// starved - RT not working; LINKSKIP = it ran promptly but the interval still
    /// stretched, so the display server skipped a vsync - RT working). The finer
    /// split kept alongside the descheduled/coalesced pair for an old-vs-new read.
    var tickMissPreemptedTotal: UInt64 = 0
    var tickMissLinkskipTotal: UInt64 = 0

    // P1 PRESENT/DISPLAY: EDR-headroom trend + HDR-engaged + screen + ProMotion.
    /// EDR headroom (NSScreen.maximumEDR) min/avg/max over this window. 1.0 = SDR;
    /// >1.0 = HDR engaged. The trend catches the panel falling out of HDR.
    var edrHeadroomMin: Double?
    var edrHeadroomAvg: Double?
    var edrHeadroomMax: Double?
    /// Latest discrete display state (HDR engaged, screen name, ProMotion). nil
    /// before the first probe (layer not bound to a screen yet).
    var displayState: DisplayProbe?

    // network
    var recvJitterMs: Double?
    var fecRecoveryRate: Double?
    var packetsPerSecond: Double?
    // FRACTIONAL ms (Double): the native backend measures RTT from a high-res
    // local monotonic clock, so these carry sub-ms precision. The exporter emits
    // them with 2-3 decimals (was Int-truncated, which floored a 8.73ms RTT to 8).
    var rttMs: Double?
    var rttVarianceMs: Double?

    // network - P1 receive-quality (derived from the RTP seq/arrival of packets
    // WE receive; no host tool). Loss/OOO/dup are per-second RATES the exporter
    // derives from monotonic-total deltas; goodput is the measured received
    // bitrate vs the negotiated ceiling; the gap distribution is the microburst
    // detector. All nil until the receive path has flushed its first ~2s window.
    /// Pre-FEC packet-loss rate this window (lost / expected), 0...1.
    var preFecLossRate: Double?
    /// Out-of-order (reorder) rate this window (reordered / received), 0...1.
    var outOfOrderRate: Double?
    /// Duplicate rate this window (duplicates / received), 0...1.
    var duplicateRate: Double?
    /// Measured received goodput (Mbps) - bytes/s into the pipeline this window.
    var goodputMbps: Double?
    /// Negotiated stream bitrate ceiling (Mbps) - the goodput baseline.
    var negotiatedBitrateMbps: Double?
    /// Received goodput as a fraction of the negotiated ceiling (0...1+), so a dip
    /// well below 1 (static scene) vs a saturation near 1 is one glanceable gauge.
    var goodputUtilization: Double?
    /// Inter-packet-gap distribution (µs): p50/p95 + max. The microburst tell -
    /// a tight p50 with a fat p95/max means the host (or radio) delivers in bursts.
    var packetGapP50Us: Double?
    var packetGapP95Us: Double?
    var packetGapMaxUs: Double?

    // network - FEC health (the FecHeadroomController response + per-frame parity
    // headroom). READ-ONLY observability: surfaces a degrading link's reorder-hold
    // escalation and how close frames ran to unrecoverable. nil until the first ~2s
    // receive window flushes.
    /// Live reorder-hold window (ms): base 24, cap 48.
    var fecReorderHoldMs: Double?
    /// Jitter / out-of-order / retransmit headroom level (0 = clean).
    var fecHeadroomLevel: Int?
    /// Direct-loss headroom level (0 = clean).
    var fecLossLevel: Int?
    /// Host per-frame FEC percentage (latest frame).
    var fecPercentage: Int?
    /// Spare parity shards on the worst frame this window (parity − deficit).
    var fecParityMargin: Int?

    // AWDL Wi-Fi helper: whether awdl0 is parked this stream and how many times
    // macOS re-raised it (the contention the helper fights). nil = helper off.
    var awdlSuppressing: Bool?
    var awdlReSuppressTotal: UInt64?

    // ENet reliable-stream health
    var enetSentReliable: Int?
    var enetOldestUnackedMs: UInt32?
    var enetSinceLastAckMs: UInt32?
    /// Reliable-channel retransmits this session (monotonic). A short-window
    /// `increase()` is the climb that precedes a control-stream stall - pairs with
    /// the oldest-unacked trend (enetOldestUnackedMs) to bracket a wedge.
    var enetRetransmitTotal: UInt64 = 0
    /// ACK-silence NEAR-MISS edges this session (monotonic): the control loop's ACK
    /// silence crossed a deep RTT multiple short of the 10s dead-peer cutoff and
    /// then recovered - the near-death blip the dead-peer counter never records.
    var ackSilenceNearMissTotal: UInt64 = 0

    // pacing
    var pacingQueueDepth: Int?
    var pacingAdaptiveTargetDepth: Int?
    var inFlightDecodeBacklog: Int?

    // drops by cause (session-cumulative)
    var dropsDecoder: UInt64?
    var dropsBackpressure: UInt64?
    var dropsPresentationLate: UInt64?

    // input
    var inputEventsPerSecond: Double?
    var inputFlushPerSecond: Double?
    /// Idle→active input edge count (monotonic). A short-window `increase()` of
    /// this marks the exact "resumed controlling after idle" beat so the latency
    /// transient is auto-correlatable instead of hand-reconstructed.
    var inputIdleToActiveTotal: UInt64 = 0
    /// Milliseconds since the last input event. Climbs while idle, snaps to ~0 on
    /// resume - pairs with the edge counter to bracket the idle window.
    var timeSinceLastInputMs: Double?
    /// CLIENT-SIDE input latency histogram: queue→wire age of merged input on the
    /// batcher (oldest unflushed entry → flush). A standalone stage, not part of
    /// `latencyHistograms`; rendered in the input family.
    var inputLocalLatency: LatencyHistogramSnapshot.Stage?
    /// CLIENT-SIDE input DELIVER latency histogram: the pre-hop main-thread leg
    /// (controller handler entry → batcher slot stamp). Standalone stage, rendered
    /// in the input family alongside inputLocalLatency.
    var inputDeliverLatency: LatencyHistogramSnapshot.Stage?
    /// Input flush ticks skipped by backpressure, split by signal (the input p99
    /// tail attribution): local radio backlog vs host reliable-ACK silence.
    var inputFlushSendBackloggedSkipTotal: UInt64 = 0
    var inputFlushReliableBackloggedSkipTotal: UInt64 = 0

    // display refresh / cadence (ProMotion ramp-down detector)
    var refreshMinHz: Double?
    var refreshAvgHz: Double?
    var refreshMaxHz: Double?
    /// 1 on a tick window where the realized refresh CHANGED (the ProMotion ramp
    /// edge), else 0 - emitted as a gauge so a Grafana marker lines up with the
    /// idle-resume transient.
    var refreshChanged: Bool = false

    // host encode latency trend (host idle-ramp visibility)
    var hostEncodeLatencyMinMs: Double?
    var hostEncodeLatencyAvgMs: Double?
    var hostEncodeLatencyMaxMs: Double?

    // frame size + type (big-frame / recurring-IDR hypothesis)
    var avgFrameBytes: Double?
    var maxFrameBytes: Int?
    var idrFramePercent: Double?

    // thermal + power (throttling)
    /// ProcessInfo.thermalState as an ordinal 0...3 (nominal/fair/serious/critical)
    /// so it plots as a gauge and a threshold alert is trivial.
    var thermalState: Int?
    var lowPowerModeEnabled: Bool?

    // process
    var processCpuPercent: Double?
    var threadCount: Int?

    // P1 RESOURCE (the P-vs-E-core visibility pass). Two halves that bracket "are
    // we using P vs E cores right?": the per-PROCESS per-thread view (which threads
    // are hot + their QoS INTENT, mapped to the thread name) + the process memory
    // footprint + AC/battery, captured by `ResourceTelemetry`; and the SYSTEM-side
    // P-cluster vs E-cluster ACTIVE RESIDENCY via IOReport, captured by
    // `IOReportSampler`. Both sampled on the 1Hz exporter queue only (never a hot
    // path) and only on the gate-on path. nil before the first sample / when the
    // sampler isn't available.
    var resource: ResourceSnapshot?
    var clusterResidency: ClusterResidencySnapshot?

    // event counters (monotonic)
    var rfiTotal: UInt64 = 0
    var idrRequestedTotal: UInt64 = 0
    var backlogOverflowTotal: UInt64 = 0
    var presentStallTotal: UInt64 = 0
    var frameLossTotal: UInt64 = 0
    var unrecoverableFrameTotal: UInt64 = 0
    var pacerDisabledTotal: UInt64 = 0
    /// User "that felt bad" bookmark presses (signal 4). A short-window
    /// `increase()` marks the exact beat the user flagged jank.
    var bookmarkTotal: UInt64 = 0
    /// Cruise traversal-boost batch counts: boosted (gain>1) vs identity (active
    /// motion that stayed at gain==1). The split tunes vKnee against real traces.
    var cruiseBoostedBatchesTotal: UInt64 = 0
    var cruiseIdentityBatchesTotal: UInt64 = 0

    // Per-stage latency histograms. Captured from the FrameTimingTracker's
    // cumulative atomic buckets (one snapshot/tick on the exporter queue - never
    // per-frame on the hot path). Prometheus emits these as _bucket/_sum/_count
    // so Grafana derives p50/p95/p99 with histogram_quantile; the per-second
    // NDJSON snapshot carries pre-computed p50/p95/p99 per stage for a quick tail.
    // nil when telemetry's latency rig has no data this tick. The
    // `LatencyHistogramSnapshot` type lives in TelemetryLatency.swift with the
    // rest of the latency rig. Includes the glass-to-glass (signal 1) +
    // input-to-photon (signal 2) composite stages alongside the sub-stages.
    var latencyHistograms: LatencyHistogramSnapshot?

    // Wi-Fi radio (signal 3). One CoreWLAN sample per ~1Hz tick (never the hot
    // path). nil when the sampler isn't installed; the snapshot's `linkState`
    // distinguishes associated-Wi-Fi from wired/unassociated, and the radio
    // fields are nil off Wi-Fi (an absent series == "no radio here").
    var wifi: WiFiSnapshot?

    // Build attribution (signal 5a). Compile-time constants from the generated
    // BuildInfo - the git SHA + build date stamped at `make app`, emitted as a
    // Prometheus info label + an NDJSON header field so every metric is
    // attributable to a build. Session-constant; the exporter fills these from
    // BuildInfo each tick (cheap string copies).
    var buildCommit: String = ""
    var buildDate: String = ""

    // The Sunshine server this session streams FROM (its /serverinfo hostname).
    // Emitted as the `host` Prometheus label + an NDJSON field so a multi-client
    // setup splits not just by which Mac (`client`) but by which gaming PC.
    // Session-constant; the exporter copies it from its stored server label each
    // tick.
    var serverName: String = ""

    // P1 AUDIO (the OTHER stream). All read off the always-live audio
    // counters/gauges the audio receive + output path batches into OFF the hot
    // path; nil until audio is flowing. See the AudioSnapshot type below.
    var audio: AudioSnapshot?

    // P2 SESSION-LIFECYCLE signals (all read off the always-live counters /
    // `TelemetryCounters.p2` on the exporter's 1Hz queue - never a hot path).
    //
    /// CONNECT-HANDSHAKE breakdown: per-stage connect timing. Carried on EVERY
    /// tick once complete so a scrape always sees it, but emitted as a one-shot
    /// explicit NDJSON EVENT line exactly once (see the exporter). nil before any
    /// stage has fired.
    var handshake: HandshakeBreakdown?
    /// Reconnect count this run (monotonic) - a second-or-later established edge.
    var reconnectTotal: UInt64 = 0
    /// Wake-from-sleep count this run (monotonic) - wakes while a stream was live.
    var wakeTotal: UInt64 = 0
    /// Route/link-class change count this run (monotonic) - the egress-route flip
    /// (e.g. wake on a different AP) the NDJSON route_change event already marks.
    var routeChangeTotal: UInt64 = 0
    /// Latest disconnect reason (the live default is `.none` until a terminate).
    var disconnectReason: DisconnectReason = .none
    /// PROCESS-GLOBAL per-reason disconnect totals (label, total), monotonic and
    /// surviving session resets - so a scrape catches the reason the <1ms exporter
    /// teardown would otherwise hide. Emitted as `glimmer_disconnect_total{reason}`.
    var disconnectByReason: [(label: String, total: UInt64)] = []
    /// IDR/RFI round-trip: request/matched counts + the most-recent measured RTT.
    /// The full distribution rides `latencyHistograms.idrRoundTrip`.
    var idrRoundTrip: IdrRoundTripSnapshot?
    /// CORRUPTION/ARTIFACT heuristic hits this run (monotonic) + per-second rate.
    var corruptionTotal: UInt64 = 0
    var corruptionPerSecond: Double?
}

// MARK: - Audio snapshot

/// One tick's AUDIO telemetry (signal: AUDIO - the other stream alongside the
/// video signals above). Plain value type assembled on the exporter queue from
/// `TelemetryCounters`' always-live audio totals + the published playout state.
/// Every field is a performance number - nothing that could carry a secret.
///
/// The RATES (pkts/s, loss, FEC recovery) are derived by the exporter from
/// deltas of the monotonic totals against the audio-packets delta, mirroring how
/// the video receive-quality rates are derived. The totals are carried too so a
/// Prometheus scrape gets the raw counters (Grafana derives its own rates).
struct AudioSnapshot: Sendable {
    // ---- Receive-path quality (from the audio RTP we get; no host tool) ----
    /// Audio data packets accepted this session (monotonic).
    var packetsTotal: UInt64 = 0
    /// Audio packets lost AND unrecovered by FEC this session (monotonic).
    var packetsLostTotal: UInt64 = 0
    /// Audio packets recovered by Reed-Solomon FEC this session (monotonic).
    var fecRecoveredTotal: UInt64 = 0
    /// Audio packets accepted per second this window (derived from the delta).
    var packetsPerSecond: Double?
    /// Unrecovered audio-loss rate this window (lost / expected), 0...1.
    var lossRate: Double?
    /// Audio FEC-recovery rate this window (recovered / (recovered + accepted)),
    /// 0...1 - how much on-the-wire loss FEC papered over (the lossy-link story).
    var fecRecoveryRate: Double?

    // ---- Output / playout health ----
    /// Decoded audio buffered ahead of the playhead (ms) - the buffer level/fill.
    var bufferFillMs: Double?
    /// RESAMPLER applied rate offset (ppm): the drift-tracking resampler's live
    /// `varispeed.rate − 1`, parts-per-million. 0 disengaged; ~the steady host↔Mac
    /// clock offset (tens of ppm) when converged - the direct view of the loop
    /// holding the fill, vs the av_skew that bounces with video-side timing.
    var resamplerPpm: Double?
    /// AVAudioEngine running (1 = up). 0 with packets still flowing is the
    /// post-reconnect "playout dead" signature the isShutdown-latch fix targets.
    /// nil before the engine first starts.
    var engineRunning: Bool?
    /// Windowed MINIMUM buffer fill this tick (ms) - the trough of the
    /// scheduled-ahead backlog, reset-on-read. The 1Hz `bufferFillMs` gauge can
    /// miss the instantaneous low that precedes an under-run; this is the field that
    /// proves the buffer is (or is no longer) draining toward 0. Post-fix it should
    /// stay well above 0 (the held cushion); a fall toward 0 quantifies residual
    /// drift and justifies a deeper adaptive cushion. nil when no trough this tick.
    var bufferFillMinMs: Double?
    /// Playout RE-PRIME count this session (monotonic): each full drain that forced
    /// the cushion to be re-pre-rolled - the only place the fixed cushion can still
    /// gap, so it's countable alongside the under-run total.
    var rePrimeTotal: UInt64 = 0
    /// Output under-runs this session (player drained → audible gap), monotonic.
    var underrunTotal: UInt64 = 0
    /// Output over-runs this session (decoded buffer dropped - backlog too deep),
    /// monotonic.
    var overrunTotal: UInt64 = 0
    /// Under-runs per second this window (derived from the delta) - the audible-
    /// glitch RATE, the headline output-health number.
    var underrunsPerSecond: Double?
    /// Over-runs per second this window (derived from the delta).
    var overrunsPerSecond: Double?

    // ---- Audio clock + cold-start ----
    /// AUDIO CLOCK DRIFT (ms), signed: the audio playout clock's slip vs WALL
    /// CLOCK (net of the buffer cushion), NOT a cross-stream A/V delta.
    /// + = audio media played behind wall time (device clock slow), − = ahead.
    var audioClockDriftMs: Double?
    /// Time from stream start to first decoded audio (ms) - the cold-start metric
    /// (the known ~5-7s-on-lossy-link issue). One-shot; constant once measured.
    var firstPacketMs: Double?
}

// MARK: - Snapshot source

/// What the exporter needs to assemble a snapshot, captured as Sendable closures
/// so the exporter never reaches back into actor-isolated session state. The
/// session wires these from the live StatsCollector / backend / decoder / pacer.
/// The video-stats provider returns the SAME `StreamStatsSnapshot` the overlay
/// uses (one StatsCollector read, its existing lock - no second hot-path lock).
struct TelemetrySource: Sendable {
    /// Reads `StatsCollector.snapshot()` (decode/pacing/drop counters). NOTE:
    /// `snapshot()` slides the collector's FPS window on each call, so when BOTH
    /// the overlay timer and the exporter are on (both 1Hz) each gets ~half the
    /// frames over ~half the wall-time - the per-second RATES stay correct, only
    /// the averaging window halves (acceptable noise for a diagnostic). Reuses
    /// the collector's existing lock; no second hot-path lock is introduced.
    var videoStats: @Sendable () -> StreamStatsSnapshot
    /// Decoder + backpressure + presentation-late cumulative drop totals.
    var decoderDrops: @Sendable () -> UInt64
    var backpressureDrops: @Sendable () -> UInt64
    var presentationLateDrops: @Sendable () -> UInt64
    /// ENet RTT (fractional ms, high-res local clock) + reliable-stream health.
    var estimatedRtt: @Sendable () -> (rttMs: Double, varianceMs: Double)?
    var enetHealth: @Sendable () -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)?
    /// Pacer present-side liveness (adaptive depth, queue depth) + in-flight decode.
    var pacingLiveness: @Sendable () -> FramePacer.LivenessSnapshot?
    var inFlightDecodeBacklog: @Sendable () -> Int
    /// Per-second display-refresh window (min/avg/max Hz + change marker). RESET-
    /// ON-READ, so the exporter is its ONLY caller and reads it exactly once per
    /// capture tick. nil when pacing isn't up.
    var refreshWindow: @Sendable () -> FramePacer.RefreshWindowSnapshot?
    /// One main-actor PRESENT/DISPLAY probe (EDR headroom + HDR-engaged + screen +
    /// ProMotion) for the P1 display sampler. `@MainActor` because the underlying
    /// NSScreen / layer reads are main-only; the `DisplayTelemetry` sampler calls
    /// it from a MAIN-queue 1Hz timer built only on the gate-on path (never a hot
    /// path). nil before the layer is bound to a screen.
    var displayProbe: @MainActor @Sendable () -> DisplayProbe?
}
