//
//  RtpAudioQueue+Fec.swift
//
//  The FEC machinery half of the audio FEC-block reassembly state machine,
//  split from RtpAudioQueue.swift — pure move, same idiom as the RtpVideoQueue
//  and FramePacer splits — to keep each file under the SwiftLint
//  length limit. Ports the block lookup/creation path (getFecBlockForRtpPacket:
//  key synthesis from data packets, AUDIO_FEC_HEADER parsing/validation from
//  parity packets, the size-mismatch streak escape hatch) and the Reed-Solomon
//  recovery step (completeFecBlock).
//
//  These run on the SAME single receive thread as the queue/reorder core in
//  RtpAudioQueue.swift — the split is purely textual (a Swift extension can
//  only reach non-private members, which is why the queue's touched state is
//  `internal` rather than `private`; see the visibility note atop
//  RtpAudioQueue.swift). No isolation, ordering, locking, or behavioral
//  contract changes.
//

import Foundation

extension RtpAudioQueue {
    // MARK: - Block lookup / creation (getFecBlockForRtpPacket, :195-397)

    /// The FEC-header fields that key a block — either synthesized from an audio
    /// data packet or parsed from an explicit AUDIO_FEC_HEADER.
    private struct FecBlockKey {
        let payloadType: UInt8
        let baseSeqNum: UInt16
        let baseTs: UInt32
        let ssrc: UInt32
        let blockSize: Int
    }

    /// Synthesize the FEC-block key from an audio data packet (:214-238).
    private func audioFecBlockKey(packet: [UInt8], rtp: RtpHeader) -> FecBlockKey? {
        if packet.count < Self.fixedRtpHeaderSize {
            stats.packetCountInvalid += 1
            return nil
        }
        stats.packetCountAudio += 1

        // Track out-of-sequence data to tune FEC give-up timing (:214-230).
        if !synchronizing && Self.isBefore16(rtp.sequenceNumber, oldestRtpBaseSequenceNumber) {
            lastOosSequenceNumber = rtp.sequenceNumber
            stats.packetCountOOS += 1
            if !receivedOosData {
                receivedOosData = true
            }
        } else if receivedOosData && Self.isBefore16(oldestRtpBaseSequenceNumber, lastOosSequenceNumber) {
            receivedOosData = false
        }

        // Synthesize the FEC-header fields from the data packet (:232-238).
        let baseSeqNum = (rtp.sequenceNumber / UInt16(Self.dataShards)) * UInt16(Self.dataShards)
        let offset = UInt32(rtp.sequenceNumber &- baseSeqNum) * UInt32(audioPacketDuration)
        return FecBlockKey(
            payloadType: rtp.packetType,
            baseSeqNum: baseSeqNum,
            baseTs: rtp.timestamp &- offset,
            ssrc: rtp.ssrc,
            blockSize: packet.count - Self.fixedRtpHeaderSize)
    }

    /// Parse the FEC-block key from an explicit AUDIO_FEC_HEADER (:252-278).
    private func parsedFecBlockKey(packet: [UInt8]) -> FecBlockKey? {
        if packet.count < Self.fixedRtpHeaderSize + Self.audioFecHeaderSize {
            stats.packetCountFecInvalid += 1
            return nil
        }
        stats.packetCountFec += 1

        // Parse + byteswap the AUDIO_FEC_HEADER (BE→host, :252-256).
        let off = Self.fixedRtpHeaderSize
        let fecShardIndex = packet[off]
        let payloadType = packet[off + 1]
        let baseSeqNum = UInt16(packet[off + 2]) << 8 | UInt16(packet[off + 3])
        let baseTs = UInt32(packet[off + 4]) << 24 | UInt32(packet[off + 5]) << 16
            | UInt32(packet[off + 6]) << 8 | UInt32(packet[off + 7])
        // ssrc occupies the next 4 bytes (off+8 ..< off+12).
        let ssrc = UInt32(packet[off + 8]) << 24 | UInt32(packet[off + 9]) << 16
            | UInt32(packet[off + 10]) << 8 | UInt32(packet[off + 11])

        // Validate the FEC shard index to prevent OOB (:258-265).
        if fecShardIndex >= UInt8(Self.fecShards) {
            stats.packetCountFecInvalid += 1
            return nil
        }

        // FEC blocks MUST start on a dataShards boundary (:267-278). A violation
        // is a structural layout difference (not a transient fault), so the
        // escape hatch stays — but it must flip LOUDLY, never silently.
        if baseSeqNum % UInt16(Self.dataShards) != 0 {
            stats.packetCountFecInvalid += 1
            incompatibleServer = true
            Diag.notice("NativeAudio FEC DISABLED for this session: parity block base seq "
                + "\(baseSeqNum) is not \(Self.dataShards)-aligned — host violates the FEC-block "
                + "invariant. Audio continues WITHOUT FEC (data straight through, parity dropped, "
                + "lost packets fall to PLC).", Self.cat)
            return nil
        }

        return FecBlockKey(
            payloadType: payloadType,
            baseSeqNum: baseSeqNum,
            baseTs: baseTs,
            ssrc: ssrc,
            blockSize: packet.count - Self.fixedRtpHeaderSize - Self.audioFecHeaderSize)
    }

    /// `internal`: called by `addPacket` in RtpAudioQueue.swift.
    func getFecBlock(packet: [UInt8], rtp: RtpHeader) -> FecBlock? {
        let key: FecBlockKey?
        if rtp.packetType == Self.payloadTypeAudio {
            key = audioFecBlockKey(packet: packet, rtp: rtp)
        } else if rtp.packetType == Self.payloadTypeFec {
            key = parsedFecBlockKey(packet: packet)
        } else {
            return nil
        }
        guard let key else { return nil }
        let fecBlockPayloadType = key.payloadType
        let fecBlockBaseSeqNum = key.baseSeqNum
        let fecBlockBaseTs = key.baseTs
        let fecBlockSsrc = key.ssrc
        let blockSize = key.blockSize

        // Synchronize on connect: start on the NEXT block boundary so we never
        // half-start a block (:288-295).
        if synchronizing && oldestRtpBaseSequenceNumber == 0 {
            let next = fecBlockBaseSeqNum &+ UInt16(Self.dataShards)
            nextRtpSequenceNumber = next
            oldestRtpBaseSequenceNumber = next
            return nil
        }

        // Drop packets from already-completed blocks (:297-300).
        if Self.isBefore16(fecBlockBaseSeqNum, oldestRtpBaseSequenceNumber) {
            return nil
        }

        // Find an existing block (sorted by baseSeq), or the insertion point.
        var insertAt = blocks.count
        for (i, existing) in blocks.enumerated() {
            if existing.fecHeader.baseSequenceNumber == fecBlockBaseSeqNum {
                // Block size must match to safely copy shards (:311-321). On a
                // mismatch, drop THIS contribution and count it — do NOT flip
                // incompatibleServer on first contact (the C does, but here that
                // one-strike flip silently killed audio FEC for a whole session
                // off a single odd block). The streak below keeps the GFE-era
                // escape hatch reachable: a host whose layout GENUINELY differs
                // mismatches on every contact and degrades within seconds,
                // loudly, while one bad block on a jittery link costs only that
                // block (its missing packets fall to PLC like any other gap).
                if existing.blockSize != blockSize {
                    stats.packetCountFecInvalid += 1
                    TelemetryCounters.shared.audioFecMismatchTotal.increment()
                    if !loggedSizeMismatch {
                        loggedSizeMismatch = true
                        Diag.warn("NativeAudio FEC block-size mismatch: block \(existing.blockSize)B "
                            + "vs packet \(blockSize)B (base seq \(fecBlockBaseSeqNum)) — dropping this "
                            + "contribution (logged once; volume in audio_fec_mismatch_total)", Self.cat)
                    }
                    sizeMismatchStreak += 1
                    if sizeMismatchStreak >= Self.sizeMismatchStreakLimit {
                        incompatibleServer = true
                        Diag.notice("NativeAudio FEC DISABLED for this session: "
                            + "\(sizeMismatchStreak) consecutive block-size mismatches — the host's "
                            + "AUDIO_FEC_HEADER layout looks incompatible (GFE-era?). Audio continues "
                            + "WITHOUT FEC: data passes straight through, parity is dropped, lost "
                            + "packets fall to PLC.", Self.cat)
                    }
                    return nil
                }
                // Sizes agree — direct counter-evidence of a compatible layout;
                // the safeguard RECOVERS rather than ratcheting toward the kill.
                sizeMismatchStreak = 0
                // Don't return a completed block (:324).
                return existing.fullyReassembled ? nil : existing
            } else if Self.isBefore16(fecBlockBaseSeqNum, existing.fecHeader.baseSequenceNumber) {
                insertAt = i
                break
            }
        }

        // Allocate a new block and insert in seq order (:334-392).
        let block = FecBlock()
        block.queueTimeUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        block.blockSize = blockSize
        block.fecHeader.payloadType = fecBlockPayloadType
        block.fecHeader.baseSequenceNumber = fecBlockBaseSeqNum
        block.fecHeader.baseTimestamp = fecBlockBaseTs
        block.fecHeader.ssrc = fecBlockSsrc
        blocks.insert(block, at: insertAt)
        return block
    }

    // MARK: - Reed-Solomon recovery (completeFecBlock, :399-505)

    /// `internal`: called by `addPacket` in RtpAudioQueue.swift.
    func completeFecBlock(_ block: FecBlock) -> Bool {
        // Need at least dataShards of the 6 shards to do anything (:407).
        if block.dataShardsReceived + block.fecShardsReceived < Self.dataShards {
            return false
        }

        // If all data shards present, no recovery needed (:416).
        if block.dataShardsReceived == Self.dataShards {
            return true
        }

        // Build the 6-shard array: data payloads then parity payloads. Missing
        // slots are zero-filled to blockSize so the RS math is well-defined.
        var shards = [[UInt8]](repeating: [], count: Self.totalShards)
        for i in 0..<Self.dataShards {
            shards[i] = block.marks[i] == 0 ? block.dataShards[i]
                                            : [UInt8](repeating: 0, count: block.blockSize)
        }
        for i in 0..<Self.fecShards {
            shards[Self.dataShards + i] = block.marks[Self.dataShards + i] == 0
                ? block.parityShards[i]
                : [UInt8](repeating: 0, count: block.blockSize)
        }

        if !fec.decode(shards: &shards, marks: block.marks, blockSize: block.blockSize) {
            return false
        }

        // Recover the missing data slots: store the recovered payload and
        // synthesize the RTP header fields (used on drain) (:454-464).
        for i in 0..<Self.dataShards where block.marks[i] != 0 {
            block.dataShards[i] = shards[i]
            block.marks[i] = 0
        }

        if block.dataShardsReceived != Self.dataShards {
            stats.packetCountFecRecovered += UInt32(Self.dataShards - block.dataShardsReceived)
        }
        return true
    }
}
