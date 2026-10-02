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

    /// On a link that has never reordered, a frame whose gaps already exceed its parity is
    /// reported lost at once, and the next frame's first packet does not report it again.
    @Test func lossIsReportedBeforeTheNextFrameStarts() {
        let queue = makeQueue()
        queue.addRawDatagram(VideoWire.singlePacketFrame(1, seq: 0, type: 2), receiveTimeUs: 1_000)
        #expect(delegate.units.map(\.frameNumber) == [1])

        queue.addRawDatagram(frameTwoShard(0, flags: RtpVideoQueue.FLAG_SOF), receiveTimeUs: 2_000)
        #expect(delegate.losses.isEmpty)
        queue.addRawDatagram(frameTwoShard(3, flags: RtpVideoQueue.FLAG_EOF), receiveTimeUs: 2_100)
        #expect(delegate.losses.map(\.to) == [2])
        #expect(queue.currentFrameNumber == 2)
        #expect(queue.reportedLostFrame)

        queue.addRawDatagram(VideoWire.singlePacketFrame(3, seq: 6, type: 4), receiveTimeUs: 3_000)
        #expect(delegate.losses.map(\.to) == [2])
        #expect(delegate.units.map(\.frameNumber) == [1, 3])
    }

    /// A gap the parity can still fill is not reported, and reordering turns the prediction off.
    @Test(arguments: [false, true])
    func recoverableGapsAndReorderingLinksStayQuiet(reordering: Bool) {
        let queue = makeQueue()
        queue.addRawDatagram(VideoWire.singlePacketFrame(1, seq: 0, type: 2), receiveTimeUs: 1_000)
        queue.receivedOosData = reordering
        queue.addRawDatagram(frameTwoShard(0, flags: RtpVideoQueue.FLAG_SOF), receiveTimeUs: 2_000)
        queue.addRawDatagram(frameTwoShard(reordering ? 3 : 2, flags: 0), receiveTimeUs: 2_100)
        #expect(delegate.losses.isEmpty)
        #expect(!queue.reportedLostFrame)
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
