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
import Testing
@testable import Glimmer

struct ParserHelperTests {

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
    // Definition (VideoDepacketizer.swift): true iff payload.count >= 5 AND the
    // first four bytes are the 4-byte start code 00 00 00 01 (NV's frame-start
    // marker; a 3-byte start code means mid-frame), AND the NAL header at [4] is
    // SPS for H.264 (type 7, byte & 0x1F == 7) or VPS for HEVC (type 32,
    // (byte >> 1) & 0x3F == 32). Everything else - including malformed/truncated
    // input - returns false WITHOUT crashing. This is the highest-value surface
    // (untrusted host bytes), so the edge cases are fuzz-shaped.

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

    @Test func isIdrFrameStartRejects3ByteStartCode() {
        // 3-byte start code 00 00 01 means MID-frame, never a frame start: with
        // payload[2] == 1 the payload[3] == 1 check fails (payload[3] is the NAL
        // header byte, here 0x67).
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 1, 0x67, 0x00], hevc: false))
        #expect(!VideoDepacketizer.isIdrFrameStart([0, 0, 1, 0x40, 0x01], hevc: true))
    }

    @Test func isIdrFrameStartMalformedInputsReturnFalseNoCrash() {
        // Empty and sub-minimum lengths (< 5 bytes) -> false, no out-of-bounds.
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
                                 appVersionQuad: [7, 1, 450, 0],
                                 colorSpace: 0)
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

    // MARK: - RtpAudioQueue.padShard (pad/clamp a byte buffer to a fixed size)

    /// A fresh audio queue. The init only sets a couple of fields - no queue or
    /// clock - so it is safe to construct for the pure byte-shape helpers.
    private func audioQueue() -> RtpAudioQueue {
        RtpAudioQueue(appVersionQuad: [7, 1, 450, 0], audioPacketDuration: 5)
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
        #expect(audioQueue().padShard([], to: 0) == [])
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
