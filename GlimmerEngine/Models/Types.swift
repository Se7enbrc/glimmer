// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// The inputs of the launcher's bitrate ask: Settings › Quality › Bandwidth, the
/// quality dial, the multipliers applied to it, and the Wi-Fi PHY rate that capped it.
package struct BitrateDecision: Sendable {

    package init(
        mode: BitrateMode,
        dialKbps: Int,
        codecMultiplier: Double,
        boost: Double,
        radioGatePhyMbps: Double? = nil
    ) {
        self.mode = mode
        self.dialKbps = dialKbps
        self.codecMultiplier = codecMultiplier
        self.boost = boost
        self.radioGatePhyMbps = radioGatePhyMbps
    }

    package var mode: BitrateMode
    package var dialKbps: Int
    package var codecMultiplier: Double
    package var boost: Double
    /// The median Wi-Fi PHY rate the ask was capped against; nil off Wi-Fi.
    package var radioGatePhyMbps: Double?
}

package enum Remoteness: Sendable {
    case local, remote, auto

    package var cValue: Int32 {
        switch self {
        case .local:  return StreamProtocol.STREAM_CFG_LOCAL
        case .remote: return StreamProtocol.STREAM_CFG_REMOTE
        case .auto:   return StreamProtocol.STREAM_CFG_AUTO
        }
    }
}

package enum AudioConfig: Sendable {
    case stereo
    case surround51
    case surround71

    // Limelight.h defines AUDIO_CONFIGURATION_* via the function-style macro
    //   MAKE_AUDIO_CONFIGURATION(channelCount, channelMask) =
    //       ((channelMask) << 16) | (channelCount << 8) | 0xCA
    // which Clang doesn't expose to Swift. Precompute here.
    package var cValue: Int32 {
        switch self {
        case .stereo:     return (0x003   << 16) | (2 << 8) | 0xCA  // 0x000302CA
        case .surround51: return (0x03F   << 16) | (6 << 8) | 0xCA  // 0x003F06CA
        case .surround71: return (0x63F   << 16) | (8 << 8) | 0xCA  // 0x063F08CA
        }
    }

    package var channelCount: Int {
        switch self {
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    /// /launch's surroundAudioInfo: the channel mask over the channel count.
    package var surroundAudioInfo: Int32 { ((cValue >> 16) & 0xFFFF) << 16 | Int32(channelCount) }

    /// The channel count a packed configuration carries (`mask << 16 | count << 8 | 0xCA`).
    package static func channelCount(packed: Int32) -> Int { Int((packed >> 8) & 0xFF) }

    /// User-facing label for the stats overlay. Match Apple's
    /// QuickTime/Music conventions: "Stereo", "5.1 surround", "7.1
    /// surround" (lowercased "surround" follows HIG sentence-case for
    /// product-spec rows).
    package var displayLabel: String {
        switch self {
        case .stereo:     return "Stereo"
        case .surround51: return "5.1 surround"
        case .surround71: return "7.1 surround"
        }
    }
}

/// Set of video formats the client supports. Sent to the host so it picks
/// the highest format the encoder + decoder both speak.
package struct VideoFormats: OptionSet, Sendable {

    package init(
        rawValue: Int32
    ) {
        self.rawValue = rawValue
    }

    package let rawValue: Int32

    package static let h264         = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H264)
    package static let h264YUV444   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H264_HIGH8_444)
    package static let hevc         = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265)
    package static let hevcMain10   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_MAIN10)
    package static let hevcRext8_444  = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_REXT8_444)
    package static let hevcRext10_444 = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_REXT10_444)
    package static let av1          = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8)
    package static let av1Main10    = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_MAIN10)
    package static let av1High8_444   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_HIGH8_444)
    package static let av1High10_444  = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444)
}

extension VideoFormats {
    /// All AV1 profile bits (Main8/Main10 + High 4:4:4 8/10-bit).
    package static let anyAV1: VideoFormats = [.av1, .av1Main10, .av1High8_444, .av1High10_444]
    /// All HEVC profile bits (Main/Main10 + RExt 4:4:4 8/10-bit).
    package static let anyHEVC: VideoFormats = [.hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444]

    package enum TopCodec: Sendable { case av1, hevc, h264 }

    /// Codec family the host will most likely settle on for this mask (negotiation
    /// prefers AV1 → HEVC → H.264). Lets bitrate budget be codec-aware pre-launch,
    /// before the SDP handshake finalizes the exact format.
    package var topCodec: TopCodec {
        if !isDisjoint(with: .anyAV1) { return .av1 }
        if !isDisjoint(with: .anyHEVC) { return .hevc }
        return .h264
    }
}

package enum ColorSpace: Sendable {
    case rec601, rec709, rec2020
    package var cValue: Int32 {
        switch self {
        case .rec601:  return StreamProtocol.COLORSPACE_REC_601
        case .rec709:  return StreamProtocol.COLORSPACE_REC_709
        case .rec2020: return StreamProtocol.COLORSPACE_REC_2020
        }
    }
}

package enum ColorRange: Sendable {
    case limited, full
    package var cValue: Int32 {
        switch self {
        case .limited: return StreamProtocol.COLOR_RANGE_LIMITED
        case .full:    return StreamProtocol.COLOR_RANGE_FULL
        }
    }
}

// MARK: - Server info

/// Everything we need to know about the remote host to start a session.
/// Populated by Network's /serverinfo call + cached pairing data.
package struct ServerInfo: Sendable {
    package var address: String                  // hostname or IP, no port
    package var httpPort: Int = 47989
    package var httpsPort: Int = 47984
    /// Host's cert (PEM), which is the TLS pin. Set only by the RSA-verified PIN
    /// handshake or from `PinnedCertStore` via `AppModel.nativeServerInfo`;
    /// /serverinfo never sets it (C2), so nil means not paired.
    package var serverCertPEM: String?
    package var uniqueId: String                 // GUID identifying this host
    package var serverName: String               // friendly name from /serverinfo
    package var pairStatus: PairStatus = .unpaired
    package var appVersion: String?              // GFE/Sunshine version string
    /// True only for NVIDIA GameStream, whose `<state>` holds "MJOLNIR" (moonlight-qt's test); Sunshine sends
    /// `GfeVersion` too, so that proves nothing. Pairing and stream start refuse such a PC.
    package var isRealGFE: Bool = false
    package var maxLumaPixelsHEVC: Int = 0       // HEVC capability hint
    // The PC's supported formats, decoded into our VIDEO_FORMAT_* bitmask.
    package var serverCodecSupport: VideoFormats = []
    /// Raw `ServerCodecModeSupport` integer from /serverinfo, in
    /// moonlight-common-c's SCM_* bit layout - completely different from our
    /// VIDEO_FORMAT_* layout (e.g. SCM_AV1_MAIN10 = 0x20000 vs
    /// VIDEO_FORMAT_AV1_MAIN10 = 0x2000). Must be passed through verbatim to
    /// `STREAM_CONFIGURATION.serverCodecModeSupport` or the RTSP negotiation
    /// silently picks the lowest-common 8-bit codec, killing HDR. We keep
    /// both fields because `serverCodecSupport` is what our own UI / picker
    /// code thinks in, while `serverCodecModeRaw` is what the backend
    /// needs on the wire.
    package var serverCodecModeRaw: Int = 0
    package var isBusy = false
    package var currentGameID: Int = 0           // 0 = host is idle; otherwise the app ID that's streaming
    /// Host's primary-NIC MAC from /serverinfo's `<mac>`, as stock Moonlight uses for WoL.
    /// Only learnable while the host is ONLINE; some Sunshine NIC configs report a zeroed
    /// MAC, which `WakeOnLAN.normalizeMac` treats as absent (Wake on LAN fails closed on it).
    package var macAddress: String?

    package init(address: String, uniqueId: String, serverName: String) {
        self.address = address
        self.uniqueId = uniqueId
        self.serverName = serverName
    }
}

// MARK: - Events emitted during a session

package enum StreamEvent: Sendable {
    case stageStarting(name: String)
    case stageComplete(name: String)
    case stageFailed(name: String, errorCode: Int32)
    case connectionEstablished
    /// First decoded/rendered video frame for this session. Ground-truth
    /// proof the stream is LIVE - frames are flowing - independent of the
    /// one-shot `.connectionEstablished` edge. The UI promotes
    /// connecting→streaming on EITHER signal, so a missed/torn established
    /// edge can never leave the launcher stuck at "Connecting" while video
    /// is actually on screen. Fired exactly once per session (first frame
    /// only); idempotent against `.connectionEstablished` having already
    /// promoted the phase.
    case firstFrame
    /// `error` is the last reconnect attempt's failure when an episode gives up, so the launcher can
    /// name the fix (a PC that slept gets the couldn't-reach copy, not "ended unexpectedly").
    case connectionTerminated(errorCode: Int32, error: StreamError? = nil)
    /// The host closed a LIVE session with a recoverable code (e.g. Sunshine's
    /// process restarting across a Windows lock / secure-desktop transition, or
    /// a brief network blip) and we're silently re-establishing underneath the
    /// frozen last frame. The UI shows "Reconnecting..." over the held frame
    /// rather than bouncing to the launcher. Paired with `.reconnected` /
    /// (on give-up) `.connectionTerminated`.
    case reconnecting
    /// A silent reconnect succeeded - the stream resumed in place. The UI
    /// returns to the streaming state; the fresh `.connectionEstablished` /
    /// `.firstFrame` edges also promote the phase, so this is belt-and-braces.
    case reconnected
    case connectionStatus(ConnectionQuality)
    /// Raised when the *host* signals an HDR-mode change via
    /// `LiSetHdrMode`. Indicates intent, not effective output state - a host
    /// can claim HDR on an 8-bit stream and we'll refuse to engage the PQ
    /// pipeline. Use `.hdrActive` for the effective signal the UI should
    /// reflect.
    case hdrModeChanged(Bool)
    /// Raised by the video decoder when the effective HDR-active state
    /// changes: host enabled HDR AND we have a 10-bit stream AND the Metal
    /// layer is configured for PQ (HDR10) with EDR. This is the "show the HDR
    /// chip" signal.
    case hdrActive(Bool)
    /// Audio receive-start failed (H7): the session came up VIDEO-ONLY (the ping
    /// keeps the A/V session alive, but no audio flows). Non-fatal - the visual
    /// stream is unaffected - so it rides the event channel rather than aborting
    /// the connect. Carries a short reason for the log; the UI keeps streaming.
    case audioFailed(String)
    case log(String)
}

package enum ConnectionQuality: Sendable {
    case good, poor
}

// MARK: - Errors

package enum StreamError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case binaryNotFound
    case hostUnreachable(String)
    case pairingFailed(String)
    case pairingRejected
    case launchFailed(String)
    case sessionFailed(Int32)
    case decoderFailed(String)
    case audioFailed(String)
    case crypto(String)
    /// A control-channel read ended before the full HTTP body arrived (a recv
    /// timeout or transport error mid-body), distinct from a clean EOF. Surfaced
    /// instead of letting a half-read body reach the XML parser as "Malformed XML".
    case truncatedRead(String)
    /// The PC answered /launch, but a stream port never took the connection:
    /// almost always its firewall. Carries the port to allow.
    case streamPortsBlocked(proto: String, port: UInt16)
    /// The PC didn't finish launching the app before the launch deadline.
    case hostTimedOut
    /// The PC answered with an error status; carries Sunshine's own message.
    case hostRefused(message: String, code: Int)
    /// The PC is up, but its certificate isn't the one pinned at pairing.
    /// Carries the sentence that names the fix (NetworkClient.classifyPairedPathFailure).
    case hostCertChanged(String)
    /// The PC answers on its plain port only: Sunshine's secure listener needs a
    /// restart. Carries the sentence that names the fix.
    case sunshineNeedsRestart(String)
    /// The PC runs NVIDIA GameStream, not Sunshine. Refused before anything is launched.
    case gameStreamHost

    package var description: String {
        switch self {
        case .binaryNotFound: return "Streaming library not available."
        case .hostUnreachable(let detail): return "Couldn't reach the PC: \(detail)."
        case .pairingFailed(let reason): return "Pairing failed: \(reason)"
        // SECURITY: uniform user-visible message regardless of
        // whether the host rejected because the PIN was wrong or because
        // its signature failed verification (the MITM-detected branch
        // also throws .pairingRejected). The internal log distinguishes;
        // the surface does not.
        case .pairingRejected: return "Pairing failed. Try again."
        case .launchFailed(let reason): return "Couldn't launch app: \(reason)"
        case .sessionFailed(let code): return "Streaming session ended (code \(code))."
        case .decoderFailed(let reason): return "Video decoder failed: \(reason)"
        case .audioFailed(let reason): return "Audio failed: \(reason)"
        case .crypto(let reason): return "Cryptography error: \(reason)"
        case .truncatedRead(let reason): return "Control connection ended early: \(reason)"
        case .streamPortsBlocked(let proto, let port): return "The stream couldn't get through on \(proto) \(port)."
        case .hostTimedOut: return "The PC didn't respond in time."
        case .hostRefused(let message, let code): return "\(message) (code \(code))"
        case .hostCertChanged(let sentence), .sunshineNeedsRestart(let sentence): return sentence
        case .gameStreamHost: return StreamFailureCopy.needsSunshineMessage("the PC")
        }
    }

    /// LocalizedError conformance. Without this, bridging a StreamError to
    /// NSError (which Foundation does whenever `.localizedDescription` is read
    /// on a thrown error) ignores `description` and synthesizes the generic
    /// "The operation couldn't be completed. (Glimmer.StreamError error 0.)".
    /// Routing `errorDescription` back to our `description` guarantees the
    /// human sentence shows up on every path, not just the ones that special-
    /// case StreamError before reading localizedDescription.
    package var errorDescription: String? { description }
}
