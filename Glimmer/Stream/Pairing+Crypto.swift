//
//  Pairing+Crypto.swift
//
//  Crypto + encoding helpers for the pairing flow (random bytes, AES-128-ECB,
//  digests, X509 signature extraction, RSA verify/sign, XML helpers) plus the
//  lowercase hex encoding and the resolved "open items" notes. Split out of
//  Pairing.swift to keep each unit focused; see that file for the pairing flow.
//

import Foundation
import os

// MARK: - Crypto / encoding helpers
//
// All static so they're trivially testable in isolation and don't drag the
// actor's isolation into the OpenSSL calls. OpenSSL itself is thread-safe
// for these byte-shoveling primitives.

extension PairingClient {

    // MARK: Random

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            RAND_bytes(buf.baseAddress, Int32(buf.count))
        }
        guard ok == 1 else {
            throw StreamError.crypto("RAND_bytes failed")
        }
        return Data(bytes)
    }

    // MARK: AES-128-ECB (no padding)
    //
    // moonlight uses raw ECB for every challenge/response block. ECB is
    // safe-enough here because every plaintext is 16 random bytes; the usual
    // ECB pitfalls (repeated-block leaks) don't apply to one-shot 128-bit
    // values. Padding is disabled because all inputs are exact multiples of
    // the block size by construction.

    static func aesEcbEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        try aesEcb(plaintext, key: key, encrypt: true)
    }

    static func aesEcbDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try aesEcb(ciphertext, key: key, encrypt: false)
    }

    private static func aesEcb(_ input: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16 else {
            throw StreamError.crypto("AES key must be 16 bytes (got \(key.count))")
        }
        guard input.count % 16 == 0, !input.isEmpty else {
            throw StreamError.crypto("AES input must be a non-zero multiple of 16 bytes (got \(input.count))")
        }

        guard let ctx = EVP_CIPHER_CTX_new() else {
            throw StreamError.crypto("EVP_CIPHER_CTX_new failed")
        }
        defer { EVP_CIPHER_CTX_free(ctx) }

        var output = Data(count: input.count)
        var outLen: Int32 = 0

        let ok = key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) -> Int32 in
            input.withUnsafeBytes { (inBytes: UnsafeRawBufferPointer) -> Int32 in
                output.withUnsafeMutableBytes { (outBytes: UnsafeMutableRawBufferPointer) -> Int32 in
                    let keyPtr = keyBytes.bindMemory(to: UInt8.self).baseAddress
                    let inPtr  = inBytes.bindMemory(to: UInt8.self).baseAddress
                    let outPtr = outBytes.bindMemory(to: UInt8.self).baseAddress

                    let initOK: Int32
                    if encrypt {
                        initOK = EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), nil, keyPtr, nil)
                    } else {
                        initOK = EVP_DecryptInit_ex(ctx, EVP_aes_128_ecb(), nil, keyPtr, nil)
                    }
                    guard initOK == 1 else { return 0 }

                    // Critical: protocol uses raw blocks, no PKCS#7 padding.
                    EVP_CIPHER_CTX_set_padding(ctx, 0)

                    let updateOK: Int32
                    if encrypt {
                        updateOK = EVP_EncryptUpdate(ctx, outPtr, &outLen, inPtr, Int32(input.count))
                    } else {
                        updateOK = EVP_DecryptUpdate(ctx, outPtr, &outLen, inPtr, Int32(input.count))
                    }
                    return updateOK
                }
            }
        }

        guard ok == 1 else {
            throw StreamError.crypto(encrypt ? "AES encrypt failed" : "AES decrypt failed")
        }
        guard Int(outLen) == input.count else {
            throw StreamError.crypto("AES produced \(outLen) bytes, expected \(input.count)")
        }
        return output
    }

    // MARK: Digest

    static func digest(_ data: Data, sha256: Bool) throws -> Data {
        let length = sha256 ? Int(SHA256_DIGEST_LENGTH) : Int(SHA_DIGEST_LENGTH)
        let algo = sha256 ? "SHA256" : "SHA1"
        var out = [UInt8](repeating: 0, count: length)

        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                EVP_Q_digest(nil,
                             algo, nil,
                             raw.baseAddress, data.count,
                             outBuf.baseAddress, nil)
            }
        }
        guard ok == 1 else {
            throw StreamError.crypto("digest failed")
        }
        return Data(out)
    }

    // MARK: X509 signature extraction
    //
    // The "cert signature" we hash into the challenge response is the raw
    // ASN.1 BIT STRING from the X509 — not a recomputed signature, but the
    // bytes that are already on the cert. Both sides extract it the same
    // way from the same PEM, so they end up with the same value.

    static func signatureFromPemCert(_ pem: String) throws -> Data {
        let pemBytes = Data(pem.utf8)
        let cert = try parsePEMCert(pemBytes)
        defer { X509_free(cert) }

        // X509_get0_signature takes a const ASN1_BIT_STRING ** out-param. We
        // hand it a slot, then read the pointer back out. Ownership stays
        // with the X509 — we must NOT free `asnSig`.
        var asnSig: UnsafePointer<ASN1_BIT_STRING>?
        withUnsafeMutablePointer(to: &asnSig) { sigPP in
            X509_get0_signature(sigPP, nil, cert)
        }

        guard let asnSig else {
            throw StreamError.crypto("X509_get0_signature returned null")
        }
        // ASN1_BIT_STRING is a typedef of ASN1_STRING under the hood, so the
        // STRING accessors work directly.
        let asnString = UnsafePointer<ASN1_STRING>(OpaquePointer(asnSig))
        let length = Int(ASN1_STRING_length(asnString))
        guard length > 0, let dataPtr = ASN1_STRING_get0_data(asnString) else {
            throw StreamError.crypto("ASN1_STRING signature has no data")
        }
        return Data(bytes: dataPtr, count: length)
    }

    /// PEM -> X509*. Caller owns the result and must X509_free it.
    private static func parsePEMCert(_ pemBytes: Data) throws -> OpaquePointer {
        let cert: OpaquePointer? = pemBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OpaquePointer? in
            guard let base = raw.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(base, Int32(pemBytes.count)) else { return nil }
            defer { BIO_free(bio) }
            return PEM_read_bio_X509(bio, nil, nil, nil)
        }
        guard let cert else {
            throw StreamError.crypto("PEM_read_bio_X509 failed")
        }
        return cert
    }

    // MARK: RSA verify (host signature over serverSecret)

    static func verifySignature(
        data: Data,
        signature: Data,
        serverCertPEM: String
    ) throws -> Bool {
        let cert = try parsePEMCert(Data(serverCertPEM.utf8))
        defer { X509_free(cert) }

        guard let pubKey = X509_get_pubkey(cert) else {
            throw StreamError.crypto("X509_get_pubkey failed")
        }
        defer { EVP_PKEY_free(pubKey) }

        guard let mdctx = EVP_MD_CTX_new() else {
            throw StreamError.crypto("EVP_MD_CTX_new failed (verify)")
        }
        defer { EVP_MD_CTX_free(mdctx) }

        guard EVP_DigestVerifyInit(mdctx, nil, EVP_sha256(), nil, pubKey) == 1 else {
            throw StreamError.crypto("EVP_DigestVerifyInit failed")
        }

        let result = data.withUnsafeBytes { (dataBytes: UnsafeRawBufferPointer) -> Int32 in
            signature.withUnsafeBytes { (sigBytes: UnsafeRawBufferPointer) -> Int32 in
                let dataPtr = dataBytes.bindMemory(to: UInt8.self).baseAddress
                let sigPtr  = sigBytes.bindMemory(to: UInt8.self).baseAddress
                // EVP_DigestVerify is the one-shot form: update + final in one call.
                return EVP_DigestVerify(mdctx, sigPtr, signature.count, dataPtr, data.count)
            }
        }
        // 1 = signature valid, 0 = invalid, <0 = hard error. Treat anything
        // but 1 as "not valid" — we only care about the boolean outcome and
        // the caller throws on false.
        return result == 1
    }

    // MARK: RSA sign (our signature over our clientSecret)

    static func signMessage(_ message: Data, privateKeyPEM: String) throws -> Data {
        let keyBytes = Data(privateKeyPEM.utf8)

        let pkey: OpaquePointer? = keyBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OpaquePointer? in
            guard let base = raw.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(base, Int32(keyBytes.count)) else { return nil }
            defer { BIO_free(bio) }
            return PEM_read_bio_PrivateKey(bio, nil, nil, nil)
        }
        guard let pkey else {
            throw StreamError.crypto("PEM_read_bio_PrivateKey failed")
        }
        defer { EVP_PKEY_free(pkey) }

        guard let ctx = EVP_MD_CTX_new() else {
            throw StreamError.crypto("EVP_MD_CTX_new failed (sign)")
        }
        defer { EVP_MD_CTX_free(ctx) }

        guard EVP_DigestSignInit(ctx, nil, EVP_sha256(), nil, pkey) == 1 else {
            throw StreamError.crypto("EVP_DigestSignInit failed")
        }

        // Two-pass: first call with NULL out buffer to discover signature
        // length, then second call to actually fill it. This is the canonical
        // OpenSSL pattern; signature length depends on the RSA key size.
        let updateOK = message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            EVP_DigestSignUpdate(ctx, raw.baseAddress, message.count)
        }
        guard updateOK == 1 else {
            throw StreamError.crypto("EVP_DigestSignUpdate failed")
        }

        var sigLen: Int = 0
        guard EVP_DigestSignFinal(ctx, nil, &sigLen) == 1, sigLen > 0 else {
            throw StreamError.crypto("EVP_DigestSignFinal (probe) failed")
        }

        var signature = Data(count: sigLen)
        let finalOK = signature.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            EVP_DigestSignFinal(ctx, raw.bindMemory(to: UInt8.self).baseAddress, &sigLen)
        }
        guard finalOK == 1 else {
            throw StreamError.crypto("EVP_DigestSignFinal failed")
        }
        // OpenSSL may report a smaller actual size than the probe value
        // (e.g. for DER-encoded ECDSA sigs); trim to the real length.
        signature.count = sigLen
        return signature
    }

    // MARK: XML helpers
    //
    // NetworkClient hands us a parsed XMLNode tree. The host's pair responses
    // are shaped like:
    //   <root status_code="200"><paired>1</paired><plaincert>...</plaincert></root>
    // We pull the status_code attribute off <root> and read child text by
    // tag name.

    static func verifyResponseStatus(_ xml: XMLNode) throws {
        guard let root = xml.firstChild(named: "root") else {
            throw StreamError.pairingFailed("response missing <root> element")
        }
        let codeRaw = root.attributes["status_code"] ?? "-1"
        // GFE 3.20.3 sometimes returns 0xFFFFFFFF — parse as UInt32 first then
        // narrow, matching NvHTTP::verifyResponseStatus.
        let code: Int
        if let unsigned = UInt32(codeRaw) {
            code = Int(Int32(bitPattern: unsigned))
        } else {
            code = Int(codeRaw) ?? -1
        }
        if code == 200 { return }

        let message = root.attributes["status_message"] ?? ""
        throw StreamError.pairingFailed("host returned status \(code) \(message)")
    }

    static func xmlString(_ xml: XMLNode, tag: String) -> String? {
        // The root node wraps everything; XMLNode.string(forChild:) only looks
        // one level down, so we hop through <root> first.
        guard let root = xml.firstChild(named: "root") else { return nil }
        return root.string(forChild: tag)
    }
}

// MARK: - Hex encoding

extension Data {
    /// Lowercase hex string. We deliberately match moonlight-qt's wire format
    /// (`QByteArray::toHex()` → lowercase). GFE / Sunshine appear to accept
    /// either case in practice, but moonlight-qt has been the reference
    /// implementation for ~a decade — any divergence is a latent risk on some
    /// GFE 3.x build we haven't tested against. The performance cost is
    /// identical; the readability of packet captures is exactly the same. If
    /// we ever need uppercase for a specific endpoint we can add a flag.
    func hex() -> String {
        // Reserve exact capacity — saves the dynamic-resize cost on a hot path
        // (cert blobs are ~1KB which means ~2KB of hex).
        var out = String()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(String(format: "%02x", byte))
        }
        return out
    }

    /// Lenient hex decode. Accepts mixed case and ignores embedded whitespace
    /// — GFE sometimes pretty-prints with newlines inside <plaincert>.
    init?(hex: String) {
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

// MARK: - Open items
//
// All four `verify-with-host` items from earlier sweeps have been
// resolved or downgraded based on a line-by-line read of moonlight-qt's
// `app/backend/nvpairingmanager.cpp`:
//
// 1. CHALLENGE RESPONSE LAYOUT — moonlight-qt's `decrypt(challengeresponse)`
//    treats the entire decrypted blob as `hashLen || 16-byte challenge ||
//    server-cert-sig` (the sig is whatever the cert's ASN.1 BIT STRING is
//    long, typically 256/384 bytes for RSA-2048/3072). It does NOT assume
//    the ciphertext is block-aligned; OpenSSL's EVP_DecryptUpdate handles
//    that. Our `aesEcbDecrypt` rejects non-aligned input, which is correct
//    because every observed response IS aligned, but the protocol does not
//    formally require it. → kept as-is; surface a clear error if it ever
//    happens, then revisit.
//
// 2. HEX CASE — moonlight-qt uses `QByteArray::toHex()` which is lowercase.
//    We now match this exactly (see `Data.hex()` below). GFE / Sunshine
//    both accept either case in observed packet captures, but lowercase
//    eliminates a latent divergence.
//
// 3. UNIQUEID / UUID — `NetworkClient.rawRequest` injects the well-known
//    `uniqueid=0123456789ABCDEF` (matching moonlight-qt's hardcoded shared
//    ID, see comment in nvhttp.cpp) and a fresh `uuid=` nonce per request.
//    Pairing only passes its own keys.
//
// 4. URL-ENCODING — URLComponents percent-encodes hex query values, which
//    is harmless because hex chars are unreserved. Sunshine cert blobs
//    push us toward ~3KB URLs; moonlight-qt uses GET for the same payload
//    so we are within established tolerances. No action.
