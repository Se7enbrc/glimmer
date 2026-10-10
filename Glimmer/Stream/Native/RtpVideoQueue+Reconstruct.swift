// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  RtpVideoQueue+Reconstruct.swift
//  FEC reconstruction and frame submission on the single RTP receive thread.
import Foundation

/// A run of frames that needed Reed-Solomon recovery, summarized once the run
/// has been quiet for a while instead of logging a line per frame.
struct FecRecoveryEpisode {
    private(set) var frames = 0
    private var shards = 0
    private var minMargin = Int.max
    private var firstFrame: UInt32 = 0
    private var startUs: UInt64 = 0
    private var lastUs: UInt64 = 0

    mutating func note(frame: UInt32, shards rebuilt: Int, margin: Int, nowUs: UInt64) {
        if frames == 0 {
            firstFrame = frame
            startUs = nowUs
        }
        frames += 1
        shards += rebuilt
        minMargin = min(minMargin, margin)
        lastUs = nowUs
    }

    /// The summary once no frame has needed recovery for `idleUs`; nil while the run is live.
    mutating func summaryIfIdle(nowUs: UInt64, idleUs: UInt64) -> String? {
        guard frames > 0, nowUs &- lastUs >= idleUs else { return nil }
        defer { self = FecRecoveryEpisode() }
        return "\(frames) frames from \(firstFrame), \(shards) shards rebuilt, "
            + "worst parity margin \(minMargin), over \((lastUs &- startUs) / 1000) ms"
    }
}

extension RtpVideoQueue {

    // MARK: - reconstructFrame (c:193-463). Returns 0 if complete.

    func reconstructFrame() -> Int {
        let totalPackets = bufferDataPackets + bufferParityPackets
        let neededPackets = bufferDataPackets

        if pending.count < neededPackets {
            // No speculative loss report: on Wi-Fi it fired on gaps FEC then filled, dropping
            // frames for nothing. The next frame's first packet reports a real loss.
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
        // A failed rebuild is retried only once a late data shard changes the gap set.
        if receivedDataPackets == fecFailedDataCount {
            return -1
        }
        func failed() -> Int {
            fecFailedDataCount = receivedDataPackets
            return -1
        }

        // Sunshine sends a block's shards at one length, shorter than we asked for when
        // the PC caps the packet size. Parity is always full length: take the longest.
        let receiveSize = min(pending.reduce(0) { max($0, $1.length) },
                              packetSize + Self.MAX_RTP_HEADER_SIZE)
        guard let rs = reedSolomon(dataShards: bufferDataPackets, parityShards: bufferParityPackets) else {
            if !loggedBadFecGeometry {
                loggedBadFecGeometry = true
                Diag.error("NativeVideo FEC geometry rejected (ds=\(bufferDataPackets) "
                    + "ps=\(bufferParityPackets)); logged once per stream", Self.cat)
            }
            return failed()
        }

        var (shards, marks) = buildShards(totalPackets: totalPackets, receiveSize: receiveSize)

        let ok = rs.decode(shards: &shards, marks: marks, bs: receiveSize)
        if !ok {
            Diag.error("NativeVideo FEC unrecoverable frame \(currentFrameNumber): "
                + "have \(pending.count) need \(neededPackets)", Self.cat)
            return failed()
        }

        // Validate the entire recovery before committing any shard or success metric.
        var recovered: [Entry] = []
        for index in 0..<bufferDataPackets where marks[index] {
            guard let entry = rebuildRecoveredShard(shards[index], index: index, headEntry: pending.first) else {
                return failed()
            }
            recovered.append(entry)
        }
        logFecRecovery()
        for entry in recovered { _ = queuePacket(entry, isFecRecovery: true) }
        return 0
    }

    /// The decoder for this geometry, built once per (data, parity) pair.
    private func reedSolomon(dataShards: Int, parityShards: Int) -> ReedSolomon? {
        let key = dataShards << 16 | parityShards
        if let cached = reedSolomonCache[key] { return cached }
        guard let decoder = ReedSolomon(dataShards: dataShards, parityShards: parityShards) else { return nil }
        if reedSolomonCache.count >= Self.reedSolomonCacheCap {
            reedSolomonCache.removeAll(keepingCapacity: true)
        }
        reedSolomonCache[key] = decoder
        return decoder
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

    /// Count this frame's recovery for the metrics and the open episode. The first
    /// recovery of a stream logs on its own; later ones log as an episode summary.
    private func logFecRecovery() {
        currentFrameNeededFec = true
        let recovered = bufferDataPackets - receivedDataPackets
        let margin = bufferParityPackets - recovered
        windowMinParityMargin = min(windowMinParityMargin, margin)
        fecEpisode.note(frame: currentFrameNumber, shards: recovered, margin: margin, nowUs: bufferFirstRecvTimeUs)
        if !loggedFirstFecRecovery {
            loggedFirstFecRecovery = true
            Diag.notice("NativeVideo first FEC recovery: \(recovered) shards, frame \(currentFrameNumber)", Self.cat)
        }
    }

    /// FEC cannot recover every header field. Rebuild those from the block and
    /// validate flags before any recovered data becomes visible to the queue.
    private func rebuildRecoveredShard(_ shard: [UInt8], index: Int, headEntry: Entry?) -> Entry? {
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
            return nil
        }
        if index == bufferDataPackets - 1 && (recFlags & Self.FLAG_EOF) == 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (no EOF) frame \(currentFrameNumber)", Self.cat)
            return nil
        }
        if index > 0 && index < bufferDataPackets - 1 && (recFlags & Self.FLAG_CONTAINS_PIC_DATA) == 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (no PIC) frame \(currentFrameNumber)", Self.cat)
            return nil
        }
        if recFlags & ~(Self.FLAG_SOF | Self.FLAG_EOF | Self.FLAG_CONTAINS_PIC_DATA) != 0 {
            Diag.warn("NativeVideo FEC corrupt recovered packet \(recoveredSeq) (stray flags) frame \(currentFrameNumber)", Self.cat)
            return nil
        }

        return Entry(
            bytes: recovered, length: recovered.count - Self.MAX_RTP_HEADER_SIZE + dataOffset, seq: recoveredSeq,
            ts: ts, ssrc: ssrc, header: header, isParity: false)
    }

    // MARK: - stageCompleteFecBlock (c:465-524)

    func stageCompleteFecBlock() {
        // The fast path already proved sequence order. Otherwise sort by modular
        // distance from the block's low sequence so wrap and reorders stay ordered.
        let low = bufferLowestSequenceNumber
        var dataEntries = pending.filter { !$0.isParity }
        if !useFastQueuePath {
            dataEntries.sort { a, b in
                let da = Int(Self.u16(Int(a.sequenceNumber) - Int(low)))
                let db = Int(Self.u16(Int(b.sequenceNumber) - Int(low)))
                return da < db
            }
        }
        for var entry in dataEntries {
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

        // Payload = bytes after the 16-byte NV header, as a slice of the packet: the
        // depacketizer copies it into the frame before this call returns.
        let payloadStart = nv + 16
        let payloadEnd = entry.length
        let payload: ArraySlice<UInt8> = payloadStart <= payloadEnd ? entry.bytes[payloadStart..<payloadEnd] : []

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
}
