//
//  Identity+Loading.swift
//
//  Identity materialization + migration: load() (file store, with legacy
//  keychain import) and the one-time cleanup of the stores Glimmer itself
//  wrote in earlier builds - legacy keychain items and UserDefaults
//  plaintext. moonlight-qt's plist is a read-only source: we copy out of
//  it and never write to it. Split out of Identity.swift to keep each unit
//  focused; see that file for the actor.
//

import Foundation
import os.log
import Security

extension IdentityManager {

    func load() throws -> Identity {
        if let cached { return cached }

        let defaults = UserDefaults.standard

        // -----------------------------------------------------------------
        // Step 1 - file-store fast path.
        // -----------------------------------------------------------------
        if defaults.integer(forKey: Self.fileStorageFlag) >= Self.fileStorageVersion {
            if let identity = try loadFromFileStore() {
                cached = identity
                log.info("Loaded identity from file store")
                return identity
            }
            // Flag set but file missing - user wiped Application Support,
            // disk error, whatever. Fall through to regen below. The flag
            // stays set; the regen path writes to the file store and the
            // flag remains accurate.
            log.error("identityFileStorageVersion flag set but file store is empty - regenerating")
        }

        // -----------------------------------------------------------------
        // Step 2 - legacy-keychain migration (the keychain-era build's three generic-password
        // items at service "io.ugfugl.Glimmer.identity").
        //
        // We do this BEFORE the UserDefaults branch because if the
        // legacy-keychain-only flag was set, UserDefaults has already been
        // wiped by the keychain-era build and the only live copy is in the keychain.
        //
        // The `try?` swallows keychain read errors so we still fall through
        // to the next migration source if the user denies the prompt or the
        // ACL fails. The orphaned items get nuked by
        // `cleanupOrphanLoginKeychainEntries` on a subsequent launch.
        // -----------------------------------------------------------------
        if let migrated = (try? loadFromLegacyKeychain()) {
            try writeIdentityToFileStore(migrated)
            deleteLegacyKeychainItems()
            defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
            cached = migrated
            log.info("Migrated from login keychain to file store (and deleted keychain items)")
            return migrated
        }

        // -----------------------------------------------------------------
        // Step 3 - original UserDefaults plaintext (the earliest builds).
        //
        // If the legacy-keychain-only flag is set, the keychain-era build already wiped
        // UserDefaults so this branch can't help. Skip it.
        // -----------------------------------------------------------------
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

        // -----------------------------------------------------------------
        // Step 4 - moonlight-qt cross-app migration. QSettings stores PEMs
        // as Data, not String, so we read both shapes. Copy only - the
        // source plist is never modified; see the note above
        // `adoptMoonlightQtIdentity`.
        // -----------------------------------------------------------------
        let needsMigration = (storedCert?.isEmpty ?? true) || (storedKey?.isEmpty ?? true)
        if needsMigration, let adopted = adoptMoonlightQtIdentity(currentID: storedID) {
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
            wipeUserDefaultsPlaintext()
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
        wipeUserDefaultsPlaintext()
        defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
        cached = identity
        log.info("Wrote freshly-generated identity to file store")
        return identity
    }

    // MARK: moonlight-qt source (read-only)
    //
    // moonlight-qt keeps its client cert and RSA private key as plaintext
    // PEM under the `certificate` / `key` fields of its own UserDefaults
    // suite:
    //   ~/Library/Preferences/com.moonlight-stream.Moonlight.plist
    // at the default mode 0644 - readable by any process running as the
    // same UID. That posture is moonlight-qt's, and it predates us; Glimmer
    // neither created it nor can fix it on qt's behalf.
    //
    // What Glimmer controls is its own copy, and that lands in the mode-0600
    // file store above. So we COPY and stop there: we never remove, rewrite,
    // or otherwise touch a single field of the source plist. Deleting qt's
    // PEMs would silently strip moonlight-qt of its identity and therefore
    // of every host it had paired with - a real, immediate loss to the user
    // in exchange for hardening a file we do not own. Both apps stay paired.

    static let moonlightQtSuiteName = "com.moonlight-stream.Moonlight"

    /// Adopted PEM material from the moonlight-qt UserDefaults suite. The
    /// uniqueID carries forward the caller's existing ID when qt's own ID
    /// field is missing/empty, so adoption never clobbers a known ID with nil.
    struct AdoptedQtIdentity {
        let certPEM: String
        let keyPEM: String
        let uniqueID: String?
    }

    /// Step 4 helper - read the cert/key (and optional uniqueID) PEMs out of
    /// the moonlight-qt UserDefaults suite. Returns nil when the suite is
    /// unreadable or doesn't carry a usable cert+key pair.
    private func adoptMoonlightQtIdentity(currentID: String?) -> AdoptedQtIdentity? {
        guard let moonlight = UserDefaults(suiteName: Self.moonlightQtSuiteName),
              let adopted = Self.adoptedIdentity(fromMoonlightQt: moonlight,
                                                 currentID: currentID) else {
            return nil
        }
        log.info("""
            Copying moonlight-qt client identity \
            (\(adopted.certPEM.count) byte cert, \(adopted.keyPEM.count) byte key) \
            → file store; source plist left untouched
            """)
        return adopted
    }

    /// The read itself, as a pure function of a suite, so a test can point it
    /// at a scratch domain instead of the real moonlight-qt one. QSettings
    /// persists PEMs as either String or Data, so we accept both shapes.
    /// Reads only - nothing here writes back to `moonlight`.
    static func adoptedIdentity(fromMoonlightQt moonlight: UserDefaults,
                                currentID: String?) -> AdoptedQtIdentity? {
        func readPEM(_ key: String) -> String? {
            if let str = moonlight.string(forKey: key), !str.isEmpty { return str }
            if let data = moonlight.data(forKey: key),
               let str = String(data: data, encoding: .utf8), !str.isEmpty {
                return str
            }
            return nil
        }

        guard let mCert = readPEM("certificate"), let mKey = readPEM("key") else {
            return nil
        }
        let mID = moonlight.string(forKey: "uniqueid")
                 ?? moonlight.data(forKey: "uniqueid").flatMap { String(data: $0, encoding: .utf8) }

        // Preserve the caller's existing ID unless qt offers a non-empty one.
        let resolvedID = (mID?.isEmpty == false) ? mID : currentID
        return AdoptedQtIdentity(certPEM: mCert, keyPEM: mKey, uniqueID: resolvedID)
    }

    // MARK: File store (current backend)

    /// Read all three components out of the file store. Returns nil if any of
    /// them is missing - caller treats that as "fall through to next source".
    /// IO errors throw so a real read failure surfaces instead of silently
    /// triggering a destructive regen.
    func loadFromFileStore() throws -> Identity? {
        guard let certData = try FileIdentityStore.read(account: Self.accountCert),
              let certPEM = String(data: certData, encoding: .utf8),
              !certPEM.isEmpty else {
            return nil
        }
        guard let keyData = try FileIdentityStore.read(account: Self.accountKey),
              let keyPEM = String(data: keyData, encoding: .utf8),
              !keyPEM.isEmpty else {
            return nil
        }
        let uid: String
        if let uidData = try FileIdentityStore.read(account: Self.accountUID),
           let stored = String(data: uidData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            uid = stored
        } else {
            // Unique ID file missing or empty - synthesise a fresh one and
            // persist it so subsequent loads are stable. This shouldn't
            // normally happen (we always write all three together), but
            // disk truncation / partial restore could theoretically leave
            // us in this state.
            uid = try generateUniqueID()
            let uidBytes = Data(uid.utf8)
            try FileIdentityStore.write(uidBytes, account: Self.accountUID)
            log.info("File store missing uniqueID - synthesised and wrote a fresh one")
        }
        return Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
    }

    /// Persist an Identity to the file store. Each component goes through
    /// `FileIdentityStore.write` which enforces mode 0600 and verifies it
    /// stuck via stat(2).
    func writeIdentityToFileStore(_ identity: Identity) throws {
        try FileIdentityStore.write(Data(identity.certPEM.utf8),
                                    account: Self.accountCert)
        try FileIdentityStore.write(Data(identity.keyPEM.utf8),
                                    account: Self.accountKey)
        try FileIdentityStore.write(Data(identity.uniqueID.utf8),
                                    account: Self.accountUID)
    }

    // MARK: Legacy keychain (read-only migration source)

    /// Read the three generic-password items the keychain-era build wrote into the login
    /// keychain. Returns nil if any of the required components is missing.
    /// Throws on any keychain error that isn't `errSecItemNotFound` so the
    /// outer `try?` can decide whether to skip this migration source.
    func loadFromLegacyKeychain() throws -> Identity? {
        guard let certPEM = try readLegacyKeychainString(account: Self.accountCert),
              !certPEM.isEmpty else { return nil }
        guard let keyPEM = try readLegacyKeychainString(account: Self.accountKey),
              !keyPEM.isEmpty else { return nil }
        // `??` can't take a throwing RHS without an outer `try`, and that
        // would mis-tag this whole expression as a single throw site. Unfold
        // to an if-let so the missing-UID case can call into the throwing
        // generator cleanly.
        let uid: String
        if let stored = try readLegacyKeychainString(account: Self.accountUID), !stored.isEmpty {
            uid = stored
        } else {
            uid = try generateUniqueID()
        }
        return Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
    }

    func readLegacyKeychainString(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw StreamError.crypto("SecItemCopyMatching(legacy \(account)) failed: \(status)")
        }
    }

    /// Best-effort delete of the three legacy generic-password items. Called
    /// after a successful migration to the file store. Safe to call multiple
    /// times - SecItemDelete on a missing item returns `errSecItemNotFound`
    /// which we treat as success.
    func deleteLegacyKeychainItems() {
        for account in [Self.accountCert, Self.accountKey, Self.accountUID] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: UserDefaults plaintext cleanup

    /// Remove any plaintext PEMs left in UserDefaults. The uniqueID is
    /// wiped too - once we're in file-store mode the only authoritative copy
    /// lives on disk. Idempotent: removing missing keys is a no-op.
    func wipeUserDefaultsPlaintext() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: IdentityKey.certificate)
        defaults.removeObject(forKey: IdentityKey.privateKey)
        defaults.removeObject(forKey: IdentityKey.uniqueID)
        // Force a synchronous flush to disk so a process crash between
        // here and natural CFPreferences flush doesn't leave the plaintext
        // PEM on the platter.
        defaults.synchronize()
    }

    // MARK: Unique ID

    /// 32-hex-char GUID. moonlight-qt uses 64-bit base-16 (so up to 16 chars);
    /// we hand back a full 16-byte (128-bit) ID instead - wider is fine, the
    /// host treats it as an opaque string.
}
