// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  RtpVideoQueueLossTests.swift
//
//  Loss reporting and FEC bookkeeping on the video RTP queue: the speculative RFI,
//  the per-block rebuild latch and the recovery episode summary.
//

import Foundation
import Testing
@testable import Glimmer

/// Sunshine video datagrams for tests: RTP header with the extension bit, NV header, payload.
enum VideoWire {
    /// `spi` (the stream packet index) follows the sequence number unless given.
    static func shard(seq: UInt16, frame: UInt32, spi: UInt32? = nil, fecIndex: Int, dataCount: Int,
                      fecPercent: Int, flags: UInt8, multiFecBlocks: UInt8 = 0,
                      payload: [UInt8]) -> [UInt8] {
        let spi = spi ?? UInt32(seq)
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = RtpVideoQueue.FLAG_EXTENSION
        bytes[2] = UInt8(seq >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: seq)
        let fecInfo = UInt32(truncatingIfNeeded: dataCount << 22 | fecIndex << 12 | fecPercent << 4)
        for byte in 0..<4 {
            bytes[16 + byte] = UInt8(truncatingIfNeeded: (spi << 8) >> (8 * byte))
            bytes[20 + byte] = UInt8(truncatingIfNeeded: frame >> (8 * byte))
            bytes[28 + byte] = UInt8(truncatingIfNeeded: fecInfo >> (8 * byte))
        }
        bytes[24] = flags | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
        bytes[27] = multiFecBlocks
        return bytes + payload
    }

    /// Sunshine's 8-byte frame header: type 2 = IDR, 1 = P-frame, 4 = RFI recovery frame.
    static func frameHeader(type: UInt8, lastPayloadLength: Int) -> [UInt8] {
        [1, 0, 0, type, UInt8(truncatingIfNeeded: lastPayloadLength),
         UInt8(truncatingIfNeeded: lastPayloadLength >> 8), 0, 0]
    }

    /// A one-packet frame: the 8-byte header plus one payload byte.
    static func singlePacketFrame(_ frame: UInt32, seq: UInt16, type: UInt8) -> [UInt8] {
        shard(seq: seq, frame: frame, fecIndex: 0, dataCount: 1, fecPercent: 0,
              flags: RtpVideoQueue.FLAG_SOF | RtpVideoQueue.FLAG_EOF,
              payload: frameHeader(type: type, lastPayloadLength: 9) + [UInt8(truncatingIfNeeded: frame)])
    }
}

struct RtpVideoQueueLossTests {

    private let delegate = RecordingDepacketizerDelegate()

    private func makeQueue() -> RtpVideoQueue {
        let depacketizer = VideoDepacketizer(delegate: delegate,
                                             negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8,
                                             colorSpace: 0)
        return RtpVideoQueue(depacketizer: depacketizer, packetSize: 64)
    }

    /// Frame 2 of a stream whose first frame was an IDR: four data shards, one parity.
    private func frameTwoShard(_ fecIndex: Int, flags: UInt8) -> [UInt8] {
        VideoWire.shard(seq: UInt16(1 + fecIndex), frame: 2, fecIndex: fecIndex, dataCount: 4, fecPercent: 25,
                        flags: flags, payload: [UInt8](repeating: 2, count: 8))
    }

    /// Gaps beyond the parity aren't reported while the frame is still arriving: reordering on
    /// Wi-Fi fills them often enough that a speculative report only dropped frames. The next
    /// frame's first packet reports the loss once, and that frame still decodes.
    @Test func lossIsReportedWhenTheNextFrameStarts() {
        let queue = makeQueue()
        queue.addRawDatagram(VideoWire.singlePacketFrame(1, seq: 0, type: 2), receiveTimeUs: 1_000)
        #expect(delegate.units.map(\.frameNumber) == [1])

        queue.addRawDatagram(frameTwoShard(0, flags: RtpVideoQueue.FLAG_SOF), receiveTimeUs: 2_000)
        queue.addRawDatagram(frameTwoShard(3, flags: RtpVideoQueue.FLAG_EOF), receiveTimeUs: 2_100)
        #expect(delegate.losses.isEmpty)
        #expect(!queue.reportedLostFrame)

        queue.addRawDatagram(VideoWire.singlePacketFrame(3, seq: 6, type: 4), receiveTimeUs: 3_000)
        #expect(delegate.losses.map(\.to) == [2])
        #expect(delegate.units.map(\.frameNumber) == [1, 3])
    }

    // MARK: - FEC rebuild latch and geometry

    /// Frame 2 as three data shards with three parity shards (fecPercentage 67).
    private func wideShard(_ fecIndex: Int, flags: UInt8, payload: [UInt8]) -> [UInt8] {
        VideoWire.shard(seq: UInt16(1 + fecIndex), frame: 2, fecIndex: fecIndex, dataCount: 3, fecPercent: 67,
                        flags: flags, payload: payload)
    }

    /// Garbage parity makes every rebuild fail. The failure is latched until a data shard
    /// arrives, so later parity packets don't rerun Reed-Solomon, and the data shard that
    /// completes the frame on its own still delivers it.
    @Test func failedRebuildWaitsForANewDataShard() {
        let queue = makeQueue()
        queue.addRawDatagram(VideoWire.singlePacketFrame(1, seq: 0, type: 2), receiveTimeUs: 1_000)
        let garbage = [UInt8](repeating: 0xAB, count: 8), body = [UInt8](repeating: 2, count: 8)
        let header = VideoWire.frameHeader(type: 1, lastPayloadLength: body.count)
        queue.addRawDatagram(wideShard(0, flags: RtpVideoQueue.FLAG_SOF, payload: header), receiveTimeUs: 2_000)
        queue.addRawDatagram(wideShard(3, flags: 0, payload: garbage), receiveTimeUs: 2_001)
        #expect(queue.fecFailedDataCount == -1)
        queue.addRawDatagram(wideShard(4, flags: 0, payload: garbage), receiveTimeUs: 2_002)
        #expect(queue.fecFailedDataCount == 1)
        #expect(queue.reedSolomonCache.count == 1)
        queue.addRawDatagram(wideShard(5, flags: 0, payload: garbage), receiveTimeUs: 2_003)
        #expect(queue.fecFailedDataCount == 1)
        queue.addRawDatagram(wideShard(1, flags: 0, payload: body), receiveTimeUs: 2_004)
        #expect(queue.fecFailedDataCount == 2)
        queue.addRawDatagram(wideShard(2, flags: RtpVideoQueue.FLAG_EOF, payload: body), receiveTimeUs: 2_005)
        #expect(delegate.units.map(\.frameNumber) == [1, 2])
        #expect(delegate.units.last?.buffers.first?.data == Data(body + body))
        #expect(queue.fecRecoveredFramesInWindow == 0)
    }

    /// Data plus parity over 255 shards can never decode: it is logged once per stream
    /// and the block is not retried on every later parity packet.
    @Test func hostileFecGeometryLogsOnceAndLatches() {
        let queue = makeQueue()
        func shard(_ fecIndex: Int) -> [UInt8] {
            VideoWire.shard(seq: UInt16(fecIndex), frame: 1, fecIndex: fecIndex, dataCount: 200, fecPercent: 50,
                            flags: fecIndex == 0 ? RtpVideoQueue.FLAG_SOF : 0, payload: [1])
        }
        func geometryLines() -> Int {
            LogStore.shared.snapshot().filter { $0.message.contains("FEC geometry") }.count
        }
        let before = geometryLines()
        for fecIndex in 0..<199 { queue.addRawDatagram(shard(fecIndex), receiveTimeUs: 1_000) }
        #expect(queue.fecFailedDataCount == -1)
        for fecIndex in 200..<210 { queue.addRawDatagram(shard(fecIndex), receiveTimeUs: 1_000) }
        #expect(queue.fecFailedDataCount == 199)
        #expect(queue.reedSolomonCache.isEmpty)
        #expect(geometryLines() == before + 1)
    }

    /// A run of recovered frames logs once, after it has been quiet for the idle time.
    @Test func recoveryEpisodeSummarizesOnceIdle() {
        var episode = FecRecoveryEpisode()
        #expect(episode.summaryIfIdle(nowUs: 5_000_000, idleUs: 2_000_000) == nil)
        episode.note(frame: 40, shards: 2, margin: 1, nowUs: 1_000_000)
        episode.note(frame: 41, shards: 1, margin: 2, nowUs: 1_100_000)
        episode.note(frame: 45, shards: 3, margin: 0, nowUs: 1_500_000)
        #expect(episode.summaryIfIdle(nowUs: 3_400_000, idleUs: 2_000_000) == nil)
        #expect(episode.summaryIfIdle(nowUs: 3_500_000, idleUs: 2_000_000)
            == "3 frames from 40, 6 shards rebuilt, worst parity margin 0, over 500 ms")
        #expect(episode.frames == 0)
    }

    /// Dropping a frame for a lost FEC block must not silence the report for the frame after it.
    @Test func lossAfterADroppedBlockIsStillReported() {
        let queue = makeQueue()
        queue.addRawDatagram(VideoWire.singlePacketFrame(1, seq: 0, type: 2), receiveTimeUs: 1_000)
        // Frame 2 arrives starting at its second FEC block: the first is gone, the frame is dropped.
        queue.addRawDatagram(VideoWire.shard(seq: 1, frame: 2, fecIndex: 0, dataCount: 1, fecPercent: 0,
                                             flags: RtpVideoQueue.FLAG_EOF, multiFecBlocks: 0x50, payload: [2]),
                             receiveTimeUs: 2_000)
        #expect(delegate.losses.map(\.to) == [2])
        // Frame 3 never arrives at all; frame 4 opens and must still report it.
        queue.addRawDatagram(VideoWire.singlePacketFrame(4, seq: 3, type: 4), receiveTimeUs: 4_000)
        #expect(delegate.losses.map(\.to) == [2, 3])
        #expect(delegate.units.map(\.frameNumber) == [1, 4])
    }
}
