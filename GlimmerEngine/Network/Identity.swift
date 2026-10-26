// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// File-backed identities avoid keychain prompts; see docs/SECURITY.md for the same-user threat model.

import Foundation
import os.log
import Security

// MARK: - Storage keys

// Keep the Moonlight QSettings keys unchanged so existing identities survive migration.
package enum IdentityKey {
    package static let uniqueID    = "uniqueid"
    package static let certificate = "certificate"
    package static let privateKey  = "key"
}

// MARK: - FileIdentityStore

// Atomic owner-only files; verify permissions because FUSE/NFS may silently ignore chmod.

package enum FileIdentityStore {

    /// Filename for the X.509 certificate (PEM, full --BEGIN CERTIFICATE-- block).
    package static let certFileName = "client-cert.pem"

    /// Filename for the RSA private key (PEM, PKCS#8 unencrypted).
    package static let keyFileName = "client-key.pem"

    /// Filename for the 32-hex-char client unique ID (raw ASCII, no newline).
    package static let uidFileName = "client-uniqueid.txt"

    /// Account-name → filename mapping. Keeping the `account:` API on the
    /// store mirrors how the old keychain backend was addressed, so the
    /// call sites at the top of `load()` stay readable.
    package static func filename(forAccount account: String) -> String? {
        switch account {
        case IdentityManager.accountCert: return certFileName
        case IdentityManager.accountKey:  return keyFileName
        case IdentityManager.accountUID:  return uidFileName
        default: return nil
        }
    }

    /// The shell supplies the base; identities live under `Glimmer/Identity` within it.
    /// Created on first write with mode 0700.
    package static func directoryURL(base: URL) throws -> URL {
        PersistentStorage.checked(base).appendingPathComponent("Glimmer/Identity", isDirectory: true)
    }

    package static func fileURL(account: String, base: URL) throws -> URL? {
        guard let name = filename(forAccount: account) else { return nil }
        return try directoryURL(base: base).appendingPathComponent(name, isDirectory: false)
    }

    /// Returns the bytes if the file exists, nil if it's absent. Anything
    /// else (permission denied, IO error mid-read) throws so we don't
    /// silently fall through to a destructive "regenerate".
    package static func read(account: String, base: URL) throws -> Data? {
        guard let url = try fileURL(account: account, base: base) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// Atomic mode-0600 writes under a mode-0700 directory. Verify permissions because some
    /// filesystems ignore chmod; delete and throw rather than retain an exposed partial identity.
    package static func write(_ data: Data, account: String, base: URL) throws {
        guard let url = try fileURL(account: account, base: base) else {
            throw StreamError.crypto("FileIdentityStore: unknown account \(account)")
        }

        if let existing = try read(account: account, base: base) {
            guard existing == data else { throw IdentityStorageError.alreadyExists }
            return
        }
        let fm = FileManager.default
        let dir = try directoryURL(base: base)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let temporary = dir.appendingPathComponent("." + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let attrs = try fm.attributesOfItem(atPath: temporary.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber, mode.uint16Value & 0o777 == 0o600 else {
            throw StreamError.crypto("Could not protect client identity permissions")
        }
        // A hard link publishes complete, protected bytes and atomically refuses an existing destination.
        try fm.linkItem(at: temporary, to: url)
    }

    /// Idempotent unlink. Used by cleanup / future migrations.
    package static func delete(account: String, base: URL) {
        guard let url = try? fileURL(account: account, base: base) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - IdentityManager

public actor IdentityManager {

    /// A failed named suite stays unavailable; never borrow another domain's identity.
    let defaults: UserDefaults?
    let storageRoot: @Sendable () throws -> URL
    let protectedDataAvailable: @Sendable () -> Bool
    let migrateIdentity: @Sendable (String?) throws -> AdoptedQtIdentity?

    /// Cached, fully-materialized identity. Built lazily on first access; once
    /// in memory we never touch disk again for the life of the actor.
    package struct Identity {
        let uniqueID: String   // 32-hex-char GUID
        let certPEM: String    // PEM-encoded X.509 certificate
        let keyPEM: String    // PEM-encoded RSA private key (PKCS#8)
    }

    var cached: Identity?

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Identity")

    public init(defaultsSuite: String?, supportBase: URL,
                protectedDataAvailable: @escaping @Sendable () -> Bool) {
        self.init(defaultsSuite: defaultsSuite, storageRoot: { supportBase },
                  protectedDataAvailable: protectedDataAvailable, migrateIdentity: { _ in nil })
    }

    package init(defaultsSuite: String?, storageRoot: @escaping @Sendable () throws -> URL,
                 protectedDataAvailable: @escaping @Sendable () -> Bool = { true },
                 migrateIdentity: @escaping @Sendable (String?) throws -> AdoptedQtIdentity?,
                 makeDefaults: @Sendable (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) {
        if let defaultsSuite {
            self.defaults = makeDefaults(defaultsSuite)
        } else {
            self.defaults = PersistentStorage.defaults
        }
        self.storageRoot = storageRoot
        self.protectedDataAvailable = protectedDataAvailable
        self.migrateIdentity = migrateIdentity
    }

    // MARK: Public surface

    package func clientCertPEM() throws -> String {
        try load().certPEM
    }

    package func clientKeyPEM() throws -> String {
        try load().keyPEM
    }

    public func uniqueID() throws -> String {
        try load().uniqueID
    }

    /// Both peers use SHA-256(salt || PIN)[0..<16] for the raw AES-128-ECB challenge.
    package nonisolated static func aesKey(forPIN pin: String, salt: Data) -> Data {
        let pinBytes = Data(pin.utf8)
        var input = Data(capacity: salt.count + pinBytes.count)
        input.append(salt)
        input.append(pinBytes)

        // AES-128 - first 16 bytes only. The remaining bytes of the digest are
        // discarded (this matches GFE/Sunshine behaviour, not a quirk on our end).
        return PairingClient.digest(input).prefix(16)
    }

    // MARK: Loading

    // Prefer files, then legacy defaults, then shell-supplied migration, then fresh generation.
    // Never read or delete keychain items. Only successful file writes advance the migration flag.

    /// Versioned flag - once set to `fileStorageVersion`, future launches
    /// load identity directly from the file store and skip all migration
    /// branches. Bump if the on-disk shape ever changes incompatibly.
    package static let fileStorageFlag = "glimmer.identityFileStorageVersion"
    package static let fileStorageVersion = 1

    /// The keychain-era build already wiped its plaintext defaults. Keep its flag unchanged;
    /// no keychain access occurs, and a successful file write supersedes this marker.
    package static let legacyKeychainOnlyFlag = "glimmer.identityKeychainOnly"

    package static let accountCert = "client-cert-pem"
    package static let accountKey  = "client-key-pem"
    package static let accountUID  = "client-unique-id"
}

public enum IdentityStorageError: Error, Sendable {
    case unavailable
    case defaultsUnavailable
    case alreadyExists
}
