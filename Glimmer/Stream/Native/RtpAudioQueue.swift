// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

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
//  COMPATIBILITY: FEC starts on (Sunshine's 7.1.431 clears the C's 7.1.415 gate). A streak of layout
//  mismatches (non-4-aligned parity, block-size disagreements) sets `incompatibleServer` and logs why:
//  data then passes straight through (HANDLE_NOW) and FEC is dropped. One odd packet is only dropped.
//
// Queue state belongs to RtpAudioReceiver's decode worker. Pooling shards and blocks keeps
// the packet path allocation-free; startup/test callers may drive it synchronously.

import GlimmerEngine
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
    static let maxPacketSize = 1400   // MAX_PACKET_SIZE
    static let dataShards = 4         // RTPA_DATA_SHARDS
    static let fecShards = 2          // RTPA_FEC_SHARDS
    static let totalShards = 6        // RTPA_TOTAL_SHARDS
    /// The wired give-up window (ms), RTPQ_OOS_WAIT_TIME_MS: late shards on a wired NIC land within a
    /// few ms. `oosWaitTimeMs` widens it on a jittery link.
    static let oosWaitTimeBaseMs = 10
    /// The give-up window (ms) on Wi-Fi or a tunnel, where late shards arrive 25-50 ms behind; the
    /// wired 10 ms gave up on them and forced PLC. Longer would drain a shallow cushion instead.
    static let oosWaitTimeMaxMs = 45

    static let fixedRtpHeaderSize = 12   // sizeof(RTP_PACKET)
    /// sizeof(AUDIO_FEC_HEADER): fecShardIndex(1) + payloadType(1) + baseSeq(2)
    /// + baseTs(4) + ssrc(4) = 12 - `parsedFecBlockKey` reads all 12 bytes. (A
    /// prior value of 8 skewed the parity blockSize/offset by 4 bytes, so the
    /// first parity packet to meet a live block "mismatched" and killed FEC.)
    static let audioFecHeaderSize = 12
    /// Layout mismatches in a row before audio FEC turns off for the session: isolated odd
    /// packets never trip it, while a PC whose layout truly differs does within seconds.
    static let layoutMismatchStreakLimit = 8
    /// Most FEC blocks held at once: 160 ms of 5 ms packets, well past the longest
    /// out-of-order wait (`oosWaitTimeMaxMs` plus one block), so it only binds on a stall.
    static let maxQueuedBlocks = 8

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
        var dataShards = (0..<RtpAudioQueue.dataShards).map { _ in [UInt8](repeating: 0, count: 1400) }
        /// Parity shard payload bytes, one per parity slot.
        var parityShards = (0..<RtpAudioQueue.fecShards).map { _ in [UInt8](repeating: 0, count: 1400) }
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
    var freeBlocks = (0...RtpAudioQueue.maxQueuedBlocks).map { _ in FecBlock() }

    var nextRtpSequenceNumber: UInt16 = 0
    var oldestRtpBaseSequenceNumber: UInt16 = 0
    var lastOosSequenceNumber: UInt16 = 0
    var receivedOosData = false
    var synchronizing = true
    var hasSequenceBaseline = false
    var pendingSequenceRestart: UInt16?
    var incompatibleServer = false
    /// Layout mismatches since the last size-agreeing contact (see `noteLayoutMismatch`).
    var layoutMismatchStreak = 0
    /// The mismatch warning logs once per session, not once per packet.
    var loggedLayoutMismatch = false

    /// Diag category - shared with RtpAudioReceiver so the queue's (rare) FEC
    /// compatibility lines co-locate with the receiver's in the log.
    static let cat = "NativeAudio"

    /// AudioPacketDuration in ms (5 by default; 10 for slow/low-bitrate), for synthesized timestamps.
    let audioPacketDuration: Int

    /// How long (ms) a missing shard may hold its block before it's conceded to PLC, by link class.
    /// Re-read at each give-up check, so a route that resolves mid-stream applies without re-init.
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

    /// `audioPacketDuration` is AudioPacketDuration in ms (5 by default).
    init(audioPacketDuration: Int) {
        self.audioPacketDuration = audioPacketDuration
        blocks.reserveCapacity(Self.maxQueuedBlocks + 1)
        freeBlocks.reserveCapacity(Self.maxQueuedBlocks + 1)
        _ = GF256.inv
    }

    // MARK: - 16-bit wraparound helpers (Limelight-internal.h)

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

    /// A normal reorder stays inside the bounded block queue. Establishing order
    /// or proposing a larger jump requires the receiver to validate the payload.
    func requiresPayloadValidation(sequence: UInt16) -> Bool {
        guard hasSequenceBaseline else { return true }
        let base = sequence - sequence % UInt16(Self.dataShards)
        return !Self.isBefore16(base, oldestRtpBaseSequenceNumber)
            && base &- oldestRtpBaseSequenceNumber > UInt16(Self.maxQueuedBlocks * Self.dataShards)
    }

    /// Add one received (host-byteswapped) RTP audio/FEC packet.
    /// `packet` is the full datagram bytes; `rtp` is its already-byteswapped
    /// header. Returns how the receiver should dispatch (RtpaAddPacket, :564-658).
    func addPacket(_ packet: [UInt8], rtp: RtpHeader) -> RtpaResult {
        guard packet.count >= Self.fixedRtpHeaderSize, rtp.header == 0x80 else { return .none }
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
                copyShard(packet[payloadStart...], into: &block.dataShards[pos], size: block.blockSize)
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
                copyShard(packet[parityStart...], into: &block.parityShards[shardIndex], size: block.blockSize)
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
        var output: [UInt8] = []
        guard let lost = getQueuedPacket(into: &output) else { return nil }
        return lost ? .lostPlaceholder : .bytes(output)
    }

    /// Reuse the worker's output storage; true means PLC, false means assembled bytes, nil means empty.
    func getQueuedPacket(into out: inout [UInt8]) -> Bool? {
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
                return true
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
            out.removeAll(keepingCapacity: true)
            let seq = head.fecHeader.baseSequenceNumber &+ UInt16(idx)
            let ts = head.fecHeader.baseTimestamp &+ UInt32(idx * audioPacketDuration)
            appendRtpHeader(&out, header: 0x80, packetType: head.fecHeader.payloadType,
                            seq: seq, timestamp: ts, ssrc: head.fecHeader.ssrc)
            out.append(contentsOf: head.dataShards[idx].prefix(head.blockSize))

            head.nextDataPacketIndex += 1
            nextRtpSequenceNumber = nextRtpSequenceNumber &+ 1

            if head.nextDataPacketIndex == Self.dataShards {
                freeFecBlockHead()
            }
            return false
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
        // Upstream also adds the block's 20 ms here, in µs units, so 20 µs: the window is the slack alone.
        let windowUs = UInt64(oosWaitTimeMs * 1000)
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
        freeBlocks.append(head)
    }

    // MARK: - Helpers

    func copyShard(_ bytes: ArraySlice<UInt8>, into storage: inout [UInt8], size: Int) {
        for index in 0..<size { storage[index] = index < bytes.count ? bytes[bytes.startIndex + index] : 0 }
    }

    // internal for testability
    /// Append a 12-byte RTP header in BIG-ENDIAN wire order. The drained bytes are
    /// consumed downstream only for their opus payload, but we reproduce the exact
    /// header layout so the assembled packet is byte-faithful to the C path.
    func appendRtpHeader(_ out: inout [UInt8], header: UInt8, packetType: UInt8,
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
