//
//  UdpPinger.swift
//
//  Fire-and-forget UDP stream pinger for the Swift-native backend. Binds a
//  wildcard ephemeral UNCONNECTED UDP socket and sends a 20-byte SS_PING
//  { payload[16] + sequenceNumber (UInt32 BE) } to host:port at the steady
//  keepalive cadence (75ms fast / 500ms relaxed, conditional - a deliberate,
//  validated deviation from upstream's flat 500ms; see the verdict on
//  steadyPingIntervalSeconds below), or the legacy
//  4-byte "PING" when no payload was negotiated. Source: AudioStream.c
//  (AudioPingThreadProc) / VideoStream.c (VideoPingThreadProc).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  WHY THIS EXISTS: Sunshine encodes ONE combined A/V media session and won't
//  push ANY video RTP until it has received BOTH the video AND the audio stream
//  pings (AudioStream.c:90-110 - "It will not reply to our RTSP PLAY request
//  until the audio ping has been received."). The native video path was sending
//  only the video ping (on its receive socket), so the host withheld video. This
//  pinger supplies the missing AUDIO ping. It is send-only (we don't receive
//  native audio yet); the host just needs to see the ping to start the session.
//
//  The VIDEO ping stays on VideoRtpReceiver's receive socket (ping + receive MUST
//  share one socket so the host learns the correct video return port); this
//  pinger is used for the audio stream, which we don't receive, so an independent
//  ephemeral socket is fine.

import Foundation
import Network
import Darwin

final class UdpPinger: @unchecked Sendable {
    private static let cat = "NativeAudio"

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
    // WIRING NOTE: the ping loop below is currently dormant - the live
    // steady-state keepalives run on VideoRtpReceiver's and RtpAudioReceiver's
    // own ping threads (this class's audio-ping role moved into
    // RtpAudioReceiver; see NativeBackend.audioReceiver's doc). This constant
    // is the FAST cadence dial AND both live loops' wake quantum: each loop
    // wakes at this interval (exactly the pre-conditional wake rate - no new
    // thread cost) and gates the SEND on the live conditional interval, so a
    // cadence flip takes effect within one quantum. RtpAudioReceiver's
    // connect-time fast-start burst stays on its own cadence by design.
    static let steadyPingIntervalSeconds: TimeInterval = 0.075

    // The RELAXED cadence - upstream moonlight-common-c's stock 500ms
    // keepalive (AudioStream.c/VideoStream.c ping threads), i.e. the rate
    // proven sufficient for session liveness wherever NIC doze is not in
    // play. Used by EnvSignalController.steadyPingInterval() for confirmed-
    // wired routes and active-input CLEAR wifi play. Protocol-safe by the
    // same argument as the fast dial: Sunshine only times the session out
    // when pings STOP (ping_timeout, default 10s) - 500ms is 20x inside it.
    static let relaxedPingIntervalSeconds: TimeInterval = 0.5

    private let host: NWEndpoint.Host
    private let port: UInt16
    private let payload: [UInt8]      // 16 bytes, or empty for legacy "PING"
    private let label: String

    private var fd: Int32 = -1
    private var destAddr = sockaddr_storage()
    private var destAddrLen: socklen_t = 0
    private var task: Task<Void, Never>?
    private let interrupted = ManagedAtomicFlag()
    private var pingCount: UInt32 = 0

    init(host: NWEndpoint.Host, port: UInt16, payload: [UInt8], label: String) {
        self.host = host
        self.port = port
        self.payload = payload
        self.label = label
    }

    func start() {
        guard let (dest, len, family) = UdpPinger.makeSockaddr(for: host, port: port) else {
            Diag.error("\(label) pinger: could not build address for \(host)", Self.cat)
            return
        }
        destAddr = dest
        destAddrLen = len

        let sock = socket(family, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            Diag.error("\(label) pinger: socket() errno \(errno)", Self.cat)
            return
        }
        // Bind a wildcard ephemeral local port so the ping has a stable source
        // the host can bind the stream destination to.
        let bound: Bool
        if family == AF_INET {
            var ba = sockaddr_in()
            ba.sin_family = sa_family_t(AF_INET)
            ba.sin_addr.s_addr = 0 // INADDR_ANY
            ba.sin_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        } else {
            var ba = sockaddr_in6()
            ba.sin6_family = sa_family_t(AF_INET6)
            ba.sin6_addr = in6addr_any
            ba.sin6_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        guard bound else {
            close(sock)
            Diag.error("\(label) pinger: bind() errno \(errno)", Self.cat)
            return
        }
        fd = sock

        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.interrupted.isSet {
                self.sendPing()
                try? await Task.sleep(nanoseconds: UInt64(Self.steadyPingIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        interrupted.set()
        task?.cancel()
        task = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func sendPing() {
        guard fd >= 0 else { return }
        let datagram: [UInt8]
        if !payload.isEmpty {
            pingCount &+= 1
            var out = payload                     // 16 bytes
            withUnsafeBytes(of: pingCount.bigEndian) { out.append(contentsOf: $0) }  // 4 bytes BE
            datagram = out
        } else {
            pingCount &+= 1
            datagram = [0x50, 0x49, 0x4E, 0x47]   // legacy GFE "PING"
        }
        _ = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &destAddr) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fd, raw.baseAddress, raw.count, 0, sap, destAddrLen)
                }
            }
        }
        if pingCount == 1 {
            Diag.notice("\(label) first ping sent → \(host):\(port) "
                + "(\(payload.isEmpty ? "legacy" : "payload") seq=1)", Self.cat)
        }
    }

    /// Resolve a host STRING to an IP-literal `NWEndpoint.Host`, ONCE, at
    /// connection start (issue #70). An IPv4/IPv6 literal passes through with
    /// no DNS at all; a hostname is resolved via getaddrinfo - the SAME
    /// resolver (and system address ordering) the TCP/control paths in
    /// CHelpers already use - so every channel of a session targets the same
    /// address and family, and split-horizon DNS can never send video to a
    /// different host than control. Returns nil when the name does not
    /// resolve; the caller fails the connection with a resolution error
    /// instead of the old late, misleading per-receiver socket failure.
    ///
    /// WHY resolve-once-here and not inside `makeSockaddr`: DNS belongs at
    /// the connection edge, not on a path called during socket setup (the
    /// WiFiTelemetry no-DNS discipline). Before this, `.name` hosts sailed
    /// through RTSP and ENet control (getaddrinfo in CHelpers) and then died
    /// at both RTP receivers - a 100%-reproducible "CONNECTED then instant
    /// video failure" when a host was added by hostname/FQDN.
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
        // Walk in returned order (system policy - the choice gl_tcp_connect
        // makes by taking the head) and adopt the first usable family.
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let cur = info {
            if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr,
               Int(cur.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size {
                var sin = sockaddr_in()
                memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
                let bytes = withUnsafeBytes(of: sin.sin_addr) { Data($0) }
                if let v4 = IPv4Address(bytes) { return .ipv4(v4) }
            } else if cur.pointee.ai_family == AF_INET6, let sa = cur.pointee.ai_addr,
                      Int(cur.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size {
                var sin6 = sockaddr_in6()
                memcpy(&sin6, sa, MemoryLayout<sockaddr_in6>.size)
                let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Data($0) }
                if let v6 = IPv6Address(bytes) { return .ipv6(v6) }
            }
            info = cur.pointee.ai_next
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
