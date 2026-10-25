// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
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
    /// Keep the Mac's existing 4:4:4 policy separate from the shared 4:2:0 hardware probe.
    static let probedSupported: VideoFormats = {
        var formats = VideoFormats.hardwareSupported
        if isAppleSilicon() {
            if formats.contains(.hevc) { formats.formUnion([.hevcRext8_444, .hevcRext10_444]) }
            if formats.contains(.av1) { formats.formUnion([.av1High8_444, .av1High10_444]) }
        }
        logSupported(formats)
        return formats
    }()

    private static func logSupported(_ formats: VideoFormats) {
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Capabilities")
        let h264 = formats.contains(.h264)
        let hevc = formats.contains(.hevc)
        let hevcM10 = formats.contains(.hevcMain10)
        let hevc444 = formats.contains(.hevcRext10_444)
        let av1 = formats.contains(.av1)
        let av1M10 = formats.contains(.av1Main10)
        let av1444 = formats.contains(.av1High10_444)
        let raw = String(formats.rawValue, radix: 16)
        log.info("""
            VT capability probe: H264=\(h264, privacy: .public) HEVC=\(hevc, privacy: .public) \
            HEVCMain10=\(hevcM10, privacy: .public) HEVC444=\(hevc444, privacy: .public) AV1=\(av1, privacy: .public) \
            AV1Main10=\(av1M10, privacy: .public) AV1_444=\(av1444, privacy: .public) raw=0x\(raw, privacy: .public)
            """)
    }

    /// Preserve the Mac policy's runtime architecture check, including its conservative failure path.
    private static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return ok && value == 1
    }
}
