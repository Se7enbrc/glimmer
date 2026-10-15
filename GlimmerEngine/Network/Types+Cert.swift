// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import CommonCrypto
import CryptoKit
import Darwin

// MARK: - Cert fingerprint helper

// Match Sunshine's lowercase, colon-separated SHA-256 DER fingerprint for visual comparison.

public enum CertFingerprint {
    /// `ab:cd:ef:01:23:...` SHA-256 fingerprint of the cert PEM. Returns
    /// nil if the PEM can't be parsed. Public so the re-pair UI in
    /// SettingsView can render OLD-vs-NEW comparison.
    public static func sha256(forPEM pem: String) -> String? {
        guard let der = derFromPEM(pem) else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func derFromPEM(_ pem: String) -> Data? {
        let marker = "CERTIFICATE"
        let begin = "-----BEGIN \(marker)-----"
        let end   = "-----END \(marker)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            return nil
        }
        let body = pem[beginRange.upperBound..<endRange.lowerBound]
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: body)
    }
}

// MARK: - Pinned cert storage key

// Every read, write and deletion uses the PC's /serverinfo uniqueid. Mixing a hostname with
// a migrated UUID loses the pin and breaks authentication across restarts.
public enum PinnedCertStore {
    /// The shell supplies its storage and availability policy. An unreadable pin must never look unpaired.
    public static func load(forHostID hostID: String, defaults: UserDefaults, base: URL,
                            protectedDataAvailable: () -> Bool) throws -> String? {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        do {
            let data = try Data(contentsOf: fileURL(for: hostID, base: base))
            guard let pem = String(data: data, encoding: .utf8), !pem.isEmpty else {
                throw StreamError.crypto("The saved PC certificate is unreadable")
            }
            return pem
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try loadAvailable(forHostID: hostID, defaults: defaults, base: base,
                                     protectedDataAvailable: protectedDataAvailable)
        }
    }

    /// Store only the certificate returned by authenticated pairing, under the verified PC identity.
    public static func store(pem: String, forHostID hostID: String, defaults: UserDefaults, base: URL,
                             protectedDataAvailable: () -> Bool) throws {
        try storeAvailable(pem: pem, forHostID: hostID, defaults: defaults, base: base,
                           protectedDataAvailable: protectedDataAvailable)
    }

    /// Report deletion failures so the shell cannot claim a PC was forgotten while its pin survives.
    public static func delete(forHostID hostID: String, defaults: UserDefaults, base: URL,
                              protectedDataAvailable: () -> Bool) throws {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        do {
            try FileManager.default.removeItem(at: fileURL(for: hostID, base: base))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Removing an already absent pin is idempotent.
        }
        defaults.removeObject(forKey: legacyDefaultsKey(for: hostID))
    }

    /// Legacy UserDefaults key, kept only for the read-side migration
    /// (`load(forHostID:)`) which lifts the value out then deletes it.
    /// Nothing writes here anymore - see the file-backed store below.
    fileprivate static func legacyDefaultsKey(for hostID: String) -> String {
        "glimmer.pinnedCert.\(hostID)"
    }

    /// Backward-compat alias used by a couple of HostsStore call sites.
    /// New code should not need this - the file-backed `load/store/delete`
    /// methods are the API.
    package static func key(for hostID: String) -> String {
        legacyDefaultsKey(for: hostID)
    }

    // Owner-only atomic files narrow the writable defaults surface; same-UID compromise remains possible.
    // Migrate defaults forward only after a verified write, leaving legacy data intact on failure.

    /// Prefer the file pin, then migrate legacy defaults after a successful file write.
    package static func loadAvailable(forHostID hostID: String, defaults: UserDefaults,
                                      base: URL, protectedDataAvailable: () -> Bool = { true }) throws -> String? {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        // 1. File store.
        if let url = try? fileURL(for: hostID, base: base),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let pem = String(data: data, encoding: .utf8),
           !pem.isEmpty {
            return pem
        }
        // 2. Legacy UserDefaults - read then migrate.
        let legacyKey = legacyDefaultsKey(for: hostID)
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            do {
                try writePEM(legacy, forHostID: hostID, base: base)
                defaults.removeObject(forKey: legacyKey)
                defaults.synchronize()
                return legacy
            } catch {
                // Retain the legacy pin on write failure so this connection authenticates and migration can retry.
                return legacy
            }
        }
        return nil
    }

    /// Persist a pinned cert PEM for the given host. Atomic 0600 write.
    /// Throws on any IO / permission failure.
    package static func storeAvailable(pem: String, forHostID hostID: String,
                                       defaults: UserDefaults, base: URL,
                                       protectedDataAvailable: () -> Bool = { true }) throws {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        try writePEM(pem, forHostID: hostID, base: base)
        // Belt-and-braces: nuke any legacy UserDefaults entry under the
        // same key. Idempotent.
        defaults.removeObject(forKey: legacyDefaultsKey(for: hostID))
    }

    /// Remove the pinned cert for a host. Wipes both stores so a stale
    /// UserDefaults entry can't resurrect a wiped pin.
    package static func deleteAvailable(forHostID hostID: String, defaults: UserDefaults,
                                        base: URL, protectedDataAvailable: () -> Bool = { true }) throws {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        if let url = try? fileURL(for: hostID, base: base) {
            try? FileManager.default.removeItem(at: url)
        }
        defaults.removeObject(forKey: legacyDefaultsKey(for: hostID))
    }

    // MARK: File-store internals

    /// `~/Library/Application Support/Glimmer/PinnedHosts/`. Created at
    /// mode 0700 on first write.
    private static func directoryURL(base: URL) throws -> URL {
        base.appendingPathComponent("Glimmer/PinnedHosts", isDirectory: true)
    }

    /// Restrict filenames so an untrusted uniqueid cannot traverse out of the pin directory.
    private static func sanitized(_ hostID: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = hostID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitizedName = String(scalars)
        return sanitizedName.isEmpty ? "unnamed" : sanitizedName
    }

    private static func fileURL(for hostID: String, base: URL) throws -> URL {
        try directoryURL(base: base).appendingPathComponent("\(sanitized(hostID)).pem",
                                                   isDirectory: false)
    }

    /// Validate a temporary 0600 file before replacing a saved pin.
    /// A failed permission check must leave the old pin intact.
    package static func writePEM(_ pem: String, forHostID hostID: String, base: URL,
                                 verify: (URL) throws -> Void = verifyPermissions) throws {
        let fm = FileManager.default
        let dir = try directoryURL(base: base)
        try fm.createDirectory(at: dir,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let url = try fileURL(for: hostID, base: base)
        let prepared = dir.appendingPathComponent(".\(UUID().uuidString).pem")
        defer { try? fm.removeItem(at: prepared) }
        try Data(pem.utf8).write(to: prepared, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.path)
        try verify(prepared)
        guard rename(prepared.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func verifyPermissions(_ url: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            throw StreamError.crypto("PinnedCertStore: missing POSIX permissions for \(url.lastPathComponent)")
        }
        let permBits = mode.uint16Value & 0o777
        guard permBits == 0o600 else {
            let modeOctal = String(permBits, radix: 8)
            throw StreamError.crypto(
                "PinnedCertStore: refused to keep \(url.lastPathComponent) with mode \(modeOctal) (expected 600)")
        }
    }
}
