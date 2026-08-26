//
//  HostResolutionTests.swift
//
//  Issue #70: a host added by hostname/FQDN sailed through RTSP and ENet
//  control (whose C connect paths run their own getaddrinfo) and then killed
//  both RTP receivers at makeSockaddr - "CONNECTED" followed by an instant,
//  100%-reproducible video failure. `UdpPinger.resolveHost` now resolves the
//  address ONCE at the pipeline edge; these tests pin its contract: literals
//  pass through untouched (no DNS), resolvable names come back as IP
//  literals, and unresolvable names fail cleanly as nil. "localhost" is the
//  one name used - it resolves from /etc/hosts, so the suite stays
//  deterministic offline.
//

import Foundation
import Network
import Testing
@testable import Glimmer

struct HostResolutionTests {

    /// An IPv4 literal must pass through as-is - the fast path, no resolver.
    @Test func ipv4LiteralPassesThrough() {
        let host = UdpPinger.resolveHost("172.20.20.50")
        guard case .ipv4(let v4) = host else {
            Issue.record("expected .ipv4, got \(String(describing: host))")
            return
        }
        #expect("\(v4)" == "172.20.20.50")
    }

    /// An IPv6 literal must pass through as-is.
    @Test func ipv6LiteralPassesThrough() {
        let host = UdpPinger.resolveHost("::1")
        guard case .ipv6 = host else {
            Issue.record("expected .ipv6, got \(String(describing: host))")
            return
        }
    }

    /// THE bug shape: a resolvable NAME must come back as an IP literal - the
    /// exact input class that used to reach makeSockaddr as .name and die.
    /// localhost resolves via /etc/hosts (offline-safe, deterministic).
    @Test func resolvableNameBecomesIPLiteral() {
        let host = UdpPinger.resolveHost("localhost")
        switch host {
        case .ipv4, .ipv6:
            break // either family is correct - system ordering decides
        default:
            Issue.record("localhost did not resolve to an IP literal: \(String(describing: host))")
        }
    }

    /// The resolved literal must be accepted by makeSockaddr - the full chain
    /// the receivers depend on, name → literal → sockaddr.
    @Test func resolvedNameBuildsSockaddr() {
        guard let host = UdpPinger.resolveHost("localhost") else {
            Issue.record("localhost did not resolve")
            return
        }
        #expect(UdpPinger.makeSockaddr(for: host, port: 47_998) != nil)
    }

    /// An unresolvable name fails as nil - surfaced by the pipeline as ONE
    /// clear resolution error instead of the old late per-receiver failure.
    /// RFC 6761 reserves .invalid: it never resolves, on or off the network.
    @Test func unresolvableNameReturnsNil() {
        #expect(UdpPinger.resolveHost("glimmer-nonexistent-host.invalid") == nil)
    }
}
