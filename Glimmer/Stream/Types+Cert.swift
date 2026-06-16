//
//  Types+Cert.swift
//
//  Server certificate fingerprinting and the canonical pinned-cert storage key
//  (+ PairStatus). Split out of Types.swift to keep each unit focused.
//

import Foundation
import CommonCrypto
import CryptoKit

// MARK: - Cert fingerprint helper
//
// SHA-256 of the DER-encoded cert, formatted as lowercase hex bytes
// separated by `:` — the same shape `ssh-keygen -E sha256 -lf` prints
// and the shape Sunshine's web UI surfaces to the user. Keeping the
// format identical means the user can copy-paste the fingerprint
// Sunshine shows next to the one Glimmer's UI shows and visually
// compare without translating between styles.

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

// MARK: - Pinned cert storage key (canonical form)
//
// Pinning is split across call sites — Pairing.swift writes the pin
// after a successful pair, MoonlightManager.nativeServerInfo /
// HostsStore.unpair / HostsStore.saveHost read or delete it.
// All MUST hash to the same UserDefaults key for the pin to actually
// authenticate a TLS handshake. The previous shape used `host.id` for
// reads (= the host UUID from moonlight-qt migration, or the hostname for
// fresh-Glimmer hosts) and `server.uniqueId` for writes (= the hostname
// before `/serverinfo`'s `<uniqueid>` element was parsed). For users with
// a real qt-migrated UUID, those two diverged — a freshly-paired host's
// pin would land under the hostname key while the lookup checked the
// UUID key. Result: every stream went through trust-on-first-use even
// though the user had a "paired" host record on disk.
//
// Canonical key: the host's `<uniqueid>` from `/serverinfo`. We now parse
// it in `NetworkClient.fetchServerInfo` and seed it onto ServerInfo, so
// `server.uniqueId` is the right value at pair time. The lookup side
// (`MoonlightManager.nativeServerInfo`) uses `host.id`, which for migrated
// hosts is the qt UUID — same value the host emits in `/serverinfo`. The
// fresh-pair fallback (no qt migration) is the hostname on both sides, so
// the keys still align.
public enum PinnedCertStore {
    /// Legacy UserDefaults key, kept only for the read-side migration
    /// (`load(forHostID:)`) which lifts the value out then deletes it.
    /// Nothing writes here anymore — see the file-backed store below.
    fileprivate static func legacyDefaultsKey(for hostID: String) -> String {
        "glimmer.pinnedCert.\(hostID)"
    }

    /// Backward-compat alias used by a couple of HostsStore call sites.
    /// New code should not need this — the file-backed `load/store/delete`
    /// methods are the API.
    public static func key(for hostID: String) -> String {
        legacyDefaultsKey(for: hostID)
    }

    // MARK: File-backed store (mode-0600 files under Application Support)
    //
    // UserDefaults backs onto a plain XML plist in
    // ~/Library/Preferences/ (sandbox-containered or not). Any same-UID
    // process can both read and *write* to it via cfprefsd — there is no
    // per-app ACL. For a pinned host cert the read leak is mostly
    // harmless (the cert is public anyway), but the write surface is the
    // problem: a same-UID attacker can swap the pin for their own,
    // making us trust a MITM host across restarts. Group #9 of the
    // security pass.
    //
    // New shape: one PEM file per host at
    //   <ApplicationSupport>/Glimmer/PinnedHosts/<sanitized-id>.pem
    // with mode 0600 (owner-only). Same enforcement pattern as
    // `FileIdentityStore` in Identity.swift — atomic write, stat(2)
    // verify, on-failure delete-and-throw. Inside the sandbox this lands
    // at <Container>/Library/Application Support/Glimmer/PinnedHosts/...
    // which is per-app private at the filesystem level.
    //
    // Migration: read-side hits the legacy UserDefaults key as a
    // fallback, copies forward to the file store, and deletes the
    // UserDefaults entry. This is one-way; old keys never get
    // re-written.

    /// Read the PEM for a paired host, in order:
    ///   1. The new file store
    ///   2. The legacy UserDefaults key (migrated forward + cleaned up)
    /// Returns nil if neither has it.
    public static func load(forHostID hostID: String) -> String? {
        // 1. File store.
        if let url = try? fileURL(for: hostID),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let pem = String(data: data, encoding: .utf8),
           !pem.isEmpty {
            return pem
        }
        // 2. Legacy UserDefaults — read then migrate.
        let defaults = UserDefaults.standard
        let legacyKey = legacyDefaultsKey(for: hostID)
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            do {
                try writePEM(legacy, forHostID: hostID)
                defaults.removeObject(forKey: legacyKey)
                defaults.synchronize()
                return legacy
            } catch {
                // Can't write the file — return the legacy value so the
                // current stream still authenticates; next launch will
                // try again. We deliberately do NOT delete the legacy
                // entry on write failure.
                return legacy
            }
        }
        return nil
    }

    /// Persist a pinned cert PEM for the given host. Atomic 0600 write.
    /// Throws on any IO / permission failure.
    public static func store(pem: String, forHostID hostID: String) throws {
        try writePEM(pem, forHostID: hostID)
        // Belt-and-braces: nuke any legacy UserDefaults entry under the
        // same key. Idempotent.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey(for: hostID))
    }

    /// Remove the pinned cert for a host. Wipes both stores so a stale
    /// UserDefaults entry can't resurrect a wiped pin.
    public static func delete(forHostID hostID: String) {
        if let url = try? fileURL(for: hostID) {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey(for: hostID))
    }

    // MARK: File-store internals

    /// `~/Library/Application Support/Glimmer/PinnedHosts/`. Created at
    /// mode 0700 on first write. Inside the sandbox this resolves to
    /// the container's Application Support path.
    private static func directoryURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        return base.appendingPathComponent("Glimmer/PinnedHosts", isDirectory: true)
    }

    /// Restrict host-id characters in the filename to a known-safe set
    /// so an attacker can't path-traverse via a doctored uniqueid
    /// (e.g. "../../identity/client-key.pem"). The UUIDs we expect are
    /// hex + dashes, but `host.id` falls back to the hostname which
    /// can in principle contain anything; tightening the set defensively.
    private static func sanitized(_ hostID: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = hostID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitizedName = String(scalars)
        return sanitizedName.isEmpty ? "unnamed" : sanitizedName
    }

    private static func fileURL(for hostID: String) throws -> URL {
        try directoryURL().appendingPathComponent("\(sanitized(hostID)).pem",
                                                   isDirectory: false)
    }

    /// Atomic-write a PEM at mode 0600, verify the bits via stat(2),
    /// remove partial on failure. Mirrors `FileIdentityStore.write`.
    private static func writePEM(_ pem: String, forHostID hostID: String) throws {
        let fm = FileManager.default
        let dir = try directoryURL()
        try fm.createDirectory(at: dir,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let url = try fileURL(for: hostID)
        try Data(pem.utf8).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            try? fm.removeItem(at: url)
            throw StreamError.crypto("PinnedCertStore: missing POSIX permissions for \(url.lastPathComponent)")
        }
        let permBits = mode.uint16Value & 0o777
        guard permBits == 0o600 else {
            try? fm.removeItem(at: url)
            let modeOctal = String(permBits, radix: 8)
            throw StreamError.crypto(
                "PinnedCertStore: refused to keep \(url.lastPathComponent) with mode \(modeOctal) (expected 600)")
        }
    }
}

public enum PairStatus: Sendable, Equatable {
    case paired
    case unpaired
}
