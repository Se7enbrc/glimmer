// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  FuzzTests+Stream.swift
//
//  Fuzz targets for the busiest parsers the PC can reach: the video RTP queue with FEC
//  reassembly for H.264, HEVC and AV1, the AV1 sequence header and the audio RTP queue.
//  Same contract and fixed-seed SplitMix64 as FuzzTests.swift: never trap, bounded output.
//

import Foundation
import Testing
@testable import Glimmer

/// Records what the depacketizer assembled: the fuzz asserts the size bound and that the
/// valid stream really produced frames.
private final class FuzzFrameDelegate: VideoDepacketizerDelegate {
    var frames = 0
    var largestFrame = 0
    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {
        frames += 1
        largestFrame = max(largestFrame, Int(unit.fullLength))
    }
    func depacketizerDetectedFrameLoss(from: Int, to: Int) {}
    func depacketizerNeedsIdr() {}
    func depacketizerReceivedKeyFrame(frameNumber: Int) {}
}

private func shuffled<T>(_ items: [T], _ rng: inout SplitMix64) -> [T] {
    var items = items
    for index in stride(from: items.count - 1, to: 0, by: -1) {
        items.swapAt(index, rng.int(index + 1))
    }
    return items
}

struct StreamFuzzTests {

    // MARK: - Video RTP queue: addRawDatagram through FEC, reassembly and the depacketizer

    /// What a key frame's bitstream must start with for each codec's IDR detection.
    private static let keyFrameStarts: [Int32: [UInt8]] = [
        StreamProtocol.VIDEO_FORMAT_H264: [0, 0, 0, 1, 0x67],
        StreamProtocol.VIDEO_FORMAT_H265: [0, 0, 0, 1, 0x40, 0x01],
        StreamProtocol.VIDEO_FORMAT_AV1_MAIN8: []
    ]

    /// One frame's shards as Sunshine sends them: data from `VideoWire`, Cauchy parity over
    /// the whole packets, then the parity packets' own headers stamped on top.
    private static func frameShards(frame: UInt32, firstSeq: UInt16, firstSpi: UInt32, geometry: (data: Int, percent: Int),
                                    size: Int, format: Int32, rng: inout SplitMix64) -> [[UInt8]] {
        let payloadSize = size - 32
        let isKeyFrame = frame % 20 == 1
        var data: [[UInt8]] = []
        for index in 0..<geometry.data {
            var payload = (0..<payloadSize).map { _ in rng.byte() }
            if index == 0 {
                // Non-key frames carry the RFI recovery type, as the PC's do after a loss report.
                let start = VideoWire.frameHeader(type: isKeyFrame ? 2 : 4, lastPayloadLength: payloadSize)
                    + (isKeyFrame ? keyFrameStarts[format, default: []] : [])
                payload.replaceSubrange(0..<min(start.count, payloadSize), with: start.prefix(payloadSize))
            }
            var flags: UInt8 = index == 0 ? RtpVideoQueue.FLAG_SOF : 0
            if index == geometry.data - 1 { flags |= RtpVideoQueue.FLAG_EOF }
            data.append(VideoWire.shard(seq: firstSeq &+ UInt16(index), frame: frame, spi: firstSpi + UInt32(index),
                                        fecIndex: index, dataCount: geometry.data, fecPercent: geometry.percent,
                                        flags: flags, payload: payload))
        }
        let parityCount = (geometry.data * geometry.percent + 99) / 100
        guard parityCount > 0 else { return data }
        let parity = ReedSolomonTests.cauchyParity(data: data, ds: geometry.data, ps: parityCount, bs: size)
        return data + parity.enumerated().map { offset, bytes in
            VideoWire.shard(seq: firstSeq &+ UInt16(geometry.data + offset), frame: frame, spi: 0,
                            fecIndex: geometry.data + offset, dataCount: geometry.data, fecPercent: geometry.percent,
                            flags: 0, payload: Array(bytes[32...]))
        }
    }

    /// Corrupt one wire field the queue parses, or the whole datagram.
    private static func corrupt(_ shard: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var shard = shard
        switch rng.int(8) {
        case 0: shard[0] ^= RtpVideoQueue.FLAG_EXTENSION
        case 1: shard[2] = rng.byte(); shard[3] = rng.byte()
        case 2: for index in 20..<24 { shard[index] = rng.byte() }
        case 3: shard[24] = rng.byte()
        case 4: shard[27] = rng.byte()
        case 5: for index in 28..<32 { shard[index] = rng.byte() }
        case 6: shard[28 + rng.int(4)] ^= UInt8(1 << rng.int(8))
        default: shard = rng.mutate(shard, maxAppend: 128)
        }
        return shard
    }

    @Test(arguments: [StreamProtocol.VIDEO_FORMAT_H264, StreamProtocol.VIDEO_FORMAT_H265,
                      StreamProtocol.VIDEO_FORMAT_AV1_MAIN8])
    func fuzzVideoQueueAddRawDatagram(format: Int32) {
        var rng = SplitMix64(seed: 0x51DE_0ADD_0000_0011 ^ UInt64(UInt32(bitPattern: format)))
        let delegate = FuzzFrameDelegate()
        let depacketizer = VideoDepacketizer(delegate: delegate, negotiatedVideoFormat: format, colorSpace: 0)
        let queue = RtpVideoQueue(depacketizer: depacketizer, packetSize: 144)
        var clock: UInt64 = 1_000

        for _ in 0..<kIterations {
            clock += UInt64(rng.int(2_000))
            queue.addRawDatagram(rng.randomData(maxLen: 1_500), receiveTimeUs: clock)
        }

        let fresh = RtpVideoQueue(depacketizer: depacketizer, packetSize: 144)
        var seq: UInt16 = 0, spi: UInt32 = 0
        for frame in 1...UInt32(kIterations) {
            let geometry = (data: 1 + rng.int(6), percent: [0, 20, 50, 100][rng.int(4)])
            let shards = Self.frameShards(frame: frame, firstSeq: seq, firstSpi: spi, geometry: geometry,
                                          size: 40 + rng.int(121), format: format, rng: &rng)
            seq &+= UInt16(shards.count)
            spi += UInt32(geometry.data)
            // Loss, reordering and corruption as a hostile or unlucky link would deal them.
            let order = rng.int(4) == 0 ? shuffled(shards, &rng) : shards
            for shard in order where rng.int(8) != 0 {
                clock += UInt64(rng.int(200))
                fresh.addRawDatagram(rng.int(6) == 0 ? Self.corrupt(shard, &rng) : shard, receiveTimeUs: clock)
            }
        }
        // Loss, corruption and the IDR wait after sustained drops leave well over this many frames.
        #expect(delegate.frames > kIterations / 20, "the valid stream must reach the depacketizer")
        #expect(delegate.largestFrame <= VideoDepacketizer.maxFrameBytes)
    }

    // MARK: - AV1 sequence header (VideoDecoder.parseAV1SequenceHeader)

    @Test @MainActor func fuzzAV1SequenceHeader() {
        var rng = SplitMix64(seed: 0xA1A1_5E0_0000_0012)
        let decoder = VideoDecoder()
        let fixtures = [false, true].map { AV1SequenceHeaderTests.sequenceHeader(decoderModel: $0) }
        for fixture in fixtures {
            #expect(decoder.parseAV1SequenceHeader(fixture)?.bitDepth == 10)
        }
        for _ in 0..<kIterations {
            _ = decoder.parseAV1SequenceHeader(Data(rng.randomData(maxLen: 4096)))
            for fixture in fixtures {
                _ = decoder.parseAV1SequenceHeader(Data(rng.mutate([UInt8](fixture), maxAppend: 64)))
            }
        }
    }

    // MARK: - Audio RTP queue: addPacket with data and FEC datagrams

    private static func audioRtpHeader(type: UInt8, seq: UInt16, timestamp: UInt32) -> [UInt8] {
        [0x80, type, UInt8(seq >> 8), UInt8(truncatingIfNeeded: seq)]
            + (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> (24 - 8 * $0)) } + [0, 0, 0, 7]
    }

    @Test func fuzzAudioQueueAddPacket() {
        var rng = SplitMix64(seed: 0xA0D1_0F3C_0000_0013)
        let queue = RtpAudioQueue(audioPacketDuration: 5)
        var delivered = 0
        func feed(_ packet: [UInt8]) {
            // The receiver drops runts before the queue sees them (RtpAudioReceiver+Receive).
            guard packet.count >= RtpAudioQueue.fixedRtpHeaderSize else { return }
            let rtp = RtpAudioQueue.RtpHeader(
                header: packet[0], packetType: packet[1],
                sequenceNumber: UInt16(packet[2]) << 8 | UInt16(packet[3]),
                timestamp: UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7]),
                ssrc: UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16 | UInt32(packet[10]) << 8 | UInt32(packet[11]))
            let result = queue.addPacket(packet, rtp: rtp)
            if result != .none { delivered += 1 }
            if result == .packetReady {
                while queue.getQueuedPacket() != nil {}
            }
        }

        var base: UInt16 = 0
        for _ in 0..<kIterations {
            feed(rng.randomData(maxLen: 1_500))
            // One RS(4,2) block: four 5 ms packets and two parity shards, some dropped or corrupted.
            let timestamp = UInt32(base) * 240
            var packets = (0..<4).map {
                Self.audioRtpHeader(type: 97, seq: base &+ UInt16($0), timestamp: timestamp) + (0..<80).map { _ in rng.byte() }
            }
            for shard in 0..<2 {
                packets.append(Self.audioRtpHeader(type: 127, seq: base &+ 4 &+ UInt16(shard), timestamp: timestamp)
                    + [UInt8(shard), 97, UInt8(base >> 8), UInt8(truncatingIfNeeded: base)]
                    + Self.audioRtpHeader(type: 0, seq: 0, timestamp: timestamp)[4...]
                    + (0..<80).map { _ in rng.byte() })
            }
            for packet in shuffled(packets, &rng) where rng.int(6) != 0 {
                feed(rng.int(4) == 0 ? rng.mutate(packet, maxAppend: 64) : packet)
            }
            base &+= rng.int(16) == 0 ? UInt16(4 * (1 + rng.int(16))) : 4
        }
        #expect(delivered > kIterations, "the valid blocks must reach the decoder path")
    }
}
