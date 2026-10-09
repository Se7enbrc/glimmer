//
//  PairingCryptoTests.swift
//
//  Pairing and identity crypto: the PIN key, AES-128-ECB against FIPS-197, SHA-256, RSA sign/verify and the
//  generated certificate's shape, all on keypairs generateKeyPairAndCert() makes in-test, so no PEM fixture is
//  committed.
//

import Foundation
import Testing
import CryptoKit
import Security
@testable import Glimmer

struct PairingCryptoTests {

    @Test(arguments: [2048, 3072, 4096])
    func supportedRSAIdentitiesRemainUsable(_ bits: Int) async throws {
        let identity = try await EphemeralCryptoIdentity.make(bits: bits)
        let message = Data("host proof".utf8)
        let signature = try PairingClient.signMessage(message, privateKeyPEM: identity.keyPEM)
        #expect(try PairingClient.verifySignature(
            data: message, signature: signature, serverCertPEM: identity.certPEM))
        _ = try ControlTransport.clientIdentity(certPEM: identity.certPEM, keyPEM: identity.keyPEM)
        let certificate = try #require(PEM.certificate(identity.certPEM))
        #expect(try ControlTransport.acceptsHostCertificate(certificate, pinnedDER: PEM.der(identity.certPEM)))
    }

    @Test func weakRSAProofAndPinnedCertificateAreRejected() async throws {
        let identity = try await EphemeralCryptoIdentity.make(bits: 1024)
        let message = Data("valid signature from a weak host key".utf8)
        let key = try #require(PEM.privateKey(identity.keyPEM))
        let signature = try #require(SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil) as Data?)
        #expect(SecKeyVerifySignature(try #require(SecKeyCopyPublicKey(key)),
                                     .rsaSignatureMessagePKCS1v15SHA256,
                                     message as CFData, signature as CFData, nil))
        #expect(throws: StreamError.self) {
            try PairingClient.verifySignature(data: message, signature: signature, serverCertPEM: identity.certPEM)
        }
        #expect(throws: StreamError.self) {
            try ControlTransport.clientIdentity(certPEM: identity.certPEM, keyPEM: identity.keyPEM)
        }
        let certificate = try #require(PEM.certificate(identity.certPEM))
        let pin = try #require(PEM.der(identity.certPEM))
        #expect(throws: StreamError.self) {
            try ControlTransport.acceptsHostCertificate(certificate, pinnedDER: pin)
        }
        #expect(PEM.der(identity.certPEM) == pin)
    }

    @Test func malformedAndNonRSACertificatesAreRejected() async throws {
        #expect(throws: StreamError.self) {
            try PEM.certificateKey("malformed certificate", context: "PC certificate")
        }
        let identity = try await EphemeralCryptoIdentity.make(bits: 256, ellipticCurve: true)
        let certificate = try #require(PEM.certificate(identity.certPEM))
        #expect(throws: StreamError.self) {
            try ControlTransport.acceptsHostCertificate(certificate, pinnedDER: PEM.der(identity.certPEM))
        }
        #expect(throws: StreamError.self) {
            try PEM.identity(certPEM: identity.certPEM, keyPEM: identity.keyPEM)
        }
    }

    @Test func weakPairingCertificateCannotReplaceAnExistingPin() async throws {
        let previous = try await EphemeralCryptoIdentity.make(bits: 2048)
        let weak = try await EphemeralCryptoIdentity.make(bits: 1024)
        var server = ServerInfo(address: "127.0.0.1", uniqueId: "fixture", serverName: "Fixture")
        server.serverCertPEM = previous.certPEM
        let network = NetworkClient(server: server)
        do {
            try await network.setPinnedHostCert(pem: weak.certPEM)
            Issue.record("A weak pairing certificate replaced the existing pin")
        } catch StreamError.crypto(let detail) {
            #expect(detail == "PC certificate requires an RSA key of at least 2048 bits")
        }
        #expect(await network.pinnedServerCertPEM() == previous.certPEM)
    }

    // MARK: - aesKey(forPIN:salt:) known-answer

    @Test func aesKeyMatchesCryptoKitSha256Prefix() async throws {
        // Fixed salt + PIN. Independently compute SHA-256(salt || pin) with
        // CryptoKit and take the first 16 bytes; assert the app agrees.
        let salt = Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD,
                         0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        let pin = "1234"

        var input = Data()
        input.append(salt)
        input.append(Data(pin.utf8))
        let expected = Data(SHA256.hash(data: input).prefix(16))

        let actual = await IdentityManager.shared.aesKey(forPIN: pin, salt: salt)
        #expect(actual.count == 16)
        #expect(actual == expected)
    }

    @Test func aesKeyIsDeterministicAndPinSensitive() async throws {
        let salt = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33,
                         0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB])
        let mgr = IdentityManager.shared
        let k1 = await mgr.aesKey(forPIN: "0000", salt: salt)
        let k2 = await mgr.aesKey(forPIN: "0000", salt: salt)
        let kOther = await mgr.aesKey(forPIN: "9999", salt: salt)
        #expect(k1 == k2)              // deterministic
        #expect(k1 != kOther)         // PIN-sensitive
    }

    @Test func aesKeyIsSaltSensitive() async throws {
        let mgr = IdentityManager.shared
        let saltA = Data(repeating: 0x00, count: 16)
        let saltB = Data(repeating: 0xFF, count: 16)
        let kA = await mgr.aesKey(forPIN: "4321", salt: saltA)
        let kB = await mgr.aesKey(forPIN: "4321", salt: saltB)
        #expect(kA != kB)
    }

    // MARK: - AES-128-ECB round-trip

    @Test func aesEcbRoundTripSingleBlock() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let plaintext = Data((16..<32).map { UInt8($0) })  // 16 bytes
        let ct = try PairingClient.aesEcbEncrypt(plaintext, key: key)
        #expect(ct.count == 16)
        #expect(ct != plaintext)
        let recovered = try PairingClient.aesEcbDecrypt(ct, key: key)
        #expect(recovered == plaintext)
    }

    @Test func aesEcbRoundTripMultiBlock() throws {
        let key = Data(repeating: 0xA5, count: 16)
        let plaintext = Data((0..<48).map { UInt8($0 & 0xFF) })  // 3 blocks
        let ct = try PairingClient.aesEcbEncrypt(plaintext, key: key)
        #expect(ct.count == 48)
        let recovered = try PairingClient.aesEcbDecrypt(ct, key: key)
        #expect(recovered == plaintext)
    }

    @Test func aesEcbIdenticalBlocksEncryptIdentically() throws {
        // ECB property (the documented trade-off): equal plaintext blocks map
        // to equal ciphertext blocks. Pins that the mode really is ECB.
        let key = Data(repeating: 0x11, count: 16)
        let block = Data(repeating: 0x42, count: 16)
        let plaintext = block + block
        let ct = try PairingClient.aesEcbEncrypt(plaintext, key: key)
        #expect(ct.prefix(16) == ct.suffix(16))
    }

    @Test func aesEcbRejectsWrongKeyLength() {
        let plaintext = Data(repeating: 0, count: 16)
        #expect(throws: (any Error).self) {
            _ = try PairingClient.aesEcbEncrypt(plaintext, key: Data(repeating: 0, count: 15))
        }
    }

    @Test func aesEcbRejectsMisalignedInput() {
        let key = Data(repeating: 0, count: 16)
        #expect(throws: (any Error).self) {
            _ = try PairingClient.aesEcbEncrypt(Data(repeating: 0, count: 17), key: key)
        }
        #expect(throws: (any Error).self) {
            _ = try PairingClient.aesEcbEncrypt(Data(), key: key)   // empty rejected
        }
    }

    // MARK: - digest known-answer

    @Test func digestSha256KnownAnswer() throws {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let out = PairingClient.digest(Data("abc".utf8))
        #expect(out.count == 32)
        let expected = Data(SHA256.hash(data: Data("abc".utf8)))
        #expect(out == expected)
        #expect(out.map { String(format: "%02x", $0) }.joined()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func digestCrossChecksCryptoKitOnRandomInput() throws {
        let data = Data((0..<137).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let out = PairingClient.digest(data)
        #expect(out == Data(SHA256.hash(data: data)))
    }

    /// The step-4 proof goes straight from SHA-256 into AES-ECB: two whole blocks, nothing to pad.
    @Test func proofHashFillsTwoAesBlocks() throws {
        let hash = PairingClient.digest(Data("challenge".utf8))
        #expect(try PairingClient.aesEcbEncrypt(hash, key: Data(repeating: 7, count: 16)).count == 32)
    }

    // MARK: - RSA sign / verify round-trip (in-test keypair, no fixture)

    @Test func rsaSignVerifyRoundTrip() async throws {
        // Generate a throwaway 2048-bit RSA keypair + self-signed cert via the
        // app's own identity generation. No committed PEM fixture.
        let (certPEM, keyPEM) = try await IdentityManager.shared.generateKeyPairAndCert()

        let message = Data("the quick brown fox".utf8)
        let signature = try PairingClient.signMessage(message, privateKeyPEM: keyPEM)
        #expect(signature.count == 256)  // RSA-2048 -> 256-byte signature

        let ok = try PairingClient.verifySignature(
            data: message, signature: signature, serverCertPEM: certPEM)
        #expect(ok)
    }

    @Test func rsaVerifyRejectsTamperedPayload() async throws {
        let (certPEM, keyPEM) = try await IdentityManager.shared.generateKeyPairAndCert()
        let message = Data("authentic message".utf8)
        let signature = try PairingClient.signMessage(message, privateKeyPEM: keyPEM)

        let tampered = Data("authentic messagE".utf8)  // last char flipped
        let ok = try PairingClient.verifySignature(
            data: tampered, signature: signature, serverCertPEM: certPEM)
        #expect(!ok)
    }

    @Test func rsaVerifyRejectsTamperedSignature() async throws {
        let (certPEM, keyPEM) = try await IdentityManager.shared.generateKeyPairAndCert()
        let message = Data("sign me".utf8)
        var signature = [UInt8](try PairingClient.signMessage(message, privateKeyPEM: keyPEM))
        signature[signature.count - 1] ^= 0xFF  // corrupt last byte

        let ok = try PairingClient.verifySignature(
            data: message, signature: Data(signature), serverCertPEM: certPEM)
        #expect(!ok)
    }

    @Test func rsaVerifyRejectsWrongKeyCert() async throws {
        // Sign with keypair A, verify against cert B -> must fail.
        let (_, keyA) = try await IdentityManager.shared.generateKeyPairAndCert()
        let (certB, _) = try await IdentityManager.shared.generateKeyPairAndCert()
        let message = Data("cross-key check".utf8)
        let signature = try PairingClient.signMessage(message, privateKeyPEM: keyA)
        let ok = try PairingClient.verifySignature(
            data: message, signature: signature, serverCertPEM: certB)
        #expect(!ok)
    }

    // MARK: - signatureFromPemCert is deterministic for a given cert

    @Test func signatureFromPemCertIsStableForSameCert() async throws {
        let (certPEM, _) = try await IdentityManager.shared.generateKeyPairAndCert()
        let s1 = try PairingClient.signatureFromPemCert(certPEM)
        let s2 = try PairingClient.signatureFromPemCert(certPEM)
        #expect(!s1.isEmpty)
        #expect(s1 == s2)
        // RSA-2048 self-signed: the cert signature BIT STRING is 256 bytes.
        #expect(s1.count == 256)
    }

    // MARK: - Known answers and the generated certificate

    /// FIPS-197 appendix C.1.
    @Test func aesEcbMatchesFIPS197() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let plaintext = try #require(Data(hex: "00112233445566778899aabbccddeeff"))
        let ciphertext = try #require(Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a"))
        #expect(try PairingClient.aesEcbEncrypt(plaintext, key: key) == ciphertext)
        #expect(try PairingClient.aesEcbDecrypt(ciphertext, key: key) == plaintext)
    }

    /// The certificate Sunshine sees: moonlight-qt's template, self-signed, with a PKCS#8 key.
    @Test func generatedCertificateIsTheMoonlightTemplate() async throws {
        let (certPEM, keyPEM) = try await IdentityManager.shared.generateKeyPairAndCert()
        #expect(certPEM.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        #expect(keyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
        let cert = try #require(PEM.certificate(certPEM))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == "NVIDIA GameStream Client")
        let notBefore = try #require(SecCertificateCopyNotValidBeforeDate(cert) as Date?)
        let notAfter = try #require(SecCertificateCopyNotValidAfterDate(cert) as Date?)
        #expect(notAfter.timeIntervalSince(notBefore) == 60 * 60 * 24 * 365 * 20)

        let der = try #require(PEM.der(certPEM))
        let parts = try #require(DER.certificateParts(der))
        let publicKey = try #require(SecCertificateCopyKey(cert))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                      parts.tbs as CFData, parts.signature as CFData, nil))
        // [0] version v3, then serial 0.
        let tbs = [UInt8](parts.tbs)
        var index = 0
        let body = try #require(DER.element(tbs, at: &index)).body
        #expect(tbs[body].starts(with: [0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00]))
    }

    @Test func derEncodesLongLengthsAndHighBitIntegers() {
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.encode(0x04, [UInt8](repeating: 1, count: 200)).prefix(3) == [0x04, 0x81, 0xC8])
        #expect(DER.encode(0x04, [UInt8](repeating: 1, count: 300)).prefix(4) == [0x04, 0x82, 0x01, 0x2C])
    }

    @Test func derSwitchesToGeneralizedTimeIn2050() {
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_607_999)) == [0x17, 13] + Array("491231235959Z".utf8))
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_608_000)) == [0x18, 15] + Array("20500101000000Z".utf8))
    }

    // MARK: - First contact can't pair or pin (SECURITY C2)

    private static let spoofedServerInfo = Data("""
        <root status_code="200"><hostname>TOWER</hostname><uniqueid>host-1</uniqueid>
        <PairStatus>1</PairStatus><PlainCert>-----BEGIN CERTIFICATE-----AAAA</PlainCert></root>
        """.utf8)

    /// Any LAN device answering port 47989 writes this XML. A saved PC's info
    /// starts `.paired`, so the reply must knock it back, not confirm it.
    @Test func plainHTTPServerInfoNeitherPairsNorPins() async throws {
        var seed = ServerInfo(address: "192.0.2.10", uniqueId: "host-1", serverName: "TOWER")
        seed.pairStatus = .paired
        let client = NetworkClient(server: seed)
        await client.hydrateServerInfo(from: try XMLTreeBuilder.parse(data: Self.spoofedServerInfo),
                                       fetchedOverPaired: false)
        #expect(await client.server.pairStatus == .unpaired)
        #expect(await client.pinnedServerCertPEM() == nil)
    }

    /// Over pinned mutual TLS the handshake itself is the proof, whatever the body says.
    @Test func pinnedHTTPSServerInfoIsPaired() async throws {
        let client = NetworkClient(server: ServerInfo(address: "192.0.2.10", uniqueId: "host-1", serverName: "TOWER"))
        let xml = try XMLTreeBuilder.parse(data: Data(#"<root status_code="200"><PairStatus>0</PairStatus></root>"#.utf8))
        await client.hydrateServerInfo(from: xml, fetchedOverPaired: true)
        #expect(await client.server.pairStatus == .paired)
    }

    @Test func outOfRangeHTTPSPortKeepsPriorValue() async throws {
        var server = ServerInfo(address: "", uniqueId: "", serverName: "")
        server.httpsPort = 443
        let client = NetworkClient(server: server)
        let xml = try XMLTreeBuilder.parse(data: Data(#"<root status_code="200"><HttpsPort>70000</HttpsPort></root>"#.utf8))
        await client.hydrateServerInfo(from: xml, fetchedOverPaired: false)
        #expect(await client.server.httpsPort == 443)
    }

    @Test func backendCodecModeMaskPreservesBit31AndCodecBits() {
        let raw = Int(bitPattern: UInt(0x8001_0201))
        let mask = NetworkClient.backendCodecModeMask(raw)
        #expect(UInt32(bitPattern: mask) == 0x8001_0201)
    }

    /// GameStream is told apart by its `<state>`, not by `GfeVersion`, which Sunshine sends too.
    @Test func gameStreamIsToldApartByItsState() async throws {
        func isGameStream(_ body: String) async throws -> Bool {
            let client = NetworkClient(server: ServerInfo(address: "192.0.2.10", uniqueId: "host-1", serverName: "TOWER"))
            let xml = try XMLTreeBuilder.parse(data: Data("<root status_code=\"200\">\(body)</root>".utf8))
            await client.hydrateServerInfo(from: xml, fetchedOverPaired: false)
            return await client.server.isRealGFE
        }
        #expect(try await isGameStream("<state>MJOLNIR_STATE_SERVER_AVAILABLE</state>"))
        #expect(try await isGameStream("<GfeVersion>3.23.0.74</GfeVersion><state>SUNSHINE_SERVER_FREE</state>") == false)
    }

    /// TLS with no pin would send /launch's input key to any certificate, so it
    /// is refused up front, before any connection is attempted.
    @Test func httpsWithoutAPinIsRefused() async {
        let client = NetworkClient(server: ServerInfo(address: "192.0.2.10", uniqueId: "host-1", serverName: "TOWER"))
        let error = await #expect(throws: StreamError.self) {
            _ = try await client.request(path: "applist", query: [:], usePaired: true)
        }
        guard case .pairingFailed = error else {
            Issue.record("expected pairingFailed, got \(String(describing: error))")
            return
        }
    }

    // MARK: - PIN entry timeout

    @Test func getservercertDyingAtItsDeadlineIsATimeout() {
        let deadline = Date()
        let late = PairingClient.pinEntryError(
            StreamError.hostTimedOut, deadline: deadline, now: deadline)
        #expect(late as? PairingFailure == .timedOut)
        // A refusal a minute in is the host, not the person, and keeps its cause.
        let early = PairingClient.pinEntryError(
            StreamError.hostUnreachable("refused"), deadline: deadline, now: deadline.addingTimeInterval(-60))
        #expect(early is StreamError)
        // Closing the sheet is never reported as a timeout.
        let cancelled = PairingClient.pinEntryError(CancellationError(), deadline: deadline, now: deadline)
        #expect(cancelled is CancellationError)
    }

    /// Sunshine's own session verdicts keep their meaning; any other status is a refusal.
    @Test func pairStatusCodesKeepSunshinesMeaning() throws {
        func verdict(_ code: Int) throws -> Error? {
            let xml = try XMLTreeBuilder.parse(data: Data("<root status_code=\"\(code)\"><paired>0</paired></root>".utf8))
            do { try PairingClient.verifyResponseStatus(xml) } catch { return error }
            return nil
        }
        #expect(try verdict(200) == nil)
        #expect(try verdict(408) as? PairingFailure == .timedOut)
        #expect(try verdict(409) as? PairingFailure == .busy)
        #expect(try verdict(503) as? PairingFailure == .busy)
        #expect(try verdict(400) is StreamError)
        // A PC that expired the request mid-wait reads as a timeout, not a refusal.
        let expired = PairingClient.pinEntryError(PairingFailure.timedOut, deadline: Date().addingTimeInterval(60))
        #expect(expired as? PairingFailure == .timedOut)
    }

    /// The sheet words every outcome from this: each names the PC, and a timeout
    /// reads differently from a refusal so nobody retypes a code that was right.
    @Test func pairingFailureMessagesNameThePC() {
        for failure in [PairingFailure.unreachable, .gameStream, .timedOut, .busy, .rejected] {
            #expect(failure.message(pc: "TOWER").contains("TOWER"))
            #expect(!failure.message(pc: "TOWER").contains(" - "))
        }
        #expect(PairingFailure.timedOut.message(pc: "TOWER") != PairingFailure.rejected.message(pc: "TOWER"))
        #expect(PairingFailure.invalidAddress.message(pc: "TOWER") == PairingFailure.addressHint)
    }
}

/// Disposable in-memory certificates, including keys production identity generation refuses to make.
enum EphemeralCryptoIdentity {
    static func make(bits: Int, ellipticCurve: Bool = false) async throws -> (certPEM: String, keyPEM: String) {
        // RSA generation can outlast transport deadlines on a small runner; keep cooperative workers free.
        try await onTestThread { try generate(bits: bits, ellipticCurve: ellipticCurve) }
    }

    private static func generate(bits: Int, ellipticCurve: Bool) throws -> (certPEM: String, keyPEM: String) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: ellipticCurve ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits
        ]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let publicBytes = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let privateBytes = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        let rsa = DER.sequence(DER.rsaEncryption, DER.null)
        let ec = DER.sequence([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01],
                              [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let signatureAlgorithm = ellipticCurve
            ? DER.sequence([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
            : DER.sequence(DER.sha256WithRSA, DER.null)
        let name = DER.sequence(DER.set(DER.sequence(DER.commonName, DER.utf8String("Ephemeral test identity"))))
        let now = Date()
        let tbs = DER.sequence(DER.encode(0xA0, DER.integer(2)), DER.integer(1), signatureAlgorithm, name,
                               DER.sequence(DER.time(now.addingTimeInterval(-60)),
                                            DER.time(now.addingTimeInterval(3600))), name,
                               DER.sequence(ellipticCurve ? ec : rsa, DER.bitString([UInt8](publicBytes))))
        let algorithm: SecKeyAlgorithm = ellipticCurve
            ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        let signature = try #require(SecKeyCreateSignature(key, algorithm, Data(tbs) as CFData, nil) as Data?)
        let certificate = DER.sequence(tbs, signatureAlgorithm, DER.bitString([UInt8](signature)))
        let privateDER = ellipticCurve ? [UInt8](privateBytes)
            : DER.sequence(DER.integer(0), rsa, DER.octetString([UInt8](privateBytes)))
        return (PEM.encode(certificate, label: "CERTIFICATE"), PEM.encode(privateDER, label: "PRIVATE KEY"))
    }
}

struct PinnedCertStoreTests {

    @Test func failedValidationKeepsPreviousPin() throws {
        let hostID = "pin-replacement-\(UUID().uuidString)"
        defer { PinnedCertStore.delete(forHostID: hostID) }
        try PinnedCertStore.store(pem: "old certificate", forHostID: hostID)

        do {
            try PinnedCertStore.writePEM("new certificate", forHostID: hostID) { prepared in
                #expect(try String(contentsOf: prepared, encoding: .utf8) == "new certificate")
                throw CocoaError(.fileReadNoPermission)
            }
            Issue.record("Expected prepared pin validation to fail")
        } catch {
            #expect(PinnedCertStore.load(forHostID: hostID) == "old certificate")
        }
    }
}
