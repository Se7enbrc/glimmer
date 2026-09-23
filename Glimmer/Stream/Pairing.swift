//
//  Pairing.swift
//
//  PIN pairing with a GameStream host, ported from moonlight-qt's nvpairingmanager (GPLv3; see CREDITS.md):
//  four plain-HTTP rounds of raw AES-128-ECB (PIN-keyed, 16-byte blocks, no padding) and RSA signatures over
//  our client cert, then an HTTPS pairchallenge. Wire hex is lowercase; one wrong byte and the host rejects us.
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
    /// `pairStatus = .paired` and `serverCertPEM` holding the host's pinned certificate.
    public func pair(pin: String) async throws -> ServerInfo {
        try await runPairingFlow(pin: pin)
    }

    // MARK: - Pairing flow
    // Four HTTP rounds plus a final HTTPS challenge, each a one-shot GET. Sunshine keeps one session per
    // client id until it completes, fails or expires; there is no /unpair to end it early.

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
            "host=\(self.server.address, privacy: .private)")

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
        // Step 1: getservercert
        //
        // We send a fresh 16-byte salt + our PEM cert (hex-encoded). The host
        // replies with paired=1 + plaincert=<host cert hex>. From this point
        // on we treat that cert as the host's identity - it's pinned for all
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
        // Identity owns the SHA-256(salt || pin)[0..16] computation - keeping
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

        // Step 4: serverchallengeresp. The reply decrypts to the host's SHA-256 hash and a 16-byte
        // challenge; we answer with hash(hostServerChallenge || ourCertSig || clientSecret), encrypted,
        // which proves to the host that we know the PIN.
        let parsed = try parseServerChallenge(challengeResp: challengeResp, aesKey: aesKey)

        let clientSecret = try Self.randomBytes(16)
        let encryptedHash = try buildEncryptedProofHash(
            hostServerChallenge: parsed.hostServerChallenge,
            clientSecret: clientSecret,
            clientCertPEM: clientCertPEM,
            aesKey: aesKey
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
        //   a) RSA-verify the sig against the host cert's public key - this
        //      is the MITM check.
        //   b) Recompute hash(ourClientChallenge || hostCertSig || serverSecret)
        //      and compare to `serverResponseHash` from step 4. Mismatch
        //      means the host computed it with a different PIN-derived AES
        //      key, i.e. the user typed the wrong PIN.
        // ---------------------------------------------------------------
        // Step 5 verification: (a) RSA-verify the host's signature over a value
        // we picked (MITM check) and (b) confirm the user typed the right PIN.
        // Both failures collapse to `.pairingRejected` - see the helper.
        try verifyHostProof(
            serverChallengeRespXml: serverChallengeRespXml,
            randomChallenge: randomChallenge,
            serverCertPEM: serverCertPEM,
            serverResponseHash: parsed.serverResponseHash
        )

        // ---------------------------------------------------------------
        // IN-MEMORY PIN ONLY - DO NOT PERSIST YET.
        //
        // We've now (a) RSA-verified the host's signature over a value
        // we picked, which proves the host holds the private key matching
        // `serverCertPEM`, and (b) confirmed the user typed the right
        // PIN, which proves we're talking to a host that knew the PIN
        // out-of-band. Steps 6 and 7 need the cert pinned at the
        // NetworkClient layer to even attempt TLS, so we have to set the
        // in-memory pin here.
        //
        // SECURITY: the PERSISTED pin (PinnedCertStore.store(...))
        // does NOT happen here. It happens AFTER step 7
        // (HTTPS pairchallenge) returns paired=1 - at which point the
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
        await network.setPinnedHostCert(pem: serverCertPEM)

        try await completeClientPairing(
            clientSecret: clientSecret,
            signpostID: pairingSignpostID
        )

        try Task.checkCancellation()

        // Success - persist into the ServerInfo we hand back.
        server.serverCertPEM = serverCertPEM
        server.pairStatus = .paired

        // SECURITY: persist the pin (public PEM, keyed by host uniqueId) only here, AFTER step 7's pinned
        // pairchallenge returned paired=1; earlier lets a hijacker who fails step 6/7 leave a pin behind.
        // A rotated host cert hits fetchServerInfo's pin-mismatch error; the next pairing overwrites it.
        persistPinnedCert(serverCertPEM: serverCertPEM)

        log.info("Pairing succeeded for \(self.server.address, privacy: .private)")
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
        // The host holds this reply until someone types the PIN on the PC.
        let deadline = Date().addingTimeInterval(NetworkClient.pinEntryTimeout)
        let getCertResp: XMLNode
        do {
            getCertResp = try await pairRound(
                stepLabel: "getservercert",
                signpostID: signpostID,
                query: [
                    "phrase": "getservercert",
                    "salt": salt.hex(),
                    "clientcert": clientCertBytes.hex()
                ],
                usePaired: false,
                timeout: NetworkClient.pinEntryTimeout,
                failureMessage: "getservercert: host did not return paired=1"
            )
        } catch {
            throw Self.pinEntryError(error, deadline: deadline)
        }
        guard let plainCertHex = Self.xmlString(getCertResp, tag: "plaincert"),
              !plainCertHex.isEmpty,
              let serverCertBytes = Data(hex: plainCertHex) else {
            // Empty plaincert means the host is mid-pair with someone else.
            throw StreamError.pairingFailed(
                "getservercert: plaincert missing (host is likely already pairing with another client)")
        }

        // The host's cert is PEM-encoded ASCII inside the hex blob.
        guard let serverCertPEM = String(data: serverCertBytes, encoding: .utf8) else {
            throw StreamError.pairingFailed("plaincert was not valid UTF-8 PEM")
        }
        return serverCertPEM
    }

    /// A getservercert round that dies at its deadline means nobody typed the
    /// PIN in time. Report that, not the transport's own timeout wording; a
    /// cancel or an earlier failure passes through unchanged.
    static func pinEntryError(_ error: Error, deadline: Date, now: Date = Date()) -> Error {
        guard !(error is CancellationError), now.timeIntervalSince(deadline) > -1 else { return error }
        return PairingFailure.timedOut
    }

    /// Decode + decrypt the host's step-3 challenge response, split out of
    /// `runPairingFlow`. Returns the host's own hash (held for the
    /// PIN-correctness check after step 5) and the host's 16-byte challenge.
    private func parseServerChallenge(
        challengeResp: XMLNode,
        aesKey: Data
    ) throws -> (serverResponseHash: Data, hostServerChallenge: Data) {
        guard let challengeRespHex = Self.xmlString(challengeResp, tag: "challengeresponse"),
              let challengeRespBytes = Data(hex: challengeRespHex) else {
            throw StreamError.pairingFailed("clientchallenge: missing challengeresponse field")
        }
        let challengeRespPlain = try Self.aesEcbDecrypt(challengeRespBytes, key: aesKey)

        // The first 32 bytes are the host's own SHA-256; we hold onto it
        // for the PIN-correctness check after step 5.
        let hashLength = Int(SHA256_DIGEST_LENGTH)
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
        timeout: TimeInterval = NetworkClient.pairTimeout,
        failureMessage: String
    ) async throws -> XMLNode {
        OSSignposter.pairing.emitEvent(
            "PairingStep",
            id: signpostID,
            "step=\(stepLabel)")
        var fullQuery = ["devicename": NetworkClient.pairingDeviceName, "updateState": "1"]
        for (key, value) in query { fullQuery[key] = value }
        let response = try await network.request(
            path: "pair",
            query: fullQuery,
            usePaired: usePaired,
            timeout: timeout
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
    /// final liveness check over TLS - by now the host has our cert in its
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

    /// Build our step-4 (serverchallengeresp) proof: SHA-256(hostServerChallenge || ourCertSig || clientSecret),
    /// two AES blocks, AES-ECB-encrypted with the PIN-derived key. The host uses it to prove WE know the PIN.
    private func buildEncryptedProofHash(
        hostServerChallenge: Data,
        clientSecret: Data,
        clientCertPEM: String,
        aesKey: Data
    ) throws -> Data {
        let ourCertSig = try Self.signatureFromPemCert(clientCertPEM)

        // Build challengeResponse: hostServerChallenge || ourCertSig || clientSecret
        var challengeRespPayload = Data()
        challengeRespPayload.append(contentsOf: hostServerChallenge)
        challengeRespPayload.append(ourCertSig)
        challengeRespPayload.append(clientSecret)

        return try Self.aesEcbEncrypt(Self.digest(challengeRespPayload), key: aesKey)
    }

    /// Step 5 host-proof verification, split out of `runPairingFlow`.
    ///
    /// (a) MITM check.
    /// SECURITY: collapse MITM-detection and wrong-PIN errors
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
        serverResponseHash: Data
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
                Pairing rejected (host signature failed verification - \
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
        let expectedResponseHash = try Self.digest(expectedResponse)

        guard expectedResponseHash == Data(serverResponseHash) else {
            // Wrong PIN - same external surface as the MITM branch so an
            // attacker can't distinguish "you typed the wrong digit" from
            // "your cert didn't sign right." Internal log carries the
            // distinction at `.private`.
            log.error(
                """
                Pairing rejected (response-hash mismatch - \
                wrong PIN typed at \(self.server.address, privacy: .private(mask: .hash)))
                """
            )
            throw StreamError.pairingRejected
        }
    }

    /// Commit the verified host cert to the file-backed pin store.
    ///
    /// SECURITY: the caller invokes this ONLY at the very bottom of
    /// `runPairingFlow`, after step 7 (HTTPS pairchallenge) has confirmed
    /// paired=1 over a TLS handshake gated by the in-memory pin set at step 5.
    /// A storage failure must NOT abort an otherwise-successful pair: the cert
    /// is already good for this process (it lives in memory on NetworkClient);
    /// only the next-launch pin is lost, so we log loudly and continue.
    private func persistPinnedCert(serverCertPEM: String) {
        guard !self.server.uniqueId.isEmpty else {
            log.error("No host uniqueId on ServerInfo at pairing-success - cannot persist pin; cert will need re-pairing on next launch")
            return
        }
        // Atomic mode-0600 write into PinnedCertStore. That keeps other users
        // out; a same-UID process can still rewrite it (see SECURITY.md).
        do {
            try PinnedCertStore.store(pem: serverCertPEM,
                                      forHostID: self.server.uniqueId)
            log.info("Persisted pinned host cert (file-store) for host id=\(self.server.uniqueId, privacy: .private)")
        } catch {
            // Storage failure should not abort a successful pair -
            // the cert is still good for THIS process (it's in
            // memory on NetworkClient), the user just won't be
            // pinned on the next launch. Log loudly so the failure
            // doesn't go silent.
            log.error(
                """
                Failed to persist pinned host cert for \(self.server.uniqueId, privacy: .private): \
                \(String(describing: error), privacy: .private)
                """
            )
        }
    }
}
