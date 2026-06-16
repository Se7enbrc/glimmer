//
//  RtspClient+Handshake.swift
//
//  Handshake helpers (SETUP building, response checks, port/ping/session
//  parsing) and the SDP negotiation that sniffs the host's offered formats,
//  encryption features, and reference-frame-invalidation support. Split out of
//  RtspClient.swift to keep each unit focused; see that file for the client's
//  stored state and the encrypted-RTSP framing.
//

import Foundation
import Network

extension RtspClient {

    // MARK: - Handshake helpers

    func makeSetup(_ target: String) -> RtspMessage {
        var msg = makeRequest("SETUP", target)
        if hasSessionId {
            msg.headers.append(("Session", sessionIdString))
        }
        // q[0]>=6 Transport value (host ignores port but needs one).
        msg.headers.append(("Transport", "unicast;X-GS-ClientPort=50000-50001"))
        msg.headers.append(("If-Modified-Since", "Thu, 01 Jan 1970 00:00:00 GMT"))
        return msg
    }

    func check(_ response: RtspMessage, step: String) throws {
        Diag.info("RTSP \(step) → \(response.statusCode)", Self.logCategory)
        if response.statusCode != 200 {
            Diag.error("RTSP \(step) failed: \(response.statusCode)", Self.logCategory)
            throw RtspError.nonOK(step: step, code: response.statusCode)
        }
    }

    /// parseServerPortFromTransport: Transport header → "server_port=NNNN".
    func parsePort(_ response: RtspMessage) -> UInt16? {
        guard let transport = response.headerValue("Transport"),
              let prefix = transport.range(of: "server_port=") else { return nil }
        let rest = transport[prefix.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        guard let port = Int(digits), port > 0, port <= 65535 else { return nil }
        return UInt16(port)
    }

    /// Capture X-SS-Ping-Payload from a SETUP response (RtspConnection.c:1269).
    /// The header VALUE must be EXACTLY 16 chars and is memcpy'd verbatim as raw
    /// bytes — NO hex/base64 decode. If absent or not 16 chars, returns empty
    /// (→ legacy 4-byte "PING").
    func parsePingPayload(_ response: RtspMessage) -> [UInt8] {
        guard let value = response.headerValue("X-SS-Ping-Payload") else { return [] }
        // Latin-1 maps each char to one byte, matching the C memcpy of raw chars.
        let bytes = Array(value.unicodeScalars.map { UInt8($0.value & 0xFF) })
        guard bytes.count == 16 else { return [] }
        return bytes
    }

    /// Session capture: take the substring before the first ';' (strip
    /// "timeout=" garbage).
    func captureSession(from response: RtspMessage, step: String) throws {
        guard let sessionRaw = response.headerValue("Session") else {
            Diag.error("RTSP \(step) missing Session header", Self.logCategory)
            throw RtspError.badResponse("\(step) missing Session")
        }
        let token = sessionRaw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            Diag.error("RTSP \(step) malformed Session header", Self.logCategory)
            throw RtspError.badResponse("\(step) malformed Session")
        }
        sessionIdString = trimmed
        hasSessionId = true
    }

    /// strtoul(x, NULL, 0): auto base (0x → hex, else decimal).
    func parseUInt32Auto(_ value: String) -> UInt32 {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        return UInt32(trimmed) ?? 0
    }

    // MARK: - SDP negotiation (faithful to the C substring sniffing)

    func negotiate(sdp: String, into result: inout RtspHandshakeResult) {
        let supported = config.supportedVideoFormats
        if supported & StreamProtocol.VIDEO_FORMAT_MASK_AV1 != 0 && sdp.contains("AV1/90000") {
            if serverCodecModeRaw & StreamProtocol.SCM_AV1_HIGH10_444 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444
            } else if serverCodecModeRaw & StreamProtocol.SCM_AV1_MAIN10 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_AV1_MAIN10 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
            } else if serverCodecModeRaw & StreamProtocol.SCM_AV1_HIGH8_444 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_AV1_HIGH8_444 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_HIGH8_444
            } else {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN8
            }
        } else if supported & StreamProtocol.VIDEO_FORMAT_MASK_H265 != 0
            && sdp.contains("sprop-parameter-sets=AAAAAU") {
            if serverCodecModeRaw & StreamProtocol.SCM_HEVC_REXT10_444 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_H265_REXT10_444 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_REXT10_444
            } else if serverCodecModeRaw & StreamProtocol.SCM_HEVC_MAIN10 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_H265_MAIN10 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
            } else if serverCodecModeRaw & StreamProtocol.SCM_HEVC_REXT8_444 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_H265_REXT8_444 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_REXT8_444
            } else {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H265
            }
        } else {
            if serverCodecModeRaw & StreamProtocol.SCM_H264_HIGH8_444 != 0
                && supported & StreamProtocol.VIDEO_FORMAT_H264_HIGH8_444 != 0 {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H264_HIGH8_444
            } else {
                result.negotiatedVideoFormat = StreamProtocol.VIDEO_FORMAT_H264
            }
        }

        result.referenceFrameInvalidationSupported =
            sdp.contains("x-nv-video[0].refPicInvalidation")
        result.encryptionFeaturesSupported =
            SdpScan.attributeUInt(sdp, "x-ss-general.encryptionSupported") ?? 0
        // Sunshine feature flags (RtspConnection.c:1145). Gates controllerTouch
        // (0x02 = LI_FF_CONTROLLER_TOUCH_EVENTS).
        result.featureFlags =
            SdpScan.attributeUInt(sdp, "x-ss-general.featureFlags") ?? 0
    }

    /// getAttributesList: control-V2 is enabled whenever supported (Sunshine).
    /// Video/audio encryption stays off for connect-only (encryptionFlags=0).
    func computeEncryptionEnabled(supported: UInt32) -> UInt32 {
        let ssEncControlV2: UInt32 = 0x01
        var enabled: UInt32 = 0
        if supported & ssEncControlV2 != 0 {
            enabled |= ssEncControlV2
        }
        return enabled
    }

    func codecName(_ format: Int32) -> String {
        if format & StreamProtocol.VIDEO_FORMAT_MASK_AV1 != 0 { return "AV1" }
        if format & StreamProtocol.VIDEO_FORMAT_MASK_H265 != 0 { return "HEVC" }
        return "H264"
    }
}
