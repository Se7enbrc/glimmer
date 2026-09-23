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
//  The syscall probe itself (connect/getsockname/getifaddrs) runs only against
//  loopback here; real routes depend on the machine. The DECISION functions it
//  feeds are pure, and those are what this file pins.
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

    private func sdp(remote: Int32, packetSize: Int32) -> String {
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20000,
            packetSize: packetSize, streamingRemotely: remote,
            audioConfiguration: 0x00010002,
            supportedVideoFormats: 0, clientRefreshRateX100: 6000,
            colorSpace: 1, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16),
            remoteInputAesIv: [UInt8](repeating: 0, count: 16))
        let builder = SdpBuilder(
            config: config, videoPort: 47998, urlSafeAddr: "10.0.0.5",
            addrFamilyToken: "IPv4", rtspClientVersion: 14,
            negotiatedVideoFormat: 0, encryptionFeaturesEnabled: 0,
            appVersionQuad: [7, 1, 450, 0])
        return String(data: builder.build(), encoding: .utf8) ?? ""
    }

    @Test func lanSessionAdvertises1392() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_LOCAL, packetSize: 1392)
        #expect(text.contains("x-nv-video[0].packetSize:1392"))
    }

    /// The bug this whole change exists for: a resolved-remote tunnel session
    /// must advertise 1024, not the LAN 1392.
    @Test func remoteTunnelSessionAdvertises1024() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, packetSize: 1024)
        #expect(text.contains("x-nv-video[0].packetSize:1024"))
        #expect(!text.contains("x-nv-video[0].packetSize:1392"))
    }

    @Test func remoteNarrowTunnelAdvertisesMTUDerivedSize() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, packetSize: 872)
        #expect(text.contains("x-nv-video[0].packetSize:872"))
    }

    /// An unreadable MTU falls back to the flat remote size, which is what
    /// makeBackendConfig then stores.
    @Test func remoteWithoutMTUReadingStillClamps() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, packetSize: 1024)
        #expect(text.contains("x-nv-video[0].packetSize:1024"))
    }

    /// REGRESSION (shipped in 2026.7.8-rc1, purple/white HDR corruption).
    ///
    /// `packetSize` is not merely a buffer bound - it is the Reed-Solomon SHARD
    /// LENGTH the FEC reconstructor rebuilds recovered packets at
    /// (`RtpVideoQueue+Reconstruct`: `receiveSize = packetSize + MAX_RTP_HEADER_SIZE`
    /// and `length: packetSize + dataOffset`). rc1 advertised a clamped 1024 to
    /// the host while leaving the client reconstructing at 1392, so every
    /// FEC-recovered packet was rebuilt at the wrong length and fed garbage to
    /// VideoToolbox - 883 corruption events in 196s on a lossy tunnel, and zero
    /// on the previous build. A clean link never shows it, because it never
    /// exercises FEC recovery.
    ///
    /// The invariant: ONE resolved size reaches the SDP, the receive buffer, and
    /// the FEC math. `BackendStreamConfig.packetSize` IS that value, and the SDP
    /// echoes it rather than re-deriving its own.
    @Test func advertisedSizeIsExactlyTheStoredSizeUsedForFecReconstruction() {
        for size: Int32 in [512, 872, 1024, 1392] {
            let text = sdp(remote: StreamProtocol.STREAM_CFG_REMOTE, packetSize: size)
            #expect(text.contains("x-nv-video[0].packetSize:\(size)"),
                    "SDP must advertise exactly the stored packetSize \(size); any divergence corrupts every FEC-recovered frame")
        }
    }

    // MARK: - VQOS bitrate range

    private func vqosRange(remote: Int32, bitrateKbps: Int32) -> (min: Int, max: Int) {
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: bitrateKbps,
            packetSize: 1392, streamingRemotely: remote,
            audioConfiguration: 0x00010002,
            supportedVideoFormats: 0, clientRefreshRateX100: 6000,
            colorSpace: 1, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16),
            remoteInputAesIv: [UInt8](repeating: 0, count: 16))
        let builder = SdpBuilder(
            config: config, videoPort: 47998, urlSafeAddr: "10.0.0.5",
            addrFamilyToken: "IPv4", rtspClientVersion: 14,
            negotiatedVideoFormat: 0, encryptionFeaturesEnabled: 0,
            appVersionQuad: [7, 1, 450, 0])
        let text = String(data: builder.build(), encoding: .utf8) ?? ""
        func value(_ key: String) -> Int {
            guard let r = text.range(of: "\(key):") else { return -1 }
            let rest = text[r.upperBound...].prefix(while: { $0.isNumber })
            return Int(rest) ?? -1
        }
        return (value("x-nv-vqos[0].bw.minimumBitrateKbps"),
                value("x-nv-vqos[0].bw.maximumBitrateKbps"))
    }

    /// The advertised VQOS range is IDENTICAL for local and remote, and the
    /// floor keeps its original half-peak shape.
    ///
    /// An earlier revision of this branch lowered the remote floor to 5 Mbps on
    /// the theory that it gave "Sunshine's host-side VQOS room to step down".
    /// That theory is false, and was checked against Sunshine's source rather
    /// than inferred: `minimumBitrateKbps` appears ZERO times in the whole
    /// Sunshine tree, so the floor is never parsed; `cmd_announce` reads
    /// `maximumBitrateKbps` and then overwrites it with
    /// `x-ml-video.configuredBitrateKbps`; and nothing mutates the bitrate after
    /// ANNOUNCE. The encoder rate is FIXED for the session. Changing the floor
    /// was a no-op, and the field data agreed - the encoder never went near it.
    ///
    /// This test exists to stop the idea being re-introduced: if the range ever
    /// diverges by remoteness again, it is dead code dressed as a feature.
    @Test func vqosFloorRuleDoesNotVaryByRemoteness() {
        let lan = vqosRange(remote: StreamProtocol.STREAM_CFG_LOCAL, bitrateKbps: 84_000)
        let remote = vqosRange(remote: StreamProtocol.STREAM_CFG_REMOTE, bitrateKbps: 84_000)
        #expect(lan.max == 67_200)               // 84000 * 0.80
        #expect(remote.max == lan.max - 500)     // moonlight's remote headroom
        // The floor is half the peak in BOTH cases - the same rule. The two
        // numbers differ only because the remote PEAK is 500 lower, not because
        // the floor is computed differently. That is the property to protect: a
        // remoteness-dependent floor would be dead code (Sunshine never reads it).
        #expect(lan.min == lan.max / 2)
        #expect(remote.min == remote.max / 2)
        #expect(lan.min == 33_600)
        #expect(remote.min == 33_350)
    }

    /// The floor must never exceed the peak, or the advertised range inverts.
    @Test func vqosFloorNeverExceedsThePeak() {
        let range = vqosRange(remote: StreamProtocol.STREAM_CFG_REMOTE, bitrateKbps: 4_000)
        #expect(range.min <= range.max)
    }

    /// STREAM_CFG_AUTO must never reach the SDP builder as "remote" - the
    /// resolution happens at connect. If an unresolved AUTO ever leaks through,
    /// it is treated as local (the pre-existing behaviour), so this pins that
    /// the builder tests the REMOTE constant specifically and not `!= LOCAL`.
    @Test func unresolvedAutoIsTreatedAsLocalByTheBuilder() {
        let text = sdp(remote: StreamProtocol.STREAM_CFG_AUTO, packetSize: 1392)
        #expect(text.contains("x-nv-video[0].packetSize:1392"))
    }

    // MARK: - Connect-time quality gate (RTT → bitrate ceiling)

    /// A LAN keeps the full demand-based ask - the gate must be invisible there.
    @Test func lanRttKeepsFullBitrate() {
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: RttStats(samples: [1.2]))
        #expect(!path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
    }

    /// An RTT no local network produces means remote, whatever the interface
    /// looks like. Wired LAN is 0.5-2ms and LAN wifi 2-10ms; 45ms has left the
    /// building.
    @Test func highRttAloneClassifiesRemote() {
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: RttStats(samples: [45]))
        #expect(path.isRemotePath)
    }

    /// The live case: a steady ~50 ms tunnel → 0.50 → 84 becomes 42 Mbps. The
    /// host's encoder was measured delivering 37-50 Mbps on that path.
    @Test func fiftyMsTunnelHalvesTheAsk() {
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true,
                                   rtt: RttStats(samples: Array(repeating: 50, count: 6)))
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 42_000)
    }

    /// One sample is an anecdote, not a level: too few samples cap nothing.
    @Test func tooFewSamplesCapNothing() {
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true,
                                   rtt: RttStats(samples: [50, 52, 55, 60]))
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
    }

    @Test func rttBandsAreMonotonicallyStricter() {
        let bands: [(Double, Double)] = [(1, 1.00), (9.9, 1.00), (19.9, 1.00),
                                         (20, 0.75), (29, 0.75), (30, 0.50), (59, 0.50),
                                         (60, 0.35), (250, 0.35)]
        for (rtt, expected) in bands {
            #expect(StreamPathMTU.bitrateCeilingFraction(rttMs: rtt) == expected,
                    "RTT \(rtt)ms should map to \(expected)")
        }
    }

    /// An unmeasured RTT must cap NOTHING. A failed probe is "unknown", never
    /// "bad" - the same contract as the MTU clamp.
    @Test func unmeasuredRttCapsNothing() {
        #expect(StreamPathMTU.bitrateCeilingFraction(rttMs: nil) == 1.0)
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true, rtt: nil)
        // Still remote (tunnel), but with no RTT there is no basis to cap.
        #expect(path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
    }

    /// However distant the host, never ask below the floor.
    @Test func capNeverGoesBelowTheFloor() {
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true,
                                   rtt: RttStats(samples: Array(repeating: 300, count: 6)))
        let capped = StreamPathMTU.cappedBitrateKbps(configured: 20_000, path: path)
        #expect(capped == StreamPathMTU.minimumBitrateKbps)
    }

    /// The gate only ever moves DOWNWARD.
    @Test func capIsNeverAnIncrease() {
        for rtt in [0.5, 5.0, 15.0, 45.0, 120.0] {
            let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true,
                                       rtt: RttStats(samples: [rtt]))
            #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) <= 84_000)
        }
    }

    // MARK: - RTT distribution (the gate bands on the steady level, p25)

    /// A burst of bad samples (post-wake, a busy host, a Wi-Fi tail) is not a
    /// level. A quarter of the samples stuck behind a queue caps nothing.
    @Test func aMinorityOfBadSamplesCapsNothing() throws {
        let samples = Array(repeating: 8.0, count: 15) + Array(repeating: 120.0, count: 5)
        let stats = try #require(RttStats(samples: samples))
        #expect(stats.minMs == 8)
        #expect(stats.steadyMs == 8)
        #expect(stats.p95Ms == 120)
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: stats)
        #expect(!path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
        #expect(stats.tailRatio == 15)
    }

    /// The owner's example: a LAN run, three 7-second stalls, one 16. No cap.
    @Test func afewSevenSecondStallsDoNotSkewTheLevel() throws {
        let stats = try #require(RttStats(samples: [1, 2, 3, 5, 7000, 7000, 7000, 16]))
        #expect(stats.steadyMs <= 5)
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: stats)
        #expect(!path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
    }

    /// Consistently high does cap: three quarters of the samples at 45 ms.
    @Test func aConsistentlyHighLevelCaps() throws {
        let samples = Array(repeating: 8.0, count: 5) + Array(repeating: 45.0, count: 15)
        let stats = try #require(RttStats(samples: samples))
        #expect(stats.steadyMs == 45)
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: stats)
        #expect(path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 42_000)
    }

    /// The friend's-house session: launch-window samples 24-76 ms on a path the
    /// stream later measured at 10 ms. Pre-launch samples must win.
    @Test func preLaunchSamplesOutrankLaunchWindowSamples() {
        let pre = Array(repeating: 10.5, count: 12)
        let launch = [24.5, 31.0, 55.4, 60.2, 76.2]
        let chosen = RttSampler.gateSamples(pre + launch, preLaunchCount: pre.count)
        #expect(chosen == pre)
        // Too thin a pre-launch window falls back to everything.
        #expect(RttSampler.gateSamples(pre + launch, preLaunchCount: 3) == pre + launch)
        #expect(RttSampler.gateSamples(pre + launch, preLaunchCount: nil) == pre + launch)
    }

    @Test func percentilesAreOrdered() throws {
        let stats = try #require(RttStats(samples: [50, 10, 30, 20, 40]))
        #expect(stats.minMs == 10)
        #expect(stats.minMs <= stats.steadyMs)
        #expect(stats.steadyMs <= stats.p50Ms)
        #expect(stats.p50Ms <= stats.p95Ms)
        #expect(stats.count == 5)
    }

    /// A clean low-latency path has a tail that matches its floor, so nothing
    /// is capped - the do-no-harm case.
    @Test func cleanLanDistributionCapsNothing() throws {
        let stats = try #require(RttStats(samples: Array(repeating: 1.1, count: 20)))
        let path = StreamPathProbe(interfaceName: "en0", mtu: 1500, isTunnel: false, rtt: stats)
        #expect(!path.isRemotePath)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 84_000)
        #expect(stats.tailRatio == 1)
    }

    /// No samples means no knowledge - never a verdict.
    @Test func emptySampleSetYieldsNoStats() {
        #expect(RttStats(samples: []) == nil)
    }

    /// The live path measured 33-43ms across samples; whatever the draw, it must
    /// land in one band and produce a stable answer.
    @Test func measuredTunnelSpreadLandsInOneBand() {
        let stats = RttStats(samples: [33.2, 37.6, 38.1, 40.0, 42.6])
        let path = StreamPathProbe(interfaceName: "utun6", mtu: 1280, isTunnel: true, rtt: stats)
        #expect(StreamPathMTU.cappedBitrateKbps(configured: 84_000, path: path) == 42_000)
    }

    // MARK: - RTT sampling against a loopback port

    @Test func fullWindowReleasesLaunchWithoutWaitingOutTheCap() async throws {
        let port = try #require(LoopbackPort(listening: true))
        let sampler = RttSampler(host: "127.0.0.1", port: port.port)
        let start = ContinuousClock.now
        await sampler.awaitPreLaunchWindow(maxWaitMs: 10_000)
        #expect(ContinuousClock.now - start < .seconds(5))
        sampler.markLaunch()
        #expect(sampler.usesPreLaunchWindow)
        #expect((sampler.harvest()?.count ?? 0) >= RttSampler.minPreLaunchSamples)
    }

    @Test func unreachablePortWaitsOnlyToTheCap() async throws {
        let port = try #require(LoopbackPort(listening: false))
        let sampler = RttSampler(host: "127.0.0.1", port: port.port)
        let start = ContinuousClock.now
        await sampler.awaitPreLaunchWindow(maxWaitMs: 150)
        let waited = ContinuousClock.now - start
        #expect(waited >= .milliseconds(140) && waited < .seconds(5))
        #expect(sampler.harvest() == nil)
    }

    @Test func harvestReleasesAWaitingLaunch() async throws {
        let port = try #require(LoopbackPort(listening: false))
        let sampler = RttSampler(host: "127.0.0.1", port: port.port)
        let start = ContinuousClock.now
        let waiting = Task { await sampler.awaitPreLaunchWindow(maxWaitMs: 60_000) }
        try await Task.sleep(for: .milliseconds(50))
        _ = sampler.harvest()
        await waiting.value
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

/// A loopback TCP port for the RTT probes. Listening, the kernel completes each
/// handshake from the backlog with nothing accepting; bound only, it refuses.
private final class LoopbackPort {
    let fd: Int32
    let port: UInt16

    init?(listening: Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound, !listening || listen(fd, 128) == 0 else { close(fd); return nil }
        self.fd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(fd) }
}
