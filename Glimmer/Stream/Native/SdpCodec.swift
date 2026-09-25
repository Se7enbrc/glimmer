//
//  SdpCodec.swift
//
//  RTSP message (de)serialization + SDP parsing/building for the Swift-native
//  streaming engine. Source: RtspParser.c (serializeRtspMessage/parseRtspMessage)
//  + SdpGenerator.c (getSdpPayloadForStreamConfig + getAttributesList +
//  addGen5Options).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  TARGET PROFILE: Sunshine reports app version 7.1.431, so only that branch of the C is built: RTSP
//  over plain TCP, one PLAY "/", control stream "streamid=control/13/0" and RTSP client version 14.
//  GameStream PCs are refused before a stream starts.
//
//  WIRE FORMAT (exact bytes - off-by-one here = silent host rejection):
//   Request line:  "<COMMAND> <target> RTSP/1.0\r\n"
//   Option line:   "<name>: <content>\r\n"               (colon-SPACE)
//   Blank line:    "\r\n"
//   Payload:       raw bytes, NO trailing CRLF added by the serializer.
//   SDP attribute: "a=<name>:<value> \r\n"               (trailing SPACE!)
//   SDP m=video:   "m=video <port>  \r\n"                (TWO spaces!)

import Foundation

// MARK: - RTSP message

/// One RTSP request or response. Headers are an ORDERED array because the host
/// is sensitive to header order (CSeq first, then X-GS-ClientVersion). Lookup is
/// case-SENSITIVE to match the C strcmp.
struct RtspMessage {
    /// Request command (e.g. "OPTIONS"); nil for parsed responses.
    var command: String?
    /// Request target (e.g. "streamid=audio/0/0"); nil for parsed responses.
    var target: String?
    /// Response status code; 0 for requests.
    var statusCode: Int = 0
    /// Response status string.
    var statusString: String = ""
    /// Ordered (name, content) pairs.
    var headers: [(String, String)] = []
    /// Raw payload bytes (SDP for ANNOUNCE; nil otherwise).
    var payload: Data?

    init(command: String? = nil, target: String? = nil) {
        self.command = command
        self.target = target
    }

    /// Case-sensitive header lookup (first match), matching the C strcmp.
    func headerValue(_ name: String) -> String? {
        for (key, value) in headers where key == name { return value }
        return nil
    }

    /// Serialize a REQUEST to wire bytes:
    /// "<cmd> <target> RTSP/1.0\r\n" + headers + "\r\n" + payload.
    func serialize() -> Data {
        var text = "\(command ?? "") \(target ?? "") RTSP/1.0\r\n"
        for (name, content) in headers {
            text += "\(name): \(content)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let payload { data.append(payload) }
        return data
    }

    /// Parse a RESPONSE from raw bytes. Status line "RTSP/1.0 <code> <str>",
    /// headers until the blank line, remainder = payload. Header split on the
    /// first ": " (a single leading space after ':' is stripped, like the C
    /// `token+1`).
    static func parseResponse(_ data: Data) -> RtspMessage? {
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
enum SdpScan {
    /// parseSdpAttributeToUInt: find `name`, then the next ':' after it, then
    /// strtoul the digits. Returns nil if the name isn't present.
    static func attributeUInt(_ sdp: String, _ name: String) -> UInt32? {
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

    static func contains(_ sdp: String, _ needle: String) -> Bool {
        sdp.contains(needle)
    }
}

// MARK: - Audio layout (DESCRIBE surround-params)

extension SdpScan {
    /// parseOpusConfigurations (RtspConnection.c): the Opus layout to decode and whether to ask for the high tier.
    /// Stereo is the same in both tiers; surround takes high only when the PC lists a layout for it.
    static func audioLayout(_ sdp: String, channelCount: Int) -> (opus: OpusConfig, highQuality: Bool) {
        guard let fixed = fixedSurroundLayout(channelCount) else {
            return (RtspHandshakeResult.defaultOpusConfig, true)
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
        var opus = RtspHandshakeResult.defaultOpusConfig
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
struct SdpBuilder {
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
    /// Host RFI support, parsed from the DESCRIBE SDP
    /// (`x-nv-video[0].refPicInvalidation` ⇒ ReferenceFrameInvalidationSupported).
    /// Defaulted false so a host that never offered RFI degrades to full-IDR
    /// recovery (today's behavior) - no breakage.
    var serverSupportsRfi: Bool = false
    /// Our decoder's RFI capability bits (VideoSink.capabilities:
    /// CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC/HEVC/AV1). Matched against
    /// the negotiated codec in `referenceFrameInvalidationActive`.
    var decoderRfiCapabilities: Int32 = 0
    /// Ask for the high Opus tier (`SdpScan.audioLayout`): always for stereo, for surround only when the PC
    /// lists a high-tier layout, since that is the layout the decoder is built from.
    var highQualityAudio = true

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
        VideoDecryptor.packetSize(Int(config.packetSize), encryptionFeaturesEnabled: encryptionFeaturesEnabled)
    }

    /// Port of moonlight-common-c's isReferenceFrameInvalidationSupportedByDecoder
    /// (Misc.c): RFI is decoder-supported iff the negotiated codec FAMILY pairs
    /// with the matching decoder capability bit. Our VideoSink advertises
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
    func build() -> Data {
        var attrs: [(String, String)] = []

        // --- Sunshine (IS_SUNSHINE) feature flags ---
        let mlFlags = Self.ML_FF_FEC_STATUS | Self.ML_FF_SESSION_ID_V1
        attrs.append(("x-ml-general.featureFlags", "\(mlFlags)"))
        attrs.append(("x-ss-general.encryptionEnabled", "\(encryptionFeaturesEnabled)"))
        // chromaSamplingType "1" = 4:4:4, "0" = 4:2:0. Mirror the host the
        // codec the negotiator actually settled on: it only lands a YUV444
        // VIDEO_FORMAT (HEVC RExt / AV1 High 4:4:4) when the host OFFERED it
        // AND we PROBED hardware decode for it (RtspClient.negotiate +
        // VideoFormats.probedSupported). So this attribute is purely derived -
        // 4:4:4 is never forced; it engages only on a negotiated 4:4:4 format.
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
        // framesWithInvalidRefThreshold "0" is the moonlight-common-c default,
        // set UNCONDITIONALLY (SdpGenerator.c). 0 = the host imposes no ceiling
        // on how many frames may still reference an invalidated frame while an
        // RFI recovery is outstanding - i.e. it keeps shipping P-frames against
        // the older good reference instead of stalling on a full IDR. A
        // non-zero value would cap that tolerance and force an IDR sooner,
        // which is the opposite of the lossy-link win RFI buys, so "0" stays.
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
        // THERE IS NO HOST-SIDE ABR. This range was previously described here as
        // giving "Sunshine's host-side VQOS a RANGE to adapt within" so it could
        // "step the encoder down under sustained loss". That is not true, and it
        // was checked against Sunshine's source rather than inferred:
        //
        //   * `minimumBitrateKbps` appears ZERO times in the whole Sunshine tree
        //     - it is never parsed, so the floor we send here is inert.
        //   * `cmd_announce` (src/rtsp.cpp) reads
        //     `x-nv-vqos[0].bw.maximumBitrateKbps` into `config.monitor.bitrate`
        //     and then OVERWRITES it with `x-ml-video.configuredBitrateKbps`
        //     when that is non-zero - which we always send. So the number the
        //     host actually encodes at is the raw configured bitrate below, not
        //     the 0.80-adjusted peak (this matches moonlight, which sends the
        //     same pair).
        //   * Nothing in Sunshine mutates the bitrate after ANNOUNCE.
        //
        // So the encoder rate is FIXED for the session, and the only lever that
        // changes it is a new SDP - i.e. a reconnect (BitrateDownshiftController).
        // The attributes stay because they are part of the wire format moonlight
        // sends and the host parses one of them; they are not a control channel.
        // The floor keeps its original shape - half the peak, never below 10
        // Mbps, never above the peak so the range can't invert on a very low
        // configured bitrate - purely so the SDP stays well-formed.
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
        // maxNumReferenceFrames "0" when RFI is active ⇒ the host keeps multiple
        // reference frames so a loss can be recovered with a post-invalidation
        // RFI frame (header type 4/5) instead of a full IDR - the wire signal by
        // which the host learns the client accepts RFI recovery (there is no
        // separate "client supports RFI" attribute; this IS it, SdpGenerator.c).
        // "1" restricts the host to a single reference ⇒ EVERY loss recovery is
        // a full IDR (today's behavior). RFI degrades gracefully: if the host
        // ignores the 0 and still sends an IDR, the client's IDR accept-path
        // handles it unchanged.
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
        sdp += "o=android 0 \(RtspClient.clientVersion) IN \(addrFamilyToken) \(urlSafeAddr)\r\n"
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
