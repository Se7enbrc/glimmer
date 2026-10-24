// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import Foundation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

struct StreamVideoTests {
    @Test(arguments: [false, true], [false, true])
    func hardwareProbeKeepsFallbacksWithoutInventingChroma(hevc: Bool, av1: Bool) {
        let formats = VideoFormats.probeHardwareSupport { codec in
            switch codec {
            case kCMVideoCodecType_HEVC: hevc
            case kCMVideoCodecType_AV1: av1
            default: codec == kCMVideoCodecType_H264
            }
        }
        #expect(formats.contains(.h264))
        #expect(formats.contains(.hevc) == hevc)
        #expect(formats.contains(.hevcMain10) == hevc)
        #expect(formats.contains(.av1) == av1)
        #expect(formats.contains(.av1Main10) == av1)
        #expect(formats.isDisjoint(with: [.h264YUV444, .hevcRext8_444, .hevcRext10_444,
                                     .av1High8_444, .av1High10_444]))
    }

    @Test func missingHardwareDoesNotAdvertiseSoftwareFallback() {
        #expect(VideoFormats.probeHardwareSupport { _ in false }.isEmpty)
    }

    @Test(arguments: [Double.nan, .infinity, -1, 0, 1, 2, 4])
    func configurationOffersTenBitOnlyForHDRDisplays(headroom: Double) {
        let format = StreamFormat(width: 1920, height: 1080, fps: 60)
        let hardware: VideoFormats = [.h264, .hevc, .hevcMain10, .av1, .av1Main10]
        let request = format.configuration(potentialEDRHeadroom: headroom, hardwareFormats: hardware).request
        let hdr = headroom.isFinite && headroom > 1
        #expect(request.videoFormats.contains(.hevc))
        #expect(request.videoFormats.contains(.av1))
        #expect(request.videoFormats.contains(.h264))
        #expect(request.videoFormats.contains(.hevcMain10) == hdr)
        #expect(request.videoFormats.contains(.av1Main10) == hdr)
        #expect(request.width == 1920 && request.height == 1080 && request.fps == 60)
        #expect(request.bitrateKbps == StreamProfile.bitrateKbps)
        #expect(request.audio == .stereo)
        #expect(request.colorSpace == .rec709)
    }
}

extension StreamVideoTests {
    struct Offer: Sendable {
        let hardware: VideoFormats
        let headroom: Double
        let sdp: String
        let server: Int32
        let expected: VideoFormats
    }

    static let offers: [Offer] = [
        Offer(hardware: [.h264, .hevc, .hevcMain10, .av1, .av1Main10], headroom: 2,
              sdp: "AV1/90000", server: StreamProtocol.SCM_AV1_MAIN10, expected: .av1Main10),
        Offer(hardware: [.h264, .hevc, .hevcMain10, .av1, .av1Main10], headroom: 1,
              sdp: "AV1/90000", server: StreamProtocol.SCM_AV1_MAIN10, expected: .av1),
        Offer(hardware: [.h264, .hevc, .hevcMain10], headroom: 2,
              sdp: "AV1/90000\nsprop-parameter-sets=AAAAAU", server: StreamProtocol.SCM_HEVC_MAIN10,
              expected: .hevcMain10),
        Offer(hardware: [.h264, .hevc, .hevcMain10, .av1, .av1Main10], headroom: 2,
              sdp: "sprop-parameter-sets=AAAAAU", server: StreamProtocol.SCM_HEVC_MAIN10, expected: .hevcMain10),
        Offer(hardware: [.h264, .hevc, .hevcMain10], headroom: 2,
              sdp: "sprop-parameter-sets=AAAAAU", server: StreamProtocol.SCM_HEVC, expected: .hevc),
        Offer(hardware: [.h264, .hevc, .hevcMain10], headroom: 1,
              sdp: "sprop-parameter-sets=AAAAAU", server: StreamProtocol.SCM_HEVC_MAIN10, expected: .hevc),
        Offer(hardware: .h264, headroom: 2,
              sdp: "AV1/90000\nsprop-parameter-sets=AAAAAU", server: StreamProtocol.SCM_HEVC_MAIN10,
              expected: .h264),
        Offer(hardware: [.h264, .hevc, .hevcMain10, .av1, .av1Main10], headroom: 2,
              sdp: "H264/90000", server: 0, expected: .h264)
    ]

    @Test(arguments: offers)
    func negotiationUsesTheCommonHardwareFormatAndSignalsItsDepth(offer: Offer) throws {
        let request = StreamFormat(width: 1920, height: 1080, fps: 60)
            .configuration(potentialEDRHeadroom: offer.headroom, hardwareFormats: offer.hardware).request
        let config = BackendStreamConfig(width: 1920, height: 1080, fps: 60, bitrate: 20_000, packetSize: 1392,
            streamingRemotely: 0, audioConfiguration: request.audio.cValue,
            supportedVideoFormats: request.videoFormats.rawValue, clientRefreshRateX100: 6000,
            colorSpace: request.colorSpace.cValue, colorRange: request.colorRange.cValue, encryptionFlags: 0,
            remoteInputAesKey: [], remoteInputAesIv: [])
        let client = RtspClient(host: "192.0.2.10", rtspPort: 48010, rtspTargetUrl: "rtsp://192.0.2.10:48010",
            urlAddr: "192.0.2.10", urlSafeAddr: "192.0.2.10", addrFamilyToken: "IPv4",
            config: config, serverCodecModeRaw: offer.server)
        var result = RtspHandshakeResult(audioPort: 0, videoPort: 0, controlPort: 0, controlConnectData: 0,
            sessionId: "", negotiatedVideoFormat: 0, encryptionFeaturesSupported: 0, encryptionFeaturesEnabled: 0,
            referenceFrameInvalidationSupported: false)
        client.negotiate(sdp: offer.sdp, into: &result)
        #expect(result.negotiatedVideoFormat == offer.expected.rawValue)
        let payload = try #require(client.makeAnnounce(result).payload)
        let sdp = try #require(String(data: payload, encoding: .utf8))
        let tenBit = offer.expected == .hevcMain10 || offer.expected == .av1Main10
        #expect(sdp.contains("a=x-nv-video[0].dynamicRangeMode:\(tenBit ? 1 : 0) \r\n"))
        #expect(sdp.contains("a=x-ss-video[0].chromaSamplingType:0 \r\n"))
    }
}
