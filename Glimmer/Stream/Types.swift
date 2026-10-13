// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import CoreMedia
import VideoToolbox
import os

struct StreamConfig: Sendable {
    var request: StreamRequest

    var width: Int {
        get { request.width }
        set { request.width = newValue }
    }
    var height: Int {
        get { request.height }
        set { request.height = newValue }
    }
    var fps: Int {
        get { request.fps }
        set { request.fps = newValue }
    }
    var bitrateKbps: Int {
        get { request.bitrateKbps }
        set { request.bitrateKbps = newValue }
    }
    var packetSize: Int {
        get { request.packetSize }
        set { request.packetSize = newValue }
    }
    var bitrateBoost: Double {
        get { request.bitrateBoost }
        set { request.bitrateBoost = newValue }
    }
    var bitrateDecision: BitrateDecision? {
        get { request.bitrateDecision }
        set { request.bitrateDecision = newValue }
    }
    var remoteness: Remoteness {
        get { request.remoteness }
        set { request.remoteness = newValue }
    }
    var audio: AudioConfig {
        get { request.audio }
        set { request.audio = newValue }
    }
    var videoFormats: VideoFormats {
        get { request.videoFormats }
        set { request.videoFormats = newValue }
    }
    var colorSpace: ColorSpace {
        get { request.colorSpace }
        set { request.colorSpace = newValue }
    }
    var colorRange: ColorRange {
        get { request.colorRange }
        set { request.colorRange = newValue }
    }
    var playAudioOnHost: Bool {
        get { request.playAudioOnHost }
        set { request.playAudioOnHost = newValue }
    }

    /// When true, system-level keyboard combos that use the macOS Cmd key
    /// (⌘-Tab, ⌘-Space, ⌘-Q, ⌘-`, ⌘-H, ⌘-M, ...) are forwarded to the host as
    /// VK_LWIN / VK_RWIN chords instead of being handled by macOS. Off by
    /// default - most users want ⌘-Tab to still switch macOS apps even while
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
    var captureSysKeys: Bool = false

    /// On notched MacBooks, whether the fullscreen stream window covers
    /// the entire panel (including the 37pt notch reserve zone) or stops
    /// at the safe-area boundary. Default true. See `StreamWindow.coversNotch`.
    var coversNotch: Bool = true

    /// How the stream window presents: the fullscreen cover (default) or a
    /// normal titled window the user can drag and resize. Snapshotted at
    /// session start like `coversNotch`; see `StreamDisplayMode`.
    var displayMode: StreamDisplayMode = .fullScreen

    /// Title for the Window-mode window ("Tower - Desktop"). Unused in full
    /// screen (a borderless cover has no title bar).
    var windowTitle: String = ""

    init(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        request = StreamRequest(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps,
                                videoFormats: .probedSupported)
    }
}

extension VideoFormats {
    /// Build the client-supported codec mask from probed VideoToolbox
    /// capabilities, NOT from a hardcoded "we support everything" set.
    /// Negotiating against a fictional capability set is the standing
    /// "host sends us AV1 we can't decode" bug on Intel Macs (no AV1 HW
    /// decode) - the host accepted the AV1 bit, started encoding AV1, and
    /// VTDecompressionSessionCreate immediately failed, killing the
    /// session. Probing up front means the host never picks a format we
    /// can't handle.
    ///
    /// Apple Silicon (M3+ on Mac) supports the full {AV1 Main8/Main10,
    /// HEVC Main/Main10, H.264 High} matrix. Intel + earlier M-series lack
    /// AV1 HW decode and fall back to {HEVC Main/Main10, H.264 High}. The
    /// probe is the source of truth - anything Apple ships in a future
    /// chip generation lights up automatically without a code change.
    static let probedSupported: VideoFormats = probeSupported()

    private static func probeSupported() -> VideoFormats {
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Capabilities")
        var out: VideoFormats = []
        // H.264 baseline: every Mac since 2008 has HW H.264 decode.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
            out.insert(.h264)
        } else {
            log.warning("VT reports no HW H.264 decode - this Mac is unsupported")
        }
        // 4:4:4 chroma is a separate decode capability from 4:2:0: the HEVC
        // Range Extensions (RExt) and AV1 High 4:4:4 profiles need the wider
        // chroma path, which Apple's VT only exposes on Apple Silicon SoCs -
        // Intel Macs (and the rare pre-Apple-Silicon HEVC SoC) decode 4:2:0
        // only and would CHOKE on a 4:4:4 bitstream the host happily encoded.
        // VTIsHardwareDecodeSupported returns a single per-codec bit and does
        // NOT distinguish 4:2:0 from 4:4:4, so we gate 4:4:4 advertisement on
        // "this is Apple Silicon" on TOP of the per-codec HW probe. Older Macs
        // never advertise 4:4:4 and the host falls back to 4:2:0 cleanly.
        let appleSilicon = isAppleSilicon()
        // HEVC Main / Main10: SoC HEVC decoder on Macs since ~2017.
        // Apple's VTIsHardwareDecodeSupported doesn't distinguish Main8 from
        // Main10 - the same VT capability covers both. We advertise Main10
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
        log.info("""
            VT capability probe: H264=\(h264, privacy: .public) HEVC=\(hevc, privacy: .public) \
            HEVCMain10=\(hevcM10, privacy: .public) HEVC444=\(hevc444, privacy: .public) AV1=\(av1, privacy: .public) \
            AV1Main10=\(av1M10, privacy: .public) AV1_444=\(av1444, privacy: .public) raw=0x\(raw, privacy: .public)
            """)
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
