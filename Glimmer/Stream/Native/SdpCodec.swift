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
//  TARGET PROFILE: Sunshine hosts reporting appVersion 7.1.450.0 →
//  AppVersionQuad = [7,1,450,0]. q[2]=450 >= 404 ⇒ useEnet=FALSE ⇒ RTSP runs
//  over plain TCP; APP_VERSION_AT_LEAST(7,1,431) is TRUE (single PLAY "/",
//  control stream id "streamid=control/13/0"). We only build the TCP + 7.1.431+
//  branches.
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
            msg.statusCode = Int(parts[1]) ?? 0
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

// MARK: - SDP builder (ANNOUNCE payload)

/// Builds the SDP blob for the control ANNOUNCE, faithful to
/// getSdpPayloadForStreamConfig (header + ordered attributes + tail).
///
/// Reference-frame invalidation (RFI) is advertised when BOTH the host
/// supports it (DESCRIBE SDP `x-nv-video[0].refPicInvalidation`) AND our
/// decoder supports it for the negotiated codec (the sink's CAPABILITY_*
/// bits) - see `referenceFrameInvalidationActive`. That gate drives
/// maxNumReferenceFrames (0 = host may keep older good refs for an RFI
/// recovery; 1 = single ref ⇒ every loss recovery is a full IDR). YUV444 and
/// the codec block follow the negotiated format; video/audio encryption stays
/// disabled (encryptionFlags=0) - only control-V2 may auto-enable, which is
/// the CONTROL stream's concern.
struct SdpBuilder {
    let config: BackendStreamConfig
    let videoPort: UInt16
    /// addrToUrlSafeString(RemoteAddr): IPv4 plain, IPv6 bracketed.
    let urlSafeAddr: String
    /// "IPv4" or "IPv6" token for the o= line.
    let addrFamilyToken: String
    /// rtspClientVersion (= 14 for q[0]==7), used in the o= line.
    let rtspClientVersion: Int
    /// NegotiatedVideoFormat from DESCRIBE (VIDEO_FORMAT_*). Drives the codec
    /// attribute block.
    let negotiatedVideoFormat: Int32
    /// EncryptionFeaturesEnabled (control-V2 only for connect-only).
    let encryptionFeaturesEnabled: UInt32
    /// 7.1.446+ DRC gate uses these.
    let appVersionQuad: [Int32]
    /// Host RFI support, parsed from the DESCRIBE SDP
    /// (`x-nv-video[0].refPicInvalidation` ⇒ ReferenceFrameInvalidationSupported).
    /// Defaulted false so a host that never offered RFI degrades to full-IDR
    /// recovery (today's behavior) - no breakage.
    var serverSupportsRfi: Bool = false
    /// Our decoder's RFI capability bits (VideoSink.capabilities:
    /// CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC/HEVC/AV1). Matched against
    /// the negotiated codec in `referenceFrameInvalidationActive`.
    var decoderRfiCapabilities: Int32 = 0

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
        // REMOTE MTU clamp (moonlight-common-c's STREAM_CFG_AUTO Internet cap,
        // which this port had only documented, never applied): on a remote
        // session cap the advertised video packetSize to 1024 so a full RTP
        // packet fits inside common VPN path MTUs (WireGuard/Tailscale
        // ~1280-1420) after UDP/IP + tunnel encapsulation. A LAN-tuned 1392 +
        // headers can exceed the tunnel MTU and force IP fragmentation (or a
        // black-holed packet on a DF-set path). The clamp lets PMTU-friendly
        // sizing happen without IP_DONTFRAG (which would hard-fail oversized
        // packets instead of letting them fragment). LAN sessions keep the
        // full configured size.
        let advertisedPacketSize = config.streamingRemotely == 1
            ? min(config.packetSize, 1024) : config.packetSize
        attrs.append(("x-nv-video[0].packetSize", "\(advertisedPacketSize)"))
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
        // The cap is the ceiling Sunshine VQOS can ever climb to. It was 100 Mbps
        // - which silently truncated the abundant-link, high-res case (4K@240 wire
        // ~105 Mbps and 5K/6K@120 push past 125 Mbps configured → ×0.80 ≥ 100 Mbps,
        // clipped) exactly where quality should be highest. Raised to 200 Mbps to
        // match QualityCalculator's own ceiling; the host simply won't use more
        // than it can sustain, and the minimumBitrateKbps floor below still gives
        // VQOS room to drop under loss.
        var adjustedBitrate = Int(Double(config.bitrate) * 0.80)
        if config.streamingRemotely == 1 {
            if adjustedBitrate > 500 { adjustedBitrate -= 500 }
        }
        if adjustedBitrate > 200_000 { adjustedBitrate = 200_000 }
        attrs.append(("x-nv-video[0].initialBitrateKbps", "\(adjustedBitrate)"))
        attrs.append(("x-nv-video[0].initialPeakBitrateKbps", "\(adjustedBitrate)"))
        // Give Sunshine's host-side VQOS a RANGE to adapt within instead of
        // pinning min==max (which left it no room to drop bitrate when it
        // detects loss - the bandwidth estimator could only hold or stall). The
        // floor is half the peak, never below 10 Mbps, so the host can step the
        // encoder down under sustained loss and recover frame delivery rather
        // than shipping a fixed rate into a degraded path. This is host-driven
        // ABR only - there is no client→host bitrate message in this profile, so
        // the client never drives the rate; we just widen the advertised window.
        // min(..., adjustedBitrate) keeps the floor at/below the peak even for a
        // very low configured bitrate (where 10 Mbps could otherwise exceed it
        // and invert the range).
        let minBitrate = min(max(10_000, adjustedBitrate / 2), adjustedBitrate)
        attrs.append(("x-nv-vqos[0].bw.minimumBitrateKbps", "\(minBitrate)"))
        attrs.append(("x-nv-vqos[0].bw.maximumBitrateKbps", "\(adjustedBitrate)"))
        attrs.append(("x-ml-video.configuredBitrateKbps", "\(config.bitrate)"))

        attrs.append(("x-nv-vqos[0].fec.enable", "1"))
        attrs.append(("x-nv-vqos[0].videoQualityScoreUpdateTime", "5000"))

        // qosTrafficType: LOCAL → "5"/"4"; remote → "0"/"0".
        if config.streamingRemotely == 1 {
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
        if appVersionAtLeast(7, 1, 446) && (config.width < 720 || config.height < 540) {
            attrs.append(("x-nv-vqos[0].drc.enable", "1"))
            attrs.append(("x-nv-vqos[0].drc.tableType", "2"))
        } else {
            attrs.append(("x-nv-vqos[0].drc.enable", "0"))
        }
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

        // q[0]>=7 audio quality + packet duration. AudioQuality "1" requests
        // Sunshine's HIGH opus tier (~256 kbps stereo) instead of "0" (~96 kbps) -
        // there's no bandwidth reason to ship low-bitrate audio, and the link-aware
        // cushion already absorbs the slightly larger packets on a bad link.
        attrs.append(("x-nv-audio.surround.AudioQuality", "1"))
        attrs.append(("x-nv-aqos.packetDuration", "5"))

        // q[0]>=7 csc mode = (colorSpace<<1)|colorRange.
        let cscMode = (config.colorSpace << 1) | config.colorRange
        attrs.append(("x-nv-video[0].encoderCscMode", "\(cscMode)"))

        // --- assemble: header + attrs + tail ---
        var sdp = ""
        sdp += "v=0\r\n"
        sdp += "o=android 0 \(rtspClientVersion) IN \(addrFamilyToken) \(urlSafeAddr)\r\n"
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

    private func appVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Bool {
        guard appVersionQuad.count >= 3 else { return false }
        if appVersionQuad[0] != major { return appVersionQuad[0] > major }
        if appVersionQuad[1] != minor { return appVersionQuad[1] > minor }
        return appVersionQuad[2] >= patch
    }
}
