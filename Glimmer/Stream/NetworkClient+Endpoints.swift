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
                    // Disambiguate before blaming the network: a READ-ONLY
                    // plain-HTTP probe (the pin is NEVER rebound from it -
                    // the C2 contract above stands). Three outcomes:
                    //   * host answers, PairStatus=0 → the host is up but
                    //     doesn't know THIS client (typical after a migrated
                    //     srvcert seeded the pin while pairing was never done
                    //     by Glimmer, or a host-side re-install dropped us).
                    //     Mutual TLS then fails in ~150ms and used to surface
                    //     as "couldn't reach / is it awake" - dishonest.
                    //   * host answers, PairStatus=1 → genuine cert weirdness;
                    //     keep the loud mismatch message.
                    //   * probe also fails → host genuinely unreachable.
                    if let probe = try? await rawRequest(path: "serverinfo",
                                                         query: [:],
                                                         extraQuery: nil,
                                                         usePaired: false,
                                                         timeout: 3),
                       (try? Self.verifyStatus(probe)) != nil {
                        if (probe.int(forChild: "PairStatus") ?? 0) == 0 {
                            throw StreamError.pairingFailed(
                                "Host answered but doesn't recognize this Mac - pair (again) from Settings → PCs."
                            )
                        }
                        throw StreamError.hostUnreachable(
                            "Host cert mismatch - possible MITM. Settings → PCs → ... → Trust new cert and re-pair."
                        )
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

    /// Populate `server` from the /serverinfo XML, split out of
    /// `fetchServerInfo`. Tag names are taken from GFE / Sunshine source;
    /// Sunshine returns the same shape as GFE 3.x for compatibility, with one
    /// or two extras. Each field falls through to its existing value when the
    /// host omits the tag, so partial responses still hydrate cleanly.
    private func hydrateServerInfo(from xml: XMLNode, fetchedOverPaired: Bool) {
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
        if let gfeVer = xml.string(forChild: "GfeVersion") {
            server.gfeVersion = gfeVer
        }
        // Host primary-NIC MAC (WoL / Luna power gate). Falls through when
        // omitted; a zeroed value is stored as-is and rejected downstream.
        if let mac = xml.string(forChild: "mac"), !mac.isEmpty {
            server.macAddress = mac
        }
        // Distinguish real GFE from Sunshine-pretending-to-be-GFE by the
        // `<state>` field. NVIDIA's state strings contain "MJOLNIR"; Sunshine
        // uses "SUNSHINE_SERVER_*". Used to gate the fps>60 launch-URL quirk.
        if let state = xml.string(forChild: "state") {
            server.isRealGFE = state.contains("MJOLNIR")
        }
        if let port = xml.int(forChild: "HttpsPort"), port > 0 {
            server.httpsPort = port
        }
        if let pairFlag = xml.int(forChild: "PairStatus") {
            server.pairStatus = (pairFlag == 1) ? .paired : .unpaired
        }
        // Successful mutual-TLS handshake is itself proof of pairing - the host
        // wouldn't have accepted our client cert if our identity weren't in
        // its allowlist. Some Sunshine builds omit <PairStatus> from the HTTPS
        // response (or return 0 even when paired); don't be fooled.
        if fetchedOverPaired {
            server.pairStatus = .paired
        }
        if let maxLuma = xml.int(forChild: "MaxLumaPixelsHEVC") {
            server.maxLumaPixelsHEVC = maxLuma
        }
        if let codecsRaw = xml.int(forChild: "ServerCodecModeSupport") {
            server.serverCodecSupport = Self.decodeCodecMode(codecsRaw)
            server.serverCodecModeRaw = codecsRaw   // wire-format SCM_* bits, do NOT remap
        }
        // 0 = host idle, non-zero = app ID currently streaming. Drives the
        // launch-vs-resume decision in StreamSession.
        if let active = xml.int(forChild: "currentgame") {
            server.currentGameID = active
        }
        // Sunshine exposes the host certificate inline so a fresh client can
        // surface the cert hash to the user before pairing. GFE doesn't
        // include it; in that case the cert only becomes visible during
        // the pairing handshake (via /pair's plaincert blob).
        //
        // SECURITY (C2): we DO NOT auto-bind a pin here on a previously
        // unpinned host. That used to be the path a same-LAN attacker
        // could ride to silently pin their own cert as the host's. The
        // real pin gets set by Pairing.swift's `runPairingFlow` once the
        // user has typed a PIN that the *real* host can prove it knows -
        // the host's plaincert at that point is authenticated by the RSA
        // signature step. Only THEN is the cert worth pinning.
        //
        // We still expose the host cert opportunistically on ServerInfo so
        // a future "show fingerprint to user" UI has something to render -
        // but it does not become a pin until pairing succeeds.
        if server.serverCertPEM == nil {
            if let pemFromXML = xml.string(forChild: "PlainCert"), !pemFromXML.isEmpty {
                server.serverCertPEM = pemFromXML
            }
        }
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

        // HDR signaling - only attach the static-metadata bag if the client
        // actually intends to negotiate a 10-bit format. Without this, GFE
        // 3.22+ will refuse to enable HDR even on a 10-bit-capable host.
        let supports10bit = !config.videoFormats
            .isDisjoint(with: [.hevcMain10, .av1Main10])
        let hdrParams = supports10bit
            ? "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0"
              + "&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1"
              + "&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
            : ""

        // GFE >60fps SOPS quirk: feeding real GFE a value >60 makes it pick
        // 720p60 instead of the resolution we asked for. Sunshine, which
        // pretends to be GFE in /serverinfo for compatibility, does NOT have
        // this bug - and crucially, sending fps=0 to Sunshine makes it
        // misinterpret the request and fall back to safe SDR 8-bit defaults,
        // which silently kills HDR negotiation. Gate the workaround on the
        // MJOLNIR-detected `isRealGFE` flag instead of any-non-empty
        // gfeVersion.
        let fpsField = (server.isRealGFE && config.fps > 60) ? 0 : config.fps

        var query: [String: String] = [
            "mode": "\(config.width)x\(config.height)x\(fpsField)",
            "additionalStates": "1",
            "sops": "1",
            "rikey": riKeyHex,
            "rikeyid": "\(riKeyID)",
            "localAudioPlayMode": "0",
            "surroundAudioInfo": "\(gl_surround_audio_info_from_audio_configuration(config.audio.cValue))",
            "remoteControllersBitmap": "0",
            "gcmap": "0",
            "gcpersist": "0"
        ]
        if let appID { query["appid"] = "\(appID)" }
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
