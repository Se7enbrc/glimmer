//
//  RtpVideoQueue+Reconstruct.swift
//
//  The Reed-Solomon reconstruct + FEC-staging + submit/emit half of the RTP video
//  queue state machine, split out of RtpVideoQueue.swift to keep each file under
//  the SwiftLint length limit. Ports RtpVideoQueue.c reconstructFrame (FEC decode
//  + recovered-shard re-queue), stageCompleteFecBlock (in-order DATA staging),
//  submitCompletedFrame/emit (hand to the depacketizer), and
//  reportFinalFrameFecStatus (the per-frame QoS feedback Sunshine wants).
//
//  These run on the SAME single receive thread as the add path in
//  RtpVideoQueue.swift - the split is purely textual (a Swift extension can only
//  reach non-private members, which is why the queue's touched state is `internal`
//  rather than `private`; see the visibility note atop RtpVideoQueue.swift). No
//  isolation, ordering, or locking contract changes.
//

import Foundation

extension RtpVideoQueue {

    // MARK: - reconstructFrame (c:193-463). Returns 0 if complete.

    func reconstructFrame() -> Int {
        let totalPackets = bufferDataPackets + bufferParityPackets
        let neededPackets = bufferDataPackets

        if pending.count < neededPackets {
            // Speculative loss prediction (control-stream RFI) is skipped for
            // first-light; just wait.
            return -1
        }

        // Full frame, no FEC needed.
        if receivedDataPackets == bufferDataPackets {
            return 0
        }

        // FEC disabled for this (large) frame.
        if fecPercentage == 0 {
            return -1
        }

        let receiveSize = packetSize + Self.MAX_RTP_HEADER_SIZE
        guard let rs = decoder(dataShards: bufferDataPackets, parityShards: bufferParityPackets) else {
            Diag.error("NativeVideo reed_solomon_new failed (ds=\(bufferDataPackets) ps=\(bufferParityPackets))", Self.cat)
            return -1
        }

        var (shards, marks) = buildShards(totalPackets: totalPackets, receiveSize: receiveSize)

        let ok = rs.decode(shards: &shards, marks: marks, bs: receiveSize)
        if !ok {
            Diag.error("NativeVideo FEC unrecoverable frame \(currentFrameNumber): "
                + "have \(pending.count) need \(neededPackets)", Self.cat)
            return -1
        }

        if bufferDataPackets != receivedDataPackets {
            logFecRecovery()
        }

        // Re-queue recovered DATA shards (i < bufferDataPackets) (c:348-446).
        let headEntry = pending.first
        for i in 0..<totalPackets where marks[i] && i < bufferDataPackets {
            requeueRecoveredShard(shards[i], index: i, headEntry: headEntry)
        }

        return 0
    }

    /// Cauchy decoder for a (dataShards, parityShards) shape, memoized so a loss
    /// burst over repeating shapes builds each matrix once. `ReedSolomon` is an
    /// immutable value type whose `decode` only mutates caller-supplied shards, so a
    /// cached instance is reused safely. nil for invalid geometry (not cached).
    private func decoder(dataShards ds: Int, parityShards ps: Int) -> ReedSolomon? {
        let shape = ReedSolomonShape(ds: ds, ps: ps)
        if let cached = rsDecoderCache[shape] { return cached }
        guard let rs = ReedSolomon(dataShards: ds, parityShards: ps) else { return nil }
        rsDecoderCache[shape] = rs
        return rs
    }

    /// Assemble the Reed-Solomon shard array from the pending entries: each shard
    /// is its packet's bytes zero-padded (or clamped) to `receiveSize`, indexed by
    /// distance from `bufferLowestSequenceNumber`. Still-missing slots get a fresh
    /// zero buffer. `marks[i]` is true while slot `i` is missing (RtpVideoQueue.c
    /// :260-302). Returns the shards and their missing-marks in parallel arrays.
    private func buildShards(totalPackets: Int, receiveSize: Int) -> (shards: [[UInt8]], marks: [Bool]) {
        var shards = [[UInt8]](repeating: [], count: totalPackets)
        var marks = [Bool](repeating: true, count: totalPackets)

        for entry in pending {
            let index = Int(Self.u16(Int(entry.sequenceNumber) - Int(bufferLowestSequenceNumber)))
            guard index >= 0 && index < totalPackets else { continue }
            // Zero-pad each shard to receiveSize.
            var shard = entry.bytes
            if shard.count < receiveSize {
                shard.append(contentsOf: [UInt8](repeating: 0, count: receiveSize - shard.count))
            } else if shard.count > receiveSize {
                shard = Array(shard.prefix(receiveSize))
            }
            shards[index] = shard
            marks[index] = false
        }
        // Allocate zero buffers for still-missing slots.
        for i in 0..<totalPackets where marks[i] {
            shards[i] = [UInt8](repeating: 0, count: receiveSize)
        }
        return (shards, marks)
    }

    /// Note that the current frame needed Reed-Solomon recovery: latch the metric,
    /// log the recovery (first one at notice level), and emit the per-frame FEC
    /// status the host's QoS eval expects (RtpVideoQueue.c:331-345).
    private func logFecRecovery() {
        // This frame needed Reed-Solomon recovery - count it once for the
        // periodic FEC-recovery-rate metric (latched; tallied at submit time).
        currentFrameNeededFec = true
        let recovered = bufferDataPackets - receivedDataPackets
        // FEC observability (read-only): track the worst parity headroom this window
        // - how many spare parity shards remained after this frame's deficit.
        // Published + reset in maybeLogMetrics. Pure book-keeping, no control effect.
        windowMinParityMargin = min(windowMinParityMargin, bufferParityPackets - recovered)
        if !loggedFirstFecRecovery {
            loggedFirstFecRecovery = true
            Diag.notice("NativeVideo first FEC recovery: \(recovered) shards, frame \(currentFrameNumber)", Self.cat)
        } else {
            Diag.info("NativeVideo FEC recovery: \(recovered) shards, frame \(currentFrameNumber) "
                + "block \(multiFecCurrentBlockNumber)", Self.cat)
        }

        // Report the final FEC status if we needed to perform a recovery
        // (RtpVideoQueue.c:344-345).
        reportFinalFrameFecStatus()
    }

    /// Rebuild the RTP+NV header on one recovered DATA shard (slot `index`) and
    /// re-feed it through queuePacket, dropping it if its sanity-checked flags are
    /// corrupt (RtpVideoQueue.c:348-446). `headEntry` is the block's first received
    /// packet, used to source the header/timestamp/ssrc the FEC math can't recover.
    private func requeueRecoveredShard(_ shard: [UInt8], index: Int, headEntry: Entry?) {
        var recovered = shard
        // Rebuild RTP header on the recovered shard.
        let recoveredSeq = Self.u16(index + Int(bufferLowestSequenceNumber))
        let header = headEntry?.header ?? recovered[0]
        let ts = headEntry?.rtpTimestamp ?? 0
        let ssrc = headEntry?.ssrc ?? 0

        var dataOffset = Self.FIXED_RTP_HEADER_SIZE
        if header & Self.FLAG_EXTENSION != 0 { dataOffset += 4 }

        // Write back RTP fields (host order kept; queue stores host-order).
        recovered[0] = header
        // Set nvPacket.frameIndex = currentFrameNumber (LE) and multiFecBlocks.
        let nv = dataOffset
        if nv + 16 <= recovered.count {
            let fi = currentFrameNumber
            recovered[nv + 4] = UInt8(fi & 0xFF)
            recovered[nv + 5] = UInt8((fi >> 8) & 0xFF)
            recovered[nv + 6] = UInt8((fi >> 16) & 0xFF)
            recovered[nv + 7] = UInt8((fi >> 24) & 0xFF)
            recovered[nv + 11] = ((multiFecLastBlockNumber << 2) | multiFecCurrentBlockNumber) << 4
        }

        // Sanity-check recovered packet flags (c:427-438).
        let recFlags = (nv + 8 < recovered.count) ? recovered[nv + 8] : 0
        if index == 0 && (recFlags & Self.FLAG_SOF) == 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (no SOF) frame \(currentFrameNumber)", Self.cat)
            return
        }
        if index == bufferDataPackets - 1 && (recFlags & Self.FLAG_EOF) == 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (no EOF) frame \(currentFrameNumber)", Self.cat)
            return
        }
        if index > 0 && index < bufferDataPackets - 1 && (recFlags & Self.FLAG_CONTAINS_PIC_DATA) == 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (no PIC) frame \(currentFrameNumber)", Self.cat)
            return
        }
        if recFlags & ~(Self.FLAG_SOF | Self.FLAG_EOF | Self.FLAG_CONTAINS_PIC_DATA) != 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (stray flags) frame \(currentFrameNumber)", Self.cat)
            return
        }

        let recoveredEntry = Entry(
            bytes: recovered, length: packetSize + dataOffset, seq: recoveredSeq,
            ts: ts, ssrc: ssrc, header: header, isParity: false)
        _ = queuePacket(recoveredEntry)
    }

    // MARK: - stageCompleteFecBlock (c:465-524)

    func stageCompleteFecBlock() {
        // Pull pending DATA entries in sequence order from bufferLowestSeq;
        // drop parity. Sort by 16-bit-distance from the buffer low to handle
        // wraparound + reorder, then move in order.
        let low = bufferLowestSequenceNumber
        let dataEntries = pending
            .filter { !$0.isParity }
            .sorted { a, b in
                let da = Int(Self.u16(Int(a.sequenceNumber) - Int(low)))
                let db = Int(Self.u16(Int(b.sequenceNumber) - Int(low)))
                return da < db
            }
        for entry in dataEntries {
            entry.receiveTimeUs = bufferFirstRecvTimeUs
            completed.append(entry)
        }
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: - submitCompletedFrame (c:526-537)

    func submitCompletedFrame() {
        for entry in completed {
            emit(entry)
        }
        completed.removeAll(keepingCapacity: true)

        // Metrics: tally one completed frame and whether it needed FEC recovery
        // (any of its multi-FEC blocks). The latch is cleared per frame.
        framesInWindow += 1
        if currentFrameNeededFec { fecRecoveredFramesInWindow += 1 }
        currentFrameNeededFec = false
    }

    /// Hand one completed packet to the depacketizer.
    private func emit(_ entry: Entry) {
        var dataOffset = Self.FIXED_RTP_HEADER_SIZE
        if entry.header & Self.FLAG_EXTENSION != 0 { dataOffset += 4 }
        let nv = dataOffset
        guard entry.length >= nv + 16 else { return }

        let spi = le32(entry.bytes, nv + 0)
        let frameIndex = le32(entry.bytes, nv + 4)
        let flags = entry.bytes[nv + 8]
        let extraFlags = entry.bytes[nv + 9]
        let multiFecBlocks = entry.bytes[nv + 11]
        let fecCurrentBlock = (multiFecBlocks >> 4) & 0x3
        let fecLastBlock = (multiFecBlocks >> 6) & 0x3

        // Payload = bytes after the 16-byte NV header.
        let payloadStart = nv + 16
        let payloadEnd = entry.length
        let payload: [UInt8] = payloadStart <= payloadEnd
            ? Array(entry.bytes[payloadStart..<payloadEnd]) : []

        let pkt = VideoDepacketizer.CompletedPacket(
            frameIndex: frameIndex,
            flags: flags,
            extraFlags: extraFlags,
            fecCurrentBlock: fecCurrentBlock,
            fecLastBlock: fecLastBlock,
            streamPacketIndex: spi,
            rtpTimestamp: entry.rtpTimestamp,
            presentationTimeUs: entry.presentationTimeUs,
            receiveTimeUs: entry.receiveTimeUs,
            payload: payload)
        depacketizer.process(pkt)
    }

    // MARK: - reportFinalFrameFecStatus (RtpVideoQueue.c:92-108)

    /// Build the per-frame FEC status from the current queue state and hand it to
    /// the sink (= connectionSendFrameFecStatus). Byte-for-byte field parity with
    /// reportFinalFrameFecStatus(): every value is taken from the live queue
    /// counters at the moment of the call. The serializer (FrameFecStatus
    /// .wireBytes) applies the big-endian wire order the C struct uses.
    ///
    /// multiFecBlockCount = multiFecLastBlockNumber + 1 (the C casts the +1 to
    /// u8). multiFecBlockIndex = multiFecCurrentBlockNumber.
    func reportFinalFrameFecStatus() {
        guard let sink = frameFecStatusSink else { return }
        let status = FrameFecStatus(
            frameIndex: currentFrameNumber,
            highestReceivedSequenceNumber: receivedHighestSequenceNumber,
            nextContiguousSequenceNumber: nextContiguousSequenceNumber,
            missingPacketsBeforeHighestReceived: Self.u16(missingPackets),
            totalDataPackets: Self.u16(bufferDataPackets),
            totalParityPackets: Self.u16(bufferParityPackets),
            receivedDataPackets: Self.u16(receivedDataPackets),
            receivedParityPackets: Self.u16(receivedParityPackets),
            fecPercentage: UInt8(truncatingIfNeeded: fecPercentage),
            multiFecBlockIndex: multiFecCurrentBlockNumber,
            multiFecBlockCount: multiFecLastBlockNumber &+ 1)
        sink(status)
    }
}
