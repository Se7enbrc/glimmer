// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Darwin
import Foundation
import Network

enum MacStreamPath {
    static func makeSampler(host: String, port: UInt16, maxAttempts: Int = RttSampler.maxAttempts) -> RttSampler {
        RttSampler(host: host, port: port, maxAttempts: maxAttempts,
                   measure: { measureOneRttMs(host: $0, port: $1) })
    }

    /// How long to wait for the RTT probe's TCP handshake before giving up.
    /// Deliberately tight: this sits on the connect path, and an unmeasured RTT
    /// is a safe answer (it caps nothing), so waiting is worse than not knowing.
    private static let rttProbeTimeoutMs: Int32 = 400

    /// Handshakes in the reconnect burst: ~120 ms on a 40 ms path, a few ms on
    /// a LAN, against a reconnect that takes over a second.
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

    /// Reconnect fallback: no free window to sample across, so a few back-to-back
    /// handshakes, all of them. One LAN sample settles the distance gate but not
    /// the wired boost's 2 ms test, and a lone sample must not decide that.
    private static func burstRtt(host: String, port: UInt16) -> RttStats? {
        RttStats(samples: (0..<rttProbeSamples).compactMap { _ in measureOneRttMs(host: host, port: port) })
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
