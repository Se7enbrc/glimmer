// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  RtpReceiverLoopbackTests.swift
//
//  The video and audio receivers against a loopback peer: each pings the PC's port, and RTP
//  sent back to the ping's source runs the real receive loop through to the sink.
//

import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

struct RtpReceiverLoopbackTests {

    private static let pingPayload = [UInt8](1...16)

    /// Every field is read or written while holding the lock.
    private final class FrameSink: VideoSink, @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Int32] = []
        let submitted = DispatchSemaphore(value: 0)
        var capabilities: Int32 { 0 }
        func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 { 0 }
        func start() {}
        func stop() {}
        func cleanup() {}
        func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 {
            lock.withLock { frames.append(unit.frameNumber) }
            submitted.signal()
            return StreamProtocol.DR_OK
        }
        var frameNumbers: [Int32] { lock.withLock { frames } }
    }

    /// Every field is read or written while holding the lock.
    private final class OpusSink: NativeAudioSink, @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        let decoded = DispatchSemaphore(value: 0)
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: UnsafeRawBufferPointer) {
            lock.withLock { packets.append(Array(opus)) }
            decoded.signal()
        }
        func decodeAndPlayPLC() {}
        func cleanup() {}
        var firstBytes: [UInt8] { lock.withLock { packets.compactMap(\.first) } }
    }

    private static func firstPing(at peer: LoopbackUdpPeer) async throws -> (bytes: [UInt8], from: sockaddr_in) {
        try #require(try await onTestThread { peer.receive(within: .seconds(5)) })
    }

    @Test func videoPingsThePeerAndDeliversTheFrameSentBack() async throws {
        let peer = try #require(LoopbackUdpPeer())
        let sink = FrameSink()
        let receiver = VideoRtpReceiver(
            host: .ipv4(.loopback), videoPort: peer.port, pingPayload: Self.pingPayload, packetSize: 64,
            bitrateKbps: 10_000, negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8,
            encryptionFeaturesEnabled: 0, aesKey: [], colorSpace: 0, sink: sink,
            requestIdr: {}, invalidateReferenceFrames: { _, _ in })
        try await receiver.start()
        defer { receiver.stop() }

        let ping = try await Self.firstPing(at: peer)
        #expect(ping.bytes == Self.pingPayload + [0, 0, 0, 1])
        peer.send(VideoWire.singlePacketFrame(1, seq: 0, type: 2), to: ping.from)
        #expect(await sink.submitted.waitAsync(for: .seconds(5)) == .success)
        #expect(sink.frameNumbers == [1])
    }

    @Test func audioPingsThePeerAndDecodesWhatItSendsBack() async throws {
        let peer = try #require(LoopbackUdpPeer())
        let sink = OpusSink()
        let receiver = RtpAudioReceiver(
            host: .ipv4(.loopback), audioPort: peer.port, pingPayload: Self.pingPayload, audioPacketDuration: 5,
            opusConfig: SdpScan.defaultOpusConfig, audioConfig: 0, audioEncryption: false,
            aesKey: EnetFixture.key, aesIvId: [UInt8](repeating: 0, count: 16), sink: sink)
        try receiver.start()
        defer { receiver.stop() }

        let ping = try await Self.firstPing(at: peer)
        #expect(ping.bytes == Self.pingPayload + [0, 0, 0, 1])
        let sequences = UInt16(0)...11
        for seq in sequences {
            peer.send([0x80, RtpAudioQueue.payloadTypeAudio, UInt8(seq >> 8), UInt8(truncatingIfNeeded: seq),
                       0, 0, 0, UInt8(truncatingIfNeeded: seq &* 5), 0, 0, 0, 1,
                       UInt8(truncatingIfNeeded: seq), 0xAA, 0xBB], to: ping.from)
        }
        // The queue holds the first FEC block back while it synchronises.
        let expected = Array(UInt8(RtpAudioQueue.dataShards)...11)
        for _ in expected {
            try #require(await sink.decoded.waitAsync(for: .seconds(5)) == .success)
        }
        #expect(sink.firstBytes == expected)
    }
}
