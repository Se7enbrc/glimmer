// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// AES-128-GCM control-V2 framing from ControlStream.c; transport provenance is in CREDITS.md.
// Wire: [u16 0x0001 LE][u16 length LE][u32 seq LE][tag16][ciphertext of inner V2 header + payload].
// IV: seq LE in bytes 0...3, originator ('C'/'H') then 'C' in bytes 10...11; tag precedes ciphertext.

import Foundation
import CryptoKit

package enum StreamCryptoError: Error, CustomStringConvertible {
    case badKeyLength(Int)
    case runtPacket(Int)
    case lengthMismatch(expected: Int, got: Int)
    case authFailed
    case sealFailed(String)

    package var description: String {
        switch self {
        case .badKeyLength(let len): return "AES key must be 16 bytes, got \(len)"
        case .runtPacket(let len): return "control packet too short to decrypt (\(len) bytes)"
        case .lengthMismatch(let expected, let got):
            return "encrypted length mismatch (expected \(expected), got \(got))"
        case .authFailed: return "AES-GCM authentication failed"
        case .sealFailed(let reason): return "AES-GCM seal failed: \(reason)"
        }
    }
}

/// AES-128-GCM control-stream crypto for the Gen7 "control V2" framing. One instance per session; reuse the single key.
/// `seq` uniqueness (driven by a strictly-monotonic counter held by the caller) is what makes each (key, nonce) pair
/// unique - never reuse a seq.
package struct ControlCrypto {
    private let key: SymmetricKey

    /// `rikey` must be exactly the 16-byte remoteInputAesKey used for /launch.
    package init(rikey: [UInt8]) throws {
        guard rikey.count == 16 else { throw StreamCryptoError.badKeyLength(rikey.count) }
        self.key = SymmetricKey(data: Data(rikey))
    }

    /// Build the 12-byte control-V2 IV. iv[0..3] = seq little-endian; iv[10],
    /// iv[11] tag the direction ('C'/'C' client->host, 'H'/'C' host->client).
    private static func iv(seq: UInt32, originatorHostByte: UInt8) -> Data {
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xFF)
        iv[1] = UInt8((seq >> 8) & 0xFF)
        iv[2] = UInt8((seq >> 16) & 0xFF)
        iv[3] = UInt8((seq >> 24) & 0xFF)
        iv[10] = originatorHostByte  // 'C' client / 'H' host
        iv[11] = 0x43               // 'C' = control stream
        return Data(iv)
    }

    /// Seal client→PC [0x0001 LE][length LE][seq LE][tag16][ciphertext], with inner type/length LE + payload.
    /// Supply seq monotonically under the same lock that orders ENet sends; nonce reuse breaks authentication.
    package func seal(type: UInt16, payload: [UInt8], seq: UInt32) throws -> [UInt8] {
        // Inner V2 plaintext: type (LE) + payloadLength (LE) + payload.
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(4 + payload.count)
        plaintext.append(UInt8(type & 0xFF))
        plaintext.append(UInt8((type >> 8) & 0xFF))
        let plen = UInt16(payload.count)
        plaintext.append(UInt8(plen & 0xFF))
        plaintext.append(UInt8((plen >> 8) & 0xFF))
        plaintext.append(contentsOf: payload)

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: Self.iv(seq: seq, originatorHostByte: 0x43 /* 'C' */))
        } catch {
            throw StreamCryptoError.sealFailed("\(error)")
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(Data(plaintext), using: key, nonce: nonce)
        } catch {
            throw StreamCryptoError.sealFailed("\(error)")
        }

        // Control puts the tag first, unlike CryptoKit's combined representation; assemble it explicitly.
        let tag = [UInt8](sealed.tag)              // 16 bytes
        let ciphertext = [UInt8](sealed.ciphertext) // == plaintext.count
        // length = sizeof(seq:4) + 16(tag) + ciphertext (which already includes
        // the inner V2 header since it's part of the plaintext).
        let length = UInt16(4 + 16 + ciphertext.count)

        var out = [UInt8]()
        out.reserveCapacity(8 + tag.count + ciphertext.count)
        out.append(0x01); out.append(0x00)                       // encryptedHeaderType = 0x0001 LE
        out.append(UInt8(length & 0xFF)); out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(seq & 0xFF)); out.append(UInt8((seq >> 8) & 0xFF))
        out.append(UInt8((seq >> 16) & 0xFF)); out.append(UInt8((seq >> 24) & 0xFF))
        out.append(contentsOf: tag)
        out.append(contentsOf: ciphertext)
        return out
    }

    /// Open one inbound control packet (host->client). Returns the decrypted
    /// inner V2 plaintext (type LE + payloadLength LE + payload), or throws.
    /// Caller validates the leading LE16 == 0x0001 before calling.
    package func open(_ bytes: [UInt8]) throws -> [UInt8] {
        // Minimum: 8-byte cleartext header + 16-byte tag.
        guard bytes.count >= 24 else { throw StreamCryptoError.runtPacket(bytes.count) }
        let length = Int(bytes[2]) | (Int(bytes[3]) << 8)
        // length covers seq(4) + tag(16) + ciphertext; total wire bytes =
        // length + sizeof(encryptedHeaderType:2) + sizeof(length:2).
        let expected = length + 4
        guard bytes.count == expected else {
            throw StreamCryptoError.lengthMismatch(expected: expected, got: bytes.count)
        }
        let seq = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        let tag = Array(bytes[8..<24])
        let ciphertext = Array(bytes[24...])

        let nonce = try AES.GCM.Nonce(data: Self.iv(seq: seq, originatorHostByte: 0x48 /* 'H' */))
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        } catch {
            throw StreamCryptoError.authFailed
        }
        do {
            return [UInt8](try AES.GCM.open(box, using: key))
        } catch {
            throw StreamCryptoError.authFailed
        }
    }
}
