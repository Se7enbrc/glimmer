// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// Four HTTP rounds prove the PIN and RSA identity before the final pinned HTTPS challenge.

import CryptoKit
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

    /// Bind the proven certificate to the expected PC before the shell can save it.
    public func pair(pin: String, expectedUniqueId: String) async throws -> ServerInfo {
        _ = try await runPairingFlow(pin: pin)
        let verified = try await network.fetchServerInfo(requiredUniqueId: expectedUniqueId)
        try Task.checkCancellation()
        return verified
    }

    /// The Mac shell checks cancellation between the handshake and its pinned identity request.
    /// It must verify /serverinfo before persisting this provisional result.
    package func pair(pin: String) async throws -> ServerInfo {
        try await runPairingFlow(pin: pin)
    }

    // MARK: - Pairing flow
    // Four HTTP rounds plus a final HTTPS challenge, each a one-shot GET. Sunshine keeps one session per
    // client id until it completes, fails or expires; there is no /unpair to end it early.

    private func runPairingFlow(pin: String) async throws -> ServerInfo {

        // Keep the interval and per-round events so Instruments identifies a stalled pairing step.
        #if os(macOS)
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
        #else
        let pairingSignpostID = OSSignpostID.invalid
        #endif

        // Send salt and the client cert. The returned PC cert is only a proposal until the PIN/RSA proof.
        let salt = try Self.randomBytes(16)
        let identity = try await network.identity()
        let clientCertPEM = identity.certPEM
        let clientCertBytes = Data(clientCertPEM.utf8)

        let serverCertPEM = try await fetchServerCert(
            salt: salt,
            clientCertBytes: clientCertBytes,
            signpostID: pairingSignpostID
        )

        // Both peers derive the same PIN-keyed AES key through the shared identity helper.
        let aesKey = IdentityManager.aesKey(forPIN: pin, salt: salt)
        guard aesKey.count == 16 else {
            throw StreamError.crypto("derived AES key is not 16 bytes")
        }

        // A random AES-encrypted challenge lets the PC prove knowledge of the PIN-derived key.
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

        // Verify the PC signature and hash(our challenge || PC cert signature || serverSecret).
        // Both failures report pairingRejected so an attacker cannot distinguish a PIN from a signature failure.
        try verifyHostProof(
            serverChallengeRespXml: serverChallengeRespXml,
            randomChallenge: randomChallenge,
            serverCertPEM: serverCertPEM,
            serverResponseHash: parsed.serverResponseHash
        )

        // The signature and PIN proof allow an in-memory pin for steps 6 and 7.
        // Save it only after the pinned HTTPS challenge and identity check succeed.
        // This is the only in-memory pin write; /serverinfo cannot silently rebind it.
        try await network.setPinnedHostCert(pem: serverCertPEM)

        try await completeClientPairing(
            clientSecret: clientSecret,
            clientKeyPEM: identity.keyPEM,
            signpostID: pairingSignpostID
        )

        try Task.checkCancellation()

        // Success - persist into the ServerInfo we hand back.
        server.serverCertPEM = serverCertPEM
        server.pairStatus = .paired

        log.info("Pairing succeeded for \(self.server.address, privacy: .private)")
        #if os(macOS)
        pairingOutcome = "success"
        #endif
        return server
    }

    /// Decode and check the host's proposed certificate. Only the later PIN and signature proof
    /// can authorize pinning it; rejecting its key here leaves any existing pin untouched.
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
        _ = try PEM.certificateKey(serverCertPEM, context: "PC certificate")
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
        let hashLength = SHA256.byteCount
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

    /// Each round keeps its signpost and checks HTTP status plus paired=1. Shared device fields
    /// keep every round tied to the same client identity.
    private func pairRound(
        stepLabel: StaticString,
        signpostID: OSSignpostID,
        query: [String: String],
        usePaired: Bool,
        timeout: TimeInterval = NetworkClient.pairTimeout,
        failureMessage: String
    ) async throws -> XMLNode {
        #if os(macOS)
        OSSignposter.pairing.emitEvent(
            "PairingStep",
            id: signpostID,
            "step=\(stepLabel)")
        #endif
        var fullQuery = ["devicename": network.deviceName(), "updateState": "1"]
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

    /// Sign the client secret, then confirm paired=1 over pinned mutual TLS.
    /// A TLS failure means the PC has not accepted this identity; do not persist the pin.
    private func completeClientPairing(
        clientSecret: Data,
        clientKeyPEM: String,
        signpostID: OSSignpostID
    ) async throws {
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

    /// Collapse wrong-PIN and signature failures to pairingRejected to avoid an oracle.
    /// Preserve the distinction only in private diagnostics.
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
        let expectedResponseHash = Self.digest(expectedResponse)

        guard expectedResponseHash == Data(serverResponseHash) else {
            // Match signature-failure wording to avoid an oracle; the private log retains the cause.
            log.error(
                """
                Pairing rejected (response-hash mismatch - \
                wrong PIN typed at \(self.server.address, privacy: .private(mask: .hash)))
                """
            )
            throw StreamError.pairingRejected
        }
    }
}
