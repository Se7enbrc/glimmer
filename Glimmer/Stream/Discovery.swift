//
//  Discovery.swift
//
//  mDNS discovery for GameStream/Sunshine hosts on the local network. Apple
//  Bonjour exposes `_nvstream._tcp` (GFE) and `_nvstream-tcp._tcp` (Sunshine
//  alias) services. We browse, then resolve each result to an IP/port.

import Foundation
import Network
import os.log

/// Continuously-updated list of hosts seen on the network.
public actor HostDiscovery {
    public static let shared = HostDiscovery()

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Discovery")
    private var browsers: [NWBrowser] = []
    private var resultsContinuation: AsyncStream<[Discovered]>.Continuation?
    private var seen: [String: Discovered] = [:]  // keyed by service name

    /// Resolver connections kept alive long enough for `NWConnection`'s state
    /// machine to walk from `.preparing` → `.ready` and expose its resolved
    /// `currentPath.remoteEndpoint`. Keyed by service name so a flapping mDNS
    /// announcement doesn't spawn duplicate probes.
    private var resolvers: [String: NWConnection] = [:]

    public struct Discovered: Sendable, Hashable, Identifiable {
        public let id: String          // service name, stable across resolves
        public let displayName: String
        public let host: String        // hostname or IP (resolved)
        public let port: Int

        public init(id: String, displayName: String, host: String, port: Int) {
            self.id = id
            self.displayName = displayName
            self.host = host
            self.port = port
        }
    }

    /// Start browsing. Emits the *current* set on every change. Cancel by
    /// breaking out of the for-await loop or calling `stop()`.
    public func start() -> AsyncStream<[Discovered]> {
        AsyncStream { continuation in
            self.resultsContinuation = continuation
            for type in ["_nvstream._tcp", "_nvstream-tcp._tcp"] {
                let browser = NWBrowser(
                    for: .bonjour(type: type, domain: nil),
                    using: .tcp
                )
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    Task { await self?.handleResults(results) }
                }
                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed(let err) = state {
                        self?.log.error("Browser failed for \(type): \(err.localizedDescription)")
                    }
                }
                browser.start(queue: .global(qos: .userInitiated))
                browsers.append(browser)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    public func stop() {
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
        for resolver in resolvers.values { resolver.cancel() }
        resolvers.removeAll()
        resultsContinuation?.finish()
        resultsContinuation = nil
        seen.removeAll()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) async {
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint {
                let key = name
                // Resolve the Bonjour service to a concrete host:port via
                // NWConnection. We start a TCP connection at the service
                // endpoint - Network.framework's name resolver walks DNS-SD
                // PTR → SRV → A/AAAA for us, and once the connection lands
                // in `.ready` its `currentPath?.remoteEndpoint` is a
                // `.hostPort(host:port:)` carrying the actual numeric
                // address and the SRV-advertised port. That lets us cope
                // with hosts on non-default ports and multi-homed Macs
                // without parsing TXT records ourselves.
                if seen[key] == nil && resolvers[key] == nil {
                    startResolve(name: name, endpoint: r.endpoint)
                }
            }
        }
        // Drop departed services and tear down any in-flight resolver for them.
        let liveKeys: Set<String> = Set(results.compactMap {
            if case let .service(name, _, _, _) = $0.endpoint { return name } else { return nil }
        })
        for (key, conn) in resolvers where !liveKeys.contains(key) {
            conn.cancel()
            resolvers.removeValue(forKey: key)
        }
        seen = seen.filter { liveKeys.contains($0.key) }
        resultsContinuation?.yield(Array(seen.values))
    }

    /// Spin up a short-lived `NWConnection` whose only job is to drive the
    /// service endpoint through resolution. We never send data - once the
    /// path is ready (or the attempt fails) we extract host:port from the
    /// resolved remote endpoint, cache the result, and cancel the connection.
    private func startResolve(name: String, endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.finishResolve(name: name, conn: conn) }
            case .failed(let err):
                Task { await self?.failResolve(name: name, error: err) }
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func finishResolve(name: String, conn: NWConnection) {
        defer {
            conn.cancel()
            resolvers.removeValue(forKey: name)
        }
        guard let remote = conn.currentPath?.remoteEndpoint else {
            // Path went ready but we somehow don't have a remote endpoint to
            // read. Fall back to the service name so the host is at least
            // reachable by DNS-SD-aware callers; canonical port.
            if seen[name] == nil {
                seen[name] = Discovered(id: name, displayName: name,
                                         host: name, port: 47989)
                resultsContinuation?.yield(Array(seen.values))
            }
            return
        }
        if case let .hostPort(host: host, port: port) = remote {
            let resolvedHost: String
            switch host {
            case .name(let hostName, _): resolvedHost = hostName
            case .ipv4(let addr):       resolvedHost = Self.canonicalHost("\(addr)", ipv6: false)
            case .ipv6(let addr):       resolvedHost = Self.canonicalHost("\(addr)", ipv6: true)
            @unknown default:           resolvedHost = name
            }
            let resolvedPort = Int(port.rawValue)
            seen[name] = Discovered(id: name, displayName: name,
                                    host: resolvedHost, port: resolvedPort)
            log.info("Resolved host \(name, privacy: .public) → \(resolvedHost, privacy: .public):\(resolvedPort)")
            resultsContinuation?.yield(Array(seen.values))
        }
    }

    /// Drop the interface-zone suffix Network appends to a resolved address
    /// (e.g. `192.0.2.10%en0`). The zone is an interface hint that's noise
    /// for a routable address and breaks the HTTP/TLS host parsing downstream
    /// (pairing dialed the literal `...%en0` and failed - issue #21). It is
    /// REQUIRED for IPv6 link-local (fe80::/10) to connect at all, so keep it
    /// there; strip it everywhere else.
    static func canonicalHost(_ raw: String, ipv6: Bool) -> String {
        if ipv6 && raw.lowercased().hasPrefix("fe80") { return raw }
        return String(raw.prefix { $0 != "%" })
    }

    private func failResolve(name: String, error: NWError) {
        log.error("Resolve failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        resolvers[name]?.cancel()
        resolvers.removeValue(forKey: name)
    }
}
