//
//  Pairing.swift
//
//  PIN-based pairing handshake with a GameStream host (GFE or Sunshine).
//
//  Ported from moonlight-qt's app/backend/nvpairingmanager.{cpp,h} (GPLv3; see
//  CREDITS.md). The protocol is a five-round-trip dance over plain HTTP plus a
//  final HTTPS liveness check; each round mixes AES-128-ECB symmetric crypto
//  (keyed off the PIN the user types into the host UI) with RSA signatures over our
//  long-lived client cert. If any step deviates by a single byte the host
//  silently rejects us, so the comments below are unusually thorough —
//  this is the kind of code where "it didn't work" debug sessions are
//  measured in hours.
//
//  All hex on the wire is uppercase. All AES operations use 16-byte blocks
//  with padding explicitly disabled — moonlight's protocol is raw ECB on
//  pre-sized buffers, not the higher-level CBC/CTR shapes you'd expect.
//

import Foundation
import os
public actor PairingClient {

    // MARK: Dependencies

    private let network: NetworkClient
    private var server: ServerInfo

    private let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Pairing")

    // MARK: Init

    public init(network: NetworkClient, server: ServerInfo) {
        self.network = network
        self.server = server
    }

    // MARK: Public API

    /// Walk the full PIN handshake. On success the returned `ServerInfo` has
    /// `pairStatus = .paired` and `serverCertPEM` populated with the host's
    /// pinned certificate. On failure we always send `/unpair` to the host
    /// before throwing — leaving a half-paired state on the host side trips
    /// "Already pairing" errors on retry.
    public func pair(pin: String) async throws -> ServerInfo {
        do {
            return try await runPairingFlow(pin: pin)
        } catch {
            // Best-effort cleanup. Swallow any error from unpair — we're
            // already in the failure path and the original error is what
            // the caller cares about.
            await sendUnpair()
            throw error
        }
    }

    // MARK: - Pairing flow
    //
    // The flow has five HTTP rounds plus a final HTTPS challenge. Each round
    // is a one-shot GET with all parameters in the query string; there's no
    // session state on the host side beyond what we tell it on each call.

    private func runPairingFlow(pin: String) async throws -> ServerInfo {

        // Wrap the whole flow in an Instruments interval so a stuck pair
        // shows exactly where it stopped. Per-step events below mark every
        // handshake round so the timeline reads as: PairingFlow opens →
        // getservercert → clientchallenge → serverchallengeresp →
        // pairingsecret → clientpairingsecret → pairchallenge → PairingFlow
        // closes.
        let pairingSignpostID = OSSignposter.pairing.makeSignpostID()
        let pairingIntervalState = OSSignposter.pairing.beginInterval(
            "PairingFlow",
            id: pairingSignpostID,
            "host=\(self.server.address, privacy: .public)")

        // Outcome is appended to the interval close. Default = "failed" so a
        // thrown error from anywhere below still closes the interval cleanly.
        // The defer fires before the throw propagates.
        var pairingOutcome: StaticString = "failed"
        defer {
            OSSignposter.pairing.endInterval(
                "PairingFlow",
                pairingIntervalState,
                "outcome=\(pairingOutcome, privacy: .public)")
        }

        // ---------------------------------------------------------------
        // Step 0: figure out which hash algorithm to use.
        //
        // Gen 7+ (GFE 3.x and all Sunshine builds) uses SHA-256 with a
        // 32-byte hash. Older GFE used SHA-1 + 20 bytes. We sniff the major
        // version from server.appVersion ("7.1.431.0" -> 7). If we don't have
        // a version string yet, assume modern — Sunshine never advertises a
        // version field shape consistent with old GFE.
        // ---------------------------------------------------------------
        let useSha256 = parseMajorVersion(server.appVersion) >= 7 || server.appVersion == nil
        let hashLength = useSha256 ? 32 : 20
        log.info("Starting pair with hashLength=\(hashLength, privacy: .public)")

        // ---------------------------------------------------------------
        // Step 1: getservercert
        //
        // We send a fresh 16-byte salt + our PEM cert (hex-encoded). The host
        // replies with paired=1 + plaincert=<host cert hex>. From this point
        // on we treat that cert as the host's identity — it's pinned for all
        // subsequent TLS verification until pairing finishes (or fails).
        // ---------------------------------------------------------------
        let salt = try Self.randomBytes(16)
        let clientCertPEM = try await IdentityManager.shared.clientCertPEM()
        let clientCertBytes = Data(clientCertPEM.utf8)

        let serverCertPEM = try await fetchServerCert(
            salt: salt,
            clientCertBytes: clientCertBytes,
            signpostID: pairingSignpostID
        )

        // ---------------------------------------------------------------
        // Step 2: derive the AES key from the salt + PIN.
        //
        // Identity owns the SHA-256(salt || pin)[0..16] computation — keeping
        // it there means both sides of the codebase (us + the discovery flow,
        // if it ever needs to verify) hash the PIN identically.
        // ---------------------------------------------------------------
        let aesKey = try await IdentityManager.shared.aesKey(forPIN: pin, salt: salt)
        guard aesKey.count == 16 else {
            throw StreamError.crypto("derived AES key is not 16 bytes")
        }

        // ---------------------------------------------------------------
        // Step 3: clientchallenge
        //
        // Send a random 16-byte block, AES-ECB-encrypted with the PIN-derived
        // key. The host will decrypt it, prove it can do so by including the
        // result in its own challenge response, and send back its own random
        // bytes alongside a hash of (our challenge || its cert sig).
        // ---------------------------------------------------------------
        let randomChallenge = try Self.randomBytes(16)
        let encryptedClientChallenge = try Self.aesEcbEncrypt(randomChallenge, key: aesKey)

        let challengeResp = try await pairRound(
            stepLabel: "clientchallenge",
            signpostID: pairingSignpostID,
            query: ["clientchallenge": encryptedClientChallenge.hex()],
            usePaired: false,
            failureMessage: "clientchallenge: host returned paired!=1 (likely wrong PIN entry mode)"
        )

        // ---------------------------------------------------------------
        // Step 4: serverchallengeresp
        //
        // Decrypt the host's response (size depends on the hash algo: hash
        // length + 16-byte server challenge + cert sig). Then construct OUR
        // proof:
        //   hash( hostServerChallenge || ourCertSig || clientSecret )
        // and send it back encrypted. The host uses this to prove WE know
        // the PIN.
        // ---------------------------------------------------------------
        let parsed = try parseServerChallenge(
            challengeResp: challengeResp,
            aesKey: aesKey,
            hashLength: hashLength
        )

        let clientSecret = try Self.randomBytes(16)
        let encryptedHash = try buildEncryptedProofHash(
            hostServerChallenge: parsed.hostServerChallenge,
            clientSecret: clientSecret,
            clientCertPEM: clientCertPEM,
            aesKey: aesKey,
            useSha256: useSha256
        )

        let serverChallengeRespXml = try await pairRound(
            stepLabel: "serverchallengeresp",
            signpostID: pairingSignpostID,
            query: ["serverchallengeresp": encryptedHash.hex()],
            usePaired: false,
            failureMessage: "serverchallengeresp: host rejected our hash"
        )

        // ---------------------------------------------------------------
        // Step 5: pairingsecret
        //
        // Host sends back its random 16-byte serverSecret followed by an RSA
        // signature over (serverSecret || serverCert) using its private key.
        // We:
        //   a) RSA-verify the sig against the host cert's public key — this
        //      is the MITM check.
        //   b) Recompute hash(ourClientChallenge || hostCertSig || serverSecret)
        //      and compare to `serverResponseHash` from step 4. Mismatch
        //      means the host computed it with a different PIN-derived AES
        //      key, i.e. the user typed the wrong PIN.
        // ---------------------------------------------------------------
        // Step 5 verification: (a) RSA-verify the host's signature over a value
        // we picked (MITM check) and (b) confirm the user typed the right PIN.
        // Both failures collapse to `.pairingRejected` — see the helper.
        try verifyHostProof(
            serverChallengeRespXml: serverChallengeRespXml,
            randomChallenge: randomChallenge,
            serverCertPEM: serverCertPEM,
            serverResponseHash: parsed.serverResponseHash,
            useSha256: useSha256
        )

        // ---------------------------------------------------------------
        // IN-MEMORY PIN ONLY — DO NOT PERSIST YET.
        //
        // We've now (a) RSA-verified the host's signature over a value
        // we picked, which proves the host holds the private key matching
        // `serverCertPEM`, and (b) confirmed the user typed the right
        // PIN, which proves we're talking to a host that knew the PIN
        // out-of-band. Steps 6 and 7 need the cert pinned at the
        // NetworkClient layer to even attempt TLS, so we have to set the
        // in-memory pin here.
        //
        // SECURITY (#11): the PERSISTED pin (PinnedCertStore.store(...))
        // does NOT happen here. It happens AFTER step 7
        // (HTTPS pairchallenge) returns paired=1 — at which point the
        // host has proven, over a TLS handshake gated by THIS exact
        // cert, that it can speak the moonlight protocol with our
        // client cert in its allowlist. If a mid-handshake hijacker
        // somehow makes it through (a) and (b) but fails to complete
        // step 6 or step 7, we throw and never persist; the bogus pin
        // dies with the NetworkClient at process scope. Earlier shapes
        // of this code persisted the pin right here at step 5, which
        // meant a mid-pair MITM that survived (a) + (b) but couldn't
        // complete the HTTPS round-trip still got pinned permanently.
        // That's the bug we are closing.
        //
        // Critically, this is the ONLY place the in-memory pin gets
        // installed. `NetworkClient.fetchServerInfo` no longer
        // auto-pins; the earlier behaviour (silent re-bind on TLS
        // error) is C2.
        // ---------------------------------------------------------------
        _ = try await network.setPinnedHostCert(pem: serverCertPEM)

        try await completeClientPairing(
            clientSecret: clientSecret,
            signpostID: pairingSignpostID
        )

        // Success — persist into the ServerInfo we hand back.
        server.serverCertPEM = serverCertPEM
        server.pairStatus = .paired

        // ---------------------------------------------------------------
        // PERSISTED PIN COMMIT — SECURITY-CRITICAL LATE COMMIT.
        // SECURITY (#11): this block MUST stay at the very bottom of the
        // pair flow, AFTER step 7 (HTTPS pairchallenge) has returned a
        // paired=1 over a TLS handshake gated by the in-memory pin set
        // at step 5. Moving this block earlier in the flow re-introduces
        // a window where a mid-handshake hijacker can get pinned: an
        // attacker who survives the symmetric crypto rounds but loses
        // step 6 / step 7 must NOT leave a persisted pin behind.
        // Do not refactor this block above the step 7
        // `verifyResponseStatus` / `paired=="1"` checks — if you're
        // considering moving it, you're reopening exactly the bug this
        // comment is here to prevent.
        // ---------------------------------------------------------------
        //
        // Keyed by the host's UUID so a fresh process launch can re-load
        // the pin without re-pairing. The host UUID (not the user's) is
        // the right key because moonlight-qt identifies hosts by
        // uniqueId — this aligns with how the rest of Glimmer looks up
        // paired hosts. We store the PEM (not the raw SecCertificate)
        // for forward-compat: PEM survives keychain wipes, OS
        // migrations, and Time Machine restores in a way that
        // SecCertificate refs do not. The cert is public information so
        // the same-UID-readable concern from H1 doesn't apply here.
        //
        // If the host's cert ever rotates (Sunshine reinstall, OS reset)
        // the user lands on the `NetworkClient.fetchServerInfo` pin-mismatch
        // error which directs them to Settings → PCs → … → "Trust new cert
        // and re-pair". That action wipes the pin and reopens the
        // PairSheet — the next successful run through this function
        // overwrites the persisted PEM with the new one.
        persistPinnedCert(serverCertPEM: serverCertPEM)

        log.info("Pairing succeeded for \(self.server.address, privacy: .public)")
        pairingOutcome = "success"
        return server
    }

    /// Step 1 (getservercert), split out of `runPairingFlow`: send a fresh salt
    /// + our PEM cert (hex-encoded), then decode the host's pinned cert from the
    /// `plaincert` hex blob. From here on we treat that cert as the host's
    /// identity for all subsequent TLS verification until pairing finishes.
    private func fetchServerCert(
        salt: Data,
        clientCertBytes: Data,
        signpostID: OSSignpostID
    ) async throws -> String {
        let getCertResp = try await pairRound(
            stepLabel: "getservercert",
            signpostID: signpostID,
            query: [
                "phrase": "getservercert",
                "salt": salt.hex(),
                "clientcert": clientCertBytes.hex()
            ],
            usePaired: false,
            failureMessage: "getservercert: host did not return paired=1"
        )
        guard let plainCertHex = Self.xmlString(getCertResp, tag: "plaincert"),
              !plainCertHex.isEmpty,
              let serverCertBytes = Data(hex: plainCertHex) else {
            // Empty plaincert means the host is mid-pair with someone else.
            // Mirror moonlight's behaviour — kick its state machine and bail.
            throw StreamError.pairingFailed(
                "getservercert: plaincert missing (host is likely already pairing with another client)")
        }

        // The host's cert is PEM-encoded ASCII inside the hex blob.
        guard let serverCertPEM = String(data: serverCertBytes, encoding: .utf8) else {
            throw StreamError.pairingFailed("plaincert was not valid UTF-8 PEM")
        }
        return serverCertPEM
    }

    /// Decode + decrypt the host's step-3 challenge response, split out of
    /// `runPairingFlow`. Returns the host's own hash (held for the
    /// PIN-correctness check after step 5) and the host's 16-byte challenge.
    private func parseServerChallenge(
        challengeResp: XMLNode,
        aesKey: Data,
        hashLength: Int
    ) throws -> (serverResponseHash: Data, hostServerChallenge: Data) {
        guard let challengeRespHex = Self.xmlString(challengeResp, tag: "challengeresponse"),
              let challengeRespBytes = Data(hex: challengeRespHex) else {
            throw StreamError.pairingFailed("clientchallenge: missing challengeresponse field")
        }
        let challengeRespPlain = try Self.aesEcbDecrypt(challengeRespBytes, key: aesKey)

        // First `hashLength` bytes are the host's own hash; we hold onto it
        // for the PIN-correctness check after step 5.
        guard challengeRespPlain.count >= hashLength + 16 else {
            throw StreamError.pairingFailed(
                "clientchallenge: decrypted response too short (\(challengeRespPlain.count) bytes)")
        }
        let serverResponseHash = challengeRespPlain.prefix(hashLength)
        let hostServerChallenge = challengeRespPlain
            .dropFirst(hashLength)
            .prefix(16)
        return (Data(serverResponseHash), Data(hostServerChallenge))
    }

    /// One handshake round of the pairing flow: emit the per-step signpost
    /// event, fire the one-shot `pair` GET, verify the HTTP status, and assert
    /// the host returned `paired=1`. Returns the parsed XML so the caller can
    /// pull round-specific fields. `devicename`/`updateState` are added here so
    /// callers only specify the round's distinguishing query keys.
    private func pairRound(
        stepLabel: StaticString,
        signpostID: OSSignpostID,
        query: [String: String],
        usePaired: Bool,
        failureMessage: String
    ) async throws -> XMLNode {
        OSSignposter.pairing.emitEvent(
            "PairingStep",
            id: signpostID,
            "step=\(stepLabel)")
        var fullQuery = ["devicename": "roth", "updateState": "1"]
        for (key, value) in query { fullQuery[key] = value }
        let response = try await network.request(
            path: "pair",
            query: fullQuery,
            usePaired: usePaired,
            timeout: NetworkClient.pairTimeout
        )
        try Self.verifyResponseStatus(response)
        guard Self.xmlString(response, tag: "paired") == "1" else {
            throw StreamError.pairingFailed(failureMessage)
        }
        return response
    }

    /// Steps 6 + 7 of the pair flow, split out of `runPairingFlow`.
    ///
    /// Step 6 (clientpairingsecret): send our clientSecret plus an RSA signature
    /// over it using our private key; the host verifies with the public key it
    /// already has (from our cert in step 1). Step 7 (HTTPS pairchallenge): the
    /// final liveness check over TLS — by now the host has our cert in its
    /// allowlist; this call confirms it. A TLS failure here means we never got
    /// fully added on the host side. Both rounds throw on a non-`paired=1` reply.
    private func completeClientPairing(
        clientSecret: Data,
        signpostID: OSSignpostID
    ) async throws {
        let clientKeyPEM = try await IdentityManager.shared.clientKeyPEM()
        let signedClientSecret = try Self.signMessage(
            Data(clientSecret),
            privateKeyPEM: clientKeyPEM
        )
        var clientPairingSecret = Data()
        clientPairingSecret.append(clientSecret)
        clientPairingSecret.append(signedClientSecret)

        _ = try await pairRound(
            stepLabel: "clientpairingsecret",
            signpostID: signpostID,
            query: ["clientpairingsecret": clientPairingSecret.hex()],
            usePaired: false,
            failureMessage: "clientpairingsecret: host rejected our signed secret"
        )

        _ = try await pairRound(
            stepLabel: "pairchallenge",
            signpostID: signpostID,
            query: ["phrase": "pairchallenge"],
            usePaired: true,
            failureMessage: "pairchallenge: host did not confirm paired status over TLS"
        )
    }

    /// Build our step-4 (serverchallengeresp) proof, split out of
    /// `runPairingFlow`: hash(hostServerChallenge || ourCertSig || clientSecret),
    /// zero-padded to a 32-byte AES block multiple, then AES-ECB-encrypted with
    /// the PIN-derived key. The host uses this to prove WE know the PIN.
    private func buildEncryptedProofHash(
        hostServerChallenge: Data,
        clientSecret: Data,
        clientCertPEM: String,
        aesKey: Data,
        useSha256: Bool
    ) throws -> Data {
        let ourCertSig = try Self.signatureFromPemCert(clientCertPEM)

        // Build challengeResponse: hostServerChallenge || ourCertSig || clientSecret
        var challengeRespPayload = Data()
        challengeRespPayload.append(contentsOf: hostServerChallenge)
        challengeRespPayload.append(ourCertSig)
        challengeRespPayload.append(clientSecret)

        let challengeRespHash = try Self.digest(challengeRespPayload, sha256: useSha256)

        // Pad the hash up to 32 bytes so AES sees an even block multiple.
        // moonlight does the same `resize(32)` after hashing — the extra
        // zero bytes are part of the protocol, not just an alignment quirk.
        var paddedHash = challengeRespHash
        if paddedHash.count < 32 {
            paddedHash.append(Data(repeating: 0, count: 32 - paddedHash.count))
        }
        return try Self.aesEcbEncrypt(paddedHash, key: aesKey)
    }

    /// Step 5 host-proof verification, split out of `runPairingFlow`.
    ///
    /// (a) MITM check.
    /// SECURITY (#10): collapse MITM-detection and wrong-PIN errors
    /// into a single externally-visible `.pairingRejected`. The
    /// attacker shouldn't get to learn whether their attempt failed
    /// because the PIN was wrong (offline-brute-force the PIN) or
    /// because their cert didn't sign the secret (give up + switch
    /// tactics). Both fail at the same "pairing rejected" boundary.
    /// The actual cause is still logged at `.private` privacy for
    /// local debugging.
    private func verifyHostProof(
        serverChallengeRespXml: XMLNode,
        randomChallenge: Data,
        serverCertPEM: String,
        serverResponseHash: Data,
        useSha256: Bool
    ) throws {
        // Step 5 payload: the host's random 16-byte serverSecret followed by an
        // RSA signature over (serverSecret || serverCert) using its private key.
        guard let pairingSecretHex = Self.xmlString(serverChallengeRespXml, tag: "pairingsecret"),
              let pairingSecret = Data(hex: pairingSecretHex) else {
            throw StreamError.pairingFailed("serverchallengeresp: missing pairingsecret")
        }
        guard pairingSecret.count >= 16 else {
            throw StreamError.pairingFailed("pairingsecret too short (\(pairingSecret.count) bytes)")
        }
        let serverSecret = pairingSecret.prefix(16)
        let serverSignature = pairingSecret.dropFirst(16)

        // (a) MITM check.
        let sigOK = try Self.verifySignature(
            data: Data(serverSecret),
            signature: Data(serverSignature),
            serverCertPEM: serverCertPEM
        )
        guard sigOK else {
            log.error(
                """
                Pairing rejected (host signature failed verification — \
                possible MITM at \(self.server.address, privacy: .private(mask: .hash)))
                """
            )
            throw StreamError.pairingRejected
        }

        // (b) PIN-correctness check.
        var expectedResponse = Data()
        expectedResponse.append(randomChallenge)
        expectedResponse.append(try Self.signatureFromPemCert(serverCertPEM))
        expectedResponse.append(contentsOf: serverSecret)
        let expectedResponseHash = try Self.digest(expectedResponse, sha256: useSha256)

        guard expectedResponseHash == Data(serverResponseHash) else {
            // Wrong PIN — same external surface as the MITM branch so an
            // attacker can't distinguish "you typed the wrong digit" from
            // "your cert didn't sign right." Internal log carries the
            // distinction at `.private`.
            log.error(
                """
                Pairing rejected (response-hash mismatch — \
                wrong PIN typed at \(self.server.address, privacy: .private(mask: .hash)))
                """
            )
            throw StreamError.pairingRejected
        }
    }

    /// Commit the verified host cert to the file-backed pin store.
    ///
    /// SECURITY (#11): the caller invokes this ONLY at the very bottom of
    /// `runPairingFlow`, after step 7 (HTTPS pairchallenge) has confirmed
    /// paired=1 over a TLS handshake gated by the in-memory pin set at step 5.
    /// A storage failure must NOT abort an otherwise-successful pair: the cert
    /// is already good for this process (it lives in memory on NetworkClient);
    /// only the next-launch pin is lost, so we log loudly and continue.
    private func persistPinnedCert(serverCertPEM: String) {
        guard !self.server.uniqueId.isEmpty else {
            log.error("No host uniqueId on ServerInfo at pairing-success — cannot persist pin; cert will need re-pairing on next launch")
            return
        }
        // SECURITY (#4 + #9): persist into the file-backed
        // PinnedCertStore. Atomic mode-0600 write; the same-UID-
        // process write surface that UserDefaults exposed (cfprefsd
        // is shared) goes away because the file is in our
        // Application Support container with owner-only perms.
        do {
            try PinnedCertStore.store(pem: serverCertPEM,
                                      forHostID: self.server.uniqueId)
            log.info("Persisted pinned host cert (file-store) for host id=\(self.server.uniqueId, privacy: .public)")
        } catch {
            // Storage failure should not abort a successful pair —
            // the cert is still good for THIS process (it's in
            // memory on NetworkClient), the user just won't be
            // pinned on the next launch. Log loudly so the failure
            // doesn't go silent.
            log.error(
                """
                Failed to persist pinned host cert for \(self.server.uniqueId, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    // MARK: - Unpair (failure cleanup)

    private func sendUnpair() async {
        do {
            _ = try await network.request(
                path: "unpair",
                query: [:],
                usePaired: false
            )
        } catch {
            log.warning("unpair call failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Version parsing

    private nonisolated func parseMajorVersion(_ version: String?) -> Int {
        guard let version else { return 7 }
        let head = version.split(separator: ".").first ?? ""
        return Int(head) ?? 7
    }
}
