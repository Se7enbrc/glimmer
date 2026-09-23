//
//  NetworkClient+Endpoints.swift
//
//  The HTTPS REST surface NetworkClient exposes against a host (GameStream /
//  Sunshine nvhttp): /serverinfo, /applist, /launch + /resume, /cancel, the
//  low-level request plumbing, status checks and codec-mode decoding, plus the
//  small request helpers. Split out of Network.swift to keep each unit focused;
//  see that file for the actor's state, identity prep, and TLS wiring.
//

import Foundation
import Network
import os.log

extension NetworkClient {

    // MARK: - Endpoint: /serverinfo
    //
    // Threat model (C2): once we've pinned a host cert we MUST NOT silently
    // re-bind it on TLS failure. The original implementation fell back from
    // HTTPS to plain HTTP on any TLS error and accepted whatever cert the
    // host presented on the next handshake - which gave a same-LAN attacker
    // a free MITM whenever they could induce one TLS connection to fail
    // (TCP reset, ARP spoof, captive-portal injection, etc).
    //
    // The new contract:
    //   - pinnedHostCert == nil:  HTTP fallback for unpaired discovery is
    //                              still allowed (there's no TLS to validate
    //                              yet). The pin gets set the moment the
    //                              pairing handshake captures the host's
    //                              real cert in Pairing.swift.
    //   - pinnedHostCert != nil:  HTTPS only. Any TLS failure surfaces a
    //                              loud `hostUnreachable` to the UI. No
    //                              automatic re-pin. A user who legitimately
    //                              rotated their host cert must unpair + re-
    //                              pair explicitly - that's a deliberate
    //                              friction, the alternative is "the on-path
    //                              attacker rotates it for them".

    public func fetchServerInfo() async throws -> ServerInfo {
        try await ensureIdentityLoaded()

        var xml: XMLNode
        var fetchedOverPaired = false   // implicit pair-proof: HTTPS succeeded
        if server.serverCertPEM != nil {
            // Pinned. HTTPS only. Any TLS failure here is either a real
            // outage or a possible MITM - we don't try to disambiguate,
            // we just refuse and ask the user to re-pair if their host
            // genuinely rotated. See StreamError message below.
            do {
                xml = try await rawRequest(path: "serverinfo",
                                           query: [:],
                                           extraQuery: nil,
                                           usePaired: true,
                                           timeout: Self.controlTimeout)
                try Self.verifyStatus(xml)
                fetchedOverPaired = true
            } catch let err as StreamError {
                if case .hostUnreachable(let detail) = err {
                    log.error("HTTPS to pinned host failed (\(detail, privacy: .public)) - refusing HTTP fallback to preserve cert pin")
                    // A different certificate proves 47984 answered, so the PC is up
                    // whatever the plain port says; don't let a blocked 47989 hide it.
                    if Self.isCertChange(detail) {
                        throw Self.classifyPairedPathFailure(detail, hostName: server.serverName)
                    }
                    // Disambiguate before blaming the network: a READ-ONLY
                    // plain-HTTP probe (the pin is NEVER rebound from it -
                    // the C2 contract above stands). It answers exactly one
                    // question - "is the box up at all?" - and NOTHING about
                    // pairing: Sunshine computes <PairStatus> only for HTTPS
                    // requests and reports 0 on plain HTTP unconditionally, so
                    // the earlier "probe says PairStatus=0, therefore unpaired"
                    // read turned EVERY HTTPS hiccup into a false "pair again"
                    // (2026-09-02: a wedged Sunshine HTTPS listener - 47984
                    // refusing connections while 47989 answered - was reported
                    // as "re-pair", when no client-side action could help).
                    // The HTTPS failure itself carries the diagnosis, so
                    // classify THAT once the probe proves the host is up.
                    if let probe = try? await rawRequest(path: "serverinfo",
                                                         query: [:],
                                                         extraQuery: nil,
                                                         usePaired: false,
                                                         timeout: 3),
                       (try? Self.verifyStatus(probe)) != nil {
                        throw Self.classifyPairedPathFailure(detail, hostName: server.serverName)
                    }
                    throw StreamError.hostUnreachable(detail)
                }
                throw err
            }
        } else {
            // No pin yet - this is either a fresh /serverinfo discovery
            // before pairing, or a fully unpaired flow (the user is about
            // to type a PIN into the host UI). HTTP is acceptable here
            // because there's nothing to pin yet; the real cert capture
            // happens inside the pairing handshake (Pairing.swift, the
            // `plaincert` field of the getservercert response) which then
            // calls `setPinnedHostCert` on us to lock the pin in.
            xml = try await rawRequest(path: "serverinfo",
                                       query: [:],
                                       extraQuery: nil,
                                       usePaired: false,
                                       timeout: Self.controlTimeout)
            try Self.verifyStatus(xml)
        }

        hydrateServerInfo(from: xml, fetchedOverPaired: fetchedOverPaired)
        return server
    }

    /// Map a paired-path (HTTPS) failure, once plain HTTP proved the host up, by ControlTransport's `detail`:
    /// "connect to" = the 47984 listener wedged (restart it); 401 = the PC forgot or switched off this Mac; "TLS
    /// handshake" = it forgot this Mac; cert mismatch or none = its cert changed. Pairing again fixes the last three.
    static func classifyPairedPathFailure(_ detail: String, hostName: String) -> StreamError {
        let name = hostName.isEmpty ? "The PC" : hostName
        if detail.hasPrefix("connect to") {
            return .sunshineNeedsRestart(
                "\(name) is awake, but Sunshine's secure port (47984) is refusing connections because "
                + "its HTTPS listener is stuck. Restart Sunshine on the PC; quitting Glimmer will not help."
            )
        }
        if detail.contains("Host requires pairing") {
            return .pairingFailed("\(name) no longer recognizes this Mac, or this Mac is switched off on "
                + "Sunshine's Troubleshooting page. Choose Pair Again… from the PC's ⋯ menu.")
        }
        if detail.hasPrefix("TLS handshake") {
            return .pairingFailed("\(name) rejected this Mac's certificate. Choose Pair Again… from the PC's ⋯ menu.")
        }
        if isCertChange(detail) {
            return .hostCertChanged(
                "\(name)'s certificate changed. To trust it, choose Pair Again… from the PC's ⋯ menu."
            )
        }
        // The detail is in the log line above the call; the sentence stays plain.
        return .sunshineNeedsRestart(
            "\(name) answers on its plain port but not its secure one. Restart Sunshine on the PC."
        )
    }

    /// ControlTransport's detail for a pinned PC presenting a different certificate, or none.
    static func isCertChange(_ detail: String) -> Bool {
        detail.contains("cert mismatch") || detail.contains("no certificate")
    }

    /// Populate `server` from the /serverinfo XML, split out of
    /// `fetchServerInfo`. Tag names are taken from GFE / Sunshine source;
    /// Sunshine returns the same shape as GFE 3.x for compatibility, with one
    /// or two extras. Each field falls through to its existing value when the
    /// host omits the tag, so partial responses still hydrate cleanly.
    func hydrateServerInfo(from xml: XMLNode, fetchedOverPaired: Bool) {
        if let name = xml.string(forChild: "hostname"), !name.isEmpty {
            server.serverName = name
        }
        // Host's stable GUID. GFE + Sunshine both emit it as `<uniqueid>` in
        // the /serverinfo XML - it's the host-side equivalent of the client
        // uniqueid (different value, same semantic). We pick it up here so
        // downstream code (pinned-cert storage key, host-record key) can use
        // a stable token instead of the network address. Falls through to
        // whatever was already set if the host omits the field (some early
        // Sunshine builds did) so a fresh-pair on hostname-only still works.
        if let hostUid = xml.string(forChild: "uniqueid"), !hostUid.isEmpty {
            server.uniqueId = hostUid
        }
        if let appVer = xml.string(forChild: "appversion") {
            server.appVersion = appVer
        }
        // Host primary-NIC MAC (Wake on LAN). Falls through when
        // omitted; a zeroed value is stored as-is and rejected downstream.
        if let mac = xml.string(forChild: "mac"), !mac.isEmpty {
            server.macAddress = mac
        }
        // Distinguish real GFE from Sunshine-pretending-to-be-GFE by the
        // `<state>` field. NVIDIA's state strings contain "MJOLNIR"; Sunshine
        // uses "SUNSHINE_SERVER_*". Pairing and stream start refuse real GFE.
        if let state = xml.string(forChild: "state") {
            server.isRealGFE = state.contains("MJOLNIR")
        }
        if let port = xml.int(forChild: "HttpsPort"), port > 0 {
            server.httpsPort = port
        }
        // Only a pinned mutual-TLS round proves pairing. <PairStatus> is ignored:
        // over plain HTTP anyone on the LAN can write it (Sunshine always sends
        // 0 there), and some Sunshine builds omit it or send 0 over HTTPS.
        server.pairStatus = fetchedOverPaired ? .paired : .unpaired
        if let maxLuma = xml.int(forChild: "MaxLumaPixelsHEVC") {
            server.maxLumaPixelsHEVC = maxLuma
        }
        if let codecsRaw = xml.int(forChild: "ServerCodecModeSupport") {
            server.serverCodecSupport = Self.decodeCodecMode(codecsRaw)
            server.serverCodecModeRaw = codecsRaw   // wire-format SCM_* bits, do NOT remap
        }
        // 0 = host idle, non-zero = app ID currently streaming. Drives the
        // launch-vs-resume decision in StreamSession.
        server.isBusy = xml.string(forChild: "state")?.hasSuffix("_BUSY") == true
        if let active = xml.int(forChild: "currentgame") {
            server.currentGameID = active
        }
        // SECURITY (C2): <PlainCert> is never read. `serverCertPEM` IS the pin,
        // so copying an unauthenticated cert into it pinned whoever answered.
        // Only Pairing.swift's RSA-verified handshake sets the pin.
    }

    // MARK: - Endpoint: /applist

    public func appList() async throws -> [HostApp] {
        let xml = try await rawRequest(path: "applist",
                                       query: [:],
                                       extraQuery: nil,
                                       usePaired: true,
                                       timeout: Self.controlTimeout)
        try Self.verifyStatus(xml)

        // GFE returns <root><App>...</App><App>...</App></root>. Sunshine
        // matches. Field names are AppTitle / ID / IsHdrSupported.
        return xml.descendants(named: "App").compactMap { app in
            guard let idStr = app.string(forChild: "ID"),
                  let id = Int(idStr) else { return nil }
            let title = app.string(forChild: "AppTitle") ?? "App \(id)"
            let hdr   = app.bool(forChild: "IsHdrSupported") ?? false
            // Sunshine's "IsHiddenGame" is GFE's "IsAppCollectorGame" - both
            // mean "don't surface this in the picker unless the user has
            // unhidden it". Treat either as "hidden".
            let hidden = (app.bool(forChild: "IsHiddenGame")
                          ?? app.bool(forChild: "IsAppCollectorGame")
                          ?? false)
            return HostApp(id: id, name: title, hdrCapable: hdr, hidden: hidden)
        }
    }

    // MARK: - Endpoints: /launch and /resume

    public func launch(appID: Int, config: StreamConfig) async throws -> LaunchResponse {
        try await runLaunchLike(verb: "launch", appID: appID, config: config)
    }

    public func resume(config: StreamConfig) async throws -> LaunchResponse {
        // /resume doesn't take an appid - the host knows what game is paused.
        try await runLaunchLike(verb: "resume", appID: nil, config: config)
    }

    /// Shared body for /launch and /resume. They take an almost-identical
    /// query string and parse the same way.
    func runLaunchLike(verb: String,
                       appID: Int?,
                       config: StreamConfig) async throws -> LaunchResponse {

        // The host wants the rikey (remote-input AES key) hex-encoded and the
        // rikeyid as a *signed* int derived from the first 4 bytes of the IV.
        let riKey = config.remoteInputKey ?? Self.randomBytes(16)
        let riKeyIV = config.remoteInputIV ?? Self.randomBytes(16)
        let riKeyHex = riKey.map { String(format: "%02x", $0) }.joined()
        let riKeyID = Self.bigEndianInt32(from: riKeyIV)

        // HDR signaling rides only when a 10-bit format can be negotiated: Sunshine turns HDR on from
        // hdrMode=1. The clientHdrCap* keys are moonlight-qt's, sent unchanged.
        let supports10bit = !config.videoFormats
            .isDisjoint(with: [.hevcMain10, .av1Main10])
        let hdrParams = supports10bit
            ? "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0"
              + "&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1"
              + "&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
            : ""

        let query = Self.launchQuery(config: config, riKeyHex: riKeyHex, riKeyID: riKeyID, appID: appID)
        // Append HDR params as an ordered tail blob so we keep the exact key
        // order the host expects. Building it through the dictionary would lose
        // that ordering.
        let extraTail: String? = hdrParams.isEmpty ? nil : hdrParams

        let timeout = (verb == "launch") ? Self.launchTimeout : Self.resumeTimeout

        // Log the query we're about to send (HDR negotiation diff vs
        // moonlight-qt). SECURITY: rikey / rikeyid (per-session AES key
        // and IV-derived id), uuid, and uniqueid are redacted at the
        // `.public` privacy level so the unified log doesn't carry the
        // session input encryption key. Even though rikey is single-use,
        // logs persist; an attacker pulling logs from a compromised box
        // could replay/decrypt captured input traffic from the matching
        // session window. Drop them here, period.
        let queryDump = query.sorted(by: { $0.key < $1.key })
            .map { (key, value) -> String in
                if Self.sensitiveQueryKeys.contains(key.lowercased()) {
                    return "\(key)=<redacted>"
                }
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
        let fullQuery = queryDump + (extraTail ?? "")
        log.info("\(verb, privacy: .public) URL query (sensitive params redacted): \(fullQuery, privacy: .public)")

        let xml = try await rawRequest(path: verb,
                                       query: query,
                                       extraQuery: extraTail,
                                       usePaired: true,
                                       timeout: timeout)
        try Self.verifyStatus(xml)

        // Dump the launch response so we can see what HDR-related fields the
        // host echoed back. Sunshine returns gcmkey, gcmkeyid, sessionUrl0
        // etc. SECURITY: gcmkey + gcmkeyid are the AES key + key-id the host
        // expects us to use on the control channel - never log their values.
        // `Self.dumpXMLRedacted` swaps the body for `<redacted>` on a
        // hard-coded set of sensitive tags. The remaining tag names + values
        // are still useful for diagnosing the "HDR field went missing" case
        // the original log shape existed to catch.
        log.info("\(verb, privacy: .public) response XML (sensitive fields redacted): \(Self.dumpXMLRedacted(xml), privacy: .public)")

        guard let sessionURL = xml.string(forChild: "sessionUrl0"),
              !sessionURL.isEmpty else {
            // Dump the response so we can see what field name the host actually
            // returned (case mismatch? renamed field? error in disguise?).
            // Use the redacted variant so we don't accidentally log gcmkey /
            // gcmkeyid even when the response is otherwise broken.
            let dump = Self.dumpXMLRedacted(xml)
            log.error("Launch response missing sessionUrl0. Top-level children: \(dump, privacy: .public)")
            throw StreamError.launchFailed("Host did not return an RTSP session URL")
        }

        // gcmkey / gcmkeyid aren't always present on GFE - only Sunshine
        // sends them. If absent we fall back to the rikey, which is what the
        // C++ client does (it uses the same key for both channels).
        let gcmKey: Data
        if let hex = xml.string(forChild: "gcmkey"), let bytes = Self.hexDecode(hex) {
            gcmKey = bytes
        } else {
            gcmKey = riKey
        }
        let gcmKeyId: Data
        if let hex = xml.string(forChild: "gcmkeyid"), let bytes = Self.hexDecode(hex) {
            gcmKeyId = bytes
        } else {
            gcmKeyId = riKeyIV
        }

        return LaunchResponse(sessionURL: sessionURL,
                              gcmKey: gcmKey,
                              gcmKeyId: gcmKeyId)
    }

    /// The keyed part of the /launch and /resume query (HDR rides separately,
    /// as an ordered tail). Static so the wire values are checkable offline.
    static func launchQuery(config: StreamConfig, riKeyHex: String, riKeyID: Int32, appID: Int?) -> [String: String] {
        var query: [String: String] = [
            "mode": "\(config.width)x\(config.height)x\(config.fps)",
            "additionalStates": "1",
            "sops": "1",
            "rikey": riKeyHex,
            "rikeyid": "\(riKeyID)",
            // 1 = the PC keeps playing its own sound (Moonlight's "play audio on host").
            "localAudioPlayMode": config.playAudioOnHost ? "1" : "0",
            "surroundAudioInfo": "\(gl_surround_audio_info_from_audio_configuration(config.audio.cValue))",
            "remoteControllersBitmap": "0",
            "gcmap": "0",
            "gcpersist": "0",
            // Encrypted RTSP (rtspenc://), as moonlight's LiGetLaunchUrlQueryParameters asks.
            // A GameStream PC is refused before /launch, so only Sunshine sees it.
            "corever": "1"
        ]
        if let appID { query["appid"] = "\(appID)" }
        return query
    }

    // MARK: - Endpoint: /cancel

    public func cancel() async throws {
        let xml = try await rawRequest(path: "cancel",
                                       query: [:],
                                       extraQuery: nil,
                                       usePaired: true,
                                       timeout: Self.controlTimeout)
        try Self.verifyStatus(xml)
    }
}
