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
        // EVP_RSA_gen / EVP_PKEY_Q_keygen are macros / variadic — Swift can't
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

        // Serial number — fixed at 0 to match moonlight-qt. The host never
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

        // Subject + Issuer — same name since this is self-signed. The host
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
        // zero on failure — anything > 0 is fine.
        guard X509_sign(cert, pkey, EVP_sha256()) > 0 else {
            throw StreamError.crypto("X509_sign failed")
        }

        // --- Serialize key -----------------------------------------------
        let keyPEM = try pemFromBIO { bio in
            // No cipher, no passphrase — the key sits in a mode-0600 file
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

        // PEM is ASCII — copying into a String is safe and removes our reliance
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

    // MARK: - SecIdentity construction (one-time per process)
    //
    // The SecIdentity for mutual-TLS comes from the file-store PEMs. We build
    // it by feeding the PEMs through OpenSSL → PKCS#12 → SecPKCS12Import,
    // grab the SecIdentityRef the import returns, and cache it for the
    // lifetime of the process. The keychain item the import creates is
    // pre-authorized for this process via SecAccess, deleted on the next
    // launch, and re-imported fresh. That's the only documented way for an
    // adhoc-signed app to use a SecIdentity without prompting the user; once
    // we ship a real Developer ID, this whole path collapses into a single
    // SecItemCopyMatching on the data-protection keychain (see the
    // "Future: when signed with a Developer ID" note at the top of the file).

    private static let dpLabel = "Glimmer Client Identity"

    func buildOrLoadIdentity() throws -> SecIdentity {
        // We deliberately do NOT reuse the existing labelled identity from a
        // prior launch. Its ACL is pinned (via SecTrustedApplication) to the
        // Glimmer executable's CDHash at the time of import — which means
        // every rebuild during development (and every signed app-update for
        // shipped users without a stable Developer ID) invalidates the ACL,
        // making the "Glimmer wants to use the key" prompt fire.
        //
        // Re-importing on every launch costs a few ms of OpenSSL work and a
        // round-trip through Security.framework. The benefit is that the new
        // SecAccess is built from the current process's SecTrustedApplication,
        // so the ACL always matches the running binary and there's no prompt.
        deleteLabelledIdentity()
        let identity = try load()
        return try importLabelledIdentity(certPEM: identity.certPEM,
                                          keyPEM: identity.keyPEM)
    }

    /// Wipe any previous "Glimmer Client Identity" entry (and its associated
    /// cert / key) so the re-import lands cleanly without colliding.
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

    func importLabelledIdentity(certPEM: String, keyPEM: String) throws -> SecIdentity {
        let pkcs12Pass = "glimmer-transient"
        guard let p12 = makePKCS12(certPEM: certPEM, keyPEM: keyPEM, passphrase: pkcs12Pass) else {
            throw StreamError.crypto("Failed to build PKCS#12 from client identity")
        }

        // Pre-authorize Glimmer via SecAccess so the import into login keychain
        // doesn't fire the "Glimmer wants to sign using key" prompt. SecAccess
        // is deprecated (the data-protection keychain replaces it, but
        // requires entitlements adhoc-signed apps can't claim), but the API
        // still works on macOS 26 and is the only documented way to silently
        // authorize a non-entitled app to use a keychain item.
        var glimmerApp: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &glimmerApp)
        guard status == errSecSuccess, let glimmerApp else {
            throw StreamError.crypto("SecTrustedApplicationCreateFromPath failed (\(status))")
        }
        let trustedApps: [SecTrustedApplication] = [glimmerApp]
        var access: SecAccess?
        status = SecAccessCreate(Self.dpLabel as CFString, trustedApps as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw StreamError.crypto("SecAccessCreate failed (\(status))")
        }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: pkcs12Pass,
            kSecImportExportAccess as String: access
        ]
        var rawItems: CFArray?
        let importStatus = SecPKCS12Import(p12 as CFData, options as CFDictionary, &rawItems)
        guard importStatus == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw StreamError.crypto("SecPKCS12Import failed (OSStatus \(importStatus))")
        }
        // The CF type for kSecImportItemIdentity is documented as SecIdentityRef,
        // but defend against keychain misbehaviour with a typeID check before
        // casting — an unexpected value throws a crypto error rather than
        // trapping. Past the check, unsafeDowncast is the established idiom for
        // a typeID-verified CF cast (mirrors the CGColorSpace casts in
        // VideoDecoder+HDR) and avoids a force-cast.
        let identityRef = identityAny as CFTypeRef
        guard CFGetTypeID(identityRef) == SecIdentityGetTypeID() else {
            throw StreamError.crypto("SecPKCS12Import returned a non-identity (typeID \(CFGetTypeID(identityRef)))")
        }
        let identity = unsafeDowncast(identityRef, to: SecIdentity.self)

        // Label the imported items so we can find them on the next launch
        // (and so they show up as something human-readable in Keychain Access
        // rather than the default "Imported Private Key").
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: Self.dpLabel
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            log.error("SecItemAdd for labelled identity failed: \(addStatus, privacy: .public) (continuing — identity still usable)")
        }

        log.info("Imported SecIdentity from file-store PEMs (pre-authorized for current binary, no prompt)")
        return identity
    }

    /// Re-implemented here so we don't depend on Network.swift's private
    /// helpers. Same OpenSSL dance: build PKCS#12 from PEM.
    func makePKCS12(certPEM: String, keyPEM: String, passphrase: String) -> Data? {
        guard let certBio = certPEM.withCString({ BIO_new_mem_buf($0, -1) }) else { return nil }
        defer { BIO_free(certBio) }
        guard let cert = PEM_read_bio_X509(certBio, nil, nil, nil) else { return nil }
        defer { X509_free(cert) }

        guard let keyBio = keyPEM.withCString({ BIO_new_mem_buf($0, -1) }) else { return nil }
        defer { BIO_free(keyBio) }
        guard let pkey = PEM_read_bio_PrivateKey(keyBio, nil, nil, nil) else { return nil }
        defer { EVP_PKEY_free(pkey) }

        let name = "Glimmer Client Identity"
        guard let p12 = name.withCString({ namePtr in
            passphrase.withCString { passPtr in
                PKCS12_create(passPtr, namePtr, pkey, cert, nil, 0, 0, 0, 0, 0)
            }
        }) else { return nil }
        defer { PKCS12_free(p12) }

        guard let outBio = BIO_new(BIO_s_mem()) else { return nil }
        defer { BIO_free(outBio) }
        guard i2d_PKCS12_bio(outBio, p12) == 1 else { return nil }

        var ptr: UnsafeMutablePointer<CChar>?
        let len = gl_bio_get_mem_data(outBio, &ptr)
        guard len > 0, let ptr else { return nil }
        return Data(bytes: ptr, count: Int(len))
    }
}
