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
    private var resultsContinuation: AsyncStream<Update>.Continuation?
    private(set) var seen: [String: Discovered] = [:]  // keyed by service name
    private var liveByType: [String: Set<String>] = [:]
    private var run: UInt64 = 0
    private var denied = false

    /// Resolver connections kept alive long enough for `NWConnection`'s state
    /// machine to walk from `.preparing` → `.ready` and expose its resolved
    /// `currentPath.remoteEndpoint`. Keyed by service name so a flapping mDNS
    /// announcement doesn't spawn duplicate probes.
    private(set) var resolvers: [String: NWConnection] = [:]

    /// Never fall back past IPv4, for a caller that needs an address Wake on LAN reaches.
    private let ipv4Only: Bool

    public init(ipv4Only: Bool = false) {
        self.ipv4Only = ipv4Only
    }

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

    /// One emission: the PCs seen so far, and whether macOS refused Glimmer
    /// Local Network access (then `hosts` stays empty whatever is out there).
    public struct Update: Sendable {
        public let hosts: [Discovered]
        public let denied: Bool
    }

    /// Start browsing. Emits the *current* set on every change. Cancel by
    /// breaking out of the for-await loop or calling `stop()`.
    public func start() -> (stream: AsyncStream<Update>, run: UInt64) {
        run &+= 1
        reset()
        let currentRun = run
        let stream = AsyncStream<Update> { continuation in
            self.resultsContinuation = continuation
            for type in ["_nvstream._tcp", "_nvstream-tcp._tcp"] {
                let browser = NWBrowser(
                    for: .bonjour(type: type, domain: nil),
                    using: .tcp
                )
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    var services: [String: NWEndpoint] = [:]
                    for result in results {
                        if case let .service(name, _, _, _) = result.endpoint {
                            services[name] = result.endpoint
                        }
                    }
                    Task { await self?.handleResults(services, type: type, run: currentRun) }
                }
                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed(let err) = state {
                        self?.log.error("Browser failed for \(type): \(err.localizedDescription, privacy: .private)")
                    }
                    let isDenied = Self.isPolicyDenied(state)
                    Task { await self?.setDenied(isDenied, run: currentRun) }
                }
                browser.start(queue: .global(qos: .userInitiated))
                browsers.append(browser)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop(run: currentRun) }
            }
        }
        return (stream, currentRun)
    }

    public func stop() {
        run &+= 1
        reset()
    }

    public func stop(run expectedRun: UInt64) {
        guard run == expectedRun else { return }
        stop()
    }

    private func reset() {
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
        for resolver in resolvers.values { resolver.cancel() }
        resolvers.removeAll()
        resultsContinuation?.finish()
        resultsContinuation = nil
        seen.removeAll()
        liveByType.removeAll()
        denied = false
    }

    /// TN3179: a refused Local Network permission surfaces as the browser
    /// waiting (or failing) with PolicyDenied, never as an empty result.
    static func isPolicyDenied(_ state: NWBrowser.State) -> Bool {
        switch state {
        case .waiting(let error), .failed(let error):
            return error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        default:
            return false
        }
    }

    private func setDenied(_ isDenied: Bool, run expectedRun: UInt64) {
        guard run == expectedRun else { return }
        guard denied != isDenied else { return }
        denied = isDenied
        publish()
    }

    private func publish() {
        resultsContinuation?.yield(Update(hosts: Array(seen.values), denied: denied))
    }

    func retainResolver(_ conn: NWConnection, for name: String) {
        resolvers[name] = conn
    }

    func recordResolved(_ result: Discovered) {
        seen[result.id] = result
        publish()
    }

    var liveNames: Set<String> { Set(liveByType.values.joined()) }

    func handleResults(_ services: [String: NWEndpoint], type: String, run expectedRun: UInt64) {
        for (name, endpoint) in reconcileResults(services, type: type, run: expectedRun) {
            startResolve(name: name, endpoint: endpoint, run: expectedRun)
        }
    }

    func reconcileResults(_ services: [String: NWEndpoint], type: String,
                          run expectedRun: UInt64) -> [String: NWEndpoint] {
        guard run == expectedRun else { return [:] }
        liveByType[type] = Set(services.keys)
        let liveKeys = liveNames
        // Drop departed services and tear down any in-flight resolver for them.
        for (key, conn) in resolvers where !liveKeys.contains(key) {
            conn.cancel()
            resolvers.removeValue(forKey: key)
        }
        seen = seen.filter { liveKeys.contains($0.key) }
        publish()
        return services.filter { seen[$0.key] == nil && resolvers[$0.key] == nil }
    }

    /// Drive the service endpoint through resolution on a short-lived, send-nothing
    /// `NWConnection`, IPv4 first (Sunshine binds it by default), any family as a
    /// fallback unless `ipv4Only`. Once ready or failed, cache host:port and cancel.
    private func startResolve(name: String, endpoint: NWEndpoint, run expectedRun: UInt64, anyFamily: Bool = false) {
        guard run == expectedRun else { return }
        // The service endpoint resolves SRV and address records together, including non-default ports.
        let parameters = NWParameters.tcp
        if !anyFamily, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: parameters)
        retainResolver(conn, for: name)
        let fallback = (anyFamily || ipv4Only) ? nil : endpoint
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.finishResolve(name: name, conn: conn, run: expectedRun) }
            case .failed(let err):
                Task { await self?.failResolve(name: name, conn: conn, error: err, retry: fallback, run: expectedRun) }
            case .waiting(let err) where fallback != nil:
                // No usable IPv4 answer; a PC that advertises none gets any family.
                Task { await self?.failResolve(name: name, conn: conn, error: err, retry: fallback, run: expectedRun) }
            case .waiting where fallback == nil:
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.restartResolve(name: name, conn: conn, run: expectedRun)
                }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func restartResolve(name: String, conn: NWConnection, run expectedRun: UInt64) {
        guard run == expectedRun, resolvers[name] === conn else { return }
        conn.restart()
    }

    private func finishResolve(name: String, conn: NWConnection, run expectedRun: UInt64) {
        guard run == expectedRun, resolvers[name] === conn else { return }
        defer {
            conn.cancel()
            resolvers.removeValue(forKey: name)
        }
        guard let remote = conn.currentPath?.remoteEndpoint else {
            // Path went ready but we somehow don't have a remote endpoint to
            // read. Fall back to the service name so the host is at least
            // reachable by DNS-SD-aware callers; canonical port.
            if seen[name] == nil {
                recordResolved(Discovered(id: name, displayName: name,
                                          host: name, port: 47989))
            }
            return
        }
        if case let .hostPort(host: host, port: port) = remote {
            let resolvedHost: String?
            switch host {
            case .name(let hostName, _): resolvedHost = hostName
            case .ipv4(let addr):       resolvedHost = Self.canonicalHost("\(addr)", ipv6: false)
            case .ipv6(let addr):       resolvedHost = Self.canonicalHost("\(addr)", ipv6: true)
            @unknown default:           resolvedHost = name
            }
            guard let resolvedHost else {
                log.info("Skipped \(name, privacy: .private): only a link-local IPv6 address, which can't be saved")
                return
            }
            let resolvedPort = Int(port.rawValue)
            recordResolved(Discovered(id: name, displayName: name,
                                      host: resolvedHost, port: resolvedPort))
            log.info("Resolved host \(name, privacy: .private) → \(resolvedHost, privacy: .private):\(resolvedPort)")
        }
    }

    /// The address to save for a resolved PC, without the `%zone` Network
    /// appends. nil for link-local IPv6 (fe80::/10): its zone names a Mac
    /// interface, which changes when the Mac moves between Wi-Fi and Ethernet.
    static func canonicalHost(_ raw: String, ipv6: Bool) -> String? {
        let lower = raw.lowercased()
        if ipv6 && ["fe8", "fe9", "fea", "feb"].contains(where: { lower.hasPrefix($0) }) { return nil }
        return String(raw.prefix { $0 != "%" })
    }

    /// Drop a failed resolver; `retry` re-resolves the service in any address
    /// family. A stale call (service gone, or already retried) does nothing.
    private func failResolve(name: String, conn: NWConnection, error: NWError,
                             retry endpoint: NWEndpoint?, run expectedRun: UInt64) {
        guard run == expectedRun, resolvers[name] === conn else { return }
        conn.cancel()
        resolvers.removeValue(forKey: name)
        guard let endpoint else {
            log.error("Resolve failed for \(name, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return
        }
        log.info("No IPv4 answer for \(name, privacy: .private) (\(error.localizedDescription, privacy: .private)); trying any family")
        startResolve(name: name, endpoint: endpoint, run: expectedRun, anyFamily: true)
    }
}
