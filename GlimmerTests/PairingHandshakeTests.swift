//
//  PairingHandshakeTests.swift
//
//  Sunshine's PIN handshake played from both ends with the pairing helpers and generated keys, the
//  certificate pin and fingerprint checks, the wire hex, and the small pairing and poller helpers.
//

import CoreWLAN
import CryptoKit
import Foundation
import Testing
@testable import Glimmer

struct PairingHandshakeTests {

    private typealias Identity = (certPEM: String, keyPEM: String)

    /// The PC's side of rounds 3 to 5: its challenge reply and its signed pairing secret.
    private struct HostRound {
        let challengeResponse: Data
        let serverChallenge: Data
        let serverSecret: Data
        let pairingSecret: Data
    }

    private static func hostRound(host: Identity, aesKey: Data, clientChallenge: Data) throws -> HostRound {
        let randomChallenge = try PairingClient.aesEcbDecrypt(clientChallenge, key: aesKey)
        let serverSecret = Data((0..<16).map { UInt8(0xA0 + $0) })
        let serverChallenge = Data((0..<16).map { UInt8(0x50 + $0) })
        let hash = try PairingClient.digest(randomChallenge + PairingClient.signatureFromPemCert(host.certPEM) + serverSecret)
        let reply = try PairingClient.aesEcbEncrypt(hash + serverChallenge, key: aesKey)
        let signature = try PairingClient.signMessage(serverSecret, privateKeyPEM: host.keyPEM)
        return HostRound(challengeResponse: reply, serverChallenge: serverChallenge,
                         serverSecret: serverSecret, pairingSecret: serverSecret + signature)
    }

    /// Mirrors Pairing.swift's step-5 checks: the PC signed the secret, and its hash used our PIN.
    private static func clientAcceptsHost(_ round: HostRound, host: Identity, aesKey: Data,
                                          randomChallenge: Data) throws -> Bool {
        let plain = try PairingClient.aesEcbDecrypt(round.challengeResponse, key: aesKey)
        let serverResponseHash = plain.prefix(SHA256.byteCount)
        let secret = round.pairingSecret.prefix(16)
        guard try PairingClient.verifySignature(data: Data(secret), signature: Data(round.pairingSecret.dropFirst(16)),
                                                serverCertPEM: host.certPEM) else { return false }
        let expected = try PairingClient.digest(randomChallenge + PairingClient.signatureFromPemCert(host.certPEM) + secret)
        return expected == Data(serverResponseHash)
    }

    @Test func bothEndsOfThePinHandshakeAgree() async throws {
        let host = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let salt = Data((0..<16).map { UInt8($0) })
        let aesKey = await IdentityManager.shared.aesKey(forPIN: "4821", salt: salt)
        let randomChallenge = Data(repeating: 0x3C, count: 16)
        let clientChallenge = try PairingClient.aesEcbEncrypt(randomChallenge, key: aesKey)

        let round = try Self.hostRound(host: host, aesKey: aesKey, clientChallenge: clientChallenge)
        let plain = try PairingClient.aesEcbDecrypt(round.challengeResponse, key: aesKey)
        #expect(plain.count == SHA256.byteCount + 16)
        #expect(Data(plain.suffix(16)) == round.serverChallenge)
        #expect(try Self.clientAcceptsHost(round, host: host, aesKey: aesKey, randomChallenge: randomChallenge))

        // Round 4: the PC recomputes our proof from what it knows.
        let clientSecret = Data(repeating: 0x77, count: 16)
        let proofInput = try round.serverChallenge + PairingClient.signatureFromPemCert(client.certPEM) + clientSecret
        let proof = try PairingClient.aesEcbEncrypt(PairingClient.digest(proofInput), key: aesKey)
        #expect(try PairingClient.aesEcbDecrypt(proof, key: aesKey) == PairingClient.digest(proofInput))

        // Round 6: our signed secret verifies against the cert we sent in round 1.
        let signed = try PairingClient.signMessage(clientSecret, privateKeyPEM: client.keyPEM)
        #expect(try PairingClient.verifySignature(data: clientSecret, signature: signed, serverCertPEM: client.certPEM))
        #expect(try !PairingClient.verifySignature(data: clientSecret, signature: signed, serverCertPEM: host.certPEM))
    }

    @Test func aWrongPinOrAnImpostorIsRefused() async throws {
        let host = try await EphemeralCryptoIdentity.make(bits: 2048)
        let impostor = try await EphemeralCryptoIdentity.make(bits: 2048)
        let salt = Data(repeating: 9, count: 16)
        let ourKey = await IdentityManager.shared.aesKey(forPIN: "4821", salt: salt)
        let hostKey = await IdentityManager.shared.aesKey(forPIN: "4822", salt: salt)
        let challenge = Data(repeating: 0x3C, count: 16)

        let wrongPin = try Self.hostRound(host: host, aesKey: hostKey,
                                          clientChallenge: try PairingClient.aesEcbEncrypt(challenge, key: hostKey))
        #expect(try !Self.clientAcceptsHost(wrongPin, host: host, aesKey: ourKey, randomChallenge: challenge))

        let encrypted = try PairingClient.aesEcbEncrypt(challenge, key: ourKey)
        let forged = try Self.hostRound(host: impostor, aesKey: ourKey, clientChallenge: encrypted)
        #expect(try !Self.clientAcceptsHost(forged, host: host, aesKey: ourKey, randomChallenge: challenge))
    }

    @Test func certSignatureIsTheCertsOwnAndMalformedPEMIsRefused() async throws {
        let first = try await EphemeralCryptoIdentity.make(bits: 2048)
        let second = try await EphemeralCryptoIdentity.make(bits: 3072)
        #expect(try PairingClient.signatureFromPemCert(first.certPEM).count == 256)
        #expect(try PairingClient.signatureFromPemCert(second.certPEM).count == 384)
        #expect(throws: StreamError.self) { try PairingClient.signatureFromPemCert("-----BEGIN CERTIFICATE-----AAAA") }
    }

    // MARK: - Pins and fingerprints

    @Test func aMismatchedPinIsRefusedAndAWeakCertNeverReplacesAPin() async throws {
        let pinned = try await EphemeralCryptoIdentity.make(bits: 2048)
        let other = try await EphemeralCryptoIdentity.make(bits: 2048)
        let weak = try await EphemeralCryptoIdentity.make(bits: 1024)
        let presented = try #require(PEM.certificate(other.certPEM))
        #expect(try !ControlTransport.acceptsHostCertificate(presented, pinnedDER: PEM.der(pinned.certPEM)))
        #expect(try ControlTransport.acceptsHostCertificate(presented, pinnedDER: PEM.der(other.certPEM)))

        let network = NetworkClient(server: ServerInfo(address: "192.0.2.10", uniqueId: "host-1", serverName: "TOWER"))
        try await network.setPinnedHostCert(pem: pinned.certPEM)
        await #expect(throws: StreamError.self) { try await network.setPinnedHostCert(pem: weak.certPEM) }
        await #expect(throws: StreamError.self) { try await network.setPinnedHostCert(pem: "not a certificate") }
        #expect(await network.pinnedServerCertPEM() == pinned.certPEM)
    }

    @Test func fingerprintIsTheColonSeparatedSHA256OfTheDER() async throws {
        let identity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let der = try #require(PEM.der(identity.certPEM))
        let expected = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(separator: ":")
        #expect(CertFingerprint.sha256(forPEM: identity.certPEM) == expected)
        #expect(CertFingerprint.sha256(forPEM: identity.certPEM.replacingOccurrences(of: "\n", with: "\r\n")) == expected)
        #expect(expected.count == 32 * 3 - 1)
        #expect(CertFingerprint.sha256(forPEM: "-----BEGIN CERTIFICATE-----\n%%%%\n-----END CERTIFICATE-----") == nil)
        #expect(CertFingerprint.sha256(forPEM: "-----END CERTIFICATE----------BEGIN CERTIFICATE-----") == nil)
    }

    // MARK: - Wire hex and status

    @Test func wireHexIsLowercaseAndDecodingIsLenientOnlyAboutCaseAndSpace() {
        #expect(Data([0x00, 0xAB, 0x7F, 0xFF]).hex() == "00ab7fff")
        #expect(Data(hex: "00AB 7f\nFF") == Data([0x00, 0xAB, 0x7F, 0xFF]))
        #expect(Data(hex: "") == Data())
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "0g") == nil)
        #expect(Data(hex: Data([0x12, 0x34]).hex()) == Data([0x12, 0x34]))
    }

    @Test func pairStatusOverflowAndMissingRootAreRefusals() throws {
        let overflow = try XMLTreeBuilder.parse(data: Data(#"<root status_code="4294967295"/>"#.utf8))
        let error = #expect(throws: StreamError.self) { try PairingClient.verifyResponseStatus(overflow) }
        #expect(error?.description.contains("-1") == true)
        let html = try XMLTreeBuilder.parse(data: Data("<html><paired>1</paired></html>".utf8))
        #expect(throws: StreamError.self) { try PairingClient.verifyResponseStatus(html) }
        // Fields are read through <root>, so a stray <paired> elsewhere proves nothing.
        #expect(PairingClient.xmlString(html, tag: "paired") == nil)
        let reply = try XMLTreeBuilder.parse(data: Data("<root><paired> 1 </paired></root>".utf8))
        #expect(PairingClient.xmlString(reply, tag: "paired") == "1")
    }

    @Test func pairingEntropyIsFreshEachTime() throws {
        let first = try PairingClient.randomBytes(16)
        #expect(first.count == 16)
        #expect(try PairingClient.randomBytes(16) != first)
    }

    // MARK: - Sheet and poller helpers

    @Test(arguments: ["tower", "tower.local", "192.0.2.10", "2001:db8::5", "a"])
    func dialableAddressesAreAccepted(address: String) {
        #expect(AppModel.isValidPCAddress(address))
    }

    @Test(arguments: ["", "-tower", "tower.", "fe80::1%en0", "tower:47989/pin", "two words", String(repeating: "a", count: 254)])
    func undialableAddressesAreRefused(address: String) {
        #expect(!AppModel.isValidPCAddress(address))
    }

    @MainActor @Test func pinsAreFourDigits() {
        let model = AppModel()
        for _ in 0..<50 {
            let pin = model.generatePairingPIN()
            #expect(pin.count == 4 && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber))
        }
    }

    @MainActor @Test func aLateStatusNeverPaintsAnotherPC() async {
        let model = AppModel()
        model.selectedHost = Glimmer.Host(id: "tower", name: "tower", customName: nil, localAddress: "192.0.2.10",
                                          manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil,
                                          appVersion: nil, macAddress: nil)
        model.hostStatusTask?.cancel()
        let status = HostLiveStatus(hostID: "den", state: .idle, rttMs: 4, sunshineVersion: nil, capturedAt: Date())
        await model.publishLiveStatus(status, expectedHostID: "den")
        #expect(model.hostLiveStatus?.hostID != "den")
        let tower = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 4, sunshineVersion: "7.1", capturedAt: Date())
        await model.publishLiveStatus(tower, expectedHostID: "tower")
        #expect(model.hostLiveStatus == tower)
    }

    @Test func wifiLabelsNameTheBandAndLink() {
        #expect(WiFiTelemetry.bandLabel(.band2GHz) == "2.4GHz")
        #expect(WiFiTelemetry.bandLabel(.band5GHz) == "5GHz")
        #expect(WiFiTelemetry.bandLabel(.band6GHz) == "6GHz")
        #expect(WiFiTelemetry.bandLabel(.bandUnknown) == nil)
        let links: [WiFiSnapshot.LinkState] = [.associated, .unassociated, .wired]
        #expect(links.map(\.label) == ["wifi", "unassociated", "wired"])
    }
}
