// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

final class RecordingDepacketizerDelegate: VideoDepacketizerDelegate {
    var units: [DecodeUnit] = []
    var losses: [(from: Int, to: Int)] = []
    var idrRequests = 0
    var keyFrames: [Int] = []

    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) { units.append(unit) }
    func depacketizerDetectedFrameLoss(from: Int, to: Int) { losses.append((from, to)) }
    func depacketizerNeedsIdr() { idrRequests += 1 }
    func depacketizerReceivedKeyFrame(frameNumber: Int) { keyFrames.append(frameNumber) }
}

struct VideoDepacketizerRecoveryTests {
    private func depacketizer(_ recorder: RecordingDepacketizerDelegate) -> VideoDepacketizer {
        VideoDepacketizer(delegate: recorder,
                          negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8,
                          colorSpace: 0)
    }

    private func packet(frame: UInt32, spi: UInt32, type: UInt8, body: [UInt8] = [0x31],
                        length: Int? = nil, flags: UInt8 = 0x07) -> VideoDepacketizer.CompletedPacket {
        let payloadLength = length ?? body.count + 8
        let header: [UInt8] = [1, 0, 0, type,
                               UInt8(truncatingIfNeeded: payloadLength),
                               UInt8(truncatingIfNeeded: payloadLength >> 8), 0, 0]
        return VideoDepacketizer.CompletedPacket(
            frameIndex: frame, flags: flags, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: spi << 8, rtpTimestamp: frame,
            presentationTimeUs: UInt64(frame) * 1_000, receiveTimeUs: UInt64(frame) * 1_000,
            payload: (header + body)[...])
    }

    @Test func rfiWaitDropsPFramesUntilRecoveryFrame() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.queueLostFrame(2)
        dp.process(packet(frame: 3, spi: 1, type: 1))
        dp.process(packet(frame: 4, spi: 2, type: 1))
        #expect(recorder.losses.map(\.to) == [2, 3, 4])
        #expect(recorder.units.map(\.frameNumber) == [1])
        dp.process(packet(frame: 5, spi: 3, type: 4))
        #expect(recorder.units.map(\.frameNumber) == [1, 5])
        #expect(recorder.idrRequests == 0)
    }

    @Test func idrAlsoReopensRfiWait() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.queueLostFrame(2)
        dp.process(packet(frame: 3, spi: 1, type: 2))
        #expect(recorder.units.map(\.frameNumber) == [1, 3])
        #expect(recorder.keyFrames == [1, 3])
    }

    @Test func lastAv1PacketIsTruncatedToAdvertisedLength() throws {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2, body: [0x11, 0x12], length: 2, flags: 0x05))
        dp.process(VideoDepacketizer.CompletedPacket(
            frameIndex: 1, flags: 0x03, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: 1 << 8, rtpTimestamp: 1, presentationTimeUs: 1_000,
            receiveTimeUs: 1_000, payload: [0x21, 0x22, 0, 0]))
        let unit = try #require(recorder.units.first)
        #expect(unit.buffers.first?.data == Data([0x11, 0x12, 0x21, 0x22]))
    }

    @Test func oversizedLastPayloadIsDroppedAndReported() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.process(packet(frame: 2, spi: 1, type: 1, length: 20))
        #expect(recorder.units.map(\.frameNumber) == [1])
        #expect(recorder.losses.map(\.to) == [2])
    }

    /// A first packet shorter than its frame header carries no bitstream: it is dropped
    /// at the parser and recovery is requested, not fed to the decoder as video.
    @Test(arguments: [[1, 0, 0, 1, 5], [0, 0, 0, 1, 0, 0, 0, 0, 0, 0]] as [[UInt8]])
    func firstPacketShorterThanItsHeaderIsCorrupt(payload: [UInt8]) {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.process(VideoDepacketizer.CompletedPacket(
            frameIndex: 2, flags: 0x07, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: 1 << 8, rtpTimestamp: 2, presentationTimeUs: 2_000,
            receiveTimeUs: 2_000, payload: payload[...]))
        #expect(recorder.units.map(\.frameNumber) == [1])
        #expect(recorder.losses.map(\.to) == [2])
    }

    @Test func spiGapRequestsIdrBeforeFirstKeyFrameAndRfiAfterIt() {
        let before = RecordingDepacketizerDelegate()
        let first = depacketizer(before)
        first.process(packet(frame: 1, spi: 1, type: 1, flags: 0x03))
        #expect(before.idrRequests == 1)

        let after = RecordingDepacketizerDelegate()
        let second = depacketizer(after)
        second.process(packet(frame: 1, spi: 0, type: 2))
        second.process(packet(frame: 2, spi: 2, type: 1, flags: 0x03))
        #expect(after.losses.map(\.to) == [2])
        #expect(after.idrRequests == 0)
    }

    // Synthetic transport fixtures from H.264/H.265 NAL type tables and Annex B, not encoded pictures.
    private func transportNAL(_ type: UInt8, hevc: Bool, short: Bool = false) -> [UInt8] {
        let prefix: [UInt8] = short ? [0, 0, 1] : [0, 0, 0, 1]
        let reference: UInt8 = [5, 7, 8].contains(type) ? 0x60 : 0
        let header: [UInt8] = hevc ? [type << 1, 1] : [type | reference]
        return prefix + header + [0xA9, 0, 0, 3, 1, 0x80]
    }

    @Test(arguments: [false, true], [0, 1, 2, 3])
    func prefixMetadataSurvivesStartupAndRefresh(hevc: Bool, shape: Int) throws {
        let recorder = RecordingDepacketizerDelegate()
        let format = hevc ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264
        let receiver = VideoDepacketizer(delegate: recorder, negotiatedVideoFormat: format, colorSpace: 0)
        let aud = transportNAL(hevc ? 35 : 9, hevc: hevc, short: true)
        let sei = transportNAL(hevc ? 39 : 6, hevc: hevc)
        let metadata = [[], aud, sei, aud + sei + sei][shape]
        let types: [UInt8] = hevc ? [32, 33, 34] : [7, 8]
        let parameters = types.enumerated().map { transportNAL($0.element, hevc: hevc, short: $0.offset == 1) }
        let picture = transportNAL(hevc ? 19 : 5, hevc: hevc, short: true)
        let accessUnit = metadata + parameters.flatMap { $0 } + picture
        receiver.process(packet(frame: 1, spi: 0, type: 2, body: accessUnit + [0, 0, 0]))
        receiver.requestDecoderRefresh()
        receiver.process(packet(frame: 2, spi: 1, type: 1, body: transportNAL(1, hevc: hevc)))
        receiver.process(packet(frame: 3, spi: 2, type: 2, body: accessUnit))
        #expect(recorder.units.map(\.frameNumber) == [1, 3])
        #expect(recorder.keyFrames == [1, 3])
        #expect(recorder.idrRequests == 1)
        let unit = try #require(recorder.units.last)
        #expect(unit.buffers.dropLast().map(\.data) == parameters.map { Data($0) })
        #expect(unit.buffers.last?.data == Data(metadata + picture))
        #expect(unit.buffers.map(\.kind) == (hevc ? [.vps, .sps, .pps, .picData] : [.sps, .pps, .picData]))
    }

    @Test(arguments: [false, true])
    func metadataCannotHidePredictiveOrMalformedHeaders(hevc: Bool) {
        let metadata = transportNAL(hevc ? 39 : 6, hevc: hevc)
        let evidence = transportNAL(hevc ? 32 : 7, hevc: hevc)
        let predictive = transportNAL(1, hevc: hevc)
        let wrongCodec = transportNAL(hevc ? 7 : 32, hevc: !hevc)
        let invalid = [metadata, metadata + [0, 0, 1], metadata + predictive,
                       predictive + evidence, wrongCodec, metadata + [0, 0, 1, 0x80],
                       hevc ? [0, 0, 1, 64, 0] : [0, 0, 1, 0x87],
                       hevc ? [0, 0, 1, 64, 2] : [0, 0, 1, 7]]
        for bytes in invalid {
            let recorder = RecordingDepacketizerDelegate()
            let format = hevc ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264
            let receiver = VideoDepacketizer(delegate: recorder, negotiatedVideoFormat: format, colorSpace: 0)
            receiver.process(packet(frame: 1, spi: 0, type: 2, body: bytes))
            #expect(recorder.units.isEmpty && recorder.keyFrames.isEmpty)
            #expect(!VideoDepacketizer.isIdrFrameStart(bytes, hevc: hevc))
        }
        let complete = metadata + evidence
        for limit in 0...complete.count {
            let sliced = ([19, 20, 21] + complete)[3..<(3 + limit)]
            let expected = limit >= metadata.count + 4 + (hevc ? 2 : 1)
            #expect(VideoDepacketizer.isIdrFrameStart(sliced, hevc: hevc) == expected)
        }
        let large = metadata + Array(repeating: [UInt8(0), 0, 3, 1, 0xA9], count: 8_000).flatMap { $0 }
        #expect(VideoDepacketizer.isIdrFrameStart(large + evidence, hevc: hevc))
        #expect(!VideoDepacketizer.isIdrFrameStart(large, hevc: hevc))
    }

    @Test(arguments: [false, true])
    func annexBZeroBytesRemainDistinctFromGarbage(hevc: Bool) {
        let parameter = transportNAL(hevc ? 32 : 7, hevc: hevc)
        let prefix = [UInt8](repeating: 0, count: 6)
        #expect(VideoDepacketizer.isIdrFrameStart(prefix + parameter, hevc: hevc))
        #expect(!VideoDepacketizer.isIdrFrameStart([17] + prefix + parameter, hevc: hevc))
        let format = hevc ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264
        let receiver = VideoDepacketizer(delegate: RecordingDepacketizerDelegate(),
                                         negotiatedVideoFormat: format, colorSpace: 0)
        let split = receiver.splitAnnexBParamSets(Data(prefix + parameter))
        #expect(split.first?.data == Data(prefix + parameter))
    }

    @Test func sustainedDropsForceOneIdrAtTheLimit() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        for frame in 2...121 { dp.queueLostFrame(frame) }
        #expect(recorder.idrRequests == 1)
        #expect(recorder.losses.count == 119)
    }
}
