//
//  Identity.swift
//
//  Client-side identity for the streaming engine: a stable unique ID plus an
//  RSA-2048 keypair under a self-signed X.509 certificate (CN = "NVIDIA
//  GameStream Client", 20-year validity). These three pieces of state are what
//  the host uses to recognize us - both during the pairing handshake and on
//  every subsequent TLS connection. They're generated once on first launch and
//  persisted to mode-0600 files under ~/Library/Application Support/Glimmer/
//  Identity/ so a process running as our UID can re-load them silently across
//  rebuilds without any Security.framework prompt.
//
//  Ported (loosely now) from moonlight-qt's app/backend/identitymanager.{h,cpp}.
//
//
// STORAGE DECISION: mode-0600 files under Application Support, deliberately.
// We evaluated moving to the keychain once builds went Developer-ID signed,
// and chose to stay on files:
//
//   * The data-protection keychain (the clean per-app store) is gated behind a
//     `keychain-access-groups` entitlement, which on a Developer-ID Mac app
//     (no provisioning profile) makes AMFI refuse to LAUNCH the process
//     (RBSRequestErrorDomain Code=5 / POSIX 163). It needs an embedded
//     provisioning profile to work at all - not worth that machinery here.
//
//   * The login keychain works without a profile, and a stable Developer-ID
//     signature fixes the adhoc CDHash-ACL re-prompt that drove us off it
//     before - but it only buys encryption-at-rest for a narrow gain on a LAN
//     streaming identity, and the project already tried it once and retreated.
//
//   * The reference (moonlight-qt) stores PLAINTEXT PEM in a mode-0644
//     QSettings plist under ~/Library/Preferences - no keychain at all. Our
//     mode-0600 files are already stricter: 0600 keeps every other user out
//     (0600 > 0644).
//
// So: files. See SECURITY.md for the user-facing version.
//
//
// THREAT MODEL:
//
// The long-lived RSA-2048 private key authenticates Glimmer to every paired
// host indefinitely. If it leaks, the attacker is a permanent imposter against
// every host this install paired with - until the user unpairs each one.
//
// The mode-0600 files keep every other user on the Mac out. Unsandboxed, there's
// no container boundary, so a same-UID process isn't blocked by macOS - the 0600
// perms are the boundary (still stricter than moonlight-qt's 0644 plist). A
// TCC-allowlisted app with Full Disk Access can still read them - an OS-level
// boundary, not a Glimmer-specific defence.
//

import Foundation
import os.log
import Security

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

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Identity")

    private init() {}

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

    /// Bootstrap step - call this early (from MoonlightManager.bootstrap()) so
    /// the identity setup happens during launch, not on the user's first
    /// stream click. Idempotent.
    public func preflight() async {
        cleanupOrphanLoginKeychainEntries()
        // Remove the now-orphaned "Glimmer Client Identity" item that pre-OpenSSL
        // builds imported into the login keychain - the control channel no longer
        // uses a SecIdentity, so nothing of ours should linger there.
        deleteLabelledIdentity()
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
