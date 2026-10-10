// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  Identity+Crypto.swift
//
//  The client identity's unique ID, RSA key and self-signed certificate, made in memory with
//  Security (never the keychain) and written as the PEM files Sunshine and moonlight-qt expect.
//

import Foundation
import os.log
import Security

extension IdentityManager {

    func generateUniqueID() throws -> String {
        try PairingClient.randomBytes(16).hex()
    }

    // MARK: Cert + key generation

    /// The certificate moonlight-qt makes: X.509 v3, serial 0, CN "NVIDIA GameStream Client" as
    /// subject and issuer, twenty years from now, SHA-256 with RSA-2048. The key is written as
    /// PKCS#8, the form OpenSSL wrote, so identities stay readable by older builds.
    func generateKeyPairAndCert() throws -> (certPEM: String, keyPEM: String) {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicPKCS1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privatePKCS1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw StreamError.crypto("RSA key generation failed: \(String(describing: error?.takeRetainedValue()))")
        }

        let name = DER.sequence(DER.set(DER.sequence(DER.commonName, DER.utf8String("NVIDIA GameStream Client"))))
        let algorithm = DER.sequence(DER.sha256WithRSA, DER.null)
        let now = Date()
        let tbs = DER.sequence(
            DER.encode(0xA0, DER.integer(2)),   // [0] version: v3
            DER.integer(0),                     // serial, 0 like moonlight-qt
            algorithm, name,
            DER.sequence(DER.time(now), DER.time(now.addingTimeInterval(60 * 60 * 24 * 365 * 20))),
            name,
            DER.sequence(DER.sequence(DER.rsaEncryption, DER.null), DER.bitString([UInt8](publicPKCS1))))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else {
            throw StreamError.crypto("certificate signing failed: \(String(describing: error?.takeRetainedValue()))")
        }
        let cert = DER.sequence(tbs, algorithm, DER.bitString([UInt8](signature)))
        let pkcs8 = DER.sequence(DER.integer(0), DER.sequence(DER.rsaEncryption, DER.null),
                                 DER.octetString([UInt8](privatePKCS1)))
        // No passphrase: the key lives in a mode-0600 file, and a same-user attacker already won.
        return (PEM.encode(cert, label: "CERTIFICATE"), PEM.encode(pkcs8, label: "PRIVATE KEY"))
    }

    // MARK: - Legacy login-keychain cleanup
    //
    // Older builds laundered the client cert/key through a SecIdentity in the login keychain.
    // Nothing reads it now, so the versioned cleanup deletes it once.

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
