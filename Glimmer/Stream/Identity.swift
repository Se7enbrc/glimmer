//
//  Identity.swift
//
//  Client-side identity for the streaming engine: a stable unique ID plus an
//  RSA-2048 keypair under a self-signed X.509 certificate (CN = "NVIDIA
//  GameStream Client", 20-year validity). These three pieces of state are what
//  the host uses to recognize us - both during the pairing handshake and on
//  every subsequent TLS connection. Generated once on first launch and stored
//  in the data-protection keychain on signed builds (mode-0600 files only as an
//  adhoc fallback) - see STORAGE below.
//
//  Ported (loosely now) from moonlight-qt's app/backend/identitymanager.{h,cpp}.
//
//
// STORAGE: data-protection keychain on signed builds; mode-0600 files only as
// an adhoc fallback. `useKeychainBackend()` probes (a keychain write/read/delete
// round-trip, cached) whether this build can use the data-protection keychain:
//
//   * Signed with a real Team ID (Developer ID - every release, and every
//     `make dev` build, which now signs with the Developer ID too): the
//     data-protection keychain is the SOLE home. `KeychainIdentityStore` stores
//     the three components as generic-password items (kSecUseDataProtection-
//     Keychain, AfterFirstUnlockThisDeviceOnly) - encrypted at rest, gated to
//     this app's signed identity, never synced off-device, invisible in
//     Keychain Access.app. NO plaintext key touches disk. An existing install's
//     mode-0600 files are migrated in once (write keychain, verify on read-back,
//     then delete the files); see `persistIdentity` + load() Step 0. A keychain
//     write that doesn't verify THROWS - it never silently downgrades to a file.
//
//   * Adhoc / no Team ID (a from-source build with no Developer ID cert): the
//     data-protection keychain needs a signing identity, so it's unavailable;
//     `FileIdentityStore` (three mode-0600 PEM files under the sandbox
//     container) is the only option. This path never runs on a signed build.
//
// The data-protection keychain (unlike the login keychain) does NOT use the
// SecTrustedApplication CDHash ACL that prompted on every adhoc rebuild - the
// reason files were the store before a stable Team ID existed.
//
//
// THREAT MODEL:
//
// The long-lived RSA-2048 private key authenticates Glimmer to every paired
// host indefinitely. If it leaks, the attacker is a permanent imposter against
// every host this install paired with - until the user unpairs each one.
//
// On a signed build the key lives ONLY in the data-protection keychain:
// encrypted at rest and readable only by this app's signed identity, so even a
// same-UID process with Full Disk Access sees encrypted blobs, not the PEM. On
// an adhoc build the mode-0600 files are readable by any same-UID process
// (including an FDA-allowlisted one) - the cost of an unsigned build, which
// never affects shipped/signed Glimmer.
//

import Foundation
import os.log
import Security

// MARK: - Sendable bridge for Security-framework CF types
//
// SecIdentity / SecCertificate / SecKey are CoreFoundation reference types
// (SecIdentityRef etc). Apple documents the Security framework's object types
// as thread-safe for retain/release, and the values themselves are immutable
// once created - so they're effectively `Sendable`. The SDK headers do not
// (yet) declare the conformance, so we add it retroactively. The
// `@retroactive` attribute makes the intent explicit to readers and silences
// the Swift 6 warning about adopting a protocol the type's owner did not
// declare.
extension SecIdentity: @retroactive @unchecked Sendable {}
extension SecCertificate: @retroactive @unchecked Sendable {}
extension SecKey: @retroactive @unchecked Sendable {}
extension SecTrust: @retroactive @unchecked Sendable {}

// MARK: - Storage keys
//
// These string literals match QSettings keys written by moonlight-qt. Keeping
// them identical means an existing Moonlight install on the same machine (if
// its plist is migrated into ours) Just Works. Don't change them.
enum IdentityKey {
    static let uniqueID    = "uniqueid"
    static let certificate = "certificate"
    static let privateKey  = "key"
}

// MARK: - FileIdentityStore
//
// Three mode-0600 files under ~/Library/Application Support/Glimmer/Identity/.
// Atomic writes, owner-only permissions, verified by stat(2) after setattr
// because some filesystems (network mounts, FUSE) silently ignore the chmod.

enum FileIdentityStore {

    /// Filename for the X.509 certificate (PEM, full --BEGIN CERTIFICATE-- block).
    static let certFileName = "client-cert.pem"

    /// Filename for the RSA private key (PEM, PKCS#8 unencrypted).
    static let keyFileName = "client-key.pem"

    /// Filename for the 32-hex-char client unique ID (raw ASCII, no newline).
    static let uidFileName = "client-uniqueid.txt"

    /// Account-name → filename mapping. Keeping the `account:` API on the
    /// store mirrors how the old keychain backend was addressed, so the
    /// call sites at the top of `load()` stay readable.
    static func filename(forAccount account: String) -> String? {
        switch account {
        case IdentityManager.accountCert: return certFileName
        case IdentityManager.accountKey:  return keyFileName
        case IdentityManager.accountUID:  return uidFileName
        default: return nil
        }
    }

    /// `~/Library/Application Support/Glimmer/Identity/`. Created on first
    /// write with mode 0700.
    static func directoryURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        return base.appendingPathComponent("Glimmer/Identity", isDirectory: true)
    }

    static func fileURL(account: String) throws -> URL? {
        guard let name = filename(forAccount: account) else { return nil }
        return try directoryURL().appendingPathComponent(name, isDirectory: false)
    }

    /// Returns the bytes if the file exists, nil if it's absent. Anything
    /// else (permission denied, IO error mid-read) throws so we don't
    /// silently fall through to a destructive "regenerate".
    static func read(account: String) throws -> Data? {
        guard let url = try fileURL(account: account) else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Atomic write at mode 0600. Creates the parent directory at mode 0700
    /// if it doesn't yet exist. Verifies the final mode bits via stat(2)
    /// because `FileManager.setAttributes` can return `true` on filesystems
    /// that don't actually honour POSIX permissions (NFS without map-uid,
    /// some FUSE backends). On a permissions verification failure we delete
    /// the partial file and throw - half-written secrets on a too-permissive
    /// filesystem are worse than no file at all.
    static func write(_ data: Data, account: String) throws {
        guard let url = try fileURL(account: account) else {
            throw StreamError.crypto("FileIdentityStore: unknown account \(account)")
        }

        let fm = FileManager.default
        let dir = try directoryURL()

        // Ensure directory exists at 0700. `createDirectory` is a no-op if it
        // already exists (with `withIntermediateDirectories: true`), but it
        // does NOT chmod an existing directory back down. So we explicitly
        // setAttributes afterward. Best-effort - directory tightness is a
        // defense-in-depth bonus on top of the file mode.
        try fm.createDirectory(at: dir,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Atomic file write. `.atomic` writes to a temp file in the same
        // directory then renames; that means a crash mid-write can't leave
        // a torn PEM on disk.
        try data.write(to: url, options: [.atomic])

        // Apply mode 0600 and verify it stuck.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            try? fm.removeItem(at: url)
            throw StreamError.crypto("FileIdentityStore: missing POSIX permissions for \(url.lastPathComponent)")
        }
        // Mask off the SUID/SGID/sticky bits in the comparison - those are
        // never set by us but a paranoid umask could in theory surface them.
        let permBits = mode.uint16Value & 0o777
        guard permBits == 0o600 else {
            try? fm.removeItem(at: url)
            let modeOctal = String(permBits, radix: 8)
            throw StreamError.crypto(
                "FileIdentityStore: refused to keep \(url.lastPathComponent) with mode \(modeOctal) (expected 600)")
        }
    }

    /// Idempotent unlink. Used by cleanup / future migrations.
    static func delete(account: String) {
        guard let url = try? fileURL(account: account) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - KeychainIdentityStore
//
// Data-protection keychain backend (kSecUseDataProtectionKeychain). Used on
// builds signed with a real Team ID (Developer ID): the per-bundle-id DP
// keychain encrypts the items at rest and gates them to this app's signed
// identity, closing the "a Full-Disk-Access process reads the plaintext PEM"
// gap the file store carries. It is NOT the login keychain - no CDHash-ACL
// prompt - and is a distinct store from the legacy login-keychain items the
// cleanup sweep targets (those queries omit the DP flag, so they never reach
// these). On adhoc / no-Team-ID builds the DP keychain is unavailable and we
// fall back to files; `isAvailable()` probes that with a write/read/delete
// round-trip (the caller caches the result for the process).

enum KeychainIdentityStore {

    /// DP-keychain service. Items land in the app's default access group (its
    /// application-identifier); kSecAttrAccessGroup is omitted since Glimmer
    /// shares with nothing. The account names match the file store + the
    /// legacy login-keychain items, so the same migration call sites read.
    static let service = "io.ugfugl.Glimmer.identity"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Item data, or nil if absent. Throws on a real keychain error (anything
    /// but errSecItemNotFound) so the caller can fall back to files.
    static func read(account: String) throws -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:    return item as? Data
        case errSecItemNotFound: return nil
        default:
            throw StreamError.crypto("KeychainIdentityStore.read(\(account)) failed: \(status)")
        }
    }

    /// Upsert: add the item, or update its data if it already exists.
    /// AfterFirstUnlockThisDeviceOnly: readable after the first post-boot
    /// unlock, never synced or migrated off this device.
    static func write(_ data: Data, account: String) throws {
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let upStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         update as CFDictionary)
            guard upStatus == errSecSuccess else {
                throw StreamError.crypto("KeychainIdentityStore.update(\(account)) failed: \(upStatus)")
            }
        default:
            throw StreamError.crypto("KeychainIdentityStore.add(\(account)) failed: \(addStatus)")
        }
    }

    /// Idempotent delete.
    static func delete(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Probe whether the DP keychain accepts items for this app (true on
    /// Team-ID-signed builds, false on adhoc / missing-entitlement) via a
    /// throwaway write/read/delete round-trip. No prompt either way.
    static func isAvailable() -> Bool {
        let probe = "glimmer.dp-availability-probe"
        delete(account: probe)
        let token = Data("ok".utf8)
        do {
            try write(token, account: probe)
            let back = try read(account: probe)
            delete(account: probe)
            return back == token
        } catch {
            delete(account: probe)
            return false
        }
    }
}

// MARK: - IdentityManager

public actor IdentityManager {

    public static let shared = IdentityManager()

    /// Cached, fully-materialized identity. Built lazily on first access; once
    /// in memory we never touch disk again for the life of the actor.
    struct Identity {
        let uniqueID: String   // 32-hex-char GUID
        let certPEM: String    // PEM-encoded X.509 certificate
        let keyPEM: String    // PEM-encoded RSA private key (PKCS#8)
    }

    var cached: Identity?
    var cachedIdentity: SecIdentity?    // built once, reused for life of process

    /// Whether the data-protection keychain is usable on THIS build (true when
    /// signed with a real Team ID; false on adhoc). Probed once, lazily, and
    /// cached for the life of the actor - see `useKeychainBackend()`.
    private var keychainBackendAvailable: Bool?

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Identity")

    private init() {}

    /// Pick the identity backend for this build: the data-protection keychain
    /// when it's usable (Team-ID-signed), else mode-0600 files. Probes once
    /// and caches - the probe is a keychain round-trip, so we don't repeat it.
    func useKeychainBackend() -> Bool {
        if let v = keychainBackendAvailable { return v }
        let v = KeychainIdentityStore.isAvailable()
        keychainBackendAvailable = v
        log.info("Identity backend: \(v ? "data-protection keychain" : "mode-0600 files", privacy: .public)")
        return v
    }

    // MARK: Public surface

    public func clientCertPEM() throws -> String {
        try load().certPEM
    }

    public func clientKeyPEM() throws -> String {
        try load().keyPEM
    }

    public func uniqueID() throws -> String {
        try load().uniqueID
    }

    /// Returns the SecIdentity used for mutual TLS client authentication.
    ///
    /// Built once per process from the PEMs returned by `load()` and cached
    /// for subsequent calls. The PEM source (file store today, keychain on
    /// signed builds in the future) is transparent to this layer.
    public func secIdentity() throws -> SecIdentity {
        if let cachedIdentity { return cachedIdentity }
        let id = try buildOrLoadIdentity()
        cachedIdentity = id
        return id
    }

    /// Bootstrap step - call this early (from MoonlightManager.bootstrap()) so
    /// the identity setup happens during launch, not on the user's first
    /// stream click. Idempotent.
    public func preflight() async {
        cleanupOrphanLoginKeychainEntries()
        do {
            _ = try secIdentity()
            log.info("Client SecIdentity ready")
        } catch {
            log.error("Failed to prepare client SecIdentity: \(String(describing: error), privacy: .public)")
        }
        // SECURITY (#5): for users whose moonlight-qt migration already ran
        // in a pre-#5 build, the source plist still has the PEM material
        // even though we've long since stopped reading from it. Do a
        // version-gated best-effort wipe so those installs catch up.
        sweepStaleMoonlightQtPEMs()
    }

    /// Versioned one-shot cleanup of legacy keychain state from earlier builds.
    /// Repeated SecItemDelete on absent items is harmless but generates
    /// keychain log noise on every preflight; gate behind a UserDefaults flag
    /// so it runs at most once per install. Bump `currentCleanupVersion` when
    /// new orphans need sweeping.
    private static let cleanupVersionKey = "glimmer.identityCleanupVersion"
    private static let currentCleanupVersion = 2

    private func cleanupOrphanLoginKeychainEntries() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.cleanupVersionKey) < Self.currentCleanupVersion else {
            return
        }

        // Sweep 1: leftovers from earlier builds that imported unlabelled into
        // the user's login keychain. NOTE: do NOT include "Glimmer Client
        // Identity" here - that's our current SecIdentity item, and the
        // per-preflight re-import in `buildOrLoadIdentity` manages its
        // lifecycle.
        let names = ["Imported Private Key"]
        for name in names {
            for cls in [kSecClassIdentity, kSecClassKey, kSecClassCertificate] {
                let query: [String: Any] = [
                    kSecClass as String: cls,
                    kSecAttrLabel as String: name,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess {
                    log.info("Cleaned up orphan login-keychain entry: \(name)")
                }
            }
        }

        // Sweep 2: the three generic-password items the prior build
        // wrote into the login keychain at service
        // "io.ugfugl.Glimmer.identity". These are the items that
        // triggered the "allow Glimmer to read its own client identity"
        // prompt on every adhoc rebuild. The migration path in `load()`
        // pulls their values out for re-use; this sweep is the belt-and-
        // suspenders cleanup for entries that didn't get migrated (e.g.
        // because the user denied the prompt last time and the read
        // returned nil).
        for account in [Self.accountCert, Self.accountKey, Self.accountUID] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                log.info("Cleaned up legacy keychain identity item (\(account)) from login keychain")
            }
        }

        // Sweep 3: the abandoned file-based SecKeychain from an even earlier
        // build. Different path from our new mode-0600 identity files -
        // this was an entire SecKeychain database at
        // ~/Library/Application Support/Glimmer/identity.keychain that we
        // no longer need. Safe to delete on every install where the flag
        // hasn't been bumped past this version.
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask, appropriateFor: nil,
                                         create: false) {
            let oldKC = appSupport.appendingPathComponent("Glimmer/identity.keychain")
            if fm.fileExists(atPath: oldKC.path) {
                try? fm.removeItem(at: oldKC)
                log.info("Removed legacy file-based identity keychain")
            }
        }
        defaults.removeObject(forKey: "glimmer.identityKeychainPassphrase")

        defaults.set(Self.currentCleanupVersion, forKey: Self.cleanupVersionKey)
    }

    /// AES key derived from the pairing PIN. The host computes the same value
    /// from the PIN the user types into Sunshine/GFE; both sides then use it
    /// to AES-128-ECB encrypt the challenge round-trip that proves the PIN
    /// matches. First 16 bytes of SHA-256(salt || pin-as-utf8).
    public func aesKey(forPIN pin: String, salt: Data) throws -> Data {
        let pinBytes = Data(pin.utf8)
        var input = Data(capacity: salt.count + pinBytes.count)
        input.append(salt)
        input.append(pinBytes)

        var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
        let ok = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return digest.withUnsafeMutableBufferPointer { out in
                // EVP_Q_digest is cleaner than SHA256_*, lives in libcrypto 3.x.
                EVP_Q_digest(nil,
                             "SHA256", nil,
                             base, input.count,
                             out.baseAddress, nil)
            }
        }
        guard ok == 1 else {
            throw StreamError.crypto("SHA-256 of salted PIN failed")
        }

        // AES-128 - first 16 bytes only. The remaining bytes of the digest are
        // discarded (this matches GFE/Sunshine behaviour, not a quirk on our end).
        return Data(digest.prefix(16))
    }

    // MARK: Loading
    //
    // Source-of-truth precedence on every cold launch:
    //
    //   1. File store - the canonical home post-migration. Fast path: three
    //      mode-0600 PEM files, read with no keychain involvement and no
    //      Security.framework prompts.
    //
    //   2. Legacy keychain items (io.ugfugl.Glimmer.identity service,
    //      generic-password) from the keychain-era build. If present we read them out
    //      ONCE (accepting any prompt the user gets at this moment), copy
    //      them into the file store, and SecItemDelete the keychain
    //      originals. After this one-shot, the prompt never returns.
    //
    //   3. UserDefaults plaintext PEMs from the original plaintext build.
    //      If we still have this old shape, copy it into the file store and
    //      wipe the UserDefaults copy.
    //
    //   4. moonlight-qt UserDefaults (cross-app migration). QSettings
    //      stores cert/key as Data, NOT String, hence the explicit
    //      Data → String dance. Source plist is left untouched (we don't
    //      own it).
    //
    //   5. Generate fresh.
    //
    // After any non-file-store source, the result lands in the file store and
    // `glimmer.identityFileStorageVersion` is set so subsequent launches
    // go straight to step 1. The migration is idempotent - re-running it on
    // an already-migrated install hits step 1 and returns.

    /// Versioned flag - once set to `fileStorageVersion`, future launches
    /// load identity directly from the file store and skip all migration
    /// branches. Bump if the on-disk shape ever changes incompatibly.
    static let fileStorageFlag = "glimmer.identityFileStorageVersion"
    static let fileStorageVersion = 1

    /// Pre-existing flag (set by the keychain-era build) that says "we already migrated
    /// out of UserDefaults; the live copy is in the keychain". Honoured here
    /// as a signal that the legacy-keychain migration branch should run on
    /// the next launch and that the original-UserDefaults path won't have
    /// anything for us. Once we've successfully copied to the file store,
    /// `fileStorageFlag` supersedes it.
    static let legacyKeychainOnlyFlag = "glimmer.identityKeychainOnly"

    /// Service string the prior build used for the three generic-password
    /// keychain items. We only ever read from this now - never write back.
    static let legacyKeychainService = "io.ugfugl.Glimmer.identity"
    static let accountCert = "client-cert-pem"
    static let accountKey  = "client-key-pem"
    static let accountUID  = "client-unique-id"
}
