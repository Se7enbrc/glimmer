// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// File-backed identities avoid keychain prompts; see docs/SECURITY.md for the same-user threat model.

import Foundation
import Darwin
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
        try write(data, to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let permissions = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        guard permissions?.uint16Value == 0o700 else {
            throw StreamError.crypto("Could not protect client identity permissions")
        }
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

    /// Serialize recovery and publication across managers and processes; a crash releases the lock.
    package static func withExclusiveAccess<T>(base: URL, _ body: () throws -> T) throws -> T {
        let parent = try directoryURL(base: base).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(parent.appendingPathComponent(".identity-lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Only this reserved staging directory can contain an interrupted, unpublished identity.
    package static func discardStaging(base: URL) throws {
        let staging = try directoryURL(base: base).deletingLastPathComponent()
            .appendingPathComponent(".identity-staging", isDirectory: true)
        do { try FileManager.default.removeItem(at: staging) } catch CocoaError.fileNoSuchFile { return }
    }

    /// Unknown files count as established material, even when all expected components are absent.
    package static func hasStoredFiles(base: URL) throws -> Bool {
        do {
            return try !FileManager.default.contentsOfDirectory(atPath: directoryURL(base: base).path).isEmpty
        } catch CocoaError.fileReadNoSuchFile { return false }
    }

    /// The caller holds the publication lock; the exclusive rename cannot replace an established store.
    package static func publish(_ identity: IdentityManager.Identity, base: URL,
                                didStageKey: () throws -> Void = {}) throws {
        let destination = try directoryURL(base: base)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".identity-staging", isDirectory: true)
        // rmdir atomically refuses every nonempty directory, including unexpected files.
        if rmdir(destination.path) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard mkdir(staging.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Clean only this publication's staging; a crash leftover is handled by the next locked load.
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(Data(identity.certPEM.utf8), to: staging.appendingPathComponent(certFileName))
        try write(Data(identity.keyPEM.utf8), to: staging.appendingPathComponent(keyFileName))
        try didStageKey()
        try write(Data(identity.uniqueID.utf8), to: staging.appendingPathComponent(uidFileName))
        let cert = try String(contentsOf: staging.appendingPathComponent(certFileName), encoding: .utf8)
        let key = try String(contentsOf: staging.appendingPathComponent(keyFileName), encoding: .utf8)
        _ = try PEM.identity(certPEM: cert, keyPEM: key)
        guard try Data(contentsOf: staging.appendingPathComponent(uidFileName)) == Data(identity.uniqueID.utf8),
              !identity.uniqueID.isEmpty else { throw IdentityStorageError.incompleteIdentity }
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
    case incompleteIdentity
    case invalidIdentity
}
