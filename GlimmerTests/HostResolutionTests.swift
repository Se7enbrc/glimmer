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
import XCTest
@testable import Glimmer

struct HostResolutionTests {

    @Test func pingSendFailureStreakReportsOnlyEdges() {
        var streak = UdpPinger.SendFailureStreak()
        #expect(streak.note(sent: -1) == .failed)
        #expect(streak.note(sent: -1) == nil)
        #expect(streak.note(sent: 20) == .recovered(2))
        #expect(streak.note(sent: 20) == nil)
    }

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

    /// Prefer IPv4 like the control connection; localhost resolves offline.
    @Test func resolvableNamePrefersIPv4() {
        #expect(UdpPinger.resolveHost("localhost") == .ipv4(.loopback))
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

// MARK: - Paired-path failure classification (2026-09-02 false "re-pair")

/// `classifyPairedPathFailure` is the one place a HTTPS failure on a pinned
/// host becomes user-facing copy, and it used to say "pair again" for ANY
/// failure because Sunshine reports PairStatus=0 on plain HTTP no matter
/// what. These pin the contract per ControlTransport detail string.
final class PairedPathFailureClassificationTests: XCTestCase {

    private func classify(_ detail: String) -> StreamError {
        NetworkClient.classifyPairedPathFailure(detail, hostName: "tower")
    }

    func testRefusedSecurePortIsNotAPairingProblem() {
        guard case .sunshineNeedsRestart(let text) = classify("connect to tower:47984 failed or timed out") else {
            return XCTFail("expected sunshineNeedsRestart")
        }
        XCTAssertTrue(text.contains("Restart Sunshine"))
        XCTAssertTrue(text.contains("47984"))
        XCTAssertFalse(text.contains("Pair Again…"))
    }

    func test401IsUnpaired() {
        guard case .pairingFailed(let text) = classify("Host requires pairing (401)") else {
            return XCTFail("expected pairingFailed")
        }
        XCTAssertTrue(text.contains("Pair Again…"))
        XCTAssertTrue(text.hasPrefix("tower"))
        // Sunshine answers a switched-off client with the same 401 as a forgotten one.
        XCTAssertTrue(text.contains("switched off on Sunshine's Troubleshooting page"))
    }

    func testHandshakeRejectionIsUnpaired() {
        guard case .pairingFailed(let text) = classify("TLS handshake to tower:47984 failed (SSL_connect)") else {
            return XCTFail("expected pairingFailed")
        }
        XCTAssertTrue(text.contains("Pair Again…"))
    }

    /// The poller's "Trust needed" state and the stream banner both match this
    /// case, not its words, so a PC named "Concert" can't trip either.
    func testHostCertChangePointsAtPairAgain() {
        guard case .hostCertChanged(let text) = classify("pinned host cert mismatch") else {
            return XCTFail("expected hostCertChanged")
        }
        XCTAssertTrue(text.contains("Pair Again…"))
        let stuck = NetworkClient.classifyPairedPathFailure("connect to x:47984 failed", hostName: "Concert")
        XCTAssertEqual(AppModel.connectFailure(for: stuck, hostName: "Concert").kind, .other)
    }

    func testNoCopyUsesASpacedDashOrTheTransportDetail() {
        for detail in ["connect to x:47984 failed", "Host requires pairing", "TLS handshake failed",
                       "pinned host cert mismatch", "something else"] {
            XCTAssertFalse("\(classify(detail))".contains(" - "), detail)
        }
        XCTAssertFalse("\(classify("empty HTTP response"))".contains("HTTP response"))
    }

    func testEmptyHostNameFallsBackToThePC() {
        guard case .sunshineNeedsRestart(let text) = NetworkClient.classifyPairedPathFailure(
            "connect to x:47984 failed or timed out", hostName: "") else {
            return XCTFail("expected sunshineNeedsRestart")
        }
        XCTAssertTrue(text.hasPrefix("The PC"))
    }

    /// A changed certificate is classified without the plain-port probe, so a
    /// blocked 47989 can't turn it into "make sure it's awake".
    func testCertChangeIsRecognizedWithoutTheProbe() {
        XCTAssertTrue(NetworkClient.isCertChange("pinned host cert mismatch"))
        XCTAssertTrue(NetworkClient.isCertChange("host presented no certificate"))
        XCTAssertFalse(NetworkClient.isCertChange("connect to x:47984 failed or timed out"))
        XCTAssertFalse(NetworkClient.isCertChange("TLS handshake failed"))
    }
}

/// The launcher banner keeps the network layer's Pair Again… sentences as
/// they are, and any other pairing failure points at the same command.
@MainActor
struct PairingFailureBannerTests {

    @Test func theBannerNamesPairAgain() {
        let verdict = NetworkClient.classifyPairedPathFailure("Host requires pairing (401)", hostName: "Den PC")
        let kept = AppModel.connectFailure(for: verdict, hostName: "Den PC").message
        #expect(kept.hasPrefix("Den PC no longer recognizes this Mac, or this Mac is switched off"))
        let noPin = AppModel.connectFailure(for: NetworkClient.notPaired("Den PC"), hostName: "Den PC").message
        #expect(noPin == "Den PC isn't paired with this Mac. Choose Pair Again… from the PC's ⋯ menu.")
        let rejected = AppModel.connectFailure(for: StreamError.pairingRejected, hostName: "Den PC").message
        #expect(rejected.hasPrefix("Couldn't pair with Den PC.") && rejected.contains("Pair Again…"))
    }
}

// MARK: - Addresses the pair sheet accepts and discovery saves

struct PCAddressTests {

    /// The likeliest paste is Sunshine's own web UI URL; it comes down to the address.
    @Test func pastedURLsAndPortsReduceToTheAddress() {
        #expect(AppModel.normalizedPCAddress("https://192.168.1.10:47990/pin") == "192.168.1.10")
        #expect(AppModel.normalizedPCAddress("  tower.local:47989 \n") == "tower.local")
        #expect(AppModel.normalizedPCAddress("[2001:db8::5]:47989") == "2001:db8::5")
        #expect(AppModel.normalizedPCAddress("2001:db8::5") == "2001:db8::5")
    }

    @Test func undialableEntriesAreRejected() {
        #expect(AppModel.normalizedPCAddress("") == nil)
        #expect(AppModel.normalizedPCAddress("my gaming pc") == nil)
        #expect(AppModel.normalizedPCAddress("-tower") == nil)
        // A zone names a Mac interface; it breaks the moment the Mac changes network.
        #expect(AppModel.normalizedPCAddress("fe80::1%en0") == nil)
    }

    @Test func discoveryNeverSavesAZoneScopedAddress() {
        #expect(HostDiscovery.canonicalHost("192.0.2.10%en0", ipv6: false) == "192.0.2.10")
        #expect(HostDiscovery.canonicalHost("2001:db8::5%en0", ipv6: true) == "2001:db8::5")
        #expect(HostDiscovery.canonicalHost("fe80::1%en0", ipv6: true) == nil)
    }

    /// A refused Local Network permission must read as "denied", not "no PCs".
    @Test func deniedLocalNetworkIsRecognized() {
        let denied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        #expect(HostDiscovery.isPolicyDenied(.waiting(denied)))
        #expect(HostDiscovery.isPolicyDenied(.failed(denied)))
        #expect(!HostDiscovery.isPolicyDenied(.ready))
        #expect(!HostDiscovery.isPolicyDenied(.waiting(.posix(.ENETDOWN))))
    }
}

struct DiscoveryBookkeepingTests {

    @Test func anotherBrowserKeepsServiceLive() async {
        let discovery = HostDiscovery()
        let endpoint = NWEndpoint.service(name: "PC", type: "_nvstream._tcp", domain: "local", interface: nil)
        let resolver = NWConnection(to: endpoint, using: .tcp)
        let resolved = HostDiscovery.Discovered(id: "PC", displayName: "PC", host: "192.0.2.1", port: 47989)
        let first = await discovery.reconcileResults(["PC": endpoint], type: "_nvstream._tcp", run: 0)
        #expect(first["PC"] == endpoint)
        await discovery.retainResolver(resolver, for: "PC")
        await discovery.recordResolved(resolved)
        _ = await discovery.reconcileResults([:], type: "_nvstream-tcp._tcp", run: 0)
        #expect(await discovery.resolvers["PC"] === resolver)
        #expect(await discovery.seen["PC"] == resolved)
        _ = await discovery.reconcileResults([:], type: "_nvstream._tcp", run: 0)
        #expect(await discovery.resolvers["PC"] == nil)
        #expect(await discovery.seen["PC"] == nil)
    }

    @Test func unresolvedServiceRetriesOnBrowserUpdate() async {
        let discovery = HostDiscovery()
        let endpoint = NWEndpoint.service(name: "PC", type: "_nvstream._tcp", domain: "local", interface: nil)
        let services = ["PC": endpoint]
        let first = await discovery.reconcileResults(services, type: "_nvstream._tcp", run: 0)
        #expect(first["PC"] == endpoint)
        // No resolver remains after terminal failure; the next update must request one again.
        let second = await discovery.reconcileResults(services, type: "_nvstream._tcp", run: 0)
        #expect(second["PC"] == endpoint)
    }

    @Test func earlierConsumerCannotStopNewRun() async {
        let discovery = HostDiscovery()
        let first = await discovery.start()
        let second = await discovery.start()
        await discovery.stop(run: first.run)
        let endpoint = NWEndpoint.service(name: "PC", type: "_nvstream._tcp", domain: "local", interface: nil)
        let pending = await discovery.reconcileResults(["PC": endpoint], type: "_nvstream._tcp", run: second.run)
        #expect(pending["PC"] == endpoint)
        await discovery.stop(run: second.run)
    }

    @Test func stoppedRunIgnoresLateBrowserResults() async {
        let discovery = HostDiscovery()
        await discovery.stop()
        let endpoint = NWEndpoint.service(name: "PC", type: "_nvstream._tcp", domain: "local", interface: nil)
        let pending = await discovery.reconcileResults(["PC": endpoint], type: "_nvstream._tcp", run: 0)
        #expect(pending.isEmpty)
        #expect(await discovery.liveNames.isEmpty)
    }
}

struct ServerInfoPortTests {

    @Test func outOfRangeHTTPSPortKeepsDefault() async throws {
        let server = ServerInfo(address: "192.0.2.1", uniqueId: "x", serverName: "x")
        let client = NetworkClient(server: server)
        let xml = try XMLTreeBuilder.parse(data: Data(
            #"<root status_code="200"><HttpsPort>70000</HttpsPort></root>"#.utf8
        ))
        await client.hydrateServerInfo(from: xml, fetchedOverPaired: true)
        #expect(await client.server.httpsPort == 47984)
    }
}

struct PairingIdentityTests {

    @Test(arguments: [
        "",
        "<uniqueid></uniqueid>",
        "<uniqueid>different</uniqueid>"
    ]) func pinnedReplyMustSupplyMatchingIdentity(_ body: String) throws {
        let xml = try XMLTreeBuilder.parse(data: Data(
            "<root status_code=\"200\">\(body)</root>".utf8
        ))
        #expect(!NetworkClient.matchesPairingIdentity(xml, expected: "saved"))
    }

    @Test func pinnedReplyAcceptsMatchingIdentity() throws {
        let xml = try XMLTreeBuilder.parse(data: Data(
            #"<root status_code="200"><uniqueid>saved</uniqueid></root>"#.utf8
        ))
        #expect(NetworkClient.matchesPairingIdentity(xml, expected: "saved"))
    }
}
