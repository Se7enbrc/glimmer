//
//  SdpCodecTests.swift
//
//  Round-trip + known-answer coverage for the RTSP/SDP codec:
//   - RtspMessage.serialize / parseResponse (wire framing),
//   - SdpScan.attributeUInt (the loose attribute sniffing the C does), and
//   - SdpBuilder.build (a few load-bearing, format-derived attributes + the
//     exact header/attribute/tail framing, including the trailing-space quirks).
//

import Foundation
import Testing
@testable import Glimmer

struct SdpCodecTests {

    // MARK: - RtspMessage.serialize known-answer

    @Test func serializeRequestNoPayload() {
        var msg = RtspMessage(command: "OPTIONS", target: "rtsp://host")
        msg.headers.append(("CSeq", "1"))
        msg.headers.append(("X-GS-ClientVersion", "14"))
        let text = String(data: msg.serialize(), encoding: .utf8)
        #expect(text == "OPTIONS rtsp://host RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n")
    }

    @Test func serializeRequestWithPayload() {
        var msg = RtspMessage(command: "ANNOUNCE", target: "streamid=control")
        msg.headers.append(("CSeq", "3"))
        msg.payload = Data("v=0\r\n".utf8)
        let text = String(data: msg.serialize(), encoding: .utf8)
        // Payload is appended verbatim with NO trailing CRLF added by the serializer.
        #expect(text == "ANNOUNCE streamid=control RTSP/1.0\r\nCSeq: 3\r\n\r\nv=0\r\n")
    }

    // MARK: - parseResponse known-answer + round-trip

    @Test func parseResponseBasic() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: ABCDEF;timeout=30\r\n\r\n".utf8)
        let msg = try #require(RtspMessage.parseResponse(raw))
        #expect(msg.statusCode == 200)
        #expect(msg.statusString == "OK")
        #expect(msg.headerValue("CSeq") == "1")
        #expect(msg.headerValue("Session") == "ABCDEF;timeout=30")
        // Case-sensitive lookup (matches C strcmp).
        #expect(msg.headerValue("cseq") == nil)
    }

    @Test func parseResponseWithPayload() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let msg = try #require(RtspMessage.parseResponse(raw))
        #expect(msg.statusCode == 200)
        #expect(msg.payload == Data("hello".utf8))
    }

    @Test func parseResponseMultiWordStatusString() throws {
        let raw = Data("RTSP/1.0 404 Not Found\r\n\r\n".utf8)
        let msg = try #require(RtspMessage.parseResponse(raw))
        #expect(msg.statusCode == 404)
        #expect(msg.statusString == "Not Found")
    }

    @Test func serializeThenParseRoundTrip() throws {
        // Build a response-shaped message by hand, serialize... actually serialize
        // emits a REQUEST line, so round-trip the header semantics via a crafted
        // response string and confirm header values survive the colon-space split.
        let raw = Data("RTSP/1.0 200 OK\r\nA: 1\r\nB: two words\r\nC:nospace\r\n\r\n".utf8)
        let msg = try #require(RtspMessage.parseResponse(raw))
        #expect(msg.headerValue("A") == "1")
        #expect(msg.headerValue("B") == "two words")
        // Only a single leading space is stripped; "C:nospace" has none.
        #expect(msg.headerValue("C") == "nospace")
    }

    // MARK: - SdpScan.attributeUInt

    @Test func attributeUIntDecimal() {
        let sdp = "a=x-ss-general.featureFlags:163 \r\n"
        #expect(SdpScan.attributeUInt(sdp, "x-ss-general.featureFlags") == 163)
    }

    @Test func attributeUIntHex() {
        let sdp = "a=x-nv-video[0].something:0x1A \r\n"
        #expect(SdpScan.attributeUInt(sdp, "x-nv-video[0].something") == 0x1A)
    }

    @Test func attributeUIntMissingReturnsNil() {
        let sdp = "a=x-ss-general.featureFlags:163 \r\n"
        #expect(SdpScan.attributeUInt(sdp, "x-nope.absent") == nil)
    }

    @Test func attributeUIntStopsAtNonToken() {
        // Value followed by a trailing space then CRLF; only digits are consumed.
        let sdp = "a=x-nv-vqos[0].bw.minimumBitrateKbps:50000 \r\nnext"
        #expect(SdpScan.attributeUInt(sdp, "x-nv-vqos[0].bw.minimumBitrateKbps") == 50000)
    }

    @Test func scanContains() {
        #expect(SdpScan.contains("foo AV1/90000 bar", "AV1/90000"))
        #expect(!SdpScan.contains("foo bar", "AV1/90000"))
    }

    // MARK: - SdpBuilder.build framing + format-derived attributes

    private func makeConfig(
        width: Int32 = 1920, height: Int32 = 1080, fps: Int32 = 60,
        bitrate: Int32 = 20000, packetSize: Int32 = 1392,
        streamingRemotely: Int32 = 0, audioConfiguration: Int32 = 0x00010002,
        clientRefreshRateX100: Int32 = 6000,
        colorSpace: Int32 = 1, colorRange: Int32 = 0
    ) -> BackendStreamConfig {
        BackendStreamConfig(
            width: width, height: height, fps: fps, bitrate: bitrate,
            packetSize: packetSize, streamingRemotely: streamingRemotely,
            audioConfiguration: audioConfiguration,
            supportedVideoFormats: 0, clientRefreshRateX100: clientRefreshRateX100,
            colorSpace: colorSpace, colorRange: colorRange, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16),
            remoteInputAesIv: [UInt8](repeating: 0, count: 16))
    }

    private func builder(format: Int32, remote: Int32 = 0) -> SdpBuilder {
        SdpBuilder(
            config: makeConfig(streamingRemotely: remote),
            videoPort: 47998,
            urlSafeAddr: "10.0.0.5",
            addrFamilyToken: "IPv4",
            rtspClientVersion: 14,
            negotiatedVideoFormat: format,
            encryptionFeaturesEnabled: 0,
            appVersionQuad: [7, 1, 450, 0])
    }

    private func sdpString(_ b: SdpBuilder) -> String {
        String(data: b.build(), encoding: .utf8) ?? ""
    }

    @Test func buildHeaderAndTailFraming() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265))
        #expect(sdp.hasPrefix("v=0\r\n"))
        #expect(sdp.contains("o=android 0 14 IN IPv4 10.0.0.5\r\n"))
        #expect(sdp.contains("s=NVIDIA Streaming Client\r\n"))
        #expect(sdp.contains("t=0 0\r\n"))
        // "m=video <port>  \r\n" - TWO spaces before CRLF.
        #expect(sdp.hasSuffix("m=video 47998  \r\n"))
    }

    @Test func buildAttributeTrailingSpaceQuirk() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265))
        // "a=<name>:<value> \r\n" - trailing SPACE before CRLF is real.
        #expect(sdp.contains("a=x-nv-video[0].maxFPS:60 \r\n"))
        #expect(sdp.contains("a=x-nv-video[0].clientViewportWd:1920 \r\n"))
        #expect(sdp.contains("a=x-nv-video[0].clientViewportHt:1080 \r\n"))
    }

    @Test func buildHevcCodecBlock() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265))
        #expect(sdp.contains("a=x-nv-clientSupportHevc:1 \r\n"))
        #expect(sdp.contains("a=x-nv-vqos[0].bitStreamFormat:1 \r\n"))
        // H265 (not 10-bit, not 444) -> dynamicRangeMode 0, chroma 0.
        #expect(sdp.contains("a=x-nv-video[0].dynamicRangeMode:0 \r\n"))
        #expect(sdp.contains("a=x-ss-video[0].chromaSamplingType:0 \r\n"))
    }

    @Test func buildH264CodecBlock() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H264))
        #expect(sdp.contains("a=x-nv-clientSupportHevc:0 \r\n"))
        #expect(sdp.contains("a=x-nv-vqos[0].bitStreamFormat:0 \r\n"))
    }

    @Test func buildAv1CodecBlock() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8))
        #expect(sdp.contains("a=x-nv-vqos[0].bitStreamFormat:2 \r\n"))
    }

    @Test func build10BitSetsDynamicRange() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10))
        #expect(sdp.contains("a=x-nv-video[0].dynamicRangeMode:1 \r\n"))
    }

    @Test func build444SetsChroma() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265_REXT8_444))
        #expect(sdp.contains("a=x-ss-video[0].chromaSamplingType:1 \r\n"))
    }

    @Test func buildCscModeIsColorSpaceShiftedOrRange() {
        // colorSpace=1, colorRange=0 -> csc = (1<<1)|0 = 2.
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H264))
        #expect(sdp.contains("a=x-nv-video[0].encoderCscMode:2 \r\n"))
    }

    @Test func buildLocalQosTrafficType() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H264, remote: 0))
        #expect(sdp.contains("a=x-nv-vqos[0].qosTrafficType:5 \r\n"))
        #expect(sdp.contains("a=x-nv-aqos.qosTrafficType:4 \r\n"))
        // Local session advertises the full configured packet size (no clamp).
        #expect(sdp.contains("a=x-nv-video[0].packetSize:1392 \r\n"))
    }

    @Test func buildRemoteClampsPacketSizeAndQos() {
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H264, remote: 1))
        #expect(sdp.contains("a=x-nv-vqos[0].qosTrafficType:0 \r\n"))
        #expect(sdp.contains("a=x-nv-aqos.qosTrafficType:0 \r\n"))
        // Remote session clamps packetSize to 1024 (min(1392, 1024)).
        #expect(sdp.contains("a=x-nv-video[0].packetSize:1024 \r\n"))
    }

    @Test func buildMaxNumReferenceFramesDefaultsToOneWithoutRfi() {
        // serverSupportsRfi defaults false -> RFI inactive -> "1".
        let sdp = sdpString(builder(format: StreamProtocol.VIDEO_FORMAT_H265))
        #expect(sdp.contains("a=x-nv-video[0].maxNumReferenceFrames:1 \r\n"))
    }
}
