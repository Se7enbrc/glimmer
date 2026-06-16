//
//  Types.swift
//
//  Public types for the streaming engine. These are the values that flow
//  between the SwiftUI layer (host cards, settings) and the StreamSession
//  actor underneath. The backend's stream-configuration value types are filled
//  in from these on the way down to startConnection.

import Foundation
import CoreAudio
import CoreMedia
import VideoToolbox
import os

// MARK: - Configuration

/// Configuration the caller provides when starting a stream. Mirrors the
/// fields of moonlight-common-c's STREAM_CONFIGURATION but with idiomatic
/// Swift types and only the knobs callers should set.
public struct StreamConfig: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int
    /// Video packet size on the wire (UDP payload, before FEC framing).
    /// moonlight-common-c documents the default as "use 1024 if unsure" but
    /// that's a conservative remote-streaming value — on a LAN where MTU is
    /// 1500 we can pack ~30% more video data into each packet, which
    /// measurably reduces jitter (fewer fragments per frame, fewer reassembly
    /// stalls under RTT variance). moonlight-qt ships 1392 as the LAN
    /// default; 1392 + UDP/IP headers (28) + the small moonlight framing
    /// overhead lands well below 1500 with headroom for VPN encapsulation.
    /// On a REMOTE session the SDP builder clamps the value it ADVERTISES to
    /// the host back to 1024 (`SdpBuilder.build`, the `streamingRemotely`
    /// branch) so a full RTP packet fits inside common VPN path MTUs
    /// (WireGuard/Tailscale ~1280-1420) after tunnel encapsulation — mirroring
    /// moonlight-common-c's STREAM_CFG_AUTO Internet cap, which this Swift port
    /// applies at SDP-build time rather than mutating this field. This stored
    /// value is the LAN default and is unchanged; only the advertised number is
    /// clamped, and only when remote.
    public var packetSize: Int = 1392
    public var remoteness: Remoteness = .auto
    /// Default to whatever the system default-output device can render
    /// natively (stereo / 5.1 / 7.1). The host will downmix if it doesn't
    /// support the requested config, but requesting at least what our
    /// local hardware can render means a Mac plugged into a 5.1 receiver
    /// gets actual 5.1 from Sunshine instead of stereo upsold by
    /// AVAudioEngine.
    public var audio: AudioConfig = .bestForCurrentOutput()
    /// Default to whatever VideoToolbox actually reports as hardware-decodable
    /// on this machine — see `VideoFormats.probedSupported`. Callers can
    /// override (tests pin a specific set; the picker UI may downgrade based
    /// on user preference) but the safe default is "advertise only what we
    /// can decode," so the host's RTSP codec negotiation never picks a
    /// format we'd have to reject in `handleSetup`.
    public var videoFormats: VideoFormats = .probedSupported
    public var hdr: Bool = true
    public var colorSpace: ColorSpace = .rec2020
    public var colorRange: ColorRange = .full
    /// Default to full-stream encryption (video + audio). Older
    /// Sunshine/GFE builds defaulted clients to audio-only because
    /// video-encryption added measurable CPU load on then-current
    /// hardware; modern hosts have plenty of headroom, and streaming over
    /// an untrusted LAN (coffee-shop / shared-house WiFi / corp-guest
    /// VLAN) is exactly the case "audio-only" fails. Users can downgrade
    /// in Settings → Streaming → Encryption if they need to.
    public var encryption: EncryptionPreference = .all

    /// When true, system-level keyboard combos that use the macOS Cmd key
    /// (⌘-Tab, ⌘-Space, ⌘-Q, ⌘-`, ⌘-H, ⌘-M, …) are forwarded to the host as
    /// VK_LWIN / VK_RWIN chords instead of being handled by macOS. Off by
    /// default — most users want ⌘-Tab to still switch macOS apps even while
    /// a game stream is up, and ⌘-Q to still quit Glimmer. Mirrors
    /// moonlight-qt's `captureSysKeysMode` preference.
    ///
    /// When false the InputForwarder drops the Cmd modifier entirely:
    ///   * ⌘-modified key-down events are not forwarded.
    ///   * `flagsChanged` events for the Cmd modifier do not synthesize a
    ///     VK_LWIN/VK_RWIN event.
    ///   * MODIFIER_META is stripped from the modifier byte we send with
    ///     other key events, so a non-Cmd key pressed while Cmd is held
    ///     doesn't carry a phantom Win-key modifier.
    /// The user's configured quit hotkey is still honoured (it's intercepted
    /// in Glimmer before the capture gate).
    public var captureSysKeys: Bool = false

    /// On notched MacBooks, whether the fullscreen stream window covers
    /// the entire panel (including the 37pt notch reserve zone) or stops
    /// at the safe-area boundary. Default true. See `StreamWindow.coversNotch`.
    public var coversNotch: Bool = true

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }
}

public enum Remoteness: Sendable {
    case local, remote, auto

    var cValue: Int32 {
        switch self {
        case .local:  return StreamProtocol.STREAM_CFG_LOCAL
        case .remote: return StreamProtocol.STREAM_CFG_REMOTE
        case .auto:   return StreamProtocol.STREAM_CFG_AUTO
        }
    }
}

public enum AudioConfig: Sendable {
    case stereo
    case surround51
    case surround71

    // Limelight.h defines AUDIO_CONFIGURATION_* via the function-style macro
    //   MAKE_AUDIO_CONFIGURATION(channelCount, channelMask) =
    //       ((channelMask) << 16) | (channelCount << 8) | 0xCA
    // which Clang doesn't expose to Swift. Precompute here.
    var cValue: Int32 {
        switch self {
        case .stereo:     return (0x003   << 16) | (2 << 8) | 0xCA  // 0x000302CA
        case .surround51: return (0x03F   << 16) | (6 << 8) | 0xCA  // 0x003F06CA
        case .surround71: return (0x63F   << 16) | (8 << 8) | 0xCA  // 0x063F08CA
        }
    }

    var channelCount: Int {
        switch self {
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    /// User-facing label for the stats overlay. Match Apple's
    /// QuickTime/Music conventions: "Stereo", "5.1 surround", "7.1
    /// surround" (lowercased "surround" follows HIG sentence-case for
    /// product-spec rows).
    public var displayLabel: String {
        switch self {
        case .stereo:     return "Stereo"
        case .surround51: return "5.1 surround"
        case .surround71: return "7.1 surround"
        }
    }

    /// Pick the richest channel layout the system's current default output
    /// device can render natively, falling back to stereo if we can't tell.
    /// Sunshine/GFE will downmix on the host side if they don't support
    /// the requested config, so requesting more than we need is safe — but
    /// requesting more than the local hardware supports invites a chain of
    /// AVAudioEngine downmixes that can blur the front-stage. Probe the
    /// CoreAudio default-output device once at startup and pick the
    /// matching tier.
    public static func bestForCurrentOutput() -> AudioConfig {
        let channels = currentDefaultOutputChannelCount()
        if channels >= 8 { return .surround71 }
        if channels >= 6 { return .surround51 }
        return .stereo
    }

    /// Query the CoreAudio default-output device's stream channel count.
    /// Returns 2 on any probe failure (safest fallback). Run on startup
    /// rather than per-stream so the cost — a small handful of AudioHAL
    /// property reads — doesn't sit on the stream-start critical path.
    private static func currentDefaultOutputChannelCount() -> Int {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return 2 }

        // Ask for the output-scope stream configuration; sum channels across
        // every buffer in the AudioBufferList (typically one buffer
        // containing N channels, but multi-stream devices can split).
        var listSize: UInt32 = 0
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(deviceID, &listAddr, 0, nil, &listSize) == noErr,
              listSize > 0 else { return 2 }
        let listPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(listSize))
        defer { listPtr.deallocate() }
        var fetchSize = listSize
        guard AudioObjectGetPropertyData(
            deviceID, &listAddr, 0, nil, &fetchSize, listPtr) == noErr else {
            return 2
        }
        let bufferList = listPtr.withMemoryRebound(
            to: AudioBufferList.self, capacity: 1) { $0 }
        let unsafeList = UnsafeMutableAudioBufferListPointer(bufferList)
        var total = 0
        for buffer in unsafeList { total += Int(buffer.mNumberChannels) }
        return total > 0 ? total : 2
    }
}

/// Set of video formats the client supports. Sent to the host so it picks
/// the highest format the encoder + decoder both speak.
public struct VideoFormats: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let h264         = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H264)
    public static let h264YUV444   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H264_HIGH8_444)
    public static let hevc         = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265)
    public static let hevcMain10   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_MAIN10)
    public static let hevcRext8_444  = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_REXT8_444)
    public static let hevcRext10_444 = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_H265_REXT10_444)
    public static let av1          = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8)
    public static let av1Main10    = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_MAIN10)
    public static let av1High8_444   = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_HIGH8_444)
    public static let av1High10_444  = VideoFormats(rawValue: StreamProtocol.VIDEO_FORMAT_AV1_HIGH10_444)

    /// Build the client-supported codec mask from probed VideoToolbox
    /// capabilities, NOT from a hardcoded "we support everything" set.
    /// Negotiating against a fictional capability set is the standing
    /// "host sends us AV1 we can't decode" bug on Intel Macs (no AV1 HW
    /// decode) — the host accepted the AV1 bit, started encoding AV1, and
    /// VTDecompressionSessionCreate immediately failed, killing the
    /// session. Probing up front means the host never picks a format we
    /// can't handle.
    ///
    /// Apple Silicon (M3+ on Mac) supports the full {AV1 Main8/Main10,
    /// HEVC Main/Main10, H.264 High} matrix. Intel + earlier M-series lack
    /// AV1 HW decode and fall back to {HEVC Main/Main10, H.264 High}. The
    /// probe is the source of truth — anything Apple ships in a future
    /// chip generation lights up automatically without a code change.
    public static let probedSupported: VideoFormats = probeSupported()

    private static func probeSupported() -> VideoFormats {
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Capabilities")
        var out: VideoFormats = []
        // H.264 baseline: every Mac since 2008 has HW H.264 decode.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
            out.insert(.h264)
        } else {
            log.warning("VT reports no HW H.264 decode — this Mac is unsupported")
        }
        // 4:4:4 chroma is a separate decode capability from 4:2:0: the HEVC
        // Range Extensions (RExt) and AV1 High 4:4:4 profiles need the wider
        // chroma path, which Apple's VT only exposes on Apple Silicon SoCs —
        // Intel Macs (and the rare pre-Apple-Silicon HEVC SoC) decode 4:2:0
        // only and would CHOKE on a 4:4:4 bitstream the host happily encoded.
        // VTIsHardwareDecodeSupported returns a single per-codec bit and does
        // NOT distinguish 4:2:0 from 4:4:4, so we gate 4:4:4 advertisement on
        // "this is Apple Silicon" on TOP of the per-codec HW probe. Older Macs
        // never advertise 4:4:4 and the host falls back to 4:2:0 cleanly.
        let appleSilicon = isAppleSilicon()
        // HEVC Main / Main10: SoC HEVC decoder on Macs since ~2017.
        // Apple's VTIsHardwareDecodeSupported doesn't distinguish Main8 from
        // Main10 — the same VT capability covers both. We advertise Main10
        // whenever HEVC is available; the 10-bit path is what unlocks HDR.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            out.insert(.hevc)
            out.insert(.hevcMain10)
            // HEVC RExt 4:4:4 (8 + 10-bit) only on Apple Silicon.
            if appleSilicon {
                out.insert(.hevcRext8_444)
                out.insert(.hevcRext10_444)
            }
        }
        // AV1 Main8 / Main10: M3+ on Mac (and some M2 Pro/Max SKUs), macOS 14+.
        // VT exposes a single AV1 capability bit; Apple's AV1 decoder supports
        // both 8 and 10-bit Main when present at all.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            out.insert(.av1)
            out.insert(.av1Main10)
            // AV1 High 4:4:4 (8 + 10-bit) only on Apple Silicon.
            if appleSilicon {
                out.insert(.av1High8_444)
                out.insert(.av1High10_444)
            }
        }
        let h264 = out.contains(.h264)
        let hevc = out.contains(.hevc)
        let hevcM10 = out.contains(.hevcMain10)
        let hevc444 = out.contains(.hevcRext10_444)
        let av1 = out.contains(.av1)
        let av1M10 = out.contains(.av1Main10)
        let av1444 = out.contains(.av1High10_444)
        let raw = String(out.rawValue, radix: 16)
        log.info(
            // swiftlint:disable:next line_length
            "VT capability probe: H264=\(h264, privacy: .public) HEVC=\(hevc, privacy: .public) HEVCMain10=\(hevcM10, privacy: .public) HEVC444=\(hevc444, privacy: .public) AV1=\(av1, privacy: .public) AV1Main10=\(av1M10, privacy: .public) AV1_444=\(av1444, privacy: .public) raw=0x\(raw, privacy: .public)"
        )
        return out
    }

    /// True on Apple Silicon Macs. Used to gate 4:4:4-chroma decode
    /// advertisement: Apple's VideoToolbox only exposes the HEVC RExt / AV1
    /// High 4:4:4 decode paths on Apple Silicon SoCs, and
    /// VTIsHardwareDecodeSupported's single per-codec bit can't tell 4:2:0 from
    /// 4:4:4. We read the `hw.optional.arm64` sysctl (1 on Apple Silicon, absent
    /// /0 under Rosetta or on Intel) rather than a compile-time `#if arch(arm64)`
    /// so a Rosetta-translated build never claims a 4:4:4 path the running CPU
    /// lacks. Probe failure → false (don't advertise 4:4:4).
    private static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return ok && value == 1
    }
}

public enum ColorSpace: Sendable {
    case rec601, rec709, rec2020
    var cValue: Int32 {
        switch self {
        case .rec601:  return StreamProtocol.COLORSPACE_REC_601
        case .rec709:  return StreamProtocol.COLORSPACE_REC_709
        case .rec2020: return StreamProtocol.COLORSPACE_REC_2020
        }
    }
}

public enum ColorRange: Sendable {
    case limited, full
    var cValue: Int32 {
        switch self {
        case .limited: return StreamProtocol.COLOR_RANGE_LIMITED
        case .full:    return StreamProtocol.COLOR_RANGE_FULL
        }
    }
}

public enum EncryptionPreference: Sendable {
    case none, audioOnly, all

    var encryptionFlags: Int32 {
        switch self {
        case .none:      return StreamProtocol.ENCFLG_NONE
        case .audioOnly: return StreamProtocol.ENCFLG_AUDIO
        case .all:       return StreamProtocol.ENCFLG_ALL
        }
    }
}

// MARK: - Server info

/// Everything we need to know about the remote host to start a session.
/// Populated by Network's /serverinfo call + cached pairing data.
public struct ServerInfo: Sendable {
    public var address: String                  // hostname or IP, no port
    public var httpPort: Int = 47989
    public var httpsPort: Int = 47984
    /// Host's public cert, PEM-encoded. Sources, in order of trust:
    ///   1. The pairing handshake (`Pairing.swift`, `plaincert` blob,
    ///      authenticated by RSA-verifying the host's signature over our
    ///      challenge). This is the only path that produces a *pinned*
    ///      cert.
    ///   2. The persisted pin from a prior pairing
    ///      (`glimmer.pinnedCert.<uniqueId>` in UserDefaults), seeded in
    ///      via `MoonlightManager.nativeServerInfo`. Same trust level as
    ///      (1) because that's how it landed in storage.
    ///   3. A `<PlainCert>` value picked up during an unpaired
    ///      /serverinfo call. INFORMATIONAL ONLY — not bound as a pin.
    ///      Suitable for UI display ("here's the host's fingerprint —
    ///      compare to the one on your host machine") but never trusted
    ///      to authenticate a subsequent TLS handshake. See C2 in the
    ///      security audit.
    public var serverCertPEM: String?
    public var uniqueId: String                 // GUID identifying this host
    public var serverName: String               // friendly name from /serverinfo
    public var pairStatus: PairStatus = .unpaired
    public var appVersion: String?              // GFE/Sunshine version string
    public var gfeVersion: String?
    /// True only for genuine NVIDIA GameStream hosts. Sunshine also populates
    /// `GfeVersion` in its `/serverinfo` response for compatibility, so a
    /// non-empty `gfeVersion` does NOT prove real GFE. moonlight-qt
    /// distinguishes by looking at `<state>` for the substring "MJOLNIR"
    /// (NVIDIA's internal codename) — Sunshine's `<state>` is
    /// "SUNSHINE_SERVER_FREE" / "_BUSY" instead. This field gates the
    /// GFE-only `fps>60 → fps=0` workaround in the launch query; applying
    /// that workaround to Sunshine makes Sunshine fall back to safe SDR
    /// defaults including 8-bit codecs, killing HDR negotiation.
    public var isRealGFE: Bool = false
    public var maxLumaPixelsHEVC: Int = 0       // HEVC capability hint
    public var serverCodecSupport: VideoFormats = []  // server-supported formats (decoded into our VIDEO_FORMAT_* bitmask for our own use)
    /// Raw `ServerCodecModeSupport` integer from /serverinfo, in
    /// moonlight-common-c's SCM_* bit layout — completely different from our
    /// VIDEO_FORMAT_* layout (e.g. SCM_AV1_MAIN10 = 0x20000 vs
    /// VIDEO_FORMAT_AV1_MAIN10 = 0x2000). Must be passed through verbatim to
    /// `STREAM_CONFIGURATION.serverCodecModeSupport` or the RTSP negotiation
    /// silently picks the lowest-common 8-bit codec, killing HDR. We keep
    /// both fields because `serverCodecSupport` is what our own UI / picker
    /// code thinks in, while `serverCodecModeRaw` is what the backend
    /// needs on the wire.
    public var serverCodecModeRaw: Int = 0
    public var currentGameID: Int = 0           // 0 = host is idle; otherwise the app ID that's streaming

    public init(address: String, uniqueId: String, serverName: String) {
        self.address = address
        self.uniqueId = uniqueId
        self.serverName = serverName
    }
}

// MARK: - Events emitted during a session

public enum StreamEvent: Sendable {
    case stageStarting(name: String)
    case stageComplete(name: String)
    case stageFailed(name: String, errorCode: Int32)
    case connectionEstablished
    /// First decoded/rendered video frame for this session. Ground-truth
    /// proof the stream is LIVE — frames are flowing — independent of the
    /// one-shot `.connectionEstablished` edge. The UI promotes
    /// connecting→streaming on EITHER signal, so a missed/torn established
    /// edge can never leave the launcher stuck at "Connecting" while video
    /// is actually on screen. Fired exactly once per session (first frame
    /// only); idempotent against `.connectionEstablished` having already
    /// promoted the phase.
    case firstFrame
    case connectionTerminated(errorCode: Int32)
    /// The host closed a LIVE session with a recoverable code (e.g. Sunshine's
    /// process restarting across a Windows lock / secure-desktop transition, or
    /// a brief network blip) and we're silently re-establishing underneath the
    /// frozen last frame. The UI shows "Reconnecting…" over the held frame
    /// rather than bouncing to the launcher. Paired with `.reconnected` /
    /// (on give-up) `.connectionTerminated`.
    case reconnecting
    /// A silent reconnect succeeded — the stream resumed in place. The UI
    /// returns to the streaming state; the fresh `.connectionEstablished` /
    /// `.firstFrame` edges also promote the phase, so this is belt-and-braces.
    case reconnected
    case connectionStatus(ConnectionQuality)
    /// Raised when the *host* signals an HDR-mode change via
    /// `LiSetHdrMode`. Indicates intent, not effective output state — a host
    /// can claim HDR on an 8-bit stream and we'll refuse to engage the PQ
    /// pipeline. Use `.hdrActive` for the effective signal the UI should
    /// reflect.
    case hdrModeChanged(Bool)
    /// Raised by the video decoder when the effective HDR-active state
    /// changes: host enabled HDR AND we have a 10-bit stream AND the Metal
    /// layer is configured for PQ/HLG with EDR. This is the "show the HDR
    /// chip" signal.
    case hdrActive(Bool)
    case log(String)
}

public enum ConnectionQuality: Sendable {
    case good, poor
}

// MARK: - Errors

public enum StreamError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case binaryNotFound
    case hostUnreachable(String)
    case pairingFailed(String)
    case pairingRejected
    case launchFailed(String)
    case sessionFailed(Int32)
    case decoderFailed(String)
    case audioFailed(String)
    case crypto(String)

    public var description: String {
        switch self {
        case .binaryNotFound: return "Streaming library not available."
        case .hostUnreachable(let host): return "Couldn't reach \(host)."
        case .pairingFailed(let reason): return "Pairing failed: \(reason)"
        // SECURITY (#10): uniform user-visible message regardless of
        // whether the host rejected because the PIN was wrong or because
        // its signature failed verification (the MITM-detected branch
        // also throws .pairingRejected). The internal log distinguishes;
        // the surface does not.
        case .pairingRejected: return "Pairing failed — try again."
        case .launchFailed(let reason): return "Couldn't launch app: \(reason)"
        case .sessionFailed(let code): return "Streaming session ended (code \(code))."
        case .decoderFailed(let reason): return "Video decoder failed: \(reason)"
        case .audioFailed(let reason): return "Audio failed: \(reason)"
        case .crypto(let reason): return "Cryptography error: \(reason)"
        }
    }

    /// LocalizedError conformance. Without this, bridging a StreamError to
    /// NSError (which Foundation does whenever `.localizedDescription` is read
    /// on a thrown error) ignores `description` and synthesizes the generic
    /// "The operation couldn't be completed. (Glimmer.StreamError error 0.)".
    /// Routing `errorDescription` back to our `description` guarantees the
    /// human sentence shows up on every path, not just the ones that special-
    /// case StreamError before reading localizedDescription.
    public var errorDescription: String? { description }
}
