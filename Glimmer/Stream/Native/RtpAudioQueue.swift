//
//  RtpAudioQueue.swift
//
//  Audio FEC-block reassembly state machine for the Swift-native AUDIO receive
//  path. Ports RtpAudioQueue.c, reduced to the release-build subset (no
//  FEC_VALIDATION_MODE, no debug invariant asserts).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  MODEL: audio is sent as RS(4,2) FEC blocks. Each block covers 4 consecutive
//  RTP sequence numbers starting on a multiple of 4 (baseSequenceNumber), plus 2
//  parity shards. Data packets are RTP_PAYLOAD_TYPE_AUDIO (97); parity packets
//  are RTP_PAYLOAD_TYPE_FEC (127) carrying a 12-byte AUDIO_FEC_HEADER after the
//  12-byte RTP header.
//
//  FLOW: `addPacket` returns one of:
//   - .handleNow   : the in-order fast path - decode this packet immediately.
//   - .packetReady : drain via `getQueuedPacket()` in a loop until nil.
//   - .none        : packet consumed/duplicate/rejected; nothing to decode now.
//  `getQueuedPacket()` returns either assembled RTP-packet bytes (12-byte header
//  + opus payload) or a size-0 placeholder (PLC marker) for an unrecovered gap
//  when the block is played out with discontinuities.
//
//  COMPATIBILITY: FEC requires APP_VERSION_AT_LEAST(7,1,415). For older hosts,
//  or hosts that violate the FEC-block alignment invariant (non-4-aligned base
//  seq), `incompatibleServer` is set and ALL data packets are passed straight
//  through (HANDLE_NOW), FEC packets dropped. A block-SIZE mismatch is NOT a
//  one-strike kill: a single mismatched block is dropped (counted + warned
//  once) and only a sustained streak - every contact mismatching - flips
//  `incompatibleServer`, loudly. Every flip logs what was disabled and why;
//  the old silent first-contact flip killed audio FEC for an entire session.
//
//  THREADING: single-receive-thread access (RtpAudioReceiver's serial queue), so
//  this class needs no internal locking - exactly like the C single receive
//  thread. It is a reference type so the block list can be mutated in place.

import Foundation

/// The dispatch result of `RtpAudioQueue.addPacket`. Mirrors the
/// RTPQ_RET_* return codes (RtpAudioQueue.h) collapsed to the cases the receiver
/// actually branches on.
enum RtpaResult {
    /// In-order data packet - decode it immediately (RTPQ_RET_HANDLE_NOW).
    case handleNow
    /// One or more packets are ready; drain via getQueuedPacket (RTPQ_RET_PACKET_READY).
    case packetReady
    /// Nothing to do (consumed into a block, duplicate, or rejected).
    case none
}

/// A drained queue entry from `getQueuedPacket`.
enum RtpaQueuedPacket {
    /// Assembled RTP packet: 12-byte RTP header + opus payload bytes.
    case bytes([UInt8])
    /// An unrecovered gap - the caller must perform packet-loss concealment.
    case lostPlaceholder
}

final class RtpAudioQueue {
    // NOTE: several type members below are `internal` (no `private`) rather than
    // truly private. The FEC machinery half of this state machine (block lookup/
    // creation + Reed-Solomon recovery) lives in the same-module
    // RtpAudioQueue+Fec.swift extension (split out to keep each file under the
    // SwiftLint length limit), and a Swift extension in a separate file can only
    // reach non-private members. Everything stays touched ONLY on the single
    // receive thread, so the relaxed visibility changes no isolation guarantee -
    // same contract as the RtpVideoQueue splits.

    // Constants (RtpAudioQueue.h:18-20, plus the OOS wait).
    static let dataShards = 4         // RTPA_DATA_SHARDS
    static let fecShards = 2          // RTPA_FEC_SHARDS
    static let totalShards = 6        // RTPA_TOTAL_SHARDS
    /// OOS give-up SLACK floor (ms) - the wired figure (RTPQ_OOS_WAIT_TIME_MS).
    /// Late-but-arriving shards on a wired NIC land within a few ms, so the LAN
    /// figure is right there; `oosWaitTimeMs` scales UP from here on a jittery
    /// link (see below).
    static let oosWaitTimeBaseMs = 10
    /// OOS give-up SLACK ceiling (ms) on a tunnel/wifi link. A VPN delivers
    /// late audio shards 25-50ms behind the block; the fixed 10ms LAN window
    /// gave up on them and forced PLC (audible glitching). Bounded so a wedged
    /// route can't grow the give-up window without limit.
    static let oosWaitTimeMaxMs = 45

    static let fixedRtpHeaderSize = 12   // sizeof(RTP_PACKET)
    /// sizeof(AUDIO_FEC_HEADER): fecShardIndex(1) + payloadType(1) + baseSeq(2)
    /// + baseTs(4) + ssrc(4) = 12 - `parsedFecBlockKey` reads all 12 bytes. (A
    /// prior value of 8 skewed the parity blockSize/offset by 4 bytes, so the
    /// first parity packet to meet a live block "mismatched" and killed FEC.)
    static let audioFecHeaderSize = 12
    /// Consecutive size-mismatch contacts before concluding the host's FEC
    /// layout is genuinely incompatible (GFE-era) and disabling audio FEC for
    /// the session. Big enough that isolated corrupt/odd blocks on a jittery
    /// link can never trip it; small enough that a truly incompatible host
    /// stops churning within seconds.
    static let sizeMismatchStreakLimit = 8

    static let payloadTypeAudio: UInt8 = 97   // RTP_PAYLOAD_TYPE_AUDIO
    static let payloadTypeFec: UInt8 = 127    // RTP_PAYLOAD_TYPE_FEC

    /// Per-stream cumulative counters (LiGetRTPAudioStats parity, subset).
    struct Stats {
        var packetCountAudio: UInt32 = 0
        var packetCountFec: UInt32 = 0
        var packetCountOOS: UInt32 = 0
        var packetCountInvalid: UInt32 = 0
        var packetCountFecInvalid: UInt32 = 0
        var packetCountFecRecovered: UInt32 = 0
        var packetCountFecFailed: UInt32 = 0
    }

    var stats = Stats()

    // The synthesized/parsed FEC header common to every shard of a block.
    struct FecHeader {
        var payloadType: UInt8 = 0
        var baseSequenceNumber: UInt16 = 0
        var baseTimestamp: UInt32 = 0
        var ssrc: UInt32 = 0
    }

    /// One FEC block: 4 data slots + 2 parity slots + reassembly state.
    /// (= RTPA_FEC_BLOCK, RtpAudioQueue.h:33-55.)
    final class FecBlock {
        var fecHeader = FecHeader()
        var blockSize: Int = 0
        /// Data shard payload bytes (the bytes AFTER the 12-byte RTP header), one
        /// per data slot; empty until received/recovered.
        var dataShards: [[UInt8]] = Array(repeating: [], count: RtpAudioQueue.dataShards)
        /// Parity shard payload bytes, one per parity slot.
        var parityShards: [[UInt8]] = Array(repeating: [], count: RtpAudioQueue.fecShards)
        /// 1 == shard missing, 0 == present (matches C `marks`). Indices 0..3 data,
        /// 4..5 parity.
        var marks: [UInt8] = Array(repeating: 1, count: RtpAudioQueue.totalShards)
        var dataShardsReceived: Int = 0
        var fecShardsReceived: Int = 0
        /// Read cursor: next data shard index to drain (0..4).
        var nextDataPacketIndex: Int = 0
        var allowDiscontinuity = false
        var fullyReassembled = false
        var queueTimeUs: UInt64 = 0
    }

    /// FEC blocks held in sequence order by baseSequenceNumber (the C ordered
    /// doubly-linked list collapses to a sorted array here). blocks[0] == head.
    var blocks: [FecBlock] = []

    var nextRtpSequenceNumber: UInt16 = 0
    var oldestRtpBaseSequenceNumber: UInt16 = 0
    var lastOosSequenceNumber: UInt16 = 0
    var receivedOosData = false
    var synchronizing = true
    var incompatibleServer = false
    /// CONSECUTIVE block-size-mismatch contacts; reset by any size-agreeing
    /// contact, so isolated mismatches can never accumulate into the FEC kill
    /// switch (see the mismatch handling in `getFecBlock`).
    var sizeMismatchStreak = 0
    /// One-shot latch so the size-mismatch warning logs once per session, not
    /// once per packet (the totals carry the volume).
    var loggedSizeMismatch = false

    /// Diag category - shared with RtpAudioReceiver so the queue's (rare) FEC
    /// compatibility lines co-locate with the receiver's in the log.
    static let cat = "NativeAudio"

    /// AudioPacketDuration in ms (5 by default; 10 for slow/low-bitrate). Used to
    /// synthesize timestamps and to size the OOS give-up window.
    let audioPacketDuration: Int

    /// OOS give-up SLACK (ms) added past the block's own playout duration before a
    /// missing shard is conceded to PLC. LINK-SCALED, not a magic constant: the
    /// audio receive path has no clean per-stream jitter signal of its own, so -
    /// like the cushion seed (AudioDecoder+CushionMemory.swift:134) - it scales off
    /// the resolved stream-link class. A wired NIC delivers late shards within a
    /// few ms (keep the ~10ms LAN floor); a wifi/tunnel link delivers them 25-50ms
    /// behind, so a too-short window gives up on shards that WOULD have arrived and
    /// forces audible PLC glitching. Bounded by `oosWaitTimeMaxMs`. Re-read each
    /// give-up check (once per missing-packet decision, off the per-datagram fast
    /// path) so a route that resolves mid-stream takes effect without re-init.
    private var oosWaitTimeMs: Int {
        switch EnvSignalController.shared.streamLink {
        case "wired":
            return Self.oosWaitTimeBaseMs
        case "wifi", "tunnel":
            return Self.oosWaitTimeMaxMs
        default:
            // Route unknown: fail toward the safer (wider) window - a few extra ms
            // of audio latency is non-critical; a too-tight window glitches.
            return Self.oosWaitTimeMaxMs
        }
    }

    let fec = AudioFecDecoder()

    /// - Parameters:
    ///   - appVersionQuad: parsed host version [major, minor, patch, build].
    ///   - audioPacketDuration: AudioPacketDuration in ms (5 default).
    init(appVersionQuad: [Int32], audioPacketDuration: Int) {
        self.audioPacketDuration = audioPacketDuration

        // FEC requires GFE 3.19+ / APP_VERSION_AT_LEAST(7,1,415). For older hosts,
        // disable FEC and pass audio straight through (RtpAudioQueue.c:40-44).
        if !Self.appVersionAtLeast(appVersionQuad, 7, 1, 415) {
            incompatibleServer = true
        }
    }

    // MARK: - Version + 16-bit wraparound helpers (Limelight-internal.h)

    private static func appVersionAtLeast(_ quad: [Int32],
                                          _ major: Int32, _ minor: Int32, _ patch: Int32) -> Bool {
        // Compares the first three components lexicographically. A negative 4th
        // component (Sunshine) does not affect this gate.
        let q0 = quad.isEmpty ? 0 : quad[0]
        let q1 = quad.count > 1 ? quad[1] : 0
        let q2 = quad.count > 2 ? quad[2] : 0
        if q0 != major { return q0 > major }
        if q1 != minor { return q1 > minor }
        return q2 >= patch
    }

    /// Wrap-safe 16-bit "is x before y" (isBefore16, Limelight-internal.h:76).
    @inline(__always) static func isBefore16(_ x: UInt16, _ y: UInt16) -> Bool {
        (x &- y) > 0x7FFF
    }
    /// Wrap-safe 32-bit "is x before y" (isBefore32, Limelight-internal.h:78).
    @inline(__always) private static func isBefore32(_ x: UInt32, _ y: UInt32) -> Bool {
        (x &- y) > 0x7FFF_FFFF
    }

    // MARK: - Parsed RTP header (host order)

    /// Host-order RTP header fields. The receiver byteswaps the multi-byte fields
    /// BE→host before calling addPacket (matching AudioStream.c:321-323).
    struct RtpHeader {
        var header: UInt8
        var packetType: UInt8
        var sequenceNumber: UInt16
        var timestamp: UInt32
        var ssrc: UInt32
    }

    // MARK: - Public API

    /// Add one received (host-byteswapped) RTP audio/FEC packet.
    /// `packet` is the full datagram bytes; `rtp` is its already-byteswapped
    /// header. Returns how the receiver should dispatch (RtpaAddPacket, :564-658).
    func addPacket(_ packet: [UInt8], rtp: RtpHeader) -> RtpaResult {
        // incompatibleServer shortcut (:565-575): feed data straight through.
        if incompatibleServer {
            if rtp.packetType == Self.payloadTypeAudio {
                return .handleNow
            }
            return .none
        }

        guard let block = getFecBlock(packet: packet, rtp: rtp) else {
            return .none
        }

        if rtp.packetType == Self.payloadTypeAudio {
            let pos = Int(rtp.sequenceNumber &- block.fecHeader.baseSequenceNumber)
            // Validated in getFecBlock: pos < dataShards.
            guard pos >= 0, pos < Self.dataShards else { return .none }

            if block.marks[pos] != 0 {
                // Missing data shard: copy the opus payload (after the 12-byte
                // RTP header) into the slot (:589-594).
                let payloadStart = Self.fixedRtpHeaderSize
                block.dataShards[pos] = padShard(Array(packet[payloadStart...]), to: block.blockSize)
                block.marks[pos] = 0
                block.dataShardsReceived += 1
            } else {
                // Duplicate packet - reject (:595-598).
                return .none
            }

            // FAST PATH (:600-620): in-order receive of the next data shard.
            if rtp.sequenceNumber == nextRtpSequenceNumber {
                nextRtpSequenceNumber = rtp.sequenceNumber &+ 1
                block.nextDataPacketIndex += 1

                // If we've returned all packets in this block, free it.
                if nextRtpSequenceNumber == (block.fecHeader.baseSequenceNumber &+ UInt16(Self.dataShards)) {
                    freeFecBlockHead()
                }
                return .handleNow
            }
        } else if rtp.packetType == Self.payloadTypeFec {
            // Parse the FEC header (already validated in getFecBlock).
            let fecHeaderOff = Self.fixedRtpHeaderSize
            let shardIndex = Int(packet[fecHeaderOff])  // fecShardIndex
            guard shardIndex >= 0, shardIndex < Self.fecShards else { return .none }

            let markIdx = Self.dataShards + shardIndex
            if block.marks[markIdx] != 0 {
                // Missing FEC shard: copy just the parity bytes (after the
                // 12-byte RTP header + 12-byte FEC header) into the slot (:628-633).
                let parityStart = Self.fixedRtpHeaderSize + Self.audioFecHeaderSize
                block.parityShards[shardIndex] = padShard(Array(packet[parityStart...]), to: block.blockSize)
                block.marks[markIdx] = 0
                block.fecShardsReceived += 1
            } else {
                // Duplicate packet - reject (:634-637).
                return .none
            }
        } else {
            return .none
        }

        // Try to complete the block via data shards or data+FEC shards (:647).
        if completeFecBlock(block) {
            block.fullyReassembled = true
        }

        // If we still have nothing ready, see if we should skip missing packets.
        if !queueHasPacketReady() {
            handleMissingPackets()
        }

        return queueHasPacketReady() ? .packetReady : .none
    }

    /// Drain one ready packet (RtpaGetQueuedPacket, :660-729). Returns assembled
    /// RTP bytes, a PLC placeholder for an unrecovered gap, or nil when nothing is
    /// ready. Call in a loop until nil after a `.packetReady` result.
    func getQueuedPacket() -> RtpaQueuedPacket? {
        // Discontinuity path: fill in placeholders for lost packets (:665-700).
        if let head = blocks.first, head.allowDiscontinuity {
            let idx = head.nextDataPacketIndex
            if idx < Self.dataShards && head.marks[idx] != 0 {
                // This packet is missing - emit a PLC placeholder.
                head.nextDataPacketIndex += 1
                nextRtpSequenceNumber = nextRtpSequenceNumber &+ 1

                if head.nextDataPacketIndex == Self.dataShards {
                    freeFecBlockHead()
                }
                return .lostPlaceholder
            }
            // else fall through to the ready-packet path below.
        }

        // Return the next in-order assembled packet (:704-726).
        if queueHasPacketReady() {
            let head = blocks[0]
            let idx = head.nextDataPacketIndex

            // Reassemble the full RTP packet: 12-byte header + payload. The header
            // for in-order received packets was copied verbatim; for recovered
            // packets it was synthesized in completeFecBlock. We rebuild it here
            // from the FEC header + index so a single code path covers both.
            var out = [UInt8]()
            out.reserveCapacity(Self.fixedRtpHeaderSize + head.blockSize)
            let seq = head.fecHeader.baseSequenceNumber &+ UInt16(idx)
            let ts = head.fecHeader.baseTimestamp &+ UInt32(idx * audioPacketDuration)
            appendRtpHeader(&out, header: 0x80, packetType: head.fecHeader.payloadType,
                            seq: seq, timestamp: ts, ssrc: head.fecHeader.ssrc)
            out.append(contentsOf: head.dataShards[idx])

            head.nextDataPacketIndex += 1
            nextRtpSequenceNumber = nextRtpSequenceNumber &+ 1

            if head.nextDataPacketIndex == Self.dataShards {
                freeFecBlockHead()
            }
            return .bytes(out)
        }

        return nil
    }

    // MARK: - Ready / give-up logic

    /// queueHasPacketReady (:507-513).
    private func queueHasPacketReady() -> Bool {
        guard let head = blocks.first else { return false }
        let idx = head.nextDataPacketIndex
        let inOrderReady = idx < Self.dataShards
            && head.marks[idx] == 0
            && (head.fecHeader.baseSequenceNumber &+ UInt16(idx)) == nextRtpSequenceNumber
        return inOrderReady || head.allowDiscontinuity
    }

    /// handleMissingPackets (:515-562).
    private func handleMissingPackets() {
        guard let head = blocks.first else { return }

        // If the packet we're waiting on precedes the earliest block, a whole
        // earlier block was lost - resync forward without discontinuity (:528-532).
        if Self.isBefore16(nextRtpSequenceNumber, head.fecHeader.baseSequenceNumber) {
            nextRtpSequenceNumber = head.fecHeader.baseSequenceNumber
            oldestRtpBaseSequenceNumber = head.fecHeader.baseSequenceNumber
            return
        }

        // The missing packet is in the head block. Wait until a SECOND block is
        // queued before giving up (:534-540).
        if blocks.count < 2 {
            return
        }

        // Give up if we've never seen OOS data, or the wait window elapsed (:542-561).
        let nowUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        let windowUs = UInt64(audioPacketDuration * Self.dataShards) + UInt64(oosWaitTimeMs * 1000)
        if !receivedOosData || (nowUs &- head.queueTimeUs) > windowUs {
            stats.packetCountFecFailed += 1
            // Play out the block with PLC placeholders for the missing packets.
            head.allowDiscontinuity = true
        }
    }

    // MARK: - Block lifecycle

    /// freeFecBlockHead (:142-171). Advances oldestRtpBaseSequenceNumber and
    /// clears the synchronizing flag once the first block completes.
    private func freeFecBlockHead() {
        guard !blocks.isEmpty else { return }
        let head = blocks.removeFirst()
        oldestRtpBaseSequenceNumber = head.fecHeader.baseSequenceNumber &+ UInt16(Self.dataShards)
        synchronizing = false
        // The C free-list cache (RTPA_CACHED_FEC_BLOCK_LIMIT) is a pure perf
        // optimization; ARC reclaims the block here instead.
    }

    // MARK: - Helpers

    /// Pad (or, defensively, truncate) a shard to exactly `size` bytes. Sunshine
    /// uses constant-size shards within a block, but the RS math requires every
    /// shard be exactly blockSize.
    private func padShard(_ bytes: [UInt8], to size: Int) -> [UInt8] {
        if bytes.count == size { return bytes }
        if bytes.count > size { return Array(bytes[0..<size]) }
        var out = bytes
        out.append(contentsOf: repeatElement(0, count: size - bytes.count))
        return out
    }

    /// Append a 12-byte RTP header in BIG-ENDIAN wire order. The drained bytes are
    /// consumed downstream only for their opus payload, but we reproduce the exact
    /// header layout so the assembled packet is byte-faithful to the C path.
    private func appendRtpHeader(_ out: inout [UInt8], header: UInt8, packetType: UInt8,
                                 seq: UInt16, timestamp: UInt32, ssrc: UInt32) {
        out.append(header)
        out.append(packetType)
        out.append(UInt8((seq >> 8) & 0xFF)); out.append(UInt8(seq & 0xFF))
        out.append(UInt8((timestamp >> 24) & 0xFF)); out.append(UInt8((timestamp >> 16) & 0xFF))
        out.append(UInt8((timestamp >> 8) & 0xFF)); out.append(UInt8(timestamp & 0xFF))
        out.append(UInt8((ssrc >> 24) & 0xFF)); out.append(UInt8((ssrc >> 16) & 0xFF))
        out.append(UInt8((ssrc >> 8) & 0xFF)); out.append(UInt8(ssrc & 0xFF))
    }
}
