// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

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
// The pairing identity remains in mode-0600 files. Provisioning profiles now
// remove a historical keychain packaging obstacle; no identity migration is
// implied by that signing change. See docs/SECURITY.md for the threat model.
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

import GlimmerEngine
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

extension URL {
    /// `~/Library/Application Support`, or `base` when a caller supplies its own root.
    static func supportRoot(base: URL?) throws -> URL {
        if let base { return base }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    }
}

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
    static func directoryURL(base: URL? = nil) throws -> URL {
        try URL.supportRoot(base: base).appendingPathComponent("Glimmer/Identity", isDirectory: true)
    }

    static func fileURL(account: String, base: URL? = nil) throws -> URL? {
        guard let name = filename(forAccount: account) else { return nil }
        return try directoryURL(base: base).appendingPathComponent(name, isDirectory: false)
    }

    /// Returns the bytes if the file exists, nil if it's absent. Anything
    /// else (permission denied, IO error mid-read) throws so we don't
    /// silently fall through to a destructive "regenerate".
    static func read(account: String, base: URL? = nil) throws -> Data? {
        guard let url = try fileURL(account: account, base: base) else { return nil }
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
    static func write(_ data: Data, account: String, base: URL? = nil) throws {
        guard let url = try fileURL(account: account, base: base) else {
            throw StreamError.crypto("FileIdentityStore: unknown account \(account)")
        }

        let fm = FileManager.default
        let dir = try directoryURL(base: base)

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
    static func delete(account: String, base: URL? = nil) {
        guard let url = try? fileURL(account: account, base: base) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - IdentityManager

public actor IdentityManager {

    public static let shared = IdentityManager()

    /// Where this manager keeps its state; the defaults are the real locations.
    let defaults: UserDefaults
    let supportBase: URL?
    let moonlightQtSuite: String

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

    init(defaultsSuite: String? = nil, supportBase: URL? = nil,
         moonlightQtSuite: String = IdentityManager.moonlightQtSuiteName) {
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.supportBase = supportBase
        self.moonlightQtSuite = moonlightQtSuite
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

    /// AES key derived from the pairing PIN. The host computes the same value
    /// from the PIN the user types into Sunshine/GFE; both sides then use it
    /// to AES-128-ECB encrypt the challenge round-trip that proves the PIN
    /// matches. First 16 bytes of SHA-256(salt || pin-as-utf8).
    public func aesKey(forPIN pin: String, salt: Data) -> Data {
        let pinBytes = Data(pin.utf8)
        var input = Data(capacity: salt.count + pinBytes.count)
        input.append(salt)
        input.append(pinBytes)

        // AES-128 - first 16 bytes only. The remaining bytes of the digest are
        // discarded (this matches GFE/Sunshine behaviour, not a quirk on our end).
        return PairingClient.digest(input).prefix(16)
    }

    // MARK: Loading
    //
    // Source-of-truth precedence on every cold launch:
    //
    //   1. File store - the canonical home post-migration. Fast path: three
    //      mode-0600 PEM files, read with no keychain involvement and no
    //      Security.framework prompts.
    //
    //   2. (Removed) Glimmer never reads or deletes keychain items (#138); a
    //      pre-public build's leftovers stay where they are, unused.
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

    static let accountCert = "client-cert-pem"
    static let accountKey  = "client-key-pem"
    static let accountUID  = "client-unique-id"
}
