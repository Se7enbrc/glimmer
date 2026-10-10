//
//  rtsp.swift
//
//  RTSP responses from the PC, and the SDP reads RtspClient makes on DESCRIBE's body.
//

import Foundation

// RtspClient's file needs Network and CryptoKit; SdpCodec reads only these from it.
enum RtspClient {
    static let clientVersion = 14
}

enum RtspHandshakeResult {
    static let defaultOpusConfig = OpusConfig(
        sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 1,
        samplesPerFrame: 240, mapping: [0, 1])
}

enum VideoDecryptor {
    static func packetSize(_ configured: Int, encryptionFeaturesEnabled: UInt32) -> Int { configured }
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzRtsp(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    guard let response = RtspMessage.parseResponse(Data(bytes: data, count: size)) else { return 0 }
    _ = response.headerValue("CSeq")
    guard let payload = response.payload, let sdp = String(data: payload, encoding: .utf8) else { return 0 }
    _ = SdpScan.attributeUInt(sdp, "x-ss-general.encryptionSupported")
    _ = SdpScan.attributeUInt(sdp, "x-ss-general.featureFlags")
    for channels in [2, 6, 8] {
        let layout = SdpScan.audioLayout(sdp, channelCount: channels).opus
        precondition(layout.mapping.count == Int(layout.channelCount))
    }
    return 0
}
