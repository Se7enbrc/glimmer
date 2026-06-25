//
//  RtpVideoQueue.swift
//
//  The Swift-native RTP video reassembly + FEC state machine. Ports
//  RtpVideoQueue.c (RtpvAddPacket, reconstructFrame, stageCompleteFecBlock,
//  submitCompletedFrame), driving Reed-Solomon recovery (ReedSolomon.swift) and
//  emitting in-order completed packets to the VideoDepacketizer.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  WIRE LAYOUT (Video.h, big/little-endian split is load-bearing):
//   - RTP_PACKET (BIG-endian on wire): header(1) packetType(1) seq(2 BE)
//     timestamp(4 BE) ssrc(4 BE) = 12 bytes. FLAG_EXTENSION(0x10) is always set
//     so dataOffset = 12 + 4 = 16. The caller (VideoRtpReceiver) hands us the
//     full datagram bytes; we host-byteswap seq/timestamp/ssrc.
//   - NV_VIDEO_PACKET (LITTLE-endian) begins at dataOffset(16):
//     streamPacketIndex(4 LE) frameIndex(4 LE) flags(1) extraFlags(1)
//     multiFecFlags(1) multiFecBlocks(1) fecInfo(4 LE) = 16 bytes.
//
//  The FEC block operates over the WHOLE packet (RTP+NV+payload), zero-padded to
//  receiveSize = packetSize + MAX_RTP_HEADER_SIZE(16). Recovered shards are
//  complete RTP packets re-fed through queuePacket. Multi-FEC (host 7.1.431+):
//  a frame can span up to 4 FEC blocks; only after the LAST block is the frame
//  submitted.

import Foundation

final class RtpVideoQueue {
    // NOTE: many type members below are `internal` (no `private`) rather than
    // truly private. The reconstruct + FEC-staging + submit/emit half of this
    // state machine lives in the same-module RtpVideoQueue+Reconstruct.swift
    // extension (split out to keep each file under the SwiftLint length limit),
    // and a Swift extension in a separate file can only reach non-private members.
    // Everything stays touched ONLY on the single receive thread, so the relaxed
    // visibility changes no isolation guarantee - same contract as the
    // RtpVideoQueue+ReceiveQuality.swift split.
    static let cat = "NativeVideo"

    // Wire constants.
    static let FIXED_RTP_HEADER_SIZE = 12
    static let MAX_RTP_HEADER_SIZE = 16
    static let FLAG_EXTENSION: UInt8 = 0x10
    static let FLAG_SOF: UInt8 = 0x4
    static let FLAG_EOF: UInt8 = 0x2
    static let FLAG_CONTAINS_PIC_DATA: UInt8 = 0x1

    // Return codes (RtpVideoQueue.h).
    enum AddResult { case queued, rejected }

    /// One pending/completed packet. We hold the full RTP packet bytes (so FEC
    /// can reconstruct headers) plus the decoded fields.
    final class Entry {
        var bytes: [UInt8]          // full RTP packet (RTP+NV+payload), host-order seq/ts/ssrc
        var length: Int             // valid length within bytes
        var sequenceNumber: UInt16
        var rtpTimestamp: UInt32
        var ssrc: UInt32
        var header: UInt8
        var isParity: Bool
        var presentationTimeUs: UInt64
        var receiveTimeUs: UInt64 = 0
        init(bytes: [UInt8], length: Int, seq: UInt16, ts: UInt32, ssrc: UInt32,
             header: UInt8, isParity: Bool) {
            self.bytes = bytes
            self.length = length
            self.sequenceNumber = seq
            self.rtpTimestamp = ts
            self.ssrc = ssrc
            self.header = header
            self.isParity = isParity
            self.presentationTimeUs = (UInt64(ts) * 1000) / 90
        }
    }

    let depacketizer: VideoDepacketizer
    let packetSize: Int
    let multiFecCapable: Bool

    /// Best-effort sink for per-frame FEC status (Sunshine SS_FRAME_FEC_PTYPE).
    /// Called from reportFinalFrameFecStatus() at the SAME three call sites as
    /// moonlight (FEC recovery needed; frame/block abandoned). The receiver
    /// (EnetControlChannel) queues + sends it UNRELIABLE on the next ping tick.
    /// nil on construction → no-op (e.g. unit tests / receivers without control).
    var frameFecStatusSink: ((FrameFecStatus) -> Void)?

    // Queue state (mirrors RTP_VIDEO_QUEUE). `internal` where the reconstruct
    // extension also reads/writes them (see the visibility note at the top).
    var currentFrameNumber: UInt32 = 1
    var multiFecCurrentBlockNumber: UInt8 = 0
    var multiFecLastBlockNumber: UInt8 = 0

    var pending: [Entry] = []        // pendingFecBlockList
    var completed: [Entry] = []       // completedFecBlockList

    var bufferLowestSequenceNumber: UInt16 = 0
    var bufferFirstParitySequenceNumber: UInt16 = 0
    var bufferHighestSequenceNumber: UInt16 = 0
    var nextContiguousSequenceNumber: UInt16 = 0
    var receivedHighestSequenceNumber: UInt16 = 0
    var bufferDataPackets = 0
    var bufferParityPackets = 0
    var fecPercentage = 0
    var receivedDataPackets = 0
    var receivedParityPackets = 0
    var missingPackets = 0
    var useFastQueuePath = true
    var reportedLostFrame = false
    var bufferFirstRecvTimeUs: UInt64 = 0

    var loggedFirstFecRecovery = false

    /// Cauchy-decoder cache keyed by (dataShards, parityShards). The matrix is a pure
    /// function of the shape, so rebuilding it per recovered frame (the shape repeats
    /// across a loss burst) is wasted GF work; memoize by shape. Single receive
    /// thread, so the plain dictionary needs no lock. `internal`: read/written by the
    /// reconstruct extension. Bounded by the handful of (ds,ps) shapes a stream uses.
    var rsDecoderCache: [ReedSolomonShape: ReedSolomon] = [:]
    struct ReedSolomonShape: Hashable { let ds: Int; let ps: Int }

    // MARK: - Receive-side reorder tolerance
    //
    // On a reordering link the tail/EOF data shards of frame N frequently arrive
    // AFTER the SOF of frame N+1 (cross-frame reordering). Declaring loss the
    // instant N+1 starts - as the unmodified port does - fires a false-loss RFI
    // even though N's late shards are microseconds away and FEC could still
    // complete it. We mirror moonlight's receivedOosData signal ("this link
    // reorders") and, ONLY while it's set, hold the just-arrived next-frame
    // packet in a one-deep deferred slot for a bounded reorder window so the late
    // shard can land and complete frame N via FEC. Everything is gated behind
    // receivedOosData (false on a clean in-order stream), so a good link is
    // byte-identical to before: zero hold, zero added latency.

    /// True once a genuinely out-of-order datagram has been observed (a packet
    /// whose seq precedes a previously-queued seq). Mirrors moonlight's
    /// RtpVideoQueue.c receivedOosData. Gates the entire reorder-hold path.
    /// `internal`: read/written by the add path in RtpVideoQueue+AddPacket.swift.
    var receivedOosData = false
    /// presentationTimeUs of the last OOS observation; the cooldown that returns
    /// us to the strict no-hold regime is measured against it.
    var lastOosPresentationUs: UInt64 = 0
    /// Cooldown after which clean sequenced data clears `receivedOosData` (5 min,
    /// matching moonlight's SPECULATIVE_RFI_COOLDOWN_PERIOD_US).
    static let speculativeRfiCooldownUs: UInt64 = 300_000_000
    /// Bounded cross-frame reorder window: how long (wall-clock from the current
    /// frame's first receive) we hold an incomplete frame before declaring loss
    /// when the next frame's first packet arrives. 24ms ≈ 2.7 frame intervals at
    /// 114fps - widened from 12ms so the OBSERVED ~22ms cross-frame jitter spikes
    /// (which exceeded the old 12ms window and generated false-loss RFI clusters,
    /// rfi_total +20) no longer fall outside the window. Still well under the
    /// worst-case 56ms jitter envelope, and the right-sized FramePacer absorbs the
    /// added hold. Strictly gated behind `receivedOosData` (false on a clean
    /// in-order link), so a non-reordering stream is byte-identical to before:
    /// zero hold, zero added latency.
    ///
    /// This is the BASELINE (steady-state) value. PROACTIVE FEC headroom: on a
    /// SUSTAINED degradation trend the `fecHeadroom` controller widens the live
    /// window in bounded steps (up to 48ms) so the host's existing parity gets more
    /// time to complete a marginal frame via FEC BEFORE it tips into unrecoverable -
    /// then relaxes back to this baseline when the link clears. The live value is
    /// read via `reorderWindowUs` below; this constant is the controller's floor.
    /// (See FecHeadroomController.swift for the full safety contract.)
    static let baseReorderWindowUs: UInt64 = 24_000
    /// The LIVE reorder-hold window (µs): the proactive-FEC-headroom controller's
    /// current value, which equals `baseReorderWindowUs` on a clean link and steps
    /// up under a sustained degradation trend. Single-thread (receive thread), so a
    /// plain computed read of the controller's level is race-free.
    /// `internal`: read by the reorder-hold gate in RtpVideoQueue+AddPacket.swift.
    var reorderWindowUs: UInt64 { fecHeadroom.holdWindowUs }

    /// PROACTIVE FEC headroom controller. Driven once per ~2s receive-metrics
    /// window from maybeLogMetrics off the recv-jitter / out-of-order / ENet-
    /// retransmit signals; widens/relaxes `reorderWindowUs` on a sustained trend.
    /// Conservative + bounded + hysteretic by construction (see the type). Owned
    /// here on the single receive thread, so it needs no lock.
    var fecHeadroom = FecHeadroomController()
    /// ENet reliable-retransmit total snapshotted at the last window flush, so the
    /// controller sees the per-WINDOW delta (a trend signal) rather than the
    /// session-monotonic total. The retransmit counter lives in TelemetryCounters
    /// (it's incremented on the control thread); reading its value here once per
    /// ~2s window is a single cheap lock far off the per-datagram path.
    private var lastRetransmitTotalSnapshot: UInt64 = 0
    /// Unrecoverable-frame total snapshotted at the last window flush, so the FEC
    /// headroom controller's LOSS axis sees the per-WINDOW delta - the
    /// reactive loss signal alongside this window's `fecRecoveredFramesInWindow`.
    /// Same single-cheap-lock-per-2s-window cost as the retransmit snapshot above.
    private var lastUnrecoverableTotalSnapshot: UInt64 = 0
    /// One-deep slot for the deferred next-frame datagram while we hold the
    /// current incomplete frame. At most ONE frame of cross-frame reordering is
    /// absorbed; a SECOND new frame forces immediate loss declaration.
    /// `internal`: managed by the reorder-hold path in RtpVideoQueue+AddPacket.swift.
    var deferredDatagram: (bytes: [UInt8], receiveTimeUs: UInt64)?

    // --- Receive-path smoothness metrics (Track B; logged via Diag since we don't
    // own StatsCollector). Emitted ~every 2s so stream smoothness is measurable
    // straight from the logs without the overlay. ---
    /// RFC 3550-style smoothed inter-arrival jitter (microseconds) over the RTP
    /// receiveTimeUs of incoming datagrams. transit = receiveTime - presentation.
    private var jitterUs = 0.0
    private var lastTransitUs = 0.0
    private var haveLastTransit = false
    /// Frames seen vs. frames that needed Reed-Solomon recovery in the window.
    /// `internal`: tallied by submitCompletedFrame in the reconstruct extension.
    var framesInWindow = 0
    var fecRecoveredFramesInWindow = 0
    /// Whether the CURRENT frame needed FEC recovery (latched in reconstructFrame,
    /// counted once when the frame is submitted/dropped).
    var currentFrameNeededFec = false
    /// Datagrams seen in the window (for a packets/s sanity figure).
    private var packetsInWindow = 0
    private var metricsWindowStartUs: UInt64 = 0
    private static let metricsWindowUs: UInt64 = 2_000_000  // 2s

    // --- P1 NETWORK receive-quality accumulators (Track B, opt-in telemetry).
    // All derived purely from the RTP sequence numbers + arrival times of packets
    // WE receive - no host tool - and folded into the always-live TelemetryCounters
    // in the same ~2s window that already flushes the totals above. The hot
    // per-datagram path gains only a few integer compares + a histogram bump (no
    // lock, no alloc, no clock read beyond the receiveTimeUs jitter already reads).
    //
    // Internal (not private) so the accumulation methods can live in the focused
    // RtpVideoQueue+ReceiveQuality.swift extension (extensions can't hold stored
    // state, so the fields stay here while the logic moves out - which keeps this
    // file's type body from growing past the SwiftLint limit). Same isolation as
    // the rest of the queue: all touched only on the single receive thread.
    //
    /// Highest RTP seq observed in the session-long sequence space (16-bit,
    /// wrap-aware). Drives pre-FEC loss (gaps below the highest) + out-of-order
    /// (a seq behind it). Seeded on the first datagram.
    var seqHighestSeen: UInt16 = 0
    var haveSeqBaseline = false
    /// Per-window receive-quality tallies (flushed + zeroed in maybeLogMetrics).
    /// `windowLostPreFec` adds the gap (forward jump − 1) each time the highest seq
    /// grows - counted BEFORE FEC, so it is the true on-the-wire loss the host
    /// can't see for us. The exporter derives the loss RATE as
    /// lost / (lost + received) (received = the videoPacketsTotal delta), i.e.
    /// lost / expected, without a separate expected counter.
    var windowLostPreFec = 0
    var windowOutOfOrder = 0
    var windowDuplicate = 0
    /// FEC observability (read-only): the smallest parity headroom seen on a
    /// FEC-recovered frame this window (parity − data deficit), tracked in
    /// logFecRecovery and published + reset in maybeLogMetrics. `Int.max` = no
    /// recovery this window, in which case the publish reports the current frame's
    /// full parity count (the healthy baseline) instead.
    var windowMinParityMargin = Int.max
    /// CROSS-WINDOW reorder credit (metric honesty). A reorder that fills a gap
    /// counted as loss should UNCOUNT one loss slot - but the gap and its filling
    /// reorder often straddle a maybeLogMetrics window boundary (the forward jump
    /// lands at the tail of one ~2s window, the late packet arrives at the head of
    /// the next), so a same-window-only decrement loses the credit and the reorder
    /// reads as permanent loss (the pre_fec_lost == out_of_order artifact on a clean
    /// link). When this window's `windowLostPreFec` is already 0, the credit is
    /// PARKED here and applied to a LATER window's loss before it is flushed, so a
    /// pure reorder never double-counts as loss across the boundary. Persists across
    /// the window reset (it is a debt against future loss, not a per-window tally).
    var pendingReorderCredit = 0
    /// Recent seqs for duplicate vs reorder disambiguation. A small ring of the
    /// last seqs seen this window: a behind-highest arrival that's in the ring is a
    /// DUPLICATE, otherwise a genuine reorder. Bounded + cleared per window so it
    /// can't grow; sized well over the deepest realistic reorder/duplication burst.
    var recentSeqs: Set<UInt16> = []
    var recentSeqOrder: [UInt16] = []
    static let recentSeqCapacity = 512
    /// Cap on the parked cross-window reorder credit. A credit legitimately spans
    /// only ONE ~2s window boundary (gap at the tail of a window, late filler at the
    /// head of the next), so a small bound is ample; capping stops a stale credit
    /// (a reorder whose matching loss already aged out) from suppressing a genuine
    /// later loss spike. Sized over the deepest realistic single-window reorder burst.
    static let maxPendingReorderCredit = 256

    // --- Inter-packet-gap distribution (microburst detector). A 16-bucket
    // log-spaced histogram over the inter-arrival gap (µs) between consecutive
    // datagrams, plus the running max. The exporter reads p50/p95 (estimated from
    // the cumulative buckets) + max once per 1Hz tick. Histogram-not-reservoir for
    // the same reason the latency rig uses one: a record is a branchless bucket
    // find + an integer bump - no per-packet allocation or sort on the hot path. ---
    var lastArrivalUs: UInt64 = 0
    var haveLastArrival = false
    var gapBuckets = [Int](repeating: 0, count: RtpVideoQueue.gapBoundsUs.count + 1)
    var gapCount = 0
    var gapMaxUs: Double = 0
    /// Ascending upper bounds (µs) for the gap histogram. Spans sub-100µs
    /// (back-to-back wire packets at 4K240 ~ tens of µs apart) through a few ms
    /// (a microburst stall between bursts). The implicit top bucket catches
    /// anything larger.
    static let gapBoundsUs: [Double] = [
        25, 50, 75, 100, 150, 200, 300, 500, 750, 1_000, 1_500, 2_000, 3_000, 5_000, 10_000, 20_000
    ]

    init(depacketizer: VideoDepacketizer, packetSize: Int, multiFecCapable: Bool) {
        self.depacketizer = depacketizer
        self.packetSize = packetSize
        self.multiFecCapable = multiFecCapable
    }

    // MARK: - 16-bit wraparound (Limelight-internal.h)

    @inline(__always) static func u16(_ x: Int) -> UInt16 { UInt16(truncatingIfNeeded: x) }
    @inline(__always) static func isBefore16(_ x: UInt16, _ y: UInt16) -> Bool {
        (x &- y) > (UInt16.max / 2)
    }
    @inline(__always) static func isBefore32(_ x: UInt32, _ y: UInt32) -> Bool {
        (x &- y) > (UInt32.max / 2)
    }

    /// Host-order RTP header fields parsed off a datagram (RTP fields are
    /// BIG-endian on the wire; bundled to keep addPacket's signature small).
    struct ParsedRtp {
        let bytes: [UInt8]
        let length: Int
        let header: UInt8
        let seq: UInt16
        let timestamp: UInt32
        let ssrc: UInt32
        let dataOffset: Int
    }

    // MARK: - Entry point: a raw datagram from the socket

    /// Parse + enqueue one received video datagram (already decrypted /
    /// plaintext). Returns whether the buffer was queued or rejected.
    @discardableResult
    func addRawDatagram(_ datagram: [UInt8], receiveTimeUs: UInt64) -> AddResult {
        dispatchDatagram(datagram, receiveTimeUs: receiveTimeUs, isReplay: false)
    }

    /// Shared parse + dispatch. `isReplay` is true when re-driving a deferred
    /// cross-frame-reorder packet: jitter accumulation is skipped so
    /// the held datagram isn't double-counted in the receive-smoothness metric.
    @discardableResult
    func dispatchDatagram(_ datagram: [UInt8], receiveTimeUs: UInt64,
                          isReplay: Bool) -> AddResult {
        // minSize = sizeof(RTP_PACKET) = 12 (no enc header - plaintext).
        guard datagram.count >= Self.FIXED_RTP_HEADER_SIZE else { return .rejected }

        let header = datagram[0]
        // FLAG_EXTENSION is required for all supported GFE/Sunshine versions.
        var dataOffset = Self.FIXED_RTP_HEADER_SIZE
        if header & Self.FLAG_EXTENSION != 0 { dataOffset += 4 }

        // RTP fields are BIG-endian.
        let seq = (UInt16(datagram[2]) << 8) | UInt16(datagram[3])
        let timestamp = (UInt32(datagram[4]) << 24) | (UInt32(datagram[5]) << 16)
            | (UInt32(datagram[6]) << 8) | UInt32(datagram[7])
        let ssrc = (UInt32(datagram[8]) << 24) | (UInt32(datagram[9]) << 16)
            | (UInt32(datagram[10]) << 8) | UInt32(datagram[11])

        let parsed = ParsedRtp(bytes: datagram, length: datagram.count, header: header,
                               seq: seq, timestamp: timestamp, ssrc: ssrc, dataOffset: dataOffset)
        if !isReplay {
            accumulateJitter(timestamp: timestamp, receiveTimeUs: receiveTimeUs)
            // P1 NETWORK receive-quality: pre-FEC loss / out-of-order / duplicate
            // off the RTP seq, plus the inter-packet-gap histogram off the arrival
            // time. Replays are skipped (the original arrival was already counted).
            accumulateReceiveQuality(seq: seq, receiveTimeUs: receiveTimeUs)
        }

        // If a previous datagram triggered a cross-frame reorder hold,
        // the current frame's reorder window may have elapsed before this
        // datagram arrived. Flush the deferred next-frame packet first if the
        // window is up, so loss is declared no later than reorderWindowUs after
        // the current frame's first receive - bounding the worst-case hold.
        // (Skipped on a replay: the replay IS the flush, and the slot is already
        // cleared, so this would be a redundant no-op.)
        if !isReplay {
            flushDeferredIfWindowElapsed(nowUs: receiveTimeUs)
        }

        // A replayed deferred packet must NEVER be re-held (that could strand it
        // and stall progress); force the immediate path for it.
        return addPacket(parsed, receiveTimeUs: receiveTimeUs, allowHold: !isReplay)
    }

    // MARK: - Receive-path smoothness metrics

    /// RFC 3550 inter-arrival jitter over the RTP receive timeline. transit is the
    /// difference between a packet's wall-clock receive time and its RTP
    /// presentation time (90kHz → µs); jitter is the smoothed |Δtransit|. Also
    /// counts packets for the periodic window line. Cheap; runs per datagram.
    private func accumulateJitter(timestamp: UInt32, receiveTimeUs: UInt64) {
        if metricsWindowStartUs == 0 { metricsWindowStartUs = receiveTimeUs }
        packetsInWindow += 1

        let presentationUs = Double(UInt64(timestamp) * 1000 / 90)
        let transitUs = Double(receiveTimeUs) - presentationUs
        if haveLastTransit {
            let transitDelta = abs(transitUs - lastTransitUs)
            // jitter += (|D| - jitter) / 16  (RFC 3550 6.4.1).
            jitterUs += (transitDelta - jitterUs) / 16.0
        }
        lastTransitUs = transitUs
        haveLastTransit = true

        maybeLogMetrics(nowUs: receiveTimeUs)
    }

    // The P1 NETWORK per-datagram receive-quality + inter-packet-gap accumulation
    // (accumulateReceiveQuality / rememberSeq / observeGap / gapQuantile) lives in
    // RtpVideoQueue+ReceiveQuality.swift, split out to keep this type's body under
    // the SwiftLint limit. The stored accumulators above are `internal` so that
    // extension can reach them; everything still runs on the single receive thread.

    /// Emit one periodic receive-smoothness line (~every 2s): smoothed jitter,
    /// FEC-recovery rate (fraction of frames that needed Reed-Solomon recovery),
    /// and the packet rate. Resets the window afterward.
    private func maybeLogMetrics(nowUs: UInt64) {
        guard nowUs &- metricsWindowStartUs >= Self.metricsWindowUs else { return }
        let windowSec = Double(nowUs &- metricsWindowStartUs) / 1_000_000.0
        let pps = windowSec > 0 ? Double(packetsInWindow) / windowSec : 0
        let fecRate = framesInWindow > 0
            ? Double(fecRecoveredFramesInWindow) / Double(framesInWindow) : 0
        let jitterMs = String(format: "%.2f", jitterUs / 1000.0)
        let fecPct = String(format: "%.1f", fecRate * 100.0)
        let ppsStr = String(format: "%.0f", pps)
        // DEBUG (demoted from INFO, log diet): every number here already rides
        // the telemetry NDJSON per row (recv_jitter_ms / fec_recovery_rate /
        // packets_per_second), so at INFO this ~2s line only padded the session
        // file - thousands of copies in one measured session log. Ring/os_log
        // keep it for live debugging; the file sink takes INFO+ by default.
        Diag.debug("NativeVideo METRIC recv-jitter=\(jitterMs)ms fec-recovery-rate=\(fecPct)% "
            + "(\(fecRecoveredFramesInWindow)/\(framesInWindow) frames) pkts/s=\(ppsStr)", Self.cat)

        // Feed the opt-in telemetry exporter. Monotonic window deltas (so the
        // exporter derives pkts/s + fec-recovery-rate from total-deltas) plus the
        // live smoothed-jitter gauge. These are batched here (~2s) rather than
        // per-packet so the hot receive path adds nothing - the increments are
        // off the per-datagram path. Always live; the exporter only reads them
        // when telemetry is on.
        let counters = TelemetryCounters.shared
        counters.videoPacketsTotal.increment(by: UInt64(max(0, packetsInWindow)))
        counters.videoFramesTotal.increment(by: UInt64(max(0, framesInWindow)))
        counters.fecRecoveredFramesTotal.increment(by: UInt64(max(0, fecRecoveredFramesInWindow)))
        counters.setRecvJitterMs(jitterUs / 1000.0)

        // P1 NETWORK: fold the window's pre-FEC loss / out-of-order / duplicate
        // tallies into their always-live monotonic totals (the exporter derives the
        // per-second RATES from deltas vs videoPacketsTotal), and publish the
        // inter-packet-gap distribution gauge. Batched here (~2s) so the per-packet
        // path stays a few integer adds; the counters/gauge are only read when
        // telemetry is on.
        // Apply any parked cross-window reorder credit so a reorder whose gap was
        // counted as loss in a different window cancels that loss instead of
        // double-counting (the pre_fec_lost == out_of_order artifact on a clean
        // link). Returns the corrected loss; leftover credit stays parked.
        let correctedLostPreFec = applyPendingReorderCredit()
        counters.videoPacketsLostPreFecTotal.increment(by: UInt64(correctedLostPreFec))
        counters.videoPacketsOutOfOrderTotal.increment(by: UInt64(max(0, windowOutOfOrder)))
        counters.videoPacketsDuplicateTotal.increment(by: UInt64(max(0, windowDuplicate)))
        if gapCount > 0 {
            counters.setPacketGap(TelemetryCounters.PacketGapSnapshot(
                p50Us: gapQuantile(0.50), p95Us: gapQuantile(0.95), maxUs: gapMaxUs))
        }

        // PROACTIVE FEC headroom: step the reorder-hold window on a SUSTAINED
        // trend in the three receive-side health signals - the recv-jitter we just
        // smoothed, this window's genuine reorders, and the per-WINDOW ENet
        // reliable-retransmit delta. The retransmit counter is incremented on the
        // control thread; we snapshot its monotonic total once per ~2s window here
        // and hand the controller the delta so it sees a trend, not the lifetime
        // total. Driving the controller from this ~2s window (NOT the per-datagram
        // path) keeps the hot path untouched. Conservative + bounded + hysteretic
        // (see FecHeadroomController) - and it changes only a LOCAL wait, sending
        // nothing on the wire, so it can never worsen a marginal link. Done BEFORE
        // the window accumulators reset below so `windowOutOfOrder` still holds this
        // window's value.
        let retransmitTotalNow = counters.enetRetransmitTotal.value
        let retransmitDelta = retransmitTotalNow >= lastRetransmitTotalSnapshot
            ? Int(retransmitTotalNow - lastRetransmitTotalSnapshot) : 0
        lastRetransmitTotalSnapshot = retransmitTotalNow
        // When the reconciler is enabled, CONSUME the unified
        // jitter→headroom decision EnvSignalController publishes (one short
        // controller-lock pull off this ~2s window - NEVER the per-datagram path)
        // instead of self-deciding from raw jitter, so this controller and the
        // FramePacer adaptive depth walk off ONE shared level. The HARD FLOORS are
        // unchanged: the live `reorderWindowUs` still caps at `maxHoldUs` (48ms),
        // and the queue's `isFecRecoveryStillPossible()` gate in the add path is a
        // separate floor the reconciler can't reach. When the reconciler is off
        // (the kill-switch A/B), the controller self-decides exactly as today.
        let jitterChanged: Bool
        if EnvSignalController.reconcilerEnabled {
            let decision = EnvSignalController.shared.decision
            jitterChanged = fecHeadroom.reconcile(headroomLevel: decision.headroomLevel,
                                                  smoothedJitterMs: decision.smoothedJitterMs)
        } else {
            jitterChanged = fecHeadroom.observeWindow(recvJitterMs: jitterUs / 1000.0,
                                                      outOfOrder: windowOutOfOrder,
                                                      retransmits: retransmitDelta)
        }
        // LOSS AXIS: drive the SEPARATE loss accumulator off this window's
        // direct loss evidence - frames the host's parity recovered
        // (`fecRecoveredFramesInWindow`) and frames that went unrecoverable (a
        // per-window delta off the monotonic total). Runs every window regardless
        // of the reconciler (orthogonal to the jitter axis) and BEFORE the window
        // accumulators reset below, so `fecRecoveredFramesInWindow` still holds
        // this window's count. It widens the reorder-hold ONLY - never the pacer.
        let unrecoverableTotalNow = counters.unrecoverableFrameTotal.value
        let unrecoverableDelta = unrecoverableTotalNow >= lastUnrecoverableTotalSnapshot
            ? Int(unrecoverableTotalNow - lastUnrecoverableTotalSnapshot) : 0
        lastUnrecoverableTotalSnapshot = unrecoverableTotalNow
        let lossChanged = fecHeadroom.observeLoss(fecRecovered: fecRecoveredFramesInWindow,
                                                  unrecoverable: unrecoverableDelta)
        if jitterChanged || lossChanged {
            Diag.notice("NativeVideo PROACTIVE FEC headroom: reorder-hold → "
                + "\(reorderWindowUs / 1000)ms (jitter-lvl \(fecHeadroom.level) "
                + "loss-lvl \(fecHeadroom.lossLevel)) "
                + "[recv-jitter=\(String(format: "%.1f", jitterUs / 1000.0))ms "
                + "ooo=\(windowOutOfOrder) retransmit=\(retransmitDelta) "
                + "fec-recovered=\(fecRecoveredFramesInWindow) unrecoverable=\(unrecoverableDelta)]",
                Self.cat)
        }

        // FEC HEALTH gauge (read-only): publish the controller's just-stepped
        // response + the per-frame parity headroom for the dashboard. Pure read-out
        // - nothing here feeds back into the FEC/reorder logic. `fecPercentage` is the
        // latest frame's (it persists across windows). `parityMargin` is this window's
        // worst RECOVERED-frame headroom, or nil when no recovery occurred this window
        // - "full parity, nothing consumed" is not a margin and is published as absent
        // so the series only carries genuine near-miss evidence.
        counters.setFecHealth(TelemetryCounters.FecHealthSnapshot(
            reorderHoldMs: Double(reorderWindowUs) / 1000.0,
            headroomLevel: fecHeadroom.level,
            lossLevel: fecHeadroom.lossLevel,
            fecPercentage: fecPercentage,
            parityMargin: windowMinParityMargin == Int.max ? nil : windowMinParityMargin))

        framesInWindow = 0
        fecRecoveredFramesInWindow = 0
        packetsInWindow = 0
        metricsWindowStartUs = nowUs

        // Reset the P1 receive-quality window accumulators alongside the others so
        // the rates track the current ~2s slice. seqHighestSeen / haveSeqBaseline
        // PERSIST (the sequence space is session-long, not per-window). The gap
        // histogram + recent-seq ring reset so each window's distribution + dup
        // horizon is fresh; gapMaxUs resets so the published max is per-window.
        windowLostPreFec = 0
        windowOutOfOrder = 0
        windowDuplicate = 0
        windowMinParityMargin = Int.max
        for index in gapBuckets.indices { gapBuckets[index] = 0 }
        gapCount = 0
        gapMaxUs = 0
        recentSeqs.removeAll(keepingCapacity: true)
        recentSeqOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - little-endian read

    @inline(__always) func le32(_ b: [UInt8], _ off: Int) -> UInt32 {
        // Defense-in-depth: every current caller (AddPacket / Reconstruct) already
        // rejects packets shorter than the NV header before reading, so this guard
        // never fires today. It's here so the bare helper can't trap on a future
        // caller that forgets the length check - a short read degrades to 0, not a
        // hard crash in a release build where array bounds checks are compiled out.
        guard off >= 0, off + 3 < b.count else { return 0 }
        return UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}
