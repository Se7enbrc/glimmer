// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  PairingFlowTests.swift
//
//  PairingClient's five rounds against a fake Sunshine that plays the PC's side with generated
//  keys: the right PIN pairs and pins, a wrong PIN, a forged signature or a busy PC is refused.
//

@testable import GlimmerEngine
import CryptoKit
import Foundation
import os
import Testing
@testable import Glimmer

/// Sunshine's half of the PIN handshake, computed the way the PC does it.
final class FakePairingHost: Sendable {
    typealias Identity = (certPEM: String, keyPEM: String)

    let host: Identity
    private let signerKeyPEM: String
    private let pin: String
    private let serverChallenge = Data((0..<16).map { UInt8(0x50 + $0) })
    private let serverSecret = Data((0..<16).map { UInt8(0xA0 + $0) })

    private struct State {
        var aesKey = Data()
        var clientCertPEM = ""
        var clientHash = Data()
        var clientProofVerified = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `signer` stands in for an impostor that holds the PC's certificate but not its key.
    init(host: Identity, pin: String, signer: Identity? = nil) {
        self.host = host
        self.pin = pin
        signerKeyPEM = signer?.keyPEM ?? host.keyPEM
    }

    var clientProofVerified: Bool { state.withLock { $0.clientProofVerified } }

    private static func paired(_ ok: Bool, _ extra: String = "") -> ControlTransport.Response {
        FakeSunshine.xml("<paired>\(ok ? 1 : 0)</paired>\(extra)")
    }

    func respond(_ request: FakeSunshineRequest) throws -> ControlTransport.Response {
        let query = request.query
        if query["phrase"] == "getservercert", let salt = query["salt"].flatMap({ Data(hex: $0) }),
           let cert = query["clientcert"].flatMap({ Data(hex: $0) }) {
            state.withLock {
                $0.aesKey = Data(SHA256.hash(data: salt + Data(pin.utf8)).prefix(16))
                $0.clientCertPEM = String(bytes: cert, encoding: .utf8) ?? ""
            }
            return Self.paired(true, "<plaincert>\(Data(host.certPEM.utf8).hex())</plaincert>")
        }
        let key = state.withLock { $0.aesKey }
        if let challenge = query["clientchallenge"].flatMap({ Data(hex: $0) }) {
            let random = try PairingClient.aesEcbDecrypt(challenge, key: key)
            let hash = try PairingClient.digest(random + PairingClient.signatureFromPemCert(host.certPEM) + serverSecret)
            let reply = try PairingClient.aesEcbEncrypt(hash + serverChallenge, key: key)
            return Self.paired(true, "<challengeresponse>\(reply.hex())</challengeresponse>")
        }
        if let proof = query["serverchallengeresp"].flatMap({ Data(hex: $0) }) {
            let clientHash = try PairingClient.aesEcbDecrypt(proof, key: key)
            state.withLock { $0.clientHash = clientHash }
            let signature = try PairingClient.signMessage(serverSecret, privateKeyPEM: signerKeyPEM)
            return Self.paired(true, "<pairingsecret>\((serverSecret + signature).hex())</pairingsecret>")
        }
        if let secret = query["clientpairingsecret"].flatMap({ Data(hex: $0) }) {
            return Self.paired(try verifyClientSecret(secret))
        }
        let pinned = request.tls && request.credential.pinnedCertPEM == host.certPEM
            && request.credential.clientCertPEM == state.withLock({ $0.clientCertPEM })
        return Self.paired(query["phrase"] == "pairchallenge" && pinned && clientProofVerified)
    }

    /// Round 6 as the PC checks it: our signature over the secret, and our round-4 hash.
    private func verifyClientSecret(_ secret: Data) throws -> Bool {
        let (clientCert, clientHash) = state.withLock { ($0.clientCertPEM, $0.clientHash) }
        let clientSecret = secret.prefix(16)
        let signed = try PairingClient.verifySignature(data: Data(clientSecret), signature: Data(secret.dropFirst(16)),
                                                       serverCertPEM: clientCert)
        let expected = try PairingClient.digest(serverChallenge + PairingClient.signatureFromPemCert(clientCert)
                                                + clientSecret)
        let verified = signed && expected == clientHash
        state.withLock { $0.clientProofVerified = verified }
        return verified
    }
}

struct PairingFlowTests {

    private static func pairing(_ host: FakePairingHost, client: (certPEM: String, keyPEM: String))
        -> (PairingClient, NetworkClient, FakeSunshine) {
        let sunshine = FakeSunshine { try host.respond($0) }
        let server = FakeSunshine.server()
        let network = sunshine.client(server, identity: client)
        return (PairingClient(network: network, server: server), network, sunshine)
    }

    private static func expectRejected(_ pairing: PairingClient, pin: String) async {
        let error = await #expect(throws: StreamError.self) { _ = try await pairing.pair(pin: pin) }
        guard case .pairingRejected = error else {
            Issue.record("expected pairingRejected, got \(String(describing: error))")
            return
        }
    }

    @Test func theRightPinPairsAndPinsThePCsCertificate() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let host = FakePairingHost(host: hostIdentity, pin: "4821")
        let (pairing, network, sunshine) = Self.pairing(host, client: client)

        let paired = try await pairing.pair(pin: "4821")

        #expect(paired.pairStatus == .paired && paired.serverCertPEM == hostIdentity.certPEM)
        #expect(await network.pinnedServerCertPEM() == hostIdentity.certPEM)
        #expect(host.clientProofVerified)
        let requests = sunshine.requests
        #expect(requests.map(\.path) == Array(repeating: "/pair", count: 5))
        #expect(requests.map(\.tls) == [false, false, false, false, true])
        #expect(requests.map(\.port) == [47989, 47989, 47989, 47989, 47984])
        #expect(requests.allSatisfy { $0.query["updateState"] == "1" && $0.query["devicename"]?.isEmpty == false })
        #expect(requests.allSatisfy { $0.query["uniqueid"] == FakeSunshine.clientUniqueID })
        #expect(requests.first?.query["clientcert"].flatMap { Data(hex: $0) } == Data(client.certPEM.utf8))
        #expect((requests.first?.timeout ?? 0) > NetworkClient.pairTimeout)
        #expect(requests.last?.credential.clientKeyPEM == client.keyPEM)
    }

    @Test func aWrongPinIsRejectedBeforeOurSecretIsSentAndNothingIsPinned() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let (pairing, network, sunshine) = Self.pairing(FakePairingHost(host: hostIdentity, pin: "4822"), client: client)

        await Self.expectRejected(pairing, pin: "4821")
        #expect(await network.pinnedServerCertPEM() == nil)
        #expect(sunshine.requests.count == 3)
        #expect(sunshine.requests.allSatisfy { $0.query["clientpairingsecret"] == nil && !$0.tls })
    }

    @Test func anImpostorWithoutThePCsKeyIsRejected() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let impostor = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let host = FakePairingHost(host: hostIdentity, pin: "4821", signer: impostor)
        let (pairing, network, sunshine) = Self.pairing(host, client: client)

        await Self.expectRejected(pairing, pin: "4821")
        #expect(await network.pinnedServerCertPEM() == nil)
        #expect(sunshine.requests.count == 3)
    }

    @Test func aBusyOrAlreadyPairingPCIsReportedAsSuch() async throws {
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let busy = FakeSunshine { _ in FakeSunshine.xml("", status: 409) }
        let network = busy.client(FakeSunshine.server(), identity: client)
        await #expect(throws: PairingFailure.busy) {
            _ = try await PairingClient(network: network, server: FakeSunshine.server()).pair(pin: "4821")
        }

        let occupied = FakeSunshine { _ in FakeSunshine.xml("<paired>1</paired><plaincert></plaincert>") }
        let other = occupied.client(FakeSunshine.server(), identity: client)
        let error = await #expect(throws: StreamError.self) {
            _ = try await PairingClient(network: other, server: FakeSunshine.server()).pair(pin: "4821")
        }
        #expect(error?.description.contains("already pairing") == true)
        #expect(occupied.requests.count == 1)
    }

    @Test func aWeakPCCertificateStopsPairingAfterTheFirstRound() async throws {
        let weak = try await EphemeralCryptoIdentity.make(bits: 1024)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let (pairing, network, sunshine) = Self.pairing(FakePairingHost(host: weak, pin: "4821"), client: client)
        await #expect(throws: StreamError.self) { _ = try await pairing.pair(pin: "4821") }
        #expect(sunshine.requests.count == 1)
        #expect(await network.pinnedServerCertPEM() == nil)
    }

    @Test func aMalformedChallengeReplyFailsPairing() async throws {
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let host = FakePairingHost(host: hostIdentity, pin: "4821")
        let sunshine = FakeSunshine { request in
            request.query["clientchallenge"] == nil ? try host.respond(request)
                : FakeSunshine.xml("<paired>1</paired><challengeresponse>00ff</challengeresponse>")
        }
        let network = sunshine.client(FakeSunshine.server(), identity: client)
        await #expect(throws: StreamError.self) {
            _ = try await PairingClient(network: network, server: FakeSunshine.server()).pair(pin: "4821")
        }
        #expect(sunshine.requests.count == 2)
    }
}
