//
//  StreamCryptoTests.swift
//
//  Coverage for ControlCrypto (StreamCrypto.swift): the AES-128-GCM control-V2
//  sealing/unsealing. Tests pin the on-the-wire envelope shape, the
//  cross-direction round-trip (seal is client->host with IV byte 'C'; open is
//  host->client with IV byte 'H'), tamper-rejection, and the IV-distinctness
//  property that keeps client and host streams from colliding on the same key.
//
//  Note: open(seal(p)) does NOT round-trip directly - they're deliberately
//  opposite directions ('C' vs 'H' originator byte). To exercise `open` we
//  craft a host-direction envelope with CryptoKit using the matching IV; to
//  exercise `seal` we decrypt its output with CryptoKit using the 'C' IV. Both
//  mirror the exact framing the production code documents.
//

import Foundation
import Testing
import CryptoKit
@testable import Glimmer

struct StreamCryptoTests {

    // The control-V2 IV: iv[0..3] = seq LE, iv[10] = originator ('C'/'H'),
    // iv[11] = 'C' (0x43, control stream). Mirrors ControlCrypto.iv (private).
    private static func controlIV(seq: UInt32, originator: UInt8) -> Data {
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xFF)
        iv[1] = UInt8((seq >> 8) & 0xFF)
        iv[2] = UInt8((seq >> 16) & 0xFF)
        iv[3] = UInt8((seq >> 24) & 0xFF)
        iv[10] = originator
        iv[11] = 0x43
        return Data(iv)
    }

    private static let key16: [UInt8] = Array(0..<16).map { UInt8($0) }

    // Build a full host->client ('H') on-the-wire envelope around an inner V2
    // plaintext, the same byte layout `seal` produces but in the opposite
    // direction, so `open` accepts it.
    private static func sealHostDirection(
        type: UInt16, payload: [UInt8], seq: UInt32, key: [UInt8]
    ) throws -> [UInt8] {
        var plaintext = [UInt8]()
        plaintext.append(UInt8(type & 0xFF)); plaintext.append(UInt8((type >> 8) & 0xFF))
        let plen = UInt16(payload.count)
        plaintext.append(UInt8(plen & 0xFF)); plaintext.append(UInt8((plen >> 8) & 0xFF))
        plaintext.append(contentsOf: payload)

        let nonce = try AES.GCM.Nonce(data: controlIV(seq: seq, originator: 0x48 /* 'H' */))
        let box = try AES.GCM.seal(Data(plaintext),
                                   using: SymmetricKey(data: Data(key)), nonce: nonce)
        let tag = [UInt8](box.tag)
        let ciphertext = [UInt8](box.ciphertext)
        let length = UInt16(4 + 16 + ciphertext.count)

        var out = [UInt8]()
        out.append(0x01); out.append(0x00)
        out.append(UInt8(length & 0xFF)); out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(seq & 0xFF)); out.append(UInt8((seq >> 8) & 0xFF))
        out.append(UInt8((seq >> 16) & 0xFF)); out.append(UInt8((seq >> 24) & 0xFF))
        out.append(contentsOf: tag)
        out.append(contentsOf: ciphertext)
        return out
    }

    private func innerPlaintext(type: UInt16, payload: [UInt8]) -> [UInt8] {
        var pt = [UInt8]()
        pt.append(UInt8(type & 0xFF)); pt.append(UInt8((type >> 8) & 0xFF))
        let plen = UInt16(payload.count)
        pt.append(UInt8(plen & 0xFF)); pt.append(UInt8((plen >> 8) & 0xFF))
        pt.append(contentsOf: payload)
        return pt
    }

    // MARK: - init validation

    @Test func initRejectsWrongKeyLength() {
        #expect(throws: StreamCryptoError.self) {
            _ = try ControlCrypto(rikey: [UInt8](repeating: 0, count: 15))
        }
        #expect(throws: StreamCryptoError.self) {
            _ = try ControlCrypto(rikey: [UInt8](repeating: 0, count: 17))
        }
    }

    @Test func initAcceptsSixteenByteKey() throws {
        _ = try ControlCrypto(rikey: Self.key16)
    }

    // MARK: - open(host-direction envelope) recovers the inner V2 plaintext

    @Test func openRecoversHostDirectionPlaintext() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        let cases: [(UInt16, [UInt8], UInt32)] = [
            (0x1234, [], 0),
            (0x0001, [0xAA], 1),
            (0x00FF, Array(0..<32).map { UInt8($0) }, 0xDEAD_BEEF),
            (0xFFFF, [UInt8](repeating: 0x5A, count: 200), 0x0000_FFFF)
        ]
        for (type, payload, seq) in cases {
            let envelope = try Self.sealHostDirection(
                type: type, payload: payload, seq: seq, key: Self.key16)
            let recovered = try crypto.open(envelope)
            #expect(recovered == innerPlaintext(type: type, payload: payload))
        }
    }

    // MARK: - seal output is a valid 'C'-direction GCM envelope

    @Test func sealProducesValidClientDirectionEnvelope() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        let type: UInt16 = 0x0007
        let payload: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        let seq: UInt32 = 0x1122_3344

        let wire = try crypto.seal(type: type, payload: payload, seq: seq)

        // Header: encryptedHeaderType 0x0001 LE.
        #expect(wire[0] == 0x01 && wire[1] == 0x00)
        // length LE = 4(seq) + 16(tag) + ciphertext(== plaintext len = 4+payload).
        let length = Int(wire[2]) | (Int(wire[3]) << 8)
        #expect(length == 4 + 16 + (4 + payload.count))
        // Total wire = length + 4.
        #expect(wire.count == length + 4)
        // seq LE echoed in bytes 4..7.
        let wireSeq = UInt32(wire[4]) | (UInt32(wire[5]) << 8)
            | (UInt32(wire[6]) << 16) | (UInt32(wire[7]) << 24)
        #expect(wireSeq == seq)

        // Decrypt with CryptoKit using the 'C' IV; recover the inner plaintext.
        let tag = Array(wire[8..<24])
        let ciphertext = Array(wire[24...])
        let nonce = try AES.GCM.Nonce(data: Self.controlIV(seq: seq, originator: 0x43))
        let box = try AES.GCM.SealedBox(nonce: nonce,
                                        ciphertext: Data(ciphertext), tag: Data(tag))
        let recovered = [UInt8](try AES.GCM.open(box, using: SymmetricKey(data: Data(Self.key16))))
        #expect(recovered == innerPlaintext(type: type, payload: payload))
    }

    // MARK: - tamper rejection

    @Test func openRejectsTamperedCiphertext() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        var envelope = try Self.sealHostDirection(
            type: 0x0001, payload: [0x10, 0x20, 0x30, 0x40], seq: 42, key: Self.key16)
        // Flip a bit in the last ciphertext byte.
        envelope[envelope.count - 1] ^= 0x01
        #expect(throws: StreamCryptoError.self) { _ = try crypto.open(envelope) }
    }

    @Test func openRejectsTamperedTag() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        var envelope = try Self.sealHostDirection(
            type: 0x0001, payload: [0x10, 0x20, 0x30, 0x40], seq: 42, key: Self.key16)
        envelope[8] ^= 0x80   // first tag byte
        #expect(throws: StreamCryptoError.self) { _ = try crypto.open(envelope) }
    }

    @Test func openRejectsWrongDirectionEnvelope() throws {
        // A 'C'-direction (client) envelope must NOT open on the host->client
        // path: the originator byte makes the IVs disagree, so auth fails.
        let crypto = try ControlCrypto(rikey: Self.key16)
        let clientEnvelope = try crypto.seal(type: 0x0001, payload: [9, 9, 9, 9], seq: 7)
        #expect(throws: StreamCryptoError.self) { _ = try crypto.open(clientEnvelope) }
    }

    @Test func openRejectsRuntPacket() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        #expect(throws: StreamCryptoError.self) {
            _ = try crypto.open([UInt8](repeating: 0, count: 23))  // < 24 minimum
        }
    }

    @Test func openRejectsLengthMismatch() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        var envelope = try Self.sealHostDirection(
            type: 0x0001, payload: [1, 2, 3, 4], seq: 5, key: Self.key16)
        envelope.append(0xFF)  // declared length no longer matches actual bytes
        #expect(throws: StreamCryptoError.self) { _ = try crypto.open(envelope) }
    }

    // MARK: - IV distinctness ('C' vs 'H')

    @Test func clientAndHostIVsDifferAtOriginatorByte() throws {
        // Same key, same seq, same plaintext: the client ('C') and host ('H')
        // envelopes must produce DIFFERENT ciphertext/tag because the IV byte
        // differs. This is what stops the two directions colliding on one key.
        let crypto = try ControlCrypto(rikey: Self.key16)
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let seq: UInt32 = 1000

        let clientWire = try crypto.seal(type: 0x0001, payload: payload, seq: seq)
        let hostWire = try Self.sealHostDirection(
            type: 0x0001, payload: payload, seq: seq, key: Self.key16)

        // Ciphertext starts at byte 24 in both; same length, different bytes.
        let clientCipher = Array(clientWire[24...])
        let hostCipher = Array(hostWire[24...])
        #expect(clientCipher.count == hostCipher.count)
        #expect(clientCipher != hostCipher)
        // Tags (bytes 8..24) also differ.
        #expect(Array(clientWire[8..<24]) != Array(hostWire[8..<24]))
    }

    @Test func differentSeqsGiveDifferentCiphertext() throws {
        let crypto = try ControlCrypto(rikey: Self.key16)
        let a = try crypto.seal(type: 0x0001, payload: [1, 2, 3, 4], seq: 1)
        let b = try crypto.seal(type: 0x0001, payload: [1, 2, 3, 4], seq: 2)
        #expect(Array(a[24...]) != Array(b[24...]))
    }

    // MARK: - NIST SP 800-38D AES-128-GCM known-answer
    //
    // Pin CryptoKit's AES-GCM against the published Gladman/NIST GCM test
    // case 3 (full 64-byte plaintext, NO AAD) so the whole crypto stack the
    // control path relies on is anchored to a known answer. 16-byte tag.

    @Test func aesGcm128KnownAnswerVector() throws {
        let key = Data(hex: "feffe9928665731c6d6a8f9467308308")!
        let iv = Data(hex: "cafebabefacedbaddecaf888")!
        let plaintext = Data(hex:
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")!
        let expectedCT = Data(hex:
            "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e" +
            "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985")!
        let expectedTag = Data(hex: "4d5c2af327cd64a62cf35abd2ba6fab4")!

        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        #expect(Data(box.ciphertext) == expectedCT)
        #expect(Data(box.tag) == expectedTag)
    }
}

// Local hex decoder for the KAT vectors above (independent of any app helper
// so the vector test stands on its own).
private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }
}
