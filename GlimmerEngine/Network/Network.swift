// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation
import Network
import os.log

// MARK: - Host reachability (cheap TCP probe)

// MARK: - Host reachability

/// A bounded TCP-only probe keeps readiness polling cheap and never performs an HTTP/TLS exchange.
public enum HostReachability {
    public enum Outcome: Sendable, Equatable {
        case reachable(rttMs: Int)
        case unreachable     // refused / timed out / DNS failed
        case noPath          // no route from this Mac yet (Wi-Fi rejoining after a wake)
    }

    /// Time a TCP connection to `host:port` until `.ready`, then cancel it.
    /// Returns `.noPath` while this Mac lacks a route; other failures are `.unreachable`.
    public static func measureRTT(host: String,
                                  port: Int = 47989,
                                  timeoutMs: Int = 2_000) async -> Outcome {
        await measureRTT(host: host, port: port, timeoutMs: timeoutMs, prohibitedInterfaces: [.loopback])
    }

    /// The probe itself; tests lift the loopback ban to time a listener on 127.0.0.1.
    static func measureRTT(host: String, port: Int, timeoutMs: Int,
                           prohibitedInterfaces: [NWInterface.InterfaceType]) async -> Outcome {
        guard let rawPort = UInt16(exactly: port), rawPort > 0,
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            return .unreachable
        }
        // Bound a dead PC probe instead of waiting for the kernel's long SYN retry budget.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, timeoutMs / 1000)
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = prohibitedInterfaces

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
        let start = DispatchTime.now()

        // Multiple terminal callbacks can race; resume the continuation exactly once.
        let outcome: Outcome = await withCheckedContinuation { cont in
            let once = OnceResumer(cont: cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                    let ms = Int((Double(elapsedNs) / 1_000_000.0).rounded())
                    once.resume(with: .reachable(rttMs: ms))
                    conn.cancel()
                case .failed:
                    // Cancel so the connection releases this handler now
                    // rather than at the deadline.
                    once.resume(with: .unreachable)
                    conn.cancel()
                case .cancelled:
                    once.resume(with: .unreachable)
                case .waiting:
                    // A waiting connection retries forever, so tear it down. With no satisfied path
                    // (Wi-Fi rejoining after a wake) this Mac can't judge the PC; a refused port
                    // waits on a satisfied one and stays unreachable.
                    once.resume(with: conn.currentPath?.status != .satisfied ? .noPath : .unreachable)
                    conn.cancel()
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))

            // Hard ceiling: if the OS never fires a terminal state within our
            // budget (e.g. SYN-ACK lost on a stale route), we still want the
            // chip poller to make progress. Only cancel if no state beat us to it.
            let deadlineMs = max(250, timeoutMs)
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + .milliseconds(deadlineMs)) {
                    if once.resume(with: .unreachable) { conn.cancel() }
                }
        }
        return outcome
    }

    /// The lock protects fired; the immutable continuation is resumed exactly once even when
    /// Network.framework delivers multiple terminal callbacks from different queues.
    final class OnceResumer: @unchecked Sendable {
        private let cont: CheckedContinuation<Outcome, Never>
        private var fired = false
        private let lock = NSLock()
        init(cont: CheckedContinuation<Outcome, Never>) { self.cont = cont }
        /// True only for the call that actually resumed.
        @discardableResult
        func resume(with value: Outcome) -> Bool {
            lock.lock()
            let shouldFire = !fired
            fired = true
            lock.unlock()
            if shouldFire { cont.resume(returning: value) }
            return shouldFire
        }
    }
}

// MARK: - Public data types

/// One entry from /applist. The host returns a flat list of these - Desktop,
/// Steam Big Picture, and one per game it knows about.
public struct HostApp: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let hdrCapable: Bool
    public let hidden: Bool

    public init(id: Int, name: String, hdrCapable: Bool, hidden: Bool) {
        self.id = id
        self.name = name
        self.hdrCapable = hdrCapable
        self.hidden = hidden
    }
}

/// Result of /launch or /resume. The host returns an RTSP URL we then hand to
/// the native backend to start the actual video/audio/input streams, plus the
/// GCM key + key-ID it expects on the control channel.
package struct LaunchResponse: Sendable {
    package let sessionURL: String
    package let gcmKey: Data
    package let gcmKeyId: Data

    package init(sessionURL: String, gcmKey: Data, gcmKeyId: Data) {
        self.sessionURL = sessionURL
        self.gcmKey = gcmKey
        self.gcmKeyId = gcmKeyId
    }
}

// MARK: - XMLNode

// MARK: - XMLNode

/// Preserve ordered children and attributes without adding a general XML dependency.
package struct XMLNode: Sendable {
    package let name: String
    package var text: String
    package var attributes: [String: String]
    package var children: [XMLNode]

    package init(name: String,
                 text: String = "",
                 attributes: [String: String] = [:],
                 children: [XMLNode] = []) {
        self.name = name
        self.text = text
        self.attributes = attributes
        self.children = children
    }

    // MARK: Lookup helpers

    /// First descendant with the given tag name (depth-first, pre-order).
    /// Matches `self` if its own name equals `tag`.
    package func firstChild(named tag: String) -> XMLNode? {
        if name == tag { return self }
        for child in children {
            if let hit = child.firstChild(named: tag) { return hit }
        }
        return nil
    }

    /// All descendants with the given tag name (depth-first).
    package func descendants(named tag: String) -> [XMLNode] {
        var out: [XMLNode] = []
        collectDescendants(named: tag, into: &out)
        return out
    }

    private func collectDescendants(named tag: String, into out: inout [XMLNode]) {
        for child in children {
            if child.name == tag { out.append(child) }
            child.collectDescendants(named: tag, into: &out)
        }
    }

    /// Descend through Sunshine's root wrapper so callers can read the actual field.
    package func string(forChild tag: String) -> String? {
        firstChild(named: tag)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func int(forChild tag: String) -> Int? {
        string(forChild: tag).flatMap(Int.init)
    }

    package func bool(forChild tag: String) -> Bool? {
        // GameStream uses "1"/"0" rather than "true"/"false".
        guard let text = string(forChild: tag) else { return nil }
        return text == "1"
    }
}

// MARK: - NetworkClient

public actor NetworkClient {

    // MARK: State

    // MARK: State

    /// Learn ports from /serverinfo, but accept a certificate only after the pairing proof.
    var server: ServerInfo

    /// Client cert + key (PEM), snapshotted from IdentityManager on first use; ControlTransport
    /// builds its in-memory identity from them. The host-cert pin rides on `server.serverCertPEM`.
    var clientCertPEM: String?
    var clientKeyPEM: String?

    /// The 32-hex client uniqueid generated by IdentityManager, sent on every request.
    package var clientUniqueID: String?
    var requestDeadline: Date?

    package func setRequestDeadline(_ deadline: Date?) { requestDeadline = deadline }

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Network")

    /// The client credential and uniqueid requests carry; tests pass a generated one.
    package typealias Identity = @Sendable () async throws -> (certPEM: String, keyPEM: String, uniqueID: String)

    let deviceName: @Sendable () -> String
    let transport: ControlTransport.Get
    let identity: Identity

    // MARK: Init

    package init(server: ServerInfo, deviceName: @escaping @Sendable () -> String,
                 transport: @escaping ControlTransport.Get = ControlTransport.get,
                 identity: @escaping Identity) {
        self.server = server
        self.deviceName = deviceName
        self.transport = transport
        self.identity = identity
        // The host-cert pin (if any) rides on `server.serverCertPEM` already;
        // ControlTransport reads it per request. Nothing else to set up - the
        // control channel is connectionless from this object's point of view.
    }

    public init(server: ServerInfo, identity: IdentityManager, deviceName: String) {
        self.init(server: server, deviceName: { deviceName }, identity: {
            (try await identity.clientCertPEM(), try await identity.clientKeyPEM(), try await identity.uniqueID())
        })
    }

    /// No-op: the control channel is per-request (ControlTransport opens and
    /// closes a connection per call), so there's nothing persistent to tear
    /// down. Kept only so the existing `await net.shutdown()` call sites don't churn.
    public func shutdown() {}

    /// Pairing calls this after the PIN and signature proof. Reject unsupported keys before
    /// replacing a pin; subsequent TLS connections must present this exact certificate.
    package func setPinnedHostCert(pem: String) throws {
        _ = try PEM.certificateKey(pem, context: "PC certificate")
        server.serverCertPEM = pem
        log.info("Host cert pinned (length \(pem.count, privacy: .public) bytes)")
    }

    /// Currently-pinned host cert in PEM form, if any. Useful for the UI
    /// to display the fingerprint, or for the caller to persist it.
    public func pinnedServerCertPEM() -> String? {
        server.serverCertPEM
    }

    // MARK: Identity prep

    // Snapshot the client cert + key (PEM) before HTTPS so the transport needs no actor hop.

    func ensureIdentityLoaded() async throws {
        if clientCertPEM != nil { return }
        (clientCertPEM, clientKeyPEM, clientUniqueID) = try await identity()
    }

    /// Flatten the immediate-child element names + brief text of an XML node
    /// for diagnostic logging. Doesn't recurse - just enough to see whether
    /// the field we expected is there under a different name.
    static func dumpXML(_ node: XMLNode) -> String {
        var entries: [String] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                let body = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = body.isEmpty ? "" : "=\(body.prefix(60))"
                entries.append("<\(child.name)\(preview)>")
                if !child.children.isEmpty { walk(child) }
            }
        }
        walk(node)
        return entries.joined(separator: " ")
    }

    // MARK: - Redaction helpers

    // Match sensitive names case-insensitively in both request queries and echoed XML tags.
    // Keys, key IDs, nonces, client IDs and session addresses must never reach public logs.

    /// Lowercased query/tag names whose values `runLaunchLike`'s query dump and
    /// `dumpXMLRedacted` redact. `sessionurl0` is the PC's rtsp://address:port,
    /// echoed by /launch and /resume.
    static let sensitiveQueryKeys: Set<String> = [
        "rikey", "rikeyid", "gcmkey", "gcmkeyid", "uuid", "uniqueid", "sessionurl0"
    ]

    /// Retain field names for diagnostics while redacting sensitive echoed values.
    static func dumpXMLRedacted(_ node: XMLNode) -> String {
        var entries: [String] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                let body = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSensitive = sensitiveQueryKeys.contains(child.name.lowercased())
                let preview: String
                if isSensitive {
                    preview = body.isEmpty ? "" : "=<redacted>"
                } else {
                    preview = body.isEmpty ? "" : "=\(body.prefix(60))"
                }
                entries.append("<\(child.name)\(preview)>")
                if !child.children.isEmpty { walk(child) }
            }
        }
        walk(node)
        return entries.joined(separator: " ")
    }
}
