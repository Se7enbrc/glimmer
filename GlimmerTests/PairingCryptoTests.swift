//
//  PairingCryptoTests.swift
//
//  Coverage for the OpenSSL-backed pairing/identity crypto. These run because
//  the test bundle is hosted by the Glimmer app (TEST_HOST), which links
//  -lssl -lcrypto, so the OpenSSL primitives resolve at runtime.
//
//   - IdentityManager.aesKey(forPIN:salt:): first 16 bytes of
//     SHA-256(salt || pin.utf8). Cross-checked here against CryptoKit's SHA256.
//   - PairingClient.aesEcbEncrypt/Decrypt: AES-128-ECB round-trip (no padding).
//   - PairingClient.digest: SHA-256 / SHA-1 known-answer.
//   - PairingClient.signMessage / verifySignature: RSA sign->verify round-trip,
//     using a throwaway keypair+cert generated IN-TEST via the app's own
//     generateKeyPairAndCert() - no committed PEM fixture.
//

import Foundation
import Testing
import CryptoKit
@testable import Glimmer

struct PairingCryptoTests {

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

        let actual = try await IdentityManager.shared.aesKey(forPIN: pin, salt: salt)
        #expect(actual.count == 16)
        #expect(actual == expected)
    }

    @Test func aesKeyIsDeterministicAndPinSensitive() async throws {
        let salt = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33,
                         0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB])
        let mgr = IdentityManager.shared
        let k1 = try await mgr.aesKey(forPIN: "0000", salt: salt)
        let k2 = try await mgr.aesKey(forPIN: "0000", salt: salt)
        let kOther = try await mgr.aesKey(forPIN: "9999", salt: salt)
        #expect(k1 == k2)              // deterministic
        #expect(k1 != kOther)         // PIN-sensitive
    }

    @Test func aesKeyIsSaltSensitive() async throws {
        let mgr = IdentityManager.shared
        let saltA = Data(repeating: 0x00, count: 16)
        let saltB = Data(repeating: 0xFF, count: 16)
        let kA = try await mgr.aesKey(forPIN: "4321", salt: saltA)
        let kB = try await mgr.aesKey(forPIN: "4321", salt: saltB)
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
        let out = try PairingClient.digest(Data("abc".utf8), sha256: true)
        #expect(out.count == 32)
        let expected = Data(SHA256.hash(data: Data("abc".utf8)))
        #expect(out == expected)
        #expect(out.map { String(format: "%02x", $0) }.joined()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func digestSha1KnownAnswer() throws {
        // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        let out = try PairingClient.digest(Data("abc".utf8), sha256: false)
        #expect(out.count == 20)
        #expect(out.map { String(format: "%02x", $0) }.joined()
            == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func digestCrossChecksCryptoKitOnRandomInput() throws {
        let data = Data((0..<137).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let out = try PairingClient.digest(data, sha256: true)
        #expect(out == Data(SHA256.hash(data: data)))
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
}
