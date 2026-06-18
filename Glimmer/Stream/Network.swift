//
//  Network.swift
//
//  HTTPS/HTTP client for the GameStream/Sunshine control channel. Talks XML
//  over port 47989 (unpaired, plain HTTP) and 47984 (paired, mutual TLS with
//  the client cert + key from IdentityManager). Every endpoint returns XML
//  shaped like:
//
//      <root status_code="200">
//          <appversion>7.1.450.0</appversion>
//          ...
//      </root>
//
//  so we parse it into a tiny in-memory tree (`XMLNode`) and pick values out
//  by tag name. There's no schema; the host returns whatever it feels like and
//  callers are expected to know what they asked for.
//
//  Ported from moonlight-qt's app/backend/nvhttp.{h,cpp} (GPLv3; see CREDITS.md).
//  The big differences from the C++ side:
//
//    * Our own OpenSSL mutual-TLS HTTP client (ControlTransport) instead of
//      QNetworkAccessManager - the client cert + host-cert pin run straight
//      through libssl, no URLSession and no keychain in the path.
//    * Trust-on-first-use: the very first /serverinfo call goes over plain
//      HTTP, pulls the host cert out of the response (well - out of the next
//      HTTPS handshake), pins it, and from then on we refuse to talk HTTPS to
//      anything that doesn't present *exactly* that cert. This is the same
//      model moonlight-qt uses; it does NOT do PKI validation, on purpose
//      (every GameStream/Sunshine host is self-signed).
//    * XMLParser-driven tree builder instead of QXmlStreamReader's pull API.
//
//  This file is concurrency-strict. `NetworkClient` is an actor, so all its
//  state is isolated; the transport's blocking IO runs off-actor and bridges
//  back via continuations.
//

import Foundation
import Network
import os.log

// MARK: - Host reachability (cheap TCP probe)

/// Lightweight reachability probe for the readiness chip on the main window.
/// Distinct from `NetworkClient.fetchServerInfo()` - we don't want to drive a
/// full HTTP/TLS roundtrip just to colour a pill. A bare TCP connect to the
/// host's HTTP port (47989) is enough to tell "host is awake & answering on
/// the network" and gives us a useful RTT proxy as a side effect.
///
/// The measurement is the wall-clock time between `connection.start()` and
/// the connection transitioning to `.ready`. On a LAN this is dominated by
/// the TCP handshake - one round trip - so it's a serviceable RTT for the
/// "12 ms" subtitle on the chip. We don't claim ICMP-level precision.
public enum HostReachability {
    public enum Outcome: Sendable, Equatable {
        case reachable(rttMs: Int)
        case unreachable     // refused / timed out / DNS failed
    }

    /// Open a TCP connection to `host:port`, time how long it takes to reach
    /// `.ready`, cancel it, and return the result. Never throws - failures
    /// fold into `.unreachable` because the caller (a status pill poller)
    /// doesn't need to distinguish refused-vs-timed-out.
    ///
    /// - Parameters:
    ///   - host: hostname or IP
    ///   - port: TCP port to dial (Sunshine/GFE HTTP is 47989)
    ///   - timeoutMs: how long to wait before giving up
    public static func measureRTT(host: String,
                                  port: Int = 47989,
                                  timeoutMs: Int = 2_000) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .unreachable
        }
        // Tighter TCP knobs so a dead host folds to .unreachable in seconds
        // rather than the kernel's default ~75s SYN retry budget. We don't
        // need fancy features (no fast-open, no keep-alive) - this connection
        // exists for one handshake and dies.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, timeoutMs / 1000)
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.loopback]

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
        let start = DispatchTime.now()

        // Wrap the state-update callback in a continuation so the caller gets a
        // clean async result. `Once` guards against the (rare) case where
        // multiple terminal states fire - e.g. `.failed` after `.cancelled` -
        // which would otherwise resume the continuation twice and trap.
        let outcome: Outcome = await withCheckedContinuation { cont in
            let once = OnceResumer(cont: cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                    let ms = Int((Double(elapsedNs) / 1_000_000.0).rounded())
                    once.resume(with: .reachable(rttMs: ms))
                    conn.cancel()
                case .failed, .cancelled:
                    once.resume(with: .unreachable)
                case .waiting:
                    // Waiting means we couldn't form the connection (host
                    // refused / unreachable / firewalled). The Network
                    // framework will keep retrying indefinitely; we don't
                    // care - treat as unreachable and tear down.
                    once.resume(with: .unreachable)
                    conn.cancel()
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))

            // Hard ceiling: if the OS never fires a terminal state within our
            // budget (e.g. SYN-ACK lost on a stale route), we still want the
            // chip poller to make progress.
            let deadlineMs = max(250, timeoutMs)
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + .milliseconds(deadlineMs)) {
                    once.resume(with: .unreachable)
                    conn.cancel()
                }
        }
        return outcome
    }

    /// Single-shot continuation guard. NWConnection happily fires multiple
    /// terminal states in quick succession (e.g. `.cancelled` after we cancel
    /// from `.ready`); resuming a `CheckedContinuation` twice traps.
    private final class OnceResumer: @unchecked Sendable {
        private let cont: CheckedContinuation<Outcome, Never>
        private var fired = false
        private let lock = NSLock()
        init(cont: CheckedContinuation<Outcome, Never>) { self.cont = cont }
        func resume(with value: Outcome) {
            lock.lock()
            let shouldFire = !fired
            fired = true
            lock.unlock()
            if shouldFire { cont.resume(returning: value) }
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
public struct LaunchResponse: Sendable {
    public let sessionURL: String
    public let gcmKey: Data
    public let gcmKeyId: Data

    public init(sessionURL: String, gcmKey: Data, gcmKeyId: Data) {
        self.sessionURL = sessionURL
        self.gcmKey = gcmKey
        self.gcmKeyId = gcmKeyId
    }
}

// MARK: - XMLNode

/// Minimal XML tree node. We deliberately don't model namespaces, CDATA, or
/// processing instructions - the GameStream protocol uses none of them. The
/// shape is exactly what callers need: a name, optional text content, a flat
/// attribute dictionary, and ordered children.
public struct XMLNode: Sendable {
    public let name: String
    public var text: String
    public var attributes: [String: String]
    public var children: [XMLNode]

    public init(name: String,
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
    public func firstChild(named tag: String) -> XMLNode? {
        if name == tag { return self }
        for child in children {
            if let hit = child.firstChild(named: tag) { return hit }
        }
        return nil
    }

    /// All descendants with the given tag name (depth-first).
    public func descendants(named tag: String) -> [XMLNode] {
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

    /// Trimmed text content of the first descendant matching `tag`, or nil if
    /// missing. Recurses depth-first because GameStream/Sunshine wrap their
    /// data inside a `<root>` element, and most callers want the data, not
    /// the root container.
    public func string(forChild tag: String) -> String? {
        firstChild(named: tag)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func int(forChild tag: String) -> Int? {
        string(forChild: tag).flatMap(Int.init)
    }

    public func bool(forChild tag: String) -> Bool? {
        // GameStream uses "1"/"0" rather than "true"/"false".
        guard let text = string(forChild: tag) else { return nil }
        return text == "1"
    }
}

// MARK: - NetworkClient

public actor NetworkClient {

    // MARK: State

    /// The host we're talking to. Mutated as we learn things - the HTTPS port
    /// can come from /serverinfo, and the server cert is pinned on first
    /// successful HTTPS handshake.
    var server: ServerInfo

    /// Client cert + key (PEM), snapshotted from IdentityManager on first use.
    /// ControlTransport feeds them straight into OpenSSL for mutual TLS - no
    /// SecIdentity, no keychain. The host-cert pin lives on `server.serverCertPEM`
    /// and is passed per request.
    var clientCertPEM: String?
    var clientKeyPEM: String?

    /// The 32-hex client uniqueid generated by IdentityManager. We *load* it
    /// for identity-prep symmetry, but we don't send it on the wire - see
    /// the comment above `Self.wireUniqueID`.
    var clientUniqueID: String?

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Network")

    // MARK: Init

    public init(server: ServerInfo) {
        self.server = server
        // The host-cert pin (if any) rides on `server.serverCertPEM` already;
        // ControlTransport reads it per request. Nothing else to set up - the
        // control channel is connectionless from this object's point of view.
    }

    /// No-op: the control channel is per-request (ControlTransport opens and
    /// closes a connection per call), so there's nothing persistent to tear
    /// down. Kept only so the existing `await net.shutdown()` call sites don't churn.
    public func shutdown() {}

    /// Called by `PairingClient` once the host has proven possession of its
    /// private key (the RSA-signature step in /pair's pairingsecret round-trip).
    /// The cert installed here is fully validated and is what subsequent HTTPS
    /// connections must match - ControlTransport pins `server.serverCertPEM` by
    /// exact DER. This is the ONE write path for the pin - `fetchServerInfo` no
    /// longer auto-pins.
    public func setPinnedHostCert(pem: String) {
        server.serverCertPEM = pem
        log.info("Host cert pinned (length \(pem.count, privacy: .public) bytes)")
    }

    /// Currently-pinned host cert in PEM form, if any. Useful for the UI
    /// to display the fingerprint, or for the caller to persist it.
    public func pinnedServerCertPEM() -> String? {
        server.serverCertPEM
    }

    // MARK: Identity prep
    //
    // Snapshot the client cert + key (PEM) out of the IdentityManager actor
    // before any HTTPS call. ControlTransport feeds them straight into OpenSSL.

    func ensureIdentityLoaded() async throws {
        if clientCertPEM != nil { return }
        let im = IdentityManager.shared
        clientCertPEM   = try await im.clientCertPEM()
        clientKeyPEM    = try await im.clientKeyPEM()
        clientUniqueID  = try await im.uniqueID()
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

    // MARK: - Redaction helpers (logged-output sanitization)
    //
    // The launch / resume URL query carries session crypto material that
    // must never reach unified log:
    //
    //   - rikey      : per-session AES-128 key for the remote-input channel.
    //   - rikeyid    : signed-int derived from the first 4 bytes of the IV.
    //   - gcmkey     : AES key for the control-channel GCM transport
    //                  (Sunshine only echoes it on the launch response).
    //   - gcmkeyid   : matching key-id.
    //   - uuid       : per-request nonce (16 random bytes hex). Not load-
    //                  bearing for crypto on its own, but combined with
    //                  the request URL it's a session-correlation token.
    //   - uniqueid   : the well-known shared client identifier; not secret
    //                  per se, but redacting it keeps logs consistent
    //                  across builds.
    //
    // These names are matched case-insensitively against query parameter
    // names AND XML tag names (the host echoes some of them back).

    /// Lowercased query/tag names whose values must be redacted before
    /// logging. Used by the query-dump in `runLaunchLike` and `dumpXMLRedacted`.
    static let sensitiveQueryKeys: Set<String> = [
        "rikey", "rikeyid", "gcmkey", "gcmkeyid", "uuid", "uniqueid"
    ]

    /// Same shape as `dumpXML`, but every child whose tag name matches
    /// `sensitiveQueryKeys` has its body replaced with `<redacted>` so
    /// gcmkey / gcmkeyid (echoed by Sunshine on /launch /resume) never
    /// reach the log. We still preserve the tag name itself - that's
    /// the data point we actually need for the "field renamed?" diff.
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
