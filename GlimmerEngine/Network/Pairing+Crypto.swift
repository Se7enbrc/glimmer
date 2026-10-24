// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import CommonCrypto
import CryptoKit
import Foundation
import os
import Security

// MARK: - Crypto / encoding helpers
//
// All static, so they're testable in isolation and stay out of the actor's isolation.

extension PairingClient {

    // MARK: Random

    package static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw StreamError.crypto("SecRandomCopyBytes failed")
        }
        return Data(bytes)
    }

    // MARK: AES-128-ECB (no padding)

    // Sunshine requires raw ECB for pairing challenges and hashes, with block-aligned
    // inputs. Signature and challenge checks are separate from this cipher; see SECURITY.md for its limits.

    package static func aesEcbEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        try aesEcb(plaintext, key: key, encrypt: true)
    }

    package static func aesEcbDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try aesEcb(ciphertext, key: key, encrypt: false)
    }

    private static func aesEcb(_ input: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16 else {
            throw StreamError.crypto("AES key must be 16 bytes (got \(key.count))")
        }
        guard input.count % 16 == 0, !input.isEmpty else {
            throw StreamError.crypto("AES input must be a non-zero multiple of 16 bytes (got \(input.count))")
        }

        var output = Data(count: input.count)
        var moved = 0
        // No padding option: the protocol uses raw blocks, never PKCS#7.
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { keyBytes in
                input.withUnsafeBytes { inBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count, nil,
                            inBytes.baseAddress, input.count, out.baseAddress, out.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw StreamError.crypto(encrypt ? "AES encrypt failed" : "AES decrypt failed")
        }
        return output
    }

    // MARK: Digest

    /// SHA-256, the only pairing hash Sunshine uses.
    package static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: Certificate signature

    // The "cert signature" hashed into the challenge response is the bytes already on the
    // cert, not a recomputed signature, so both sides read the same value from the same PEM.

    package static func signatureFromPemCert(_ pem: String) throws -> Data {
        // Security vets the certificate before the DER walk reads its signature.
        guard PEM.certificate(pem) != nil, let der = PEM.der(pem),
              let signature = DER.certificateParts(der)?.signature else {
            throw StreamError.crypto("could not read the certificate's signature")
        }
        return signature
    }

    // MARK: RSA verify (host signature over serverSecret)

    package static func verifySignature(
        data: Data,
        signature: Data,
        serverCertPEM: String
    ) throws -> Bool {
        let key = try PEM.certificateKey(serverCertPEM, context: "PC certificate")
        // Invalid and malformed both come back false; the caller throws on false.
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                     data as CFData, signature as CFData, nil)
    }

    // MARK: RSA sign (our signature over our clientSecret)

    package static func signMessage(_ message: Data, privateKeyPEM: String) throws -> Data {
        guard let key = PEM.privateKey(privateKeyPEM) else {
            throw StreamError.crypto("could not read the client key")
        }
        try PEM.requireStrongRSA(key, context: "client private key")
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    message as CFData, &error) as Data? else {
            throw StreamError.crypto("signing failed: \(String(describing: error?.takeRetainedValue()))")
        }
        return signature
    }

    // MARK: XML helpers

    // Sunshine wraps paired/plaincert fields in a root carrying the status_code attribute.

    package static func verifyResponseStatus(_ xml: XMLNode) throws {
        guard let root = xml.firstChild(named: "root") else {
            throw StreamError.pairingFailed("response missing <root> element")
        }
        let codeRaw = root.attributes["status_code"] ?? "-1"
        // GFE 3.20.3 sometimes returns 0xFFFFFFFF - parse as UInt32 first then
        // narrow, matching NvHTTP::verifyResponseStatus.
        let code: Int
        if let unsigned = UInt32(codeRaw) {
            code = Int(Int32(bitPattern: unsigned))
        } else {
            code = Int(codeRaw) ?? -1
        }
        if code == 200 { return }
        // Sunshine's session verdicts: 408 it expired, 409 this Mac's earlier request is
        // still open, 503 too many are open. Each has its own words on the pair sheet.
        if code == 408 { throw PairingFailure.timedOut }
        if code == 409 || code == 503 { throw PairingFailure.busy }

        let message = root.attributes["status_message"] ?? ""
        throw StreamError.pairingFailed("host returned status \(code) \(message)")
    }

    package static func xmlString(_ xml: XMLNode, tag: String) -> String? {
        // The root node wraps everything; XMLNode.string(forChild:) only looks
        // one level down, so we hop through <root> first.
        guard let root = xml.firstChild(named: "root") else { return nil }
        return root.string(forChild: tag)
    }
}

// MARK: - Hex encoding

extension Data {
    /// Match moonlight-qt's lowercase wire hex; two digits preserve leading zeros.
    package func hex() -> String {
        // Reserve exact capacity - saves the dynamic-resize cost on a hot path
        // (cert blobs are ~1KB which means ~2KB of hex).
        var out = String()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(String(format: "%02x", byte))
        }
        return out
    }

    /// Lenient hex decode. Accepts mixed case and ignores embedded whitespace
    /// - GFE sometimes pretty-prints with newlines inside <plaincert>.
    package init?(hex: String) {
        let cleaned = hex.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard cleaned.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)

        var iter = cleaned.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let highNibble = Self.hexNibble(hi), let lowNibble = Self.hexNibble(lo) else {
                return nil
            }
            bytes.append((highNibble << 4) | lowNibble)
        }
        self = Data(bytes)
    }

    private static func hexNibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        default: return nil
        }
    }
}

// SHA-256 challenges are 32-byte hashes plus 16-byte secrets; raw AES uses no padding.
// Certificate signatures are the X.509 BIT STRING payload; client secrets use RSA/SHA-256.
// Sunshine uses SHA-256, while obsolete SHA-1 GameStream versions are refused before pairing.
