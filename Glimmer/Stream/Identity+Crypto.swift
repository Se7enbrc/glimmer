//
//  Identity+Crypto.swift
//
//  Key/cert generation and SecIdentity assembly: unique-ID + RSA keypair + X.509
//  self-signed cert (via OpenSSL), PEM/BIO plumbing, and PKCS#12 import into a
//  SecIdentity. Split out of Identity.swift to keep each unit focused.
//

import Foundation
import os.log
import Security

extension IdentityManager {

    func generateUniqueID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            RAND_bytes(buf.baseAddress, Int32(buf.count))
        }
        guard ok == 1 else {
            throw StreamError.crypto("RAND_bytes failed for uniqueID")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Cert + key generation
    //
    // OpenSSL is allocation-heavy and every *_new() needs a matching *_free().
    // We use `defer` blocks immediately after each allocation; on a thrown
    // error the defers still fire in reverse order, which leaves the process
    // memory-clean even on the failure paths.

    func generateKeyPairAndCert() throws -> (certPEM: String, keyPEM: String) {

        // --- Key ---------------------------------------------------------
        // EVP_RSA_gen is the modern OpenSSL 3 one-shot; it returns a fully
        // initialized EVP_PKEY* containing a fresh 2048-bit RSA keypair.
        // EVP_RSA_gen / EVP_PKEY_Q_keygen are macros / variadic - Swift can't
        // import either. Use the gl_rsa_keygen wrapper in CHelpers.h.
        guard let pkey = gl_rsa_keygen(2048) else {
            throw StreamError.crypto("gl_rsa_keygen(2048) failed")
        }
        defer { EVP_PKEY_free(pkey) }

        // --- Cert --------------------------------------------------------
        guard let cert = X509_new() else {
            throw StreamError.crypto("X509_new failed")
        }
        defer { X509_free(cert) }

        // Version 2 == X.509 v3 (the field is zero-indexed).
        guard X509_set_version(cert, 2) == 1 else {
            throw StreamError.crypto("X509_set_version failed")
        }

        // Serial number - fixed at 0 to match moonlight-qt. The host never
        // validates the serial against anything, so giving it a constant is
        // both safe and exactly what's already on the wire.
        if let serial = X509_get_serialNumber(cert) {
            ASN1_INTEGER_set(serial, 0)
        }

        // Validity window: now → now + 20 years. The host happily accepts a
        // wildly-future expiry, and a 20-year window means the user never has
        // to think about re-pairing because of a stale cert.
        let twentyYears: Int = 60 * 60 * 24 * 365 * 20
        guard let notBefore = X509_getm_notBefore(cert),
              X509_gmtime_adj(notBefore, 0) != nil else {
            throw StreamError.crypto("X509_gmtime_adj notBefore failed")
        }
        guard let notAfter = X509_getm_notAfter(cert),
              X509_gmtime_adj(notAfter, twentyYears) != nil else {
            throw StreamError.crypto("X509_gmtime_adj notAfter failed")
        }

        guard X509_set_pubkey(cert, pkey) == 1 else {
            throw StreamError.crypto("X509_set_pubkey failed")
        }

        // Subject + Issuer - same name since this is self-signed. The host
        // looks for this specific CN to identify a Moonlight-protocol client.
        guard let name = X509_NAME_new() else {
            throw StreamError.crypto("X509_NAME_new failed")
        }
        defer { X509_NAME_free(name) }

        let commonName = "NVIDIA GameStream Client"
        let added: Int32 = commonName.withCString { cstr -> Int32 in
            cstr.withMemoryRebound(to: UInt8.self, capacity: commonName.utf8.count) { bytes in
                X509_NAME_add_entry_by_txt(name,
                                           "CN",
                                           MBSTRING_ASC,
                                           bytes,
                                           -1, -1, 0)
            }
        }
        guard added == 1 else {
            throw StreamError.crypto("X509_NAME_add_entry_by_txt(CN) failed")
        }
        guard X509_set_subject_name(cert, name) == 1 else {
            throw StreamError.crypto("X509_set_subject_name failed")
        }
        guard X509_set_issuer_name(cert, name) == 1 else {
            throw StreamError.crypto("X509_set_issuer_name failed")
        }

        // SHA-256 signature. X509_sign returns the signature size on success,
        // zero on failure - anything > 0 is fine.
        guard X509_sign(cert, pkey, EVP_sha256()) > 0 else {
            throw StreamError.crypto("X509_sign failed")
        }

        // --- Serialize key -----------------------------------------------
        let keyPEM = try pemFromBIO { bio in
            // No cipher, no passphrase - the key sits in a mode-0600 file
            // already, so any extra encryption here would only be security
            // theatre against a same-UID attacker who already lost.
            PEM_write_bio_PrivateKey(bio, pkey, nil, nil, 0, nil, nil)
        } onError: {
            StreamError.crypto("PEM_write_bio_PrivateKey failed")
        }

        // --- Serialize cert ----------------------------------------------
        let certPEM = try pemFromBIO { bio in
            PEM_write_bio_X509(bio, cert)
        } onError: {
            StreamError.crypto("PEM_write_bio_X509 failed")
        }

        return (certPEM, keyPEM)
    }

    /// Wraps the BIO_new → write → BIO_get_mem_data → BIO_free dance.
    /// `write` does the OpenSSL write into the BIO and returns its native
    /// status code (1 = success for the PEM_write_* family). On any failure
    /// we throw `onError()` so the caller picks the right error message.
    func pemFromBIO(write: (OpaquePointer) -> Int32,
                    onError: () -> StreamError) throws -> String {
        guard let bio = BIO_new(BIO_s_mem()) else {
            throw StreamError.crypto("BIO_new(BIO_s_mem) failed")
        }
        defer { BIO_free(bio) }

        guard write(bio) == 1 else {
            throw onError()
        }

        var ptr: UnsafeMutablePointer<CChar>?
        let len = gl_bio_get_mem_data(bio, &ptr)
        guard len > 0, let ptr else {
            throw onError()
        }

        // PEM is ASCII - copying into a String is safe and removes our reliance
        // on the BIO's backing memory. The failable `String(bytes:encoding:)`
        // can only return nil on non-UTF-8 bytes, which OpenSSL's PEM writers
        // never produce; treat that impossible case as an encode failure.
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(len))
        let pem: String? = buffer.withMemoryRebound(to: UInt8.self) { bytes in
            String(bytes: bytes, encoding: .utf8)
        }
        guard let pem else {
            throw onError()
        }
        return pem
    }

    // MARK: - Legacy login-keychain cleanup
    //
    // Pre-OpenSSL builds laundered the client cert/key through a SecIdentity in
    // the login keychain. The control channel now runs on OpenSSL straight from
    // the PEMs, so that item is dead weight - preflight() deletes it on launch.

    private static let dpLabel = "Glimmer Client Identity"

    /// Delete the orphaned "Glimmer Client Identity" item (+ its cert/key) that
    /// older builds imported into the login keychain. Idempotent; SecItemDelete
    /// on absent items is a harmless no-op.
    func deleteLabelledIdentity() {
        for cls in [kSecClassIdentity, kSecClassKey, kSecClassCertificate] {
            let query: [String: Any] = [
                kSecClass as String: cls,
                kSecAttrLabel as String: Self.dpLabel,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }
}
