//
//  ParserHelperTests.swift
//
//  Pure helpers on the untrusted-network-input surface that are reachable from
//  the test bundle (@testable exposes `internal`, NOT `private`).
//
//  Reachable here: RtpAudioQueue.isBefore16 (internal static) - the wrap-safe
//  16-bit RTP sequence-number comparison from Limelight-internal.h:76.
//
//  Genuinely-pure parser helpers widened from `private` to `internal` (with a
//  `// internal for testability` note at each declaration) and covered below:
//    - VideoDepacketizer.isIdrFrameStart  (pure static; Annex-B start-code +
//      SPS/VPS sniff on untrusted host input - the memory-safety surface)
//    - VideoDepacketizer.splitAnnexBParamSets (transform of one AU; reads only
//      the init-time-immutable codec flag, no queue/clock/mutable state)
//    - RtpAudioQueue.padShard       (pure pad/clamp of a byte buffer)
//    - RtpAudioQueue.appendRtpHeader (pure big-endian RTP-header serialization)
//
//  Still NOT covered: RtpVideoQueue+Reconstruct.buildShards. It is an instance
//  method that reads mutable live-queue state (`pending` entries and
//  `bufferLowestSequenceNumber`, populated by packet ingestion), so exercising
//  it deterministically would mean driving a live queue - explicitly out of
//  scope. Left `private`.
//

import Foundation
import Network
import Testing
@testable import Glimmer

struct ParserHelperTests {

    @Test(arguments: [("192.0.2.1", "192.0.2.2"), ("2001:db8::1", "2001:db8::2")])
    func audioPeerFilterChecksAddressButAllowsDifferentSourcePorts(peer: String, stranger: String) throws {
        let (expected, expectedLength, _) = try #require(UdpPinger.makeSockaddr(for: NWEndpoint.Host(peer), port: 48_000))
        let (samePeer, sameLength, _) = try #require(UdpPinger.makeSockaddr(for: NWEndpoint.Host(peer), port: 54_321))
        let (otherPeer, otherLength, _) = try #require(UdpPinger.makeSockaddr(for: NWEndpoint.Host(stranger), port: 48_000))
        #expect(RtpAudioReceiver.isExpectedPeer(samePeer, length: sameLength,
                                              expected: expected, expectedLength: expectedLength))
        #expect(!RtpAudioReceiver.isExpectedPeer(otherPeer, length: otherLength,
                                               expected: expected, expectedLength: expectedLength))
        #expect(!RtpAudioReceiver.isExpectedPeer(samePeer, length: sameLength - 1,
                                               expected: expected, expectedLength: expectedLength))
    }

    @Test func audioPeerFilterRejectsWrongFamilyAndIPv6Scope() throws {
        let (destination, length, _) = try #require(UdpPinger.makeSockaddr(for: "fe80::1", port: 48_000))
        var expected = destination
        var source = expected
        withUnsafeMutableBytes(of: &expected) { $0.storeBytes(of: UInt32(4), toByteOffset: 24, as: UInt32.self) }
        withUnsafeMutableBytes(of: &source) { $0.storeBytes(of: UInt32(5), toByteOffset: 24, as: UInt32.self) }
        #expect(!RtpAudioReceiver.isExpectedPeer(source, length: length, expected: expected, expectedLength: length))
        #expect(RtpAudioReceiver.isExpectedPeer(expected, length: length, expected: expected, expectedLength: length))
        let (ipv4, ipv4Length, _) = try #require(UdpPinger.makeSockaddr(for: "192.0.2.1", port: 48_000))
        #expect(!RtpAudioReceiver.isExpectedPeer(ipv4, length: ipv4Length, expected: expected, expectedLength: length))
    }

    private func feedAudioQueue(_ queue: RtpAudioQueue, sequences: [UInt16]) {
        for sequence in sequences {
            var packet: [UInt8] = []
            queue.appendRtpHeader(&packet, header: 0x80, packetType: RtpAudioQueue.payloadTypeAudio,
                                  seq: sequence, timestamp: UInt32(sequence) * 5, ssrc: 0)
            packet += [UInt8](repeating: 0, count: 16)
            let rtp = RtpAudioQueue.RtpHeader(header: 0x80, packetType: RtpAudioQueue.payloadTypeAudio,
                                            sequenceNumber: sequence, timestamp: UInt32(sequence) * 5, ssrc: 0)
            _ = queue.addPacket(packet, rtp: rtp)
            while queue.getQueuedPacket() != nil {}
        }
    }

    @Test func oneDistantAudioPacketCannotPoisonTheReceiveCursor() {
        let queue = audioQueue()
        feedAudioQueue(queue, sequences: Array(0...7))
        #expect(queue.nextRtpSequenceNumber == 8)
        feedAudioQueue(queue, sequences: [20_000])
        #expect(queue.nextRtpSequenceNumber == 8)
        #expect(queue.blocks.isEmpty)
        feedAudioQueue(queue, sequences: [8])
        #expect(queue.nextRtpSequenceNumber == 9)
        #expect(queue.pendingSequenceRestart == nil)
    }

    @Test func consecutiveDataRecoversFromALargeLossButDuplicatesCannotConfirmIt() {
        let queue = audioQueue()
        feedAudioQueue(queue, sequences: Array(0...7))
        feedAudioQueue(queue, sequences: [20_000, 20_000])
        #expect(queue.nextRtpSequenceNumber == 8)
        feedAudioQueue(queue, sequences: [20_001, 20_002, 20_003, 20_004])
        #expect(queue.nextRtpSequenceNumber == 20_005)
    }

    @Test func audioSequenceAcceptsOrdinaryLossReorderAndWrap() {
        let queue = audioQueue()
        feedAudioQueue(queue, sequences: [65_528, 65_532, 65_534, 65_533, 65_535, 0, 1, 2, 3, 8])
        #expect(queue.nextRtpSequenceNumber == 9)
        let wrapAtStartup = audioQueue()
        feedAudioQueue(wrapAtStartup, sequences: [65_532, 0, 1, 2, 3])
        #expect(wrapAtStartup.nextRtpSequenceNumber == 4)
    }

    @Test func parityCannotEstablishOrAdvanceADistantAudioSequence() {
        let queue = audioQueue()
        var parity: [UInt8] = []
        queue.appendRtpHeader(&parity, header: 0x80, packetType: RtpAudioQueue.payloadTypeFec,
                              seq: 0, timestamp: 0, ssrc: 0)
        parity += [0, RtpAudioQueue.payloadTypeAudio, 0x4E, 0x20, 0, 1, 0x86, 0xA0, 0, 0, 0, 0]
        parity += [UInt8](repeating: 0, count: 16)
        let rtp = RtpAudioQueue.RtpHeader(header: 0x80, packetType: RtpAudioQueue.payloadTypeFec,
                                        sequenceNumber: 0, timestamp: 0, ssrc: 0)
        _ = queue.addPacket(parity, rtp: rtp)
        #expect(!queue.hasSequenceBaseline)
        feedAudioQueue(queue, sequences: Array(0...7))
        feedAudioQueue(queue, sequences: [19_999])
        _ = queue.addPacket(parity, rtp: rtp)
        #expect(queue.nextRtpSequenceNumber == 8)
        #expect(queue.blocks.isEmpty)
        feedAudioQueue(queue, sequences: [8])
        #expect(queue.nextRtpSequenceNumber == 9)
    }

    @Test func nearbyAudioParityStillRecoversAMissingDataPacket() {
        let queue = audioQueue()
        feedAudioQueue(queue, sequences: [0, 4, 6, 7])
        #expect(queue.nextRtpSequenceNumber == 5)
        var parity: [UInt8] = []
        queue.appendRtpHeader(&parity, header: 0x80, packetType: RtpAudioQueue.payloadTypeFec,
                              seq: 0, timestamp: 0, ssrc: 0)
        // Every data shard is zero, so the matching RS parity shard is zero too.
        parity += [0, RtpAudioQueue.payloadTypeAudio, 0, 4, 0, 0, 0, 20, 0, 0, 0, 0]
        parity += [UInt8](repeating: 0, count: 16)
        let rtp = RtpAudioQueue.RtpHeader(header: 0x80, packetType: RtpAudioQueue.payloadTypeFec,
                                        sequenceNumber: 0, timestamp: 0, ssrc: 0)
        _ = queue.addPacket(parity, rtp: rtp)
        while queue.getQueuedPacket() != nil {}
        #expect(queue.nextRtpSequenceNumber == 8)
        #expect(queue.stats.packetCountFecRecovered == 1)
    }

    // MARK: - RtpAudioQueue.isBefore16 (wrap-safe 16-bit sequence compare)
    //
    // Definition: isBefore16(x, y) == (x &- y) > 0x7FFF. "x is before y" within
    // half the 16-bit space, accounting for wraparound. The midpoint (exactly
    // 0x8000 apart) is the documented boundary.

    @Test func isBefore16SimpleOrdering() {
        #expect(RtpAudioQueue.isBefore16(0, 1))
        #expect(RtpAudioQueue.isBefore16(10, 20))
        #expect(!RtpAudioQueue.isBefore16(20, 10))
        #expect(!RtpAudioQueue.isBefore16(1, 0))
    }

    @Test func isBefore16EqualIsNotBefore() {
        // x &- x == 0, which is not > 0x7FFF.
        #expect(!RtpAudioQueue.isBefore16(0, 0))
        #expect(!RtpAudioQueue.isBefore16(0x1234, 0x1234))
        #expect(!RtpAudioQueue.isBefore16(0xFFFF, 0xFFFF))
    }

    @Test func isBefore16WrapsAround() {
        // The whole point: 0xFFFF is "before" 0x0001 (it precedes it on the
        // wire despite the larger raw value).
        #expect(RtpAudioQueue.isBefore16(0xFFFF, 0x0001))
        #expect(RtpAudioQueue.isBefore16(0xFFFE, 0x0000))
        // And the reverse is "after".
        #expect(!RtpAudioQueue.isBefore16(0x0001, 0xFFFF))
        #expect(!RtpAudioQueue.isBefore16(0x0000, 0xFFFE))
    }

    @Test func isBefore16HalfSpaceBoundary() {
        // Distance exactly 0x8000: (0 &- 0x8000) == 0x8000 > 0x7FFF -> before.
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x8000))
        // (0 &- 0x7FFF) == 0x8001 > 0x7FFF -> 0 IS before 0x7FFF (it's the
        // farther-back wrap distance that counts).
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x7FFF))
        // The exact NOT-before boundary: (0x7FFF &- 0) == 0x7FFF, NOT > 0x7FFF.
        #expect(!RtpAudioQueue.isBefore16(0x7FFF, 0x0000))
        // (0x7FFF &- 0xFFFF) = 0x8000 > 0x7FFF -> before.
        #expect(RtpAudioQueue.isBefore16(0x7FFF, 0xFFFF))
    }

    @Test func isBefore16IsAntisymmetricForDistinctNonAntipodal() {
        // For any pair NOT exactly 0x8000 apart, isBefore16(x,y) and
        // isBefore16(y,x) disagree (one true, one false).
        let pairs: [(UInt16, UInt16)] = [
            (1, 2), (100, 50), (0xFFFF, 3), (0x0005, 0xFFF0), (42, 0x9000)
        ]
        for (x, y) in pairs where (x &- y) != 0x8000 && x != y {
            #expect(RtpAudioQueue.isBefore16(x, y) != RtpAudioQueue.isBefore16(y, x))
        }
    }

    @Test func isBefore16AntipodalPairIsSymmetric() {
        // When exactly 0x8000 apart, BOTH directions are "before" (both
        // distances equal 0x8000 > 0x7FFF). A documented degenerate case.
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x8000))
        #expect(RtpAudioQueue.isBefore16(0x8000, 0x0000))
    }

    // MARK: - VideoDepacketizer.isIdrFrameStart (untrusted Annex-B sniff)
    //
    // Sunshine's IDRs carry SPS (H.264) or VPS (HEVC) after optional AUD/SEI NALs.
    // Malformed prefixes must not open the key-frame recovery gate.

    @Test func isIdrFrameStartH264AcceptsSpsAfter4ByteStart() {
        // 00 00 00 01 | 0x67 (NAL header: type = 0x67 & 0x1F = 7 = SPS).
        #expect(VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x67], hevc: false))
        // Trailing bytes after the header are irrelevant to the sniff.
        #expect(VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x67, 0xAA, 0xBB], hevc: false))
    }

    @Test func isIdrFrameStartH264RejectsNonSpsNal() {
        // PPS (type 8) is NOT a frame start under this rule.
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x68], hevc: false))
        // IDR slice (type 5) - also not the SPS-led frame-start marker.
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x65], hevc: false))
        // Non-IDR slice (type 1).
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x41], hevc: false))
    }

    @Test func isIdrFrameStartHevcAcceptsVpsAfter4ByteStart() {
        // HEVC NAL header: type = (byte >> 1) & 0x3F. VPS = 32 -> byte 0x40.
        #expect(VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x40, 0x01], hevc: true))
        // SPS (type 33 -> 0x42) is NOT the VPS-led frame start.
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x42, 0x01], hevc: true))
        // An H.264 SPS byte (0x67) decoded as HEVC: (0x67 >> 1) & 0x3F = 51, not VPS.
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1, 0x67], hevc: true))
    }

    @Test func isIdrFrameStartAccepts3ByteStartCode() {
        // Moonlight's getAnnexBStartSequence takes either start-code length.
        #expect(VideoDepacketizer.isIdrFrameStart([0, 0, 1, 0x67, 0x42], hevc: false))
        #expect(VideoDepacketizer.isIdrFrameStart([0, 0, 1, 0x40, 0x01], hevc: true))
    }

    @Test func isIdrFrameStartSkipsAudAndSeiBeforeParameterSets() {
        let h264: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x06, 0x80, 0, 0, 0, 1, 0x67, 0x42]
        #expect(VideoDepacketizer.isIdrFrameStart(h264, hevc: false))
        let hevc: [UInt8] = [0, 0, 0, 1, 0x46, 0x01, 0x50, 0, 0, 1, 0x4E, 0x01, 0x80, 0, 0, 0, 1, 0x40, 0x01]
        #expect(VideoDepacketizer.isIdrFrameStart(hevc, hevc: true))
    }

    @Test func isIdrFrameStartNeedsParameterSetsAfterMetadata() {
        // SEI before an ordinary slice is not a key frame.
        let seiThenSlice: [UInt8] = [0, 0, 0, 1, 0x06, 0x80, 0, 0, 1, 0x41, 0x9A]
        #expect(!VideoDepacketizer.isIdrFrameStart(seiThenSlice, hevc: false))
        // Only HEVC's prefix SEI (39) is skipped, as in Moonlight; a suffix SEI (40) ends the scan.
        let suffixSeiThenVps: [UInt8] = [0, 0, 0, 1, 0x50, 0x01, 0x80, 0, 0, 0, 1, 0x40, 0x01]
        #expect(!VideoDepacketizer.isIdrFrameStart(suffixSeiThenVps, hevc: true))
    }

    @Test func isIdrFrameStartMalformedInputsReturnFalseNoCrash() {
        // Truncated prefixes must not read beyond the payload.
        #expect(!VideoDepacketizer.isIdrFrameStart([], hevc: false))
        #expect(!VideoDepacketizer.isIdrFrameStart([], hevc: true))
        #expect(!VideoDepacketizer.isIdrFrameStart([0], hevc: false))
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 1], hevc: false))   // lone 4-byte start code, no NAL byte
        // A truncated/garbage prefix that is not the 4-byte start code.
        #expect(!VideoDepacketizer.isIdrFrameStart([0xFF, 0xFF, 0xFF, 0xFF, 0x67], hevc: false))
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 0, 0, 0x67], hevc: false))   // 00 00 00 00 - not a start code
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 1, 0, 0x67], hevc: false))   // 4th byte not 1
    }

    // MARK: - VideoDepacketizer.splitAnnexBParamSets (IDR AU NAL routing)
    //
    // Splits one Annex-B access unit into typed DecodeBuffers. VPS/SPS/PPS NALs
    // (H.264: 7/8; HEVC: 32/33/34) each become their own buffer; every other NAL
    // accumulates into ONE picData buffer in arrival order. A trailing picData
    // buffer is ALWAYS appended (even if empty). With no start code at all, the
    // whole AU comes back as a single picData buffer. Each emitted NAL retains
    // its start code (the decoder strips it later).

    /// A fresh depacketizer for the given codec. The init is side-effect free
    /// (no queue/clock); splitAnnexBParamSets only reads the codec flag.
    private func depacketizer(hevc: Bool) -> VideoDepacketizer {
        let format = hevc ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264
        return VideoDepacketizer(delegate: NoopDepacketizerDelegate(),
                                 negotiatedVideoFormat: format,
                                 colorSpace: 0)
    }

    /// Sunshine's short header (0x01) is 8 bytes; any other first byte takes its 7.1.431 length, 24.
    /// A payload shorter than its own header is refused.
    @Test func frameHeaderLengthFollowsSunshinesVersion() {
        func headerSize(_ payload: [UInt8]) -> Int {
            payload.withUnsafeBytes { depacketizer(hevc: true).parseFrameHeader($0, frameIndex: 1) }
        }
        #expect(headerSize([0x01, 0, 0, 1] + [UInt8](repeating: 0, count: 60)) == 8)
        #expect(headerSize([0x81, 0, 0, 1] + [UInt8](repeating: 0, count: 60)) == 24)
        #expect(headerSize([0x01, 0, 0]) == -1)
        #expect(headerSize([0x01, 0, 0, 1, 0, 0, 0]) == -1)
        #expect(headerSize([0x81, 0, 0, 1] + [UInt8](repeating: 0, count: 19)) == -1)
    }

    @Test func splitAnnexBNoStartCodeIsSinglePicData() {
        let au = Data([0x01, 0x02, 0x03, 0x04])
        let out = depacketizer(hevc: false).splitAnnexBParamSets(au)
        #expect(out.count == 1)
        #expect(out[0].kind == .picData)
        #expect(out[0].data == au)
    }

    @Test func splitAnnexBH264RoutesSpsPpsAndKeepsStartCodes() {
        // SPS (00 00 00 01 67 ..), PPS (00 00 01 68 ..), then an IDR slice
        // (00 00 00 01 65 ..) which is picData.
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x10, 0x20]
        let pps: [UInt8] = [0, 0, 1, 0x68, 0x30]
        let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0xDE, 0xAD, 0xBE, 0xEF]
        let au = Data(sps + pps + idr)
        let out = depacketizer(hevc: false).splitAnnexBParamSets(au)

        // Output order is sps, pps, then the single picData (no vps for H.264).
        #expect(out.count == 3)
        #expect(out[0].kind == .sps)
        #expect(out[0].data == Data(sps))
        #expect(out[1].kind == .pps)
        #expect(out[1].data == Data(pps))
        #expect(out[2].kind == .picData)
        #expect(out[2].data == Data(idr))   // start code retained
    }

    @Test func splitAnnexBAlwaysEmitsTrailingPicDataEvenWhenEmpty() {
        // SPS + PPS only: no slice NAL, but a trailing (empty) picData buffer is
        // still appended.
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x11]
        let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0x22]
        let out = depacketizer(hevc: false).splitAnnexBParamSets(Data(sps + pps))
        #expect(out.count == 3)
        #expect(out[0].kind == .sps)
        #expect(out[1].kind == .pps)
        #expect(out[2].kind == .picData)
        #expect(out[2].data.isEmpty)
    }

    @Test func splitAnnexBHevcRoutesVpsSpsPps() {
        // HEVC: VPS=32 (0x40), SPS=33 (0x42), PPS=34 (0x44); header byte is the
        // first byte after the start code, type = (byte >> 1) & 0x3F.
        let vps: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0x0A]
        let sps: [UInt8] = [0, 0, 0, 1, 0x42, 0x01, 0x0B]
        let pps: [UInt8] = [0, 0, 0, 1, 0x44, 0x01, 0x0C]
        let slice: [UInt8] = [0, 0, 0, 1, 0x26, 0x01, 0x0D]   // type 19 (IDR_W_RADL) -> picData
        let out = depacketizer(hevc: true).splitAnnexBParamSets(Data(vps + sps + pps + slice))
        #expect(out.count == 4)
        #expect(out[0].kind == .vps)
        #expect(out[0].data == Data(vps))
        #expect(out[1].kind == .sps)
        #expect(out[1].data == Data(sps))
        #expect(out[2].kind == .pps)
        #expect(out[2].data == Data(pps))
        #expect(out[3].kind == .picData)
        #expect(out[3].data == Data(slice))
    }

    @Test func splitAnnexBMultiplePicDataNalsConcatInOrder() {
        // Two non-param NALs concatenate, in arrival order, into the one picData.
        let a: [UInt8] = [0, 0, 0, 1, 0x61, 0xAA]   // H.264 type 1 (non-IDR slice)
        let b: [UInt8] = [0, 0, 1, 0x06, 0xBB]      // H.264 type 6 (SEI)
        let out = depacketizer(hevc: false).splitAnnexBParamSets(Data(a + b))
        #expect(out.count == 1)
        #expect(out[0].kind == .picData)
        #expect(out[0].data == Data(a + b))
    }

    @Test func splitAnnexBMalformedInputsDoNotCrash() {
        let dp = depacketizer(hevc: false)
        // Empty AU: no start codes -> single picData wrapping the empty AU.
        let empty = dp.splitAnnexBParamSets(Data())
        #expect(empty.count == 1)
        #expect(empty[0].kind == .picData)
        #expect(empty[0].data.isEmpty)

        // A lone 4-byte start code with no NAL header byte: the start is found
        // but headerIndex (4) is not < end (4), so the NAL is skipped; the
        // unconditional trailing picData is the only buffer.
        let loneStart = dp.splitAnnexBParamSets(Data([0, 0, 0, 1]))
        #expect(loneStart.count == 1)
        #expect(loneStart[0].kind == .picData)
        #expect(loneStart[0].data.isEmpty)

        // Truncated: start code immediately followed by EOF after one header byte
        // still classifies (SPS here) without reading past the buffer.
        let truncSps = dp.splitAnnexBParamSets(Data([0, 0, 0, 1, 0x67]))
        #expect(truncSps.count == 2)
        #expect(truncSps[0].kind == .sps)
        #expect(truncSps[1].kind == .picData)
        #expect(truncSps[1].data.isEmpty)

        // Two-byte and one-byte fragments (below the scan window) -> single
        // picData, no crash.
        #expect(dp.splitAnnexBParamSets(Data([0, 0]))[0].kind == .picData)
        #expect(dp.splitAnnexBParamSets(Data([0x00]))[0].kind == .picData)
    }

    // MARK: - VideoDepacketizer frame-index wrap (host-controlled index)

    /// A host can walk the frame index across zero in forward jumps under half the
    /// space; the gap log for frame 0 after 0xFFFFFFF0 must not trap. Every frame
    /// waits at the recovery gate (no IDR yet), so each one is counted there.
    @Test func frameIndexWrappingPastZeroDoesNotTrap() {
        let dp = depacketizer(hevc: true)
        let before = TelemetryCounters.shared.recoveryWaitDropTotal.value
        let frames: [UInt32] = [0x7FFF_FFFF, 0xFFFF_FFF0, 0]
        for (spi, frame) in frames.enumerated() {
            dp.process(VideoDepacketizer.CompletedPacket(
                frameIndex: frame, flags: 0x07,   // PIC_DATA | EOF | SOF: a one-packet frame
                extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
                streamPacketIndex: UInt32(spi) << 8, rtpTimestamp: 0,
                presentationTimeUs: UInt64(spi + 1) * 1_000, receiveTimeUs: UInt64(spi + 1) * 1_000,
                payload: []))
        }
        #expect(TelemetryCounters.shared.recoveryWaitDropTotal.value &- before >= UInt64(frames.count))
    }

    // MARK: - RtpAudioQueue.padShard (pad/clamp a byte buffer to a fixed size)

    /// A fresh audio queue. The init only sets a couple of fields - no queue or
    /// clock - so it is safe to construct for the pure byte-shape helpers.
    private func audioQueue() -> RtpAudioQueue {
        RtpAudioQueue(audioPacketDuration: 5)
    }

    /// Audio FEC is on from the first packet: Sunshine's 7.1.431 always passed moonlight's 7.1.415 gate.
    @Test func audioFecStartsEnabled() {
        #expect(!audioQueue().incompatibleServer)
    }

    @Test func padShortBufferZeroPadsToSize() {
        let out = audioQueue().padShard([1, 2, 3], to: 6)
        #expect(out == [1, 2, 3, 0, 0, 0])
    }

    @Test func padExactSizeIsUnchanged() {
        let bytes: [UInt8] = [9, 8, 7, 6]
        #expect(audioQueue().padShard(bytes, to: 4) == bytes)
    }

    @Test func padOversizeBufferIsTruncated() {
        #expect(audioQueue().padShard([1, 2, 3, 4, 5], to: 3) == [1, 2, 3])
    }

    @Test func padEmptyBufferBecomesAllZeros() {
        #expect(audioQueue().padShard([], to: 4) == [0, 0, 0, 0])
        // Pad-to-zero of an empty buffer stays empty.
        #expect(audioQueue().padShard([], to: 0).isEmpty)
    }

    // MARK: - RtpAudioQueue.appendRtpHeader (12-byte big-endian RTP header)

    @Test func appendRtpHeaderWritesBigEndianWireOrder() {
        var out: [UInt8] = []
        audioQueue().appendRtpHeader(&out,
                                     header: 0x80, packetType: 97,
                                     seq: 0x1234, timestamp: 0xDEADBEEF, ssrc: 0x01020304)
        // header, packetType, seq (BE), timestamp (BE), ssrc (BE) = 12 bytes.
        #expect(out == [0x80, 97,
                        0x12, 0x34,
                        0xDE, 0xAD, 0xBE, 0xEF,
                        0x01, 0x02, 0x03, 0x04])
    }

    @Test func appendRtpHeaderAppendsToExistingBytes() {
        var out: [UInt8] = [0xAA, 0xBB]
        audioQueue().appendRtpHeader(&out,
                                     header: 0x00, packetType: 0,
                                     seq: 0, timestamp: 0, ssrc: 0)
        #expect(out.count == 14)
        #expect(Array(out.prefix(2)) == [0xAA, 0xBB])
        #expect(Array(out.suffix(12)) == [UInt8](repeating: 0, count: 12))
    }
}

/// Inert delegate so a VideoDepacketizer can be constructed for the pure
/// Annex-B split helper without wiring a live receive loop.
private final class NoopDepacketizerDelegate: VideoDepacketizerDelegate {
    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {}
    func depacketizerDetectedFrameLoss(from: Int, to: Int) {}
    func depacketizerNeedsIdr() {}
    func depacketizerReceivedKeyFrame(frameNumber: Int) {}
}
