//
//  UdpPinger.swift
//
//  The UDP ping plumbing VideoRtpReceiver and RtpAudioReceiver share: the keepalive cadences, the SS_PING
//  datagram, IP-literal host resolution and the sockaddr builder. Each receiver pings from its own socket.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//

import Foundation
import Network
import Darwin

enum UdpPinger {
    struct SendFailureStreak {
        enum Edge: Equatable {
            case failed
            case recovered(Int)
        }

        private(set) var failures = 0

        mutating func note(sent: Int) -> Edge? {
            guard sent < 0 else {
                guard failures > 0 else { return nil }
                defer { failures = 0 }
                return .recovered(failures)
            }
            failures += 1
            return failures == 1 ? .failed : nil
        }
    }

    // STEADY-STATE stream-time keepalive cadence: 500ms -> 75ms, a deliberate
    // client-only deviation from upstream (moonlight-common-c pings every
    // 500ms) to defeat Wi-Fi NIC power-save doze.
    //
    // WHY: a Wi-Fi NIC can show routine ~40-110ms INBOUND delivery gaps
    // (measured packet_gap_max_us in the tens of ms, p99 ~100ms, on a large
    // fraction of active seconds) that are demonstrably absent while input
    // traffic flows (the blip probability drops sharply as input rate rises) -
    // a NIC power-save signature, proven radio-level by appearing
    // simultaneously on the video, audio, and ENet sockets. A denser UPLINK
    // keepalive holds the radio out of its sleep window the same way input
    // traffic demonstrably does.
    //
    // VERDICT: KEEP - validated on an input-idle wifi route against a
    // 500ms-cadence baseline (judged by packet_gap_p95/max percentiles): the
    // idle doze tail >100ms was eliminated and length-matched P(gap>50ms) fell
    // several-fold. A PHY confound was rebutted (signal strength was no better
    // on the validating run, so the improvement is not radio conditions). Do
    // not "clean up" this constant back to 0.5 without re-running that
    // comparison.
    // REFINEMENT SHIPPED (not a revert): the cadence is now CONDITIONAL -
    // the live loops gate each send on EnvSignalController.steadyPingInterval()
    // (75ms only on a wifi stream route while input-idle or under link
    // caution; `relaxedPingIntervalSeconds` on a confirmed-wired route or
    // during active-input CLEAR wifi play, where input traffic itself holds
    // the radio awake). Unknown/tunnel/stale routes FAIL TOWARD 75ms, so the
    // countermeasure is never lost to missing route truth, and a wrong relax
    // self-corrects: the gaps it would cause are the co-gap evidence that
    // escalates the env state and re-tightens the cadence. Judged from the
    // pings_sent_*_total counters + keepalive_interval_ms in the telemetry.
    //
    // COST: ~13.3 tiny 20-byte datagrams/s of uplink per ping loop (~270 B/s,
    // up from 2/s - ~11/s extra each; ~27/s ≈ ~540 B/s total on the wire
    // across the two adopting loops) - negligible airtime. Protocol-safe:
    // Sunshine only times the session out when pings STOP (ping_timeout,
    // default 10s - verified in Sunshine src/config.cpp); a denser cadence is
    // just read and discarded.
    // STREAM-TIME cadence ONLY: connect-time fast-start ping behavior
    // (RtpAudioReceiver's 80ms burst) is untouched, and no timeout math
    // anywhere derives from this value.
    //
    // WIRING NOTE: this is the FAST dial AND the wake quantum of both live loops (VideoRtpReceiver's and
    // RtpAudioReceiver's ping threads): each wakes at this interval and gates the SEND on the conditional
    // interval, so a cadence flip lands within one quantum. The audio fast-start burst keeps its own cadence.
    static let steadyPingIntervalSeconds: TimeInterval = 0.075

    // The RELAXED cadence - upstream moonlight-common-c's stock 500ms
    // keepalive (AudioStream.c/VideoStream.c ping threads), i.e. the rate
    // proven sufficient for session liveness wherever NIC doze is not in
    // play. Used by EnvSignalController.steadyPingInterval() for confirmed-
    // wired routes and active-input CLEAR wifi play. Protocol-safe by the
    // same argument as the fast dial: Sunshine only times the session out
    // when pings STOP (ping_timeout, default 10s) - 500ms is 20x inside it.
    static let relaxedPingIntervalSeconds: TimeInterval = 0.5

    /// SS_PING (AudioStream.c / VideoStream.c): the 16-byte X-SS-Ping-Payload, then the sequence number big-endian.
    static func datagram(payload: [UInt8], sequence: UInt32) -> [UInt8] {
        var out = payload
        withUnsafeBytes(of: sequence.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// Resolve once at connection start so every channel dials the same literal (issue #70).
    /// Prefer IPv4 like gl_tcp_connect because Sunshine binds IPv4 by default.
    /// Returns nil when the name does not resolve.
    static func resolveHost(_ address: String) -> NWEndpoint.Host? {
        // Literal fast path: NWEndpoint.Host's parser yields .ipv4/.ipv6 for
        // literals, .name for everything else.
        let parsed = NWEndpoint.Host(address)
        switch parsed {
        case .ipv4, .ipv6:
            return parsed
        default:
            break
        }
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG   // only families this machine can route
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &res) == 0, let first = res else {
            return nil
        }
        defer { freeaddrinfo(first) }
        for family in [AF_INET, AF_INET6] {
            var info: UnsafeMutablePointer<addrinfo>? = first
            while let cur = info {
                if cur.pointee.ai_family == family, let host = literal(from: cur.pointee) { return host }
                info = cur.pointee.ai_next
            }
        }
        return nil
    }

    private static func literal(from entry: addrinfo) -> NWEndpoint.Host? {
        if entry.ai_family == AF_INET, let sa = entry.ai_addr,
           Int(entry.ai_addrlen) >= MemoryLayout<sockaddr_in>.size {
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            let bytes = withUnsafeBytes(of: sin.sin_addr) { Data($0) }
            if let v4 = IPv4Address(bytes) { return .ipv4(v4) }
        } else if entry.ai_family == AF_INET6, let sa = entry.ai_addr,
                  Int(entry.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size {
            var sin6 = sockaddr_in6()
            memcpy(&sin6, sa, MemoryLayout<sockaddr_in6>.size)
            let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Data($0) }
            if let v6 = IPv6Address(bytes) { return .ipv6(v6) }
        }
        return nil
    }

    /// Build a sockaddr for host:port. Only IP literals reach the native path -
    /// ENFORCED at the pipeline entry by `resolveHost` (issue #70), which
    /// resolves any hostname before the receivers exist; the nil return for
    /// `.name` is now a defensive backstop, not an expected path.
    /// Shared with VideoRtpReceiver.
    static func makeSockaddr(for host: NWEndpoint.Host,
                             port: UInt16) -> (sockaddr_storage, socklen_t, Int32)? {
        var storage = sockaddr_storage()
        switch host {
        case .ipv4(let v4):
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            v4.rawValue.withUnsafeBytes { _ = memcpy(&sa.sin_addr, $0.baseAddress, 4) }
            withUnsafeBytes(of: &sa) { _ = memcpy(&storage, $0.baseAddress, MemoryLayout<sockaddr_in>.size) }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size), AF_INET)
        case .ipv6(let v6):
            var sa = sockaddr_in6()
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = port.bigEndian
            v6.rawValue.withUnsafeBytes { _ = memcpy(&sa.sin6_addr, $0.baseAddress, 16) }
            withUnsafeBytes(of: &sa) { _ = memcpy(&storage, $0.baseAddress, MemoryLayout<sockaddr_in6>.size) }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size), AF_INET6)
        default:
            return nil
        }
    }
}
