// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation
import os.log
import Security

extension IdentityManager {

    func load() throws -> Identity {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        guard let defaults else { throw IdentityStorageError.defaultsUnavailable }
        if let cached { return cached }
        return try FileIdentityStore.withExclusiveAccess(base: storageRoot()) { try loadUncached(defaults: defaults) }
    }

    private func loadUncached(defaults: UserDefaults) throws -> Identity {

        try FileIdentityStore.discardStaging(base: storageRoot())
        // Files are authoritative even when preferences were reset or restored separately.
        if let identity = try loadFromFileStore() {
            cached = identity
            defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
            log.info("Loaded identity from file store")
            return identity
        }

        // The keychain-era flag means the earliest plaintext defaults were already wiped.
        let legacyKeychainOnly = defaults.integer(forKey: Self.legacyKeychainOnlyFlag) >= 1

        var storedCert: String?
        var storedKey: String?
        var storedID: String?

        if !legacyKeychainOnly {
            storedCert = defaults.string(forKey: IdentityKey.certificate)
            storedKey  = defaults.string(forKey: IdentityKey.privateKey)
            storedID   = defaults.string(forKey: IdentityKey.uniqueID)
        } else {
            // Even with the flag set, an opaque uniqueID might still live
            // in UserDefaults from an even earlier build. Preserve it.
            storedID = defaults.string(forKey: IdentityKey.uniqueID)
        }

        // The shell may copy a legacy identity. It validates PEMs and never modifies the source suite.
        let hasLegacyIdentity = storedCert != nil || storedKey != nil || storedID != nil
        if hasLegacyIdentity {
            guard let storedCert, !storedCert.isEmpty, let storedKey, !storedKey.isEmpty,
                  let storedID, !storedID.isEmpty else { throw IdentityStorageError.incompleteIdentity }
        }
        let needsMigration = !hasLegacyIdentity
        if needsMigration, let adopted = try migrateIdentity(storedID) {
            storedCert = adopted.certPEM
            storedKey  = adopted.keyPEM
            storedID   = adopted.uniqueID
        }

        // -----------------------------------------------------------------
        // Either we have a usable PEM pair from steps 3/4, or we go to step 5.
        // -----------------------------------------------------------------
        if let certPEM = storedCert, !certPEM.isEmpty,
           let keyPEM  = storedKey, !keyPEM.isEmpty {
            let uid: String
            if let stored = storedID, !stored.isEmpty {
                uid = stored
            } else {
                uid = try generateUniqueID()
            }
            let identity = Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
            try writeIdentityToFileStore(identity)
            wipeUserDefaultsPlaintext(defaults: defaults)
            defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
            cached = identity
            log.info("Migrated identity from UserDefaults plaintext to file store")
            return identity
        }

        // -----------------------------------------------------------------
        // Step 5 - fresh install. Generate, file-store, done.
        // -----------------------------------------------------------------
        log.info("No existing client identity - generating a new one (file store)")
        let (certPEM, keyPEM) = try generateKeyPairAndCert()
        let uid: String
        if let stored = storedID, !stored.isEmpty {
            uid = stored
        } else {
            uid = try generateUniqueID()
        }
        let identity = Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
        try writeIdentityToFileStore(identity)
        wipeUserDefaultsPlaintext(defaults: defaults)
        defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
        cached = identity
        log.info("Wrote freshly-generated identity to file store")
        return identity
    }

    package struct AdoptedQtIdentity: Sendable {
        package let certPEM: String
        package let keyPEM: String
        package let uniqueID: String?
        package init(certPEM: String, keyPEM: String, uniqueID: String?) {
            self.certPEM = certPEM
            self.keyPEM = keyPEM
            self.uniqueID = uniqueID
        }
    }

    // MARK: File store (current backend)

    /// Established bytes are never repaired or replaced, including an orphaned client ID.
    func loadFromFileStore() throws -> Identity? {
        let base = try storageRoot()
        guard try FileIdentityStore.hasStoredFiles(base: base) else { return nil }
        let certData = try FileIdentityStore.read(account: Self.accountCert, base: base)
        let keyData = try FileIdentityStore.read(account: Self.accountKey, base: base)
        let uidData = try FileIdentityStore.read(account: Self.accountUID, base: base)
        guard let certData, let keyData, let uidData,
              let certPEM = String(data: certData, encoding: .utf8), !certPEM.isEmpty,
              let keyPEM = String(data: keyData, encoding: .utf8), !keyPEM.isEmpty,
              let uid = String(data: uidData, encoding: .utf8),
              !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IdentityStorageError.incompleteIdentity
        }
        do { _ = try PEM.identity(certPEM: certPEM, keyPEM: keyPEM) } catch {
            throw IdentityStorageError.invalidIdentity
        }
        return Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
    }

    /// Publish the entire validated identity at once, leaving failed creation only in staging.
    func writeIdentityToFileStore(_ identity: Identity) throws {
        do { _ = try PEM.identity(certPEM: identity.certPEM, keyPEM: identity.keyPEM) } catch {
            throw IdentityStorageError.invalidIdentity
        }
        try FileIdentityStore.publish(identity, base: storageRoot())
    }

    // MARK: UserDefaults plaintext cleanup

    /// Remove any plaintext PEMs left in UserDefaults. The uniqueID is
    /// wiped too - once we're in file-store mode the only authoritative copy
    /// lives on disk. Idempotent: removing missing keys is a no-op.
    func wipeUserDefaultsPlaintext(defaults: UserDefaults) {
        defaults.removeObject(forKey: IdentityKey.certificate)
        defaults.removeObject(forKey: IdentityKey.privateKey)
        defaults.removeObject(forKey: IdentityKey.uniqueID)
        // Force a synchronous flush to disk so a process crash between
        // here and natural CFPreferences flush doesn't leave the plaintext
        // PEM on the platter.
        defaults.synchronize()
    }
}
