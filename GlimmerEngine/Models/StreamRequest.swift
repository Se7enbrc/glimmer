// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct StreamRequest: Sendable {
    package var width: Int
    package var height: Int
    package var fps: Int
    package var bitrateKbps: Int
    /// Video packet size on the wire (UDP payload, before FEC framing).
    /// moonlight-common-c documents the default as "use 1024 if unsure" but
    /// that's a conservative remote-streaming value - on a LAN where MTU is
    /// 1500 we can pack ~30% more video data into each packet, which
    /// measurably reduces jitter (fewer fragments per frame, fewer reassembly
    /// stalls under RTT variance). moonlight-qt ships 1392 as the LAN
    /// default; 1392 + UDP/IP headers (28) + the small moonlight framing
    /// overhead lands well below 1500 with headroom for VPN encapsulation.
    /// On a REMOTE session the SDP builder clamps the value it ADVERTISES to
    /// the host back to 1024 (`SdpBuilder.build`, the `streamingRemotely`
    /// branch) so a full RTP packet fits inside common VPN path MTUs
    /// (WireGuard/Tailscale ~1280-1420) after tunnel encapsulation - mirroring
    /// moonlight-common-c's STREAM_CFG_AUTO Internet cap, which this Swift port
    /// applies at SDP-build time rather than mutating this field. This stored
    /// value is the LAN default and is unchanged; only the advertised number is
    /// clamped, and only when remote.
    package var packetSize: Int = 1392
    /// The wired boost folded into `bitrateKbps` (1 = none), so the connect-time
    /// gate can withdraw it when the measured path says a Wi-Fi hop is present.
    package var bitrateBoost: Double = 1
    /// How `bitrateKbps` was chosen, for the telemetry config event only.
    package var bitrateDecision: BitrateDecision?
    package var remoteness: Remoteness = .auto
    /// Keep a surround bed available when outputs change during a stream.
    /// The Mac renders it for the active speakers or headphones.
    package var audio: AudioConfig = .surround71
    /// The caller supplies the hardware-probed mask so negotiation never advertises
    /// a codec this device cannot decode; preferences may narrow that mask.
    package var videoFormats: VideoFormats
    package var colorSpace: ColorSpace = .rec709
    package var colorRange: ColorRange = .full
    /// Moonlight's "play audio on host PC": the PC keeps its own sound and
    /// this Mac silences the stream (not the system volume).
    package var playAudioOnHost: Bool = false

    package init(width: Int, height: Int, fps: Int, bitrateKbps: Int, videoFormats: VideoFormats) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.videoFormats = videoFormats
    }
}
