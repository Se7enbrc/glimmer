//
//  StreamPathMTU.swift
//
//  CONNECT-TIME PATH PROBE for the video packet-size decision.
//
//  WHY THIS EXISTS: `StreamConfig.packetSize` ships the moonlight-qt LAN default
//  (1392), and `SdpBuilder.build` was written to clamp the ADVERTISED size back
//  to 1024 on a remote session so a full RTP datagram fits inside common VPN
//  path MTUs. That clamp was dead code: it tests `streamingRemotely == 1`
//  (STREAM_CFG_REMOTE) but `StreamConfig.remoteness` defaults to `.auto`
//  (STREAM_CFG_AUTO = 2) and nothing ever resolved it, so EVERY session - LAN or
//  tunnelled - advertised 1392. On a 1280-MTU tunnel (Tailscale/WireGuard
//  default) 1392 + RTP/UDP/IP + tunnel encapsulation overruns the path, so every
//  video packet is IP-fragmented: lose either fragment and the whole packet is
//  gone, which multiplies the pre-FEC loss rate the host's fixed parity then has
//  to absorb. This probe resolves `.auto` from the actual egress route so the
//  clamp fires where it was always meant to.
//
//  HOW: the same throwaway connected-UDP-socket trick `StreamRouteProbe` uses
//  for `stream_link` - connect() on UDP sends NOTHING, it only asks the kernel
//  to bind a route - then getsockname() for the kernel-chosen local address and
//  getifaddrs() for the interface that owns it. The AF_LINK entry for that same
//  interface carries `if_data.ifi_mtu`, so the MTU comes from the one walk we
//  already do. No DNS (the address is the IP literal RTSP already resolved), no
//  ioctl, no privileged call.
//
//  DELIBERATELY NOT `StreamRouteProbe`: that probe is telemetry-gated (built
//  only by the exporter), runs on its own queue, and re-probes for the life of
//  the session. This one is a single always-live syscall burst at the connect
//  edge, because the packet-size decision is a PROTOCOL decision that has to be
//  made before the SDP is built - it has to work with telemetry off.
//
//  DO NO HARM: a full-MTU (>=1500) non-tunnel route resolves to `.local` and
//  every advertised value is byte-identical to before. Only a tunnelled or
//  reduced-MTU path changes, and only ever downward.
//

import Darwin
import Foundation
import Network

/// One-shot connect-time probe of the route to the host: which interface the
/// stream's UDP will egress on, that interface's MTU, and whether it is a
/// tunnel. All fields are `nil`/`false` when the probe cannot answer - absent
/// knowledge stays absent and the caller falls back to the configured value,
/// never a guess.
struct StreamPathProbe: Sendable {
    /// BSD interface name the route resolved to ("en0", "utun6"), nil on failure.
    var interfaceName: String?
    /// The egress interface's MTU in bytes, nil when unreadable.
    var mtu: Int?
    /// utun*/ipsec*/ppp* - the kernel routed us through a tunnel.
    var isTunnel: Bool = false
    /// Latency distribution to the host, from TCP handshakes (SYN → SYN-ACK is
    /// exactly one RTT). nil when unmeasured or unreachable.
    var rtt: RttStats?

    /// The single number the gate bands on: the STEADY level (p25). See RttStats.
    var rttMs: Double? { rtt?.steadyMs }

    /// True when this path should be treated as a remote/Internet session:
    /// a tunnel, a route whose MTU is below standard Ethernet, or an RTT no
    /// local network produces. Any of the three means a LAN-tuned 1392-byte
    /// video packet no longer fits and a LAN-tuned bitrate is not defensible.
    var isRemotePath: Bool {
        if isTunnel { return true }
        if let mtu, mtu < StreamPathMTU.standardEthernetMTU { return true }
        if let rttMs, rttMs >= StreamPathMTU.localRttCeilingMs { return true }
        return false
    }
}

/// A latency distribution measured before ANNOUNCE. The gate bands on `steadyMs`
/// (p25): three quarters of the samples sit at or above it, so a burst of bad
/// samples (post-wake, a busy host, Wi-Fi tail) cannot cap a path by itself.
struct RttStats: Sendable, Equatable {
    var minMs: Double
    var steadyMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var count: Int

    /// Nil for an empty sample set - absent knowledge stays absent.
    init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func percentile(_ quantile: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * quantile).rounded())
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        minMs = sorted[0]
        steadyMs = percentile(0.25)
        p50Ms = percentile(0.50)
        p95Ms = percentile(0.95)
        count = sorted.count
    }

    /// How much worse the tail is than the floor. >2x on a path whose floor is
    /// already high is the bufferbloat signature.
    var tailRatio: Double { minMs > 0 ? p95Ms / minMs : 1 }
}

/// Samples RTT on a background queue from the Play click until the SDP is built.
/// Samples taken before `/launch` are the ones that count: once the host starts
/// the game and switches displays, handshakes read 3-7x the path's true RTT.
///
/// THREADING: `start`/`harvest` are called from the session actor; the sampling
/// loop owns its own queue and the sample array is lock-guarded.
final class RttSampler: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "io.ugfugl.Glimmer.rttSampler", qos: .userInitiated)
    private let lock = NSLock()
    private var samples: [Double] = []
    private var stopped = false
    /// Sample count when `markLaunch()` was called; nil until then.
    private var preLaunchCount: Int?

    /// Gap between handshakes. Fast enough to fill the pre-launch window on a
    /// quiet host without hammering its web port.
    private static let intervalMs: UInt32 = 30
    /// Hard cap so a pathologically slow launch can't sample forever.
    private static let maxSamples = 80
    /// Pre-launch samples needed before the launch-window ones are ignored.
    static let minPreLaunchSamples = 8

    /// Starts sampling immediately - there is no useful window between
    /// construction and the first sample, and the loop captures self WEAKLY, so
    /// the sampler going out of scope (an early throw on the connect path) ends
    /// it on the next iteration without any explicit teardown.
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        start()
    }

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                lock.lock()
                let done = stopped || samples.count >= Self.maxSamples
                lock.unlock()
                if done { return }
                if let sample = StreamPathMTU.measureOneRttMs(host: host, port: port) {
                    lock.lock(); samples.append(sample); lock.unlock()
                }
                usleep(Self.intervalMs * 1000)
            }
        }
    }

    /// Wait until the pre-launch window holds `minSamples`, or `maxWaitMs` has
    /// passed. Called on the connect path right before `/launch`.
    func awaitPreLaunchWindow(minSamples: Int = RttSampler.minPreLaunchSamples,
                              maxWaitMs: Int = 400) async {
        let deadline = DispatchTime.now() + .milliseconds(maxWaitMs)
        while DispatchTime.now() < deadline {
            if windowIsReady(minSamples: minSamples) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func windowIsReady(minSamples: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.count >= minSamples || stopped
    }

    /// Freeze the pre-launch boundary: everything sampled after this rides the
    /// host's game launch and is kept for diagnosis only.
    func markLaunch() {
        lock.lock(); preLaunchCount = samples.count; lock.unlock()
    }

    /// Stop sampling and return the distribution the gate should band on: the
    /// pre-launch samples when there are enough, else everything (nil if the
    /// probe never succeeded - e.g. a host that refuses the port).
    func harvest() -> RttStats? {
        lock.lock()
        stopped = true
        let collected = samples
        let boundary = preLaunchCount
        lock.unlock()
        return RttStats(samples: Self.gateSamples(collected, preLaunchCount: boundary))
    }

    /// The samples the gate bands on: the pre-launch prefix when it is big
    /// enough to stand alone, else everything.
    static func gateSamples(_ samples: [Double], preLaunchCount: Int?) -> [Double] {
        if let preLaunchCount, preLaunchCount >= minPreLaunchSamples {
            return Array(samples.prefix(preLaunchCount))
        }
        return samples
    }

    /// True when `harvest()` will band on pre-launch samples only.
    var usesPreLaunchWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return (preLaunchCount ?? 0) >= Self.minPreLaunchSamples
    }
}

/// What the connect-time gate actually decided, latched for the telemetry
/// exporter. This exists because the per-session diagnostic log
/// (`glimmer-<ts>.log`) does not begin capturing until the backend starts
/// connecting - every `Diag` line emitted while the config is still being built,
/// including this gate's and the pre-existing "Stream config:" line, lands in a
/// blind spot. The gate now silently changes picture quality, so leaving its
/// decision unrecorded in the durable artifact is not acceptable: it cost an
/// hour of "did it even fire?" the first time.
struct LinkGateDecision: Sendable {
    var interfaceName: String?
    var mtu: Int?
    var isTunnel: Bool
    var rtt: RttStats?
    /// Whether `rtt` is the pre-launch window (true) or every sample (false).
    var rttPreLaunch: Bool = false
    var configuredBitrateKbps: Int
    var askedBitrateKbps: Int
    var packetSize: Int
}

enum StreamPathMTU {

    // MARK: - Gate decision latch (see LinkGateDecision)

    nonisolated(unsafe) private static var latchedGate: LinkGateDecision?
    private static let gateLock = NSLock()

    /// Latch the decision at the connect edge, BEFORE the exporter exists.
    /// One writer, at a rare lifecycle edge - the `StreamRouteProbe.latchHost`
    /// discipline.
    static func latchGateDecision(_ decision: LinkGateDecision) {
        gateLock.lock(); latchedGate = decision; gateLock.unlock()
    }

    /// The decision for the session being connected, read once by the exporter's
    /// config-event writer. nil before the first connect this process run.
    static var currentGateDecision: LinkGateDecision? {
        gateLock.lock(); defer { gateLock.unlock() }
        return latchedGate
    }

    /// Standard Ethernet MTU. At or above this on a non-tunnel interface we are
    /// on a LAN and the configured (1392) packet size stands.
    static let standardEthernetMTU = 1500

    /// Per-datagram bytes that ride ABOVE the advertised video packet payload,
    /// budgeted worst-case so the clamp can never under-count:
    ///   IPv6 header 40 (IPv4 is 20) + UDP 8 + RTP 12-16 + the NV video packet
    ///   header + AES-GCM tag/IV when video encryption is on (encryption
    ///   defaults to `.all`), plus slack for a second encapsulation.
    /// Deliberately generous - overshooting costs a few bytes of payload per
    /// packet; undershooting costs a fragmented packet, which is the bug.
    static let datagramOverheadBudget = 128

    /// moonlight-common-c's Internet packet size, and the value `SdpBuilder`
    /// already documented as the remote clamp. Proven on real WAN paths.
    static let remotePacketSize = 1024

    /// Never advertise a payload smaller than this, however small the probed
    /// MTU: below it the per-packet header overhead dominates and the host's
    /// FEC blocks get pathological. A path this narrow cannot carry a stream
    /// well regardless, and the honest failure is a bad stream, not a
    /// misconfigured one.
    static let minimumPacketSize = 512

    /// Above this steady RTT we are not on a local network, whatever the
    /// interface says (wired 0.5-2 ms, LAN wifi 2-10 ms). Classifies the path for
    /// packet size and downshift eligibility; the bitrate bands start at 20.
    static let localRttCeilingMs: Double = 10

    /// Steady RTT → fraction of the demand-based bitrate we ASK for. A risk
    /// prior, not a capacity measurement: loss costs more at distance (an IDR
    /// round trip scales with RTT). Field anchor: a 35 ms tunnel → 0.50 → 42 Mbps.
    static func bitrateCeilingFraction(rttMs: Double?) -> Double {
        guard let rttMs else { return 1.0 }      // unmeasured: change nothing
        switch rttMs {
        case ..<fullRateRttCeilingMs: return 1.00  // LAN or metro fiber
        case ..<30:                   return 0.75  // good VPN
        case ..<60:                   return 0.50  // regional
        default:                      return 0.35  // distant
        }
    }

    /// Below this steady RTT the full demand-based ask stands. A 10-20 ms path is
    /// remote for packet-size purposes (see `localRttCeilingMs`) but is metro
    /// fiber, and distance alone is no reason to trim it.
    static let fullRateRttCeilingMs: Double = 20

    /// Steady RTT at or above this means a Wi-Fi hop is somewhere on the path
    /// (wired end to end reads 0.5-2 ms); the wired bitrate boost assumes none.
    static let wiredRttCeilingMs: Double = 2

    /// The share of the Wi-Fi PHY rate the ask may reach: real UDP throughput
    /// runs near 60% of PHY, and bursts and other traffic need the rest.
    static let wifiPhyRateFraction = 0.35

    /// Cap the ask by the radio's median PHY rate on a Wi-Fi route. Unknown
    /// rate (not Wi-Fi, no samples yet) changes nothing.
    static func wifiAskKbps(ask: Int, phyRateMbps: Double?) -> Int {
        guard let phyRateMbps, phyRateMbps > 0 else { return ask }
        return max(5_000, min(ask, Int((phyRateMbps * wifiPhyRateFraction * 1000).rounded())))
    }

    /// The launcher's wired ask carries `boost`; the measured path confirms or
    /// withdraws it. Unmeasured keeps it: the Mac's own route is the best guess.
    static func wiredAskKbps(capped: Int, boost: Double, steadyRttMs: Double?) -> Int {
        guard boost > 1, let steadyRttMs, steadyRttMs >= wiredRttCeilingMs else { return capped }
        return Int((Double(capped) / boost).rounded())
    }

    /// Fewer samples than this cannot cap: "consistently high" needs a sample.
    static let minGateSamples = 5

    /// The bitrate to ASK FOR, given the configured (demand-based) value and the
    /// probed path. A local path returns `configured` untouched.
    static func cappedBitrateKbps(configured: Int, path: StreamPathProbe) -> Int {
        guard path.isRemotePath else { return configured }
        guard (path.rtt?.count ?? 0) >= minGateSamples else { return configured }
        let fraction = bitrateCeilingFraction(rttMs: path.rttMs)
        guard fraction < 1.0 else { return configured }
        return max(minimumBitrateKbps, Int((Double(configured) * fraction).rounded()))
    }

    /// Never ask for less than this however distant the host - below it the
    /// stream is not worth starting, and the honest outcome is a bad stream the
    /// user can see rather than a silently crippled one.
    static let minimumBitrateKbps = 10_000

    /// How long to wait for the RTT probe's TCP handshake before giving up.
    /// Deliberately tight: this sits on the connect path, and an unmeasured RTT
    /// is a safe answer (it caps nothing), so waiting is worse than not knowing.
    private static let rttProbeTimeoutMs: Int32 = 400

    /// How many handshakes to sample before taking the minimum. Three costs
    /// ~120 ms on a 40 ms path - about 4% of the measured 3.0 s click-to-first-
    /// frame - and a LAN exits after the first (see `sampledRttMs`).
    private static let rttProbeSamples = 3

    /// The port is irrelevant to route selection (connect() on UDP only picks
    /// the egress interface), so the discard port keeps the intent obvious.
    private static let probePort: UInt16 = 9

    /// Resolve the egress interface, MTU and RTT for `host`. `host` must be an
    /// IP literal (the address RTSP already resolved); a hostname yields an
    /// empty probe rather than a blocking lookup. `rttPort` is a TCP port the
    /// host is known to be listening on (the RTSP port) - the handshake to it
    /// is the RTT sample and nothing is ever sent on the connection.
    static func probe(host: String, rttPort: UInt16? = nil,
                      rtt preCollected: RttStats? = nil) -> StreamPathProbe {
        guard let (dest, len, family) = UdpPinger.makeSockaddr(
            for: NWEndpoint.Host(host), port: probePort) else {
            return StreamPathProbe()
        }
        guard let local = connectedLocalAddress(dest: dest, len: len, family: family),
              let name = interfaceName(matching: local) else {
            return StreamPathProbe()
        }
        // Prefer the distribution the pre-connect sampler already gathered on
        // wall-clock we were spending anyway. Only fall back to a synchronous
        // burst when there is none (the reconnect path, which has no free
        // window to sample across).
        let rtt = preCollected ?? rttPort.flatMap { burstRtt(host: host, port: $0) }
        return StreamPathProbe(interfaceName: name,
                               mtu: mtu(ofInterface: name),
                               isTunnel: isTunnelName(name),
                               rtt: rtt)
    }

    /// SYNCHRONOUS fallback for the reconnect path, which has no pre-connect
    /// window to sample across. A handful of back-to-back handshakes - enough to
    /// place the band, not enough for a real p95, which is precisely why the
    /// primary path uses `RttSampler` over the free wall-clock instead.
    ///
    /// EARLY EXIT: if the first sample is already under the local ceiling we are
    /// on a LAN, the gate will cap nothing, and further samples cannot change
    /// that - so a local session pays exactly one ~1 ms handshake.
    private static func burstRtt(host: String, port: UInt16) -> RttStats? {
        var samples: [Double] = []
        for _ in 0..<rttProbeSamples {
            guard let sample = measureOneRttMs(host: host, port: port) else { continue }
            samples.append(sample)
            if sample < localRttCeilingMs { break }   // LAN - no cap possible
        }
        return RttStats(samples: samples)
    }

    /// One TCP handshake, timed. SYN → SYN-ACK is exactly one round trip, with
    /// no TLS and no application bytes on top, so it is the cleanest RTT sample
    /// available before ANNOUNCE - unlike timing an HTTPS request, which folds
    /// in the TLS handshake's extra round trips and the host's own think time.
    ///
    /// The socket is closed immediately; no data is ever written. A failure or
    /// timeout returns nil, which the caller treats as "unknown" and caps
    /// nothing - never as "bad".
    static func measureOneRttMs(host: String, port: UInt16) -> Double? {
        guard let (dest, len, family) = UdpPinger.makeSockaddr(
            for: NWEndpoint.Host(host), port: port) else { return nil }
        var destCopy = dest
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Non-blocking connect + poll, so a black-holed path costs the timeout
        // rather than the kernel's multi-second SYN retry schedule.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        let rc = withUnsafePointer(to: &destCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, rttProbeTimeoutMs) == 1 else { return nil }
            // POLLOUT alone isn't success - a refused connection also wakes the
            // poll. Ask the socket for its error before trusting the timing.
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0,
                  soError == 0 else { return nil }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        return Double(elapsed) / 1_000_000.0
    }

    /// What we should ADVERTISE to the host given the configured size, whether
    /// the session resolved to remote, and the probed egress MTU (nil when
    /// unreadable). Returns `configured` unchanged on a LAN; on a remote path
    /// clamps to the moonlight remote size and, if the probed MTU is narrower
    /// still, to what that MTU can actually carry unfragmented.
    static func advertisedPacketSize(
        configured: Int, isRemote: Bool, mtu: Int?
    ) -> Int {
        guard isRemote else { return configured }
        var size = min(configured, remotePacketSize)
        if let mtu {
            size = min(size, mtu - datagramOverheadBudget)
        }
        return max(minimumPacketSize, size)
    }

    // MARK: - Syscall plumbing

    /// connect() a throwaway UDP socket (sends nothing) → getsockname() for the
    /// local address the kernel picked for this destination.
    private static func connectedLocalAddress(
        dest: sockaddr_storage, len: socklen_t, family: Int32
    ) -> sockaddr_storage? {
        var destCopy = dest
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &destCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len) == 0
            }
        }
        // EHOSTUNREACH/ENETDOWN here is itself signal: there is no route to the
        // host right now. Honest answer is "unknown", so the caller keeps the
        // configured size rather than clamping on a guess.
        guard connected else { return nil }
        var local = sockaddr_storage()
        var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &localLen) == 0
            }
        }
        return got ? local : nil
    }

    /// Walk getifaddrs for the interface owning `local`'s address.
    private static func interfaceName(matching local: sockaddr_storage) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == local.ss_family,
                  sameAddress(addr, local) else { continue }
            return String(cString: ifa.pointee.ifa_name)
        }
        return nil
    }

    /// The MTU lives on the interface's AF_LINK entry (`if_data.ifi_mtu`), a
    /// second pass over the same list the name match walked.
    private static func mtu(ofInterface name: String) -> Int? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name,
                  let addr = ifa.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_LINK,
                  let data = ifa.pointee.ifa_data else { continue }
            let mtu = data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu
            return mtu > 0 ? Int(mtu) : nil
        }
        return nil
    }

    /// Compare the address bytes of one getifaddrs entry against the probed
    /// local address. Raw byte offsets (sin_addr at +4, sin6_addr at +8) avoid
    /// re-binding the C structs just to read 4/16 bytes. Mirrors
    /// `StreamRouteProbe.sameAddress`.
    private static func sameAddress(_ ifaceAddr: UnsafePointer<sockaddr>,
                                    _ local: sockaddr_storage) -> Bool {
        var localCopy = local
        return withUnsafeBytes(of: &localCopy) { localRaw -> Bool in
            guard let localBase = localRaw.baseAddress else { return false }
            let ifaceRaw = UnsafeRawPointer(ifaceAddr)
            switch Int32(local.ss_family) {
            case AF_INET:
                return memcmp(ifaceRaw + 4, localBase + 4, 4) == 0
            case AF_INET6:
                return memcmp(ifaceRaw + 8, localBase + 8, 16) == 0
            default:
                return false
            }
        }
    }

    /// Same tunnel prefixes `StreamRouteProbe.classify` treats as "tunnel".
    private static func isTunnelName(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }
}
