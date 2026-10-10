//
//  RtspHandshakeParsingTests.swift
//
//  What the RTSP handshake reads out of Sunshine's canned SETUP and DESCRIBE replies: ports,
//  the session token, the ping payload and the negotiated codec, plus the malformed replies refused.
//

import Foundation
import Testing
@testable import Glimmer

struct RtspHandshakeParsingTests {

    private static func client(formats: Int32 = StreamProtocol.VIDEO_FORMAT_H264, serverCodecMode: Int32 = 0) -> RtspClient {
        let key = [UInt8](repeating: 7, count: 16)
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20_000, packetSize: 1392,
            streamingRemotely: 0, audioConfiguration: 0, supportedVideoFormats: formats,
            clientRefreshRateX100: 6000, colorSpace: 0, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: key, remoteInputAesIv: key)
        return RtspClient(
            host: "192.0.2.10", rtspPort: 48010, rtspTargetUrl: "rtsp://192.0.2.10:48010",
            urlAddr: "192.0.2.10", urlSafeAddr: "192.0.2.10", addrFamilyToken: "IPv4",
            config: config, serverCodecModeRaw: serverCodecMode)
    }

    private static func reply(_ headers: String, payload: String = "") throws -> RtspMessage {
        try #require(RtspMessage.parseResponse(Data("RTSP/1.0 200 OK\r\n\(headers)\r\n\r\n\(payload)".utf8)))
    }

    private static func emptyResult() -> RtspHandshakeResult {
        RtspHandshakeResult(
            audioPort: 0, videoPort: 0, controlPort: 0, controlConnectData: 0, sessionId: "",
            negotiatedVideoFormat: 0, encryptionFeaturesSupported: 0, encryptionFeaturesEnabled: 0,
            referenceFrameInvalidationSupported: false)
    }

    // MARK: - SETUP

    @Test func setupCarriesTheSessionOnlyOnceSunshineHasGivenOne() throws {
        let rtsp = Self.client()
        let first = rtsp.makeSetup("streamid=audio/0/0")
        #expect(first.headerValue("Session") == nil)
        #expect(first.headerValue("Transport") == "unicast;X-GS-ClientPort=50000-50001")
        #expect(first.headerValue("CSeq") == "1")

        try rtsp.captureSession(from: Self.reply("Session: DEADBEEF;timeout = 90"), step: "SETUP audio")
        let second = rtsp.makeSetup("streamid=video/0/0")
        #expect(second.headerValue("Session") == "DEADBEEF")
        #expect(second.headerValue("CSeq") == "2")
        #expect(String(data: second.serialize(), encoding: .utf8)?
            .hasPrefix("SETUP streamid=video/0/0 RTSP/1.0\r\nCSeq: 2\r\n") == true)
    }

    @Test(arguments: ["X-Other: 1", "Session:  ;timeout=90", "Session: "])
    func aMissingOrBlankSessionIsRefused(headers: String) throws {
        let rtsp = Self.client()
        let response = try Self.reply(headers)
        #expect(throws: RtspError.self) { try rtsp.captureSession(from: response, step: "SETUP audio") }
        #expect(!rtsp.hasSessionId)
        #expect(rtsp.makeSetup("streamid=video/0/0").headerValue("Session") == nil)
    }

    @Test func serverPortIsReadFromTheTransportHeader() throws {
        let rtsp = Self.client()
        let audio = try Self.reply("Transport: unicast;server_port=48000-48001;source=192.0.2.10")
        #expect(rtsp.parsePort(audio) == 48000)
        #expect(rtsp.parsePort(try Self.reply("Transport: server_port=65535")) == 65535)
    }

    @Test(arguments: ["Transport: unicast", "Transport: server_port=0", "Transport: server_port=65536",
                      "Transport: server_port=-1", "X-Transport: server_port=48000"])
    func unusableServerPortsAreRejected(headers: String) throws {
        #expect(Self.client().parsePort(try Self.reply(headers)) == nil)
    }

    @Test(arguments: ["X-SS-Ping-Payload: 0123456789ABCDE", "X-SS-Ping-Payload: 0123456789ABCDEF0", "CSeq: 1"])
    func aPingPayloadThatIsNotSixteenCharsIsDropped(headers: String) throws {
        #expect(Self.client().parsePingPayload(try Self.reply(headers)).isEmpty)
    }

    @Test func controlConnectDataReadsLikeStrtoul() {
        let rtsp = Self.client()
        #expect(rtsp.parseUInt32Auto(" 0x1A2B ") == 0x1A2B)
        #expect(rtsp.parseUInt32Auto("0XFF") == 0xFF)
        #expect(rtsp.parseUInt32Auto("12345") == 12345)
        #expect(rtsp.parseUInt32Auto("0xZZ") == 0)
        #expect(rtsp.parseUInt32Auto("abc") == 0)
        #expect(rtsp.parseUInt32Auto("4294967296") == 0)
    }

    @Test func aNonOKStepThrowsWithItsStatus() throws {
        let rtsp = Self.client()
        try rtsp.check(try Self.reply("CSeq: 1"), step: "OPTIONS")
        let refused = try #require(RtspMessage.parseResponse(Data("RTSP/1.0 404 Not Found\r\n\r\n".utf8)))
        let error = #expect(throws: RtspError.self) { try rtsp.check(refused, step: "DESCRIBE") }
        #expect(error?.description == "RTSP DESCRIBE returned 404")
    }

    // MARK: - DESCRIBE negotiation

    struct Offer: Sendable, CustomTestStringConvertible {
        let sdp: String
        let client: Int32
        let server: Int32
        let expected: Int32
        let codec: String
        var testDescription: String { "\(codec) \(String(expected, radix: 16))" }
    }

    static let av1Sdp = "a=rtpmap:98 AV1/90000\r\n"
    static let hevcSdp = "a=fmtp:96 sprop-parameter-sets=AAAAAUAB\r\n"
    static let h264Sdp = "a=fmtp:96 packetization-mode=1\r\n"
    static let allFormats: Int32 = StreamProtocol.VIDEO_FORMAT_MASK_H264 | StreamProtocol.VIDEO_FORMAT_MASK_H265
        | StreamProtocol.VIDEO_FORMAT_MASK_AV1

    static let offers: [Offer] = [
        Offer(sdp: av1Sdp, client: allFormats, server: StreamProtocol.SCM_AV1_MAIN10,
              expected: StreamProtocol.VIDEO_FORMAT_AV1_MAIN10, codec: "AV1"),
        Offer(sdp: av1Sdp, client: allFormats, server: StreamProtocol.SCM_AV1_HIGH10_444,
              expected: StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444, codec: "AV1"),
        Offer(sdp: av1Sdp, client: allFormats, server: 0,
              expected: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8, codec: "AV1"),
        // A client without AV1 ignores the AV1 offer and takes HEVC.
        Offer(sdp: av1Sdp + hevcSdp, client: StreamProtocol.VIDEO_FORMAT_MASK_H265,
              server: StreamProtocol.SCM_HEVC_MAIN10, expected: StreamProtocol.VIDEO_FORMAT_H265_MAIN10, codec: "HEVC"),
        Offer(sdp: hevcSdp, client: StreamProtocol.VIDEO_FORMAT_H265, server: StreamProtocol.SCM_HEVC_MAIN10,
              expected: StreamProtocol.VIDEO_FORMAT_H265, codec: "HEVC"),
        Offer(sdp: hevcSdp, client: allFormats, server: StreamProtocol.SCM_HEVC_REXT8_444,
              expected: StreamProtocol.VIDEO_FORMAT_H265_REXT8_444, codec: "HEVC"),
        Offer(sdp: h264Sdp, client: allFormats, server: StreamProtocol.SCM_H264_HIGH8_444,
              expected: StreamProtocol.VIDEO_FORMAT_H264_HIGH8_444, codec: "H264"),
        Offer(sdp: h264Sdp, client: allFormats, server: StreamProtocol.SCM_HEVC_MAIN10,
              expected: StreamProtocol.VIDEO_FORMAT_H264, codec: "H264")
    ]

    @Test(arguments: offers)
    func negotiatedCodecFollowsTheOfferAndBothSidesSupport(offer: Offer) {
        let rtsp = Self.client(formats: offer.client, serverCodecMode: offer.server)
        var result = Self.emptyResult()
        rtsp.negotiate(sdp: offer.sdp, into: &result)
        #expect(result.negotiatedVideoFormat == offer.expected)
        #expect(rtsp.codecName(result.negotiatedVideoFormat) == offer.codec)
    }

    @Test func describeAttributesReachTheHandshakeResult() {
        let sdp = Self.h264Sdp + "a=x-nv-video[0].refPicInvalidation:1 \r\n"
            + "a=x-ss-general.encryptionSupported:7 \r\na=x-ss-general.featureFlags:0x3 \r\n"
        var result = Self.emptyResult()
        Self.client().negotiate(sdp: sdp, into: &result)
        #expect(result.referenceFrameInvalidationSupported)
        #expect(result.encryptionFeaturesSupported == 7)
        #expect(result.featureFlags == 3)

        var bare = Self.emptyResult()
        bare.featureFlags = 9
        Self.client().negotiate(sdp: Self.h264Sdp, into: &bare)
        #expect(!bare.referenceFrameInvalidationSupported)
        #expect(bare.encryptionFeaturesSupported == 0)
        #expect(bare.featureFlags == 0)
    }

    @Test func errorsDescribeWhatFailed() {
        #expect(RtspError.connectTimeout(48010).description.contains("48010"))
        #expect(RtspError.responseTimeout(10).description == "no RTSP response within 10 s")
        #expect(RtspError.responseTooLarge(262_144).description.contains("262144"))
        #expect(RtspError.badResponse("SETUP missing Session").description.hasSuffix("SETUP missing Session"))
    }
}
