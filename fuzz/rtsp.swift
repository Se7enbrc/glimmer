// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  rtsp.swift
//
//  RTSP responses from the PC, and the SDP reads RtspClient makes on DESCRIBE's body.
//

import Foundation
@testable import GlimmerEngine

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
