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

    /// True when this path should be treated as a remote/Internet session:
    /// a tunnel, or any route whose MTU is below standard Ethernet. Both mean
    /// a LAN-tuned 1392-byte video packet no longer fits.
    var isRemotePath: Bool {
        if isTunnel { return true }
        if let mtu, mtu < StreamPathMTU.standardEthernetMTU { return true }
        return false
    }
}

enum StreamPathMTU {

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

    /// The port is irrelevant to route selection (connect() on UDP only picks
    /// the egress interface), so the discard port keeps the intent obvious.
    private static let probePort: UInt16 = 9

    /// Resolve the egress interface + MTU for `host`. `host` must be an IP
    /// literal (the address RTSP already resolved); a hostname yields an empty
    /// probe rather than a blocking lookup.
    static func probe(host: String) -> StreamPathProbe {
        guard let (dest, len, family) = UdpPinger.makeSockaddr(
            for: NWEndpoint.Host(host), port: probePort) else {
            return StreamPathProbe()
        }
        guard let local = connectedLocalAddress(dest: dest, len: len, family: family),
              let name = interfaceName(matching: local) else {
            return StreamPathProbe()
        }
        return StreamPathProbe(interfaceName: name,
                               mtu: mtu(ofInterface: name),
                               isTunnel: isTunnelName(name))
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
