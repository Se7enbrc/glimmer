// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoRtpReceiverDelegateTests.swift
//
//  The receiver's depacketizer callbacks without a socket: loss episodes and the RFI they
//  forward, frames handed to the sink, and the IDR requests a struggling decoder triggers.
//

import Foundation
import Testing
@testable import Glimmer

struct VideoRtpReceiverDelegateTests {

    /// Every field is read or written while holding the lock.
    private final class RecordingSink: VideoSink, @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Int32] = []
        private let result: Int32
        init(result: Int32 = StreamProtocol.DR_OK) { self.result = result }
        var capabilities: Int32 { 0 }
        func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 { 0 }
        func start() {}
        func stop() {}
        func cleanup() {}
        func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 {
            lock.lock(); frames.append(unit.frameNumber); lock.unlock()
            return result
        }
        func submitted() -> [Int32] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    /// The receiver calls back synchronously on the test's thread.
    private final class Requests {
        var idr = 0
        var rfi: [[Int]] = []
    }

    private static func receiver(_ sink: VideoSink, _ requests: Requests) -> VideoRtpReceiver {
        VideoRtpReceiver(host: .ipv4(.loopback), videoPort: 0, pingPayload: [], packetSize: 1392,
                         bitrateKbps: 20_000, negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H265,
                         encryptionFeaturesEnabled: 0, aesKey: [], colorSpace: 0, sink: sink,
                         requestIdr: { requests.idr += 1 },
                         invalidateReferenceFrames: { requests.rfi.append([$0, $1]) })
    }

    private static func unit(_ frame: Int32, type: Int32 = StreamProtocol.FRAME_TYPE_PFRAME) -> DecodeUnit {
        DecodeUnit(frameNumber: frame, frameType: type, fullLength: 1000, frameHostProcessingLatency: 0,
                   receiveTimeUs: 1, enqueueTimeUs: 2, presentationTimeUs: 3, rtpTimestamp: 4,
                   hdrActive: false, colorspace: 0, buffers: [])
    }

    @Test func lossOpensOneEpisodeThatTheNextFrameCloses() {
        let sink = RecordingSink()
        let requests = Requests()
        let receiver = Self.receiver(sink, requests)
        receiver.depacketizerDetectedFrameLoss(from: 1_010, to: 1_012)
        receiver.depacketizerDetectedFrameLoss(from: 1_013, to: 1_014)
        #expect(requests.rfi == [[1_010, 1_012], [1_013, 1_014]])
        #expect(receiver.lossEpisode.isOpen)
        receiver.depacketizerDidAssembleFrame(Self.unit(1_015))
        #expect(!receiver.lossEpisode.isOpen)
        #expect(sink.submitted() == [1_015])
        #expect(requests.idr == 0)
        let summary = "NativeVideo loss episode: 5 frames from 1010, recovered by RFI frame 1015 after"
        #expect(LogStore.shared.snapshot().contains { $0.message.hasPrefix(summary) })
    }

    @Test func decoderNeedingAKeyframeFlushesToAnIdrRequest() {
        let sink = RecordingSink(result: StreamProtocol.DR_NEED_IDR)
        let requests = Requests()
        let receiver = Self.receiver(sink, requests)
        receiver.depacketizerDidAssembleFrame(Self.unit(7))
        #expect(requests.idr == 1)
        receiver.depacketizerDidAssembleFrame(Self.unit(8, type: StreamProtocol.FRAME_TYPE_IDR))
        #expect(requests.idr == 2)
        #expect(sink.submitted() == [7, 8])
    }

    @Test func acceptedFramesRequestNothing() {
        let requests = Requests()
        let sink = RecordingSink()
        let receiver = Self.receiver(sink, requests)
        receiver.depacketizerDidAssembleFrame(Self.unit(3, type: StreamProtocol.FRAME_TYPE_IDR))
        receiver.depacketizerReceivedKeyFrame(frameNumber: 3)
        #expect(requests.idr == 0 && requests.rfi.isEmpty)
        #expect(sink.submitted() == [3])
    }

    @Test func depacketizerIdrNeedIsForwardedOnce() {
        let requests = Requests()
        let sink = RecordingSink()
        let receiver = Self.receiver(sink, requests)
        receiver.depacketizerNeedsIdr()
        #expect(requests.idr == 1)
        #expect(sink.submitted().isEmpty)
    }
}
