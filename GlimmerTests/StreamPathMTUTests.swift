//
//  StreamPathMTUTests.swift
//
//  Coverage for the connect-time path clamp that decides the video packet size
//  we ADVERTISE to the host. The regression under test: `StreamConfig.remoteness`
//  defaults to `.auto` (STREAM_CFG_AUTO = 2), so SdpBuilder's `== 1` remote check
//  never fired and every session - including one routed over a 1280-MTU
//  Tailscale/WireGuard tunnel - advertised the 1392-byte LAN packet size, which
//  IP-fragments on that path and multiplies pre-FEC loss.
//
//  The syscall probe itself (connect/getsockname/getifaddrs) is not unit-tested -
//  it depends on the machine's live route table. The DECISION functions it feeds
//  are pure, and those are what this file pins.
//

import Foundation
import Testing
@testable import Glimmer

struct StreamPathMTUTests {

    // MARK: - isRemotePath classification

    @Test func tunnelInterfaceIsRemote() {
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true)
        #expect(path.isRemotePath)
    }

    @Test func fullMTUEthernetIsLocal() {
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false)
        #expect(!path.isRemotePath)
    }

    /// A reduced-MTU route is remote even when the interface isn't named like a
    /// tunnel - the packet-size consequence is identical.
    @Test func reducedMTUIsRemoteEvenWhenNotTunnelNamed() {
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1400, isTunnel: false)
        #expect(path.isRemotePath)
    }

    /// A failed probe knows nothing and must NOT claim remote - the caller keeps
    /// the configured size rather than clamping on a guess.
    @Test func emptyProbeIsNotRemote() {
        #expect(!StreamPathProbe().isRemotePath)
    }

    // MARK: - advertisedPacketSize

    /// Do no harm: a LAN session advertises exactly what was configured.
    @Test func localPathKeepsConfiguredSize() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 1392, isRemote: false, mtu: 1500)
        #expect(size == 1392)
    }

    /// Remote with an unreadable MTU falls back to moonlight's Internet size.
    @Test func remoteWithUnknownMTUUsesMoonlightRemoteSize() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 1392, isRemote: true, mtu: nil)
        #expect(size == StreamPathMTU.remotePacketSize)
        #expect(size == 1024)
    }

    /// The live case: Tailscale's default 1280 MTU. 1280 - 128 budget = 1152, so
    /// the flat 1024 remote size is the binding clamp and a full datagram fits.
    @Test func tailscale1280MTUClampsTo1024() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 1392, isRemote: true, mtu: 1280)
        #expect(size == 1024)
        #expect(size + StreamPathMTU.datagramOverheadBudget <= 1280)
    }

    /// A narrower tunnel than 1024+overhead must clamp BELOW the flat remote
    /// size - this machine has utun interfaces at MTU 1000, so it is not
    /// hypothetical.
    @Test func narrowTunnelClampsBelowRemoteSize() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 1392, isRemote: true, mtu: 1000)
        #expect(size == 1000 - StreamPathMTU.datagramOverheadBudget)
        #expect(size == 872)
        #expect(size + StreamPathMTU.datagramOverheadBudget <= 1000)
    }

    /// However narrow the path, never advertise below the floor.
    @Test func pathologicallyNarrowPathHitsTheFloor() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 1392, isRemote: true, mtu: 400)
        #expect(size == StreamPathMTU.minimumPacketSize)
    }

    /// The clamp only ever moves DOWNWARD - a configured size already below the
    /// remote ceiling is never inflated.
    @Test func clampNeverRaisesAConfiguredSize() {
        let size = StreamPathMTU.advertisedPacketSize(
            configured: 800, isRemote: true, mtu: 1500)
        #expect(size == 800)
    }

    // MARK: - SdpBuilder integration (the attribute actually put on the wire)

    private func sdp(remote: Int32, pathMTU: Int32, packetSize: Int32 = 1392) -> String {
        var config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20000,
            packetSize: packetSize, streamingRemotely: remote,
            audioConfiguration: 0x00010002,
            supportedVideoFormats: 0, clientRefreshRateX100: 6000,
            colorSpace: 1, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16),
            remoteInputAesIv: [UInt8](repeating: 0, count: 16))
        config.pathMTU = pathMTU
        let builder = SdpBuilder(
            config: config, videoPort: 47998, urlSafeAddr: "10.0.0.5",
            addrFamilyToken: "IPv4", rtspClientVersion: 14,
            negotiatedVideoFormat: 0, encryptionFeaturesEnabled: 0,
            appVersionQuad: [7, 1, 450, 0])
        return String(data: builder.build(), encoding: .utf8) ?? ""
    }

    @Test func lanSessionAdvertises1392() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_LOCAL, pathMTU: 1500)
        #expect(text.contains("x-nv-video[0].packetSize:1392"))
    }

    /// The bug this whole change exists for: a resolved-remote tunnel session
    /// must advertise 1024, not the LAN 1392.
    @Test func remoteTunnelSessionAdvertises1024() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, pathMTU: 1280)
        #expect(text.contains("x-nv-video[0].packetSize:1024"))
        #expect(!text.contains("x-nv-video[0].packetSize:1392"))
    }

    @Test func remoteNarrowTunnelAdvertisesMTUDerivedSize() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, pathMTU: 1000)
        #expect(text.contains("x-nv-video[0].packetSize:872"))
    }

    /// pathMTU == 0 means the probe could not read an MTU; the flat remote size
    /// still applies.
    @Test func remoteWithoutMTUReadingStillClamps() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, pathMTU: 0)
        #expect(text.contains("x-nv-video[0].packetSize:1024"))
    }

    /// STREAM_CFG_AUTO must never reach the SDP builder as "remote" - the
    /// resolution happens at connect. If an unresolved AUTO ever leaks through,
    /// it is treated as local (the pre-existing behaviour), so this pins that
    /// the builder tests the REMOTE constant specifically and not `!= LOCAL`.
    @Test func unresolvedAutoIsTreatedAsLocalByTheBuilder() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_AUTO, pathMTU: 1280)
        #expect(text.contains("x-nv-video[0].packetSize:1392"))
    }
}
