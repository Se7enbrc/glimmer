// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// RTSP/SDP from RtspParser.c and SdpGenerator.c; provenance is in CREDITS.md.
// Sunshine 7.1.431 uses TCP, one PLAY "/", control stream "streamid=control/13/0", client version 14.
// Wire whitespace is significant: RTSP colon-space, no payload suffix, SDP attributes one trailing space, m=video two.

import Foundation

// MARK: - RTSP message

/// One RTSP request or response. Headers are an ORDERED array because the PC
/// is sensitive to header order (CSeq first, then X-GS-ClientVersion). Lookup is
/// case-SENSITIVE to match the C strcmp.
public struct RtspMessage: Sendable {
    /// rtspClientVersion for app version 7, the one Sunshine reports (RtspConnection.c).
    public static let clientVersion = 14

    /// Request command (e.g. "OPTIONS"); nil for parsed responses.
    package var command: String?
    /// Request target (e.g. "streamid=audio/0/0"); nil for parsed responses.
    package var target: String?
    /// Response status code; 0 for requests.
    package var statusCode: Int = 0
    /// Response status string.
    package var statusString: String = ""
    /// Ordered (name, content) pairs.
    public var headers: [(String, String)] = []
    /// Raw payload bytes (SDP for ANNOUNCE; nil otherwise).
    package var payload: Data?

    public init(command: String? = nil, target: String? = nil) {
        self.command = command
        self.target = target
    }

    /// Case-sensitive header lookup (first match), matching the C strcmp.
    package func headerValue(_ name: String) -> String? {
        for (key, value) in headers where key == name { return value }
        return nil
    }

    /// Serialize a REQUEST to wire bytes:
    /// "<cmd> <target> RTSP/1.0\r\n" + headers + "\r\n" + payload.
    public func serialize() -> Data {
        var text = "\(command ?? "") \(target ?? "") RTSP/1.0\r\n"
        for (name, content) in headers {
            text += "\(name): \(content)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let payload { data.append(payload) }
        return data
    }

    /// Parse a RESPONSE from raw bytes. Status line "RTSP/1.0 <code> <str>", headers until the blank line, remainder =
    /// payload. Header split on the first ": " (a single leading space after ':' is stripped, like the C `token+1`).
    package static func parseResponse(_ data: Data) -> RtspMessage? {
        // Find the "\r\n\r\n" boundary that ends the headers.
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let boundary = data.range(of: crlfcrlf) else {
            // No header terminator - try to parse what we have as header-only.
            return parseHeaderBlock(data, payload: nil)
        }
        let headerData = data.subdata(in: data.startIndex..<boundary.lowerBound)
        let payloadStart = boundary.upperBound
        let payload = payloadStart < data.endIndex
            ? data.subdata(in: payloadStart..<data.endIndex)
            : nil
        return parseHeaderBlock(headerData, payload: payload)
    }

    private static func parseHeaderBlock(_ headerData: Data, payload: Data?) -> RtspMessage? {
        guard let text = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) else { return nil }
        // Lines are CRLF-delimited; split tolerantly.
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }

        var msg = RtspMessage()
        // "RTSP/1.0 <code> <status string...>"
        let parts = statusLine.split(separator: " ", maxSplits: 2,
                                     omittingEmptySubsequences: false)
        if parts.count >= 2 {
            if let statusCode = Int(parts[1]), (100...999).contains(statusCode) {
                msg.statusCode = statusCode
            }
        }
        if parts.count >= 3 {
            msg.statusString = String(parts[2])
        }

        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            // Split on the first ':'; strip a single leading space (C `token+1`).
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            var content = String(line[line.index(after: colon)...])
            if content.hasPrefix(" ") { content.removeFirst() }
            msg.headers.append((name, content))
        }
        msg.payload = payload
        return msg
    }
}

// MARK: - SDP parsing (DESCRIBE response)

/// Loose SDP attribute scanning that mirrors the C substring sniffing - NOT a
/// strict SDP parser, on purpose (Sunshine labels HEVC as H264 MIME, so codec
/// detection relies on payload substrings).
package enum SdpScan {
    /// Stereo Opus layout: the handshake default and the base every
    /// `SdpScan.audioLayout` result is built from.
    package static let defaultOpusConfig = OpusConfig(
        sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 1,
        samplesPerFrame: 240, mapping: [0, 1])

    /// parseSdpAttributeToUInt: find `name`, then the next ':' after it, then
    /// strtoul the digits. Returns nil if the name isn't present.
    package static func attributeUInt(_ sdp: String, _ name: String) -> UInt32? {
        guard let nameRange = sdp.range(of: name) else { return nil }
        guard let colon = sdp.range(of: ":", range: nameRange.upperBound..<sdp.endIndex) else {
            return nil
        }
        // Collect leading numeric chars (strtoul auto-base: handle 0x too).
        let rest = sdp[colon.upperBound...]
        let trimmed = rest.drop(while: { $0 == " " })
        // strtoul base 0: 0x → hex.
        var str = String(trimmed)
        // Cut at first non-token char.
        if let stop = str.firstIndex(where: { !($0.isHexDigit || $0 == "x" || $0 == "X") }) {
            str = String(str[str.startIndex..<stop])
        }
        if str.lowercased().hasPrefix("0x") {
            return UInt32(str.dropFirst(2), radix: 16)
        }
        // Plain decimal (the common case).
        if let dec = UInt32(str) { return dec }
        return UInt32(str, radix: 16)
    }

    package static func contains(_ sdp: String, _ needle: String) -> Bool {
        sdp.contains(needle)
    }
}

// MARK: - Audio layout (DESCRIBE surround-params)

extension SdpScan {
    /// parseOpusConfigurations (RtspConnection.c): the Opus layout to decode and whether to ask for the high tier.
    /// Stereo is the same in both tiers; surround takes high only when the PC lists a layout for it.
    package static func audioLayout(_ sdp: String, channelCount: Int) -> (opus: OpusConfig, highQuality: Bool) {
        guard let fixed = fixedSurroundLayout(channelCount) else {
            return (SdpScan.defaultOpusConfig, true)
        }
        let tiers = surroundParams(sdp, channelCount: channelCount)
        if tiers.count == 2 { return (tiers[1], true) }
        guard var normal = tiers.first else { return (fixed, false) }
        // GFE listed the normal tier's LFE last (FL FR C RL RR SL SR LFE) and Sunshine pre-rotates its line to
        // match (rtsp.cpp), so this undo stays even with GameStream refused: move LFE back behind C.
        let map = normal.mapping
        normal.mapping = Array(map[..<3]) + [map[map.count - 1]] + Array(map[3..<(map.count - 1)])
        return (normal, false)
    }

    /// Each "a=fmtp:97 surround-params=<channels><streams><coupled><mapping>" line for this channel count,
    /// normal tier first. The scan stops at a malformed one, as the C parser does.
    private static func surroundParams(_ sdp: String, channelCount: Int) -> [OpusConfig] {
        let prefix = "a=fmtp:97 surround-params=\(channelCount)"
        var tiers: [OpusConfig] = []
        var rest = sdp[...]
        while tiers.count < 2, let hit = rest.range(of: prefix) {
            rest = rest[hit.upperBound...]
            let digits = rest.utf8.prefix(channelCount + 2).map { Int($0) - Int(UInt8(ascii: "0")) }
            guard digits.count == channelCount + 2, digits.allSatisfy({ (0...9).contains($0) }) else { break }
            tiers.append(opusLayout(channelCount, streams: digits[0], coupled: digits[1],
                                    mapping: digits.dropFirst(2).map { UInt8($0) }))
        }
        return tiers
    }

    /// The fixed surround layouts, kept for a PC whose DESCRIBE lists none. Nil for stereo.
    private static func fixedSurroundLayout(_ channelCount: Int) -> OpusConfig? {
        switch channelCount {
        case 6: return opusLayout(6, streams: 4, coupled: 2, mapping: [0, 4, 1, 5, 2, 3])
        case 8: return opusLayout(8, streams: 5, coupled: 3, mapping: [0, 6, 1, 7, 2, 3, 4, 5])
        default: return nil
        }
    }

    private static func opusLayout(_ channelCount: Int, streams: Int, coupled: Int, mapping: [UInt8]) -> OpusConfig {
        var opus = SdpScan.defaultOpusConfig
        opus.channelCount = Int32(channelCount)
        opus.streams = Int32(streams)
        opus.coupledStreams = Int32(coupled)
        opus.mapping = mapping
        return opus
    }
}

// MARK: - SDP builder (ANNOUNCE payload)

/// The control ANNOUNCE's SDP, faithful to moonlight's getSdpPayloadForStreamConfig. RFI is advertised only when
/// the host and our decoder both support it (`referenceFrameInvalidationActive`); the codec block follows the
/// negotiated format, and the encryption bits are the ones `computeEncryptionEnabled` settled on.
package struct SdpBuilder {
    let config: BackendStreamConfig
    let videoPort: UInt16
    /// addrToUrlSafeString(RemoteAddr): IPv4 plain, IPv6 bracketed.
    let urlSafeAddr: String
    /// "IPv4" or "IPv6" token for the o= line.
    let addrFamilyToken: String
    /// NegotiatedVideoFormat from DESCRIBE (VIDEO_FORMAT_*). Drives the codec
    /// attribute block.
    let negotiatedVideoFormat: Int32
    /// EncryptionFeaturesEnabled (control-V2 and audio when the PC supports them, video when it requires it).
    let encryptionFeaturesEnabled: UInt32
    /// Host RFI support, parsed from the DESCRIBE SDP (`x-nv-video[0].refPicInvalidation` ⇒
    /// ReferenceFrameInvalidationSupported). Defaulted false so a host that never offered RFI degrades to full-IDR
    /// recovery (today's behavior) - no breakage.
    var serverSupportsRfi: Bool = false
    /// Our decoder's RFI capability bits (VideoSink.capabilities:
    /// CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC/HEVC/AV1). Matched against
    /// the negotiated codec in `referenceFrameInvalidationActive`.
    var decoderRfiCapabilities: Int32 = 0
    /// Ask for the high Opus tier (`SdpScan.audioLayout`): always for stereo, for surround only when the PC
    /// lists a high-tier layout, since that is the layout the decoder is built from.
    var highQualityAudio = true

    package init(config: BackendStreamConfig, videoPort: UInt16, urlSafeAddr: String,
                 addrFamilyToken: String, negotiatedVideoFormat: Int32, encryptionFeaturesEnabled: UInt32,
                 serverSupportsRfi: Bool = false, decoderRfiCapabilities: Int32 = 0, highQualityAudio: Bool = true) {
        self.config = config
        self.videoPort = videoPort
        self.urlSafeAddr = urlSafeAddr
        self.addrFamilyToken = addrFamilyToken
        self.negotiatedVideoFormat = negotiatedVideoFormat
        self.encryptionFeaturesEnabled = encryptionFeaturesEnabled
        self.serverSupportsRfi = serverSupportsRfi
        self.decoderRfiCapabilities = decoderRfiCapabilities
        self.highQualityAudio = highQualityAudio
    }

    private static let ML_FF_FEC_STATUS: UInt32 = 0x01
    private static let ML_FF_SESSION_ID_V1: UInt32 = 0x04
    private static let NVFF_BASE: UInt32 = 0x07
    private static let NVFF_AUDIO_ENCRYPTION: UInt32 = 0x20
    private static let NVFF_RI_ENCRYPTION: UInt32 = 0x80
    private static let SS_ENC_AUDIO: UInt32 = 0x04

    /// CHANNEL_COUNT_FROM_AUDIO_CONFIGURATION(x) = (x >> 8) & 0xFF
    private var audioChannelCount: Int { Int((config.audioConfiguration >> 8) & 0xFF) }
    /// CHANNEL_MASK_FROM_AUDIO_CONFIGURATION(x) = (x >> 16) & 0xFFFF
    private var audioChannelMask: Int { Int((config.audioConfiguration >> 16) & 0xFFFF) }
    /// The configured packet size, less ENC_VIDEO_HEADER when video is encrypted.
    private var videoPacketSize: Int {
        VideoPacketLayout.packetSize(Int(config.packetSize), encryptionFeaturesEnabled: encryptionFeaturesEnabled)
    }

    /// Port of moonlight-common-c's isReferenceFrameInvalidationSupportedByDecoder (Misc.c): RFI is decoder-supported
    /// iff the negotiated codec FAMILY pairs with the matching decoder capability bit. Our VideoSink advertises
    /// HEVC|AV1 (no AVC RFI), so H.264 is never decoder-supported here.
    private var rfiSupportedByDecoder: Bool {
        let fmt = negotiatedVideoFormat
        let cap = decoderRfiCapabilities
        if fmt & StreamProtocol.VIDEO_FORMAT_MASK_H264 != 0
            && cap & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC != 0 { return true }
        if fmt & StreamProtocol.VIDEO_FORMAT_MASK_H265 != 0
            && cap & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC != 0 { return true }
        if fmt & StreamProtocol.VIDEO_FORMAT_MASK_AV1 != 0
            && cap & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1 != 0 { return true }
        return false
    }

    /// Port of isReferenceFrameInvalidationEnabled (Misc.c): active iff the host
    /// supports RFI (DESCRIBE SDP) AND our decoder supports it for this codec.
    private var referenceFrameInvalidationActive: Bool {
        serverSupportsRfi && rfiSupportedByDecoder
    }

    /// Returns the full SDP payload bytes.
    package func build() -> Data {
        var attrs: [(String, String)] = []

        // --- Sunshine (IS_SUNSHINE) feature flags ---
        let mlFlags = Self.ML_FF_FEC_STATUS | Self.ML_FF_SESSION_ID_V1
        attrs.append(("x-ml-general.featureFlags", "\(mlFlags)"))
        attrs.append(("x-ss-general.encryptionEnabled", "\(encryptionFeaturesEnabled)"))
        // chromaSamplingType follows the negotiated format: 4:4:4 requires both the PC's offer and our
        // hardware probe (RtspClient.negotiate / VideoFormats.probedSupported). Never force 4:4:4 here.
        let is444 = negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_YUV444 != 0
        attrs.append(("x-ss-video[0].chromaSamplingType", is444 ? "1" : "0"))

        // --- core video ---
        attrs.append(("x-nv-video[0].clientViewportWd", "\(config.width)"))
        attrs.append(("x-nv-video[0].clientViewportHt", "\(config.height)"))
        attrs.append(("x-nv-video[0].maxFPS", "\(config.fps)"))
        // Resolved once upstream (StreamSession.makeBackendConfig, remote MTU clamp included) so the
        // PC, the receive buffer and FEC agree; encrypted video fits its header inside it.
        attrs.append(("x-nv-video[0].packetSize", "\(videoPacketSize)"))
        attrs.append(("x-nv-video[0].rateControlMode", "4"))
        attrs.append(("x-nv-video[0].timeoutLengthMs", "7000"))
        // Unconditional 0 matches SdpGenerator.c: no ceiling on frames referencing an invalidated frame.
        // The PC can keep shipping P-frames against an older good reference; a nonzero ceiling forces earlier IDRs.
        attrs.append(("x-nv-video[0].framesWithInvalidRefThreshold", "0"))

        // adjustedBitrate = bitrate * 0.80, remote -=500 if >500, cap 200000.
        // The 200 Mbps cap preserves headroom for high-resolution streams whose
        // configured bitrate exceeds the former 100 Mbps limit after adjustment.
        var adjustedBitrate = Int(Double(config.bitrate) * 0.80)
        if config.isRemoteSession {
            if adjustedBitrate > 500 { adjustedBitrate -= 500 }
        }
        if adjustedBitrate > 200_000 { adjustedBitrate = 200_000 }
        attrs.append(("x-nv-video[0].initialBitrateKbps", "\(adjustedBitrate)"))
        attrs.append(("x-nv-video[0].initialPeakBitrateKbps", "\(adjustedBitrate)"))
        // No PC-side ABR: Sunshine cmd_announce (src/rtsp.cpp) ignores minimumBitrateKbps and overwrites
        // maximumBitrateKbps with configuredBitrateKbps. Rate stays fixed until reconnect; this wire-compatible
        // floor (half peak, at least 10 Mbps but never above peak) only keeps the SDP range well-formed.
        let minBitrate = min(max(10_000, adjustedBitrate / 2), adjustedBitrate)
        attrs.append(("x-nv-vqos[0].bw.minimumBitrateKbps", "\(minBitrate)"))
        attrs.append(("x-nv-vqos[0].bw.maximumBitrateKbps", "\(adjustedBitrate)"))
        // THE number Sunshine actually encodes at (it overwrites the max above).
        attrs.append(("x-ml-video.configuredBitrateKbps", "\(config.bitrate)"))

        attrs.append(("x-nv-vqos[0].fec.enable", "1"))
        attrs.append(("x-nv-vqos[0].videoQualityScoreUpdateTime", "5000"))

        // qosTrafficType: LOCAL → "5"/"4"; remote → "0"/"0".
        if config.isRemoteSession {
            attrs.append(("x-nv-vqos[0].qosTrafficType", "0"))
            attrs.append(("x-nv-aqos.qosTrafficType", "0"))
        } else {
            attrs.append(("x-nv-vqos[0].qosTrafficType", "5"))
            attrs.append(("x-nv-aqos.qosTrafficType", "4"))
        }

        // --- addGen5Options (7.1.431+) ---
        var nvFlags = Self.NVFF_BASE | Self.NVFF_RI_ENCRYPTION
        if encryptionFeaturesEnabled & Self.SS_ENC_AUDIO != 0 {
            nvFlags |= Self.NVFF_AUDIO_ENCRYPTION
        }
        attrs.append(("x-nv-general.featureFlags", "\(nvFlags)"))
        attrs.append(("x-nv-general.useReliableUdp", "13"))
        attrs.append(("x-nv-vqos[0].fec.minRequiredFecPackets", "2"))
        attrs.append(("x-nv-vqos[0].bllFec.enable", "0"))
        attrs.append(("x-nv-vqos[0].drc.enable", "0"))
        attrs.append(("x-nv-general.enableRecoveryMode", "0"))

        // --- back in getAttributesList (q[0]>=4) ---
        attrs.append(("x-nv-video[0].videoEncoderSlicesPerFrame", "1"))

        // codec block.
        if negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_AV1 != 0 {
            attrs.append(("x-nv-vqos[0].bitStreamFormat", "2"))
        } else if negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_H265 != 0 {
            attrs.append(("x-nv-clientSupportHevc", "1"))
            attrs.append(("x-nv-vqos[0].bitStreamFormat", "1"))
        } else {
            attrs.append(("x-nv-clientSupportHevc", "0"))
            attrs.append(("x-nv-vqos[0].bitStreamFormat", "0"))
        }

        // q[0]>=7 video extras.
        let is10bit = negotiatedVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT != 0
        attrs.append(("x-nv-video[0].dynamicRangeMode", is10bit ? "1" : "0"))
        // SdpGenerator.c: 0 is the RFI capability signal, allowing multiple references and recovery types 4/5.
        // 1 forces single-reference/IDR recovery. A PC ignoring 0 still works through the unchanged IDR path.
        attrs.append(("x-nv-video[0].maxNumReferenceFrames",
                      referenceFrameInvalidationActive ? "0" : "1"))
        attrs.append(("x-nv-video[0].clientRefreshRateX100", "\(config.clientRefreshRateX100)"))

        // audio surround.
        attrs.append(("x-nv-audio.surround.numChannels", "\(audioChannelCount)"))
        attrs.append(("x-nv-audio.surround.channelMask", "\(audioChannelMask)"))
        attrs.append(("x-nv-audio.surround.enable", audioChannelCount > 2 ? "1" : "0"))

        // q[0]>=7 audio quality + packet duration. The high tier costs little bandwidth
        // and the link-aware cushion absorbs its larger packets.
        attrs.append(("x-nv-audio.surround.AudioQuality", highQualityAudio ? "1" : "0"))
        attrs.append(("x-nv-aqos.packetDuration", "5"))

        // q[0]>=7 csc mode = (colorSpace<<1)|colorRange.
        let cscMode = (config.colorSpace << 1) | config.colorRange
        attrs.append(("x-nv-video[0].encoderCscMode", "\(cscMode)"))

        // --- assemble: header + attrs + tail ---
        var sdp = ""
        sdp += "v=0\r\n"
        sdp += "o=android 0 \(RtspMessage.clientVersion) IN \(addrFamilyToken) \(urlSafeAddr)\r\n"
        sdp += "s=NVIDIA Streaming Client\r\n"
        for (name, value) in attrs {
            // "a=<name>:<value> \r\n" - trailing SPACE before CRLF is real.
            sdp += "a=\(name):\(value) \r\n"
        }
        sdp += "t=0 0\r\n"
        // "m=video <port>  \r\n" - TWO spaces before CRLF.
        sdp += "m=video \(videoPort)  \r\n"

        return Data(sdp.utf8)
    }
}
