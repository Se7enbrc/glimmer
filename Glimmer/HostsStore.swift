//
//  HostsStore.swift
//
//  Host persistence: UserDefaults-backed read/write of the paired-host list,
//  one-shot migration from moonlight-qt's UserDefaults domain, and the
//  unpair/retrust paths. The pinned-cert storage now lives in
//  `PinnedCertStore` (file-backed); the legacy `glimmer.pinnedCert.<uniqueId>`
//  UserDefaults key is read-only there for one-shot migration.
//

import Foundation
import os.log

extension MoonlightManager {

    // MARK: - Migration from moonlight-qt

    /// One-shot migration from moonlight-qt's UserDefaults domain. Reads the
    /// hosts list, server certs, and last-played dates a user may already
    /// have from a prior moonlight-qt install and copies them into Glimmer's
    /// own state. Subsequent launches read directly from Glimmer's
    /// UserDefaults.
    ///
    /// The moonlight-qt install does not have to be present - we're just
    /// reading a plist that may or may not exist. Safe to call on every
    /// launch; the flag short-circuits after the first successful pass.
    func migrateFromMoonlightQtIfNeeded() {
        let flagKey = "glimmer.hostsMigratedFromMoonlightQt"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        guard let mq = UserDefaults(suiteName: "com.moonlight-stream.Moonlight") else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }
        let count = mq.integer(forKey: "hosts.size")
        guard count > 0 else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(count, forKey: "hosts.size")
        for i in 1...count {
            func copy(_ key: String) {
                if let str = mq.string(forKey: "hosts.\(i).\(key)") {
                    defaults.set(str, forKey: "hosts.\(i).\(key)")
                } else if let data = mq.data(forKey: "hosts.\(i).\(key)") {
                    defaults.set(data, forKey: "hosts.\(i).\(key)")
                }
            }
            copy("hostname"); copy("uuid"); copy("name")
            copy("localaddress"); copy("manualaddress")
            copy("srvcert"); copy("appversion"); copy("gfeversion")
            if mq.object(forKey: "hosts.\(i).customname") != nil {
                defaults.set(mq.bool(forKey: "hosts.\(i).customname"),
                             forKey: "hosts.\(i).customname")
            }
            let appsCount = mq.integer(forKey: "hosts.\(i).apps.size")
            defaults.set(appsCount, forKey: "hosts.\(i).apps.size")
            if appsCount > 0 {
                for j in 1...appsCount {
                    func capp(_ key: String) {
                        if let str = mq.string(forKey: "hosts.\(i).apps.\(j).\(key)") {
                            defaults.set(str, forKey: "hosts.\(i).apps.\(j).\(key)")
                        }
                    }
                    capp("name")
                    defaults.set(mq.integer(forKey: "hosts.\(i).apps.\(j).id"),
                                 forKey: "hosts.\(i).apps.\(j).id")
                    defaults.set(mq.bool(forKey: "hosts.\(i).apps.\(j).hdr"),
                                 forKey: "hosts.\(i).apps.\(j).hdr")
                    defaults.set(mq.bool(forKey: "hosts.\(i).apps.\(j).hidden"),
                                 forKey: "hosts.\(i).apps.\(j).hidden")
                }
            }
        }
        defaults.set(true, forKey: flagKey)
        Logger(subsystem: "io.ugfugl.Glimmer", category: "HostsStore")
            .info("Migrated \(count, privacy: .public) paired hosts from moonlight-qt UserDefaults")
    }

    // MARK: - Load / select

    /// Rebuild `hosts` from UserDefaults. Public because Settings → PCs calls
    /// it after the user manually edits the list.
    func loadHosts() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "hosts.size")
        guard count > 0 else {
            hosts = []
            selectedHost = nil
            return
        }

        var loaded: [MoonlightHost] = []
        for i in 1...count {
            let hostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
            let appsCount = defaults.integer(forKey: "hosts.\(i).apps.size")
            guard appsCount > 0, !hostname.isEmpty else { continue }

            let uuid = defaults.string(forKey: "hosts.\(i).uuid") ?? hostname
            let hasCustom = defaults.bool(forKey: "hosts.\(i).customname")
            let customName = hasCustom ? defaults.string(forKey: "hosts.\(i).name") : nil
            let local = defaults.string(forKey: "hosts.\(i).localaddress")
            let manual = defaults.string(forKey: "hosts.\(i).manualaddress")

            var apps: [MoonlightApp] = []
            for j in 1...appsCount {
                let appName = defaults.string(forKey: "hosts.\(i).apps.\(j).name") ?? "Untitled"
                let appId = defaults.integer(forKey: "hosts.\(i).apps.\(j).id")
                let hdr = defaults.bool(forKey: "hosts.\(i).apps.\(j).hdr")
                let hidden = defaults.bool(forKey: "hosts.\(i).apps.\(j).hidden")
                if hidden { continue }
                apps.append(MoonlightApp(id: appId, name: appName, hdr: hdr, hidden: hidden))
            }

            let lastKey = "glimmer.lastConnected.\(uuid)"
            let last = defaults.object(forKey: lastKey) as? Date

            // Server cert (PEM) + version strings. moonlight-qt persisted these
            // via QSettings, which serializes strings as Data on macOS. Read
            // both formats so the value survives migration.
            func readPEM(_ key: String) -> String? {
                if let str = defaults.string(forKey: key), !str.isEmpty { return str }
                if let data = defaults.data(forKey: key),
                   let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    return str
                }
                return nil
            }
            let srvCert = readPEM("hosts.\(i).srvcert")
            let appVer  = readPEM("hosts.\(i).appversion")
            let gfeVer  = readPEM("hosts.\(i).gfeversion")

            loaded.append(MoonlightHost(
                id: uuid,
                name: hostname,
                customName: customName,
                localAddress: local,
                manualAddress: manual,
                apps: apps,
                lastConnected: last,
                serverCertPEM: srvCert,
                appVersion: appVer,
                gfeVersion: gfeVer,
                // Future: moonlight-qt doesn't persist host MAC; populate
                // from /serverinfo's `<mac>` field when we wire that up.
                macAddress: nil
            ))
        }

        hosts = loaded.sorted(by: { (a, b) in
            (a.lastConnected ?? .distantPast) > (b.lastConnected ?? .distantPast)
        })

        if let lastID = UserDefaults.standard.string(forKey: "glimmer.selectedHostID"),
           let match = hosts.first(where: { $0.id == lastID }) {
            selectedHost = match
        } else {
            selectedHost = hosts.first
        }
    }

    /// Set (or clear) a user-facing custom name for a host. Persists into the
    /// same `hosts.N.name` + `hosts.N.customname` keys that `loadHosts` reads,
    /// matching the moonlight-qt schema. An empty/whitespace name clears the
    /// override (the tile falls back to the real hostname). Keyed by UUID like
    /// `unpair`, since hostname can differ from displayName for renamed hosts.
    func renameHost(_ host: MoonlightHost, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "hosts.size")
        guard count > 0 else { return }
        var matchIndex: Int?
        for i in 1...count {
            let uuid = defaults.string(forKey: "hosts.\(i).uuid") ?? ""
            let hostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
            if uuid == host.id || (uuid.isEmpty && hostname == host.id) {
                matchIndex = i
                break
            }
        }
        guard let idx = matchIndex else {
            Logger(subsystem: "io.ugfugl.Glimmer", category: "HostsStore")
                .info("rename: no slot matched id=\(host.id, privacy: .public)")
            return
        }
        let prefix = "hosts.\(idx)"
        if trimmed.isEmpty {
            // Clear the override → tile shows the real hostname again.
            defaults.set(false, forKey: "\(prefix).customname")
            defaults.removeObject(forKey: "\(prefix).name")
        } else {
            defaults.set(true, forKey: "\(prefix).customname")
            defaults.set(trimmed, forKey: "\(prefix).name")
        }
        loadHosts()
    }

    /// Persist a freshly-paired host into the `hosts.N.*` UserDefaults schema
    /// that `loadHosts` reads. Without this a successful pair pinned the cert
    /// but never saved the host record, so the PC vanished on the next
    /// `loadHosts()`. Reuses the existing slot when the uuid is already known
    /// (re-pair), otherwise appends a new slot. `apps` come from /applist.
    func saveHost(uuid: String, hostname: String, address: String,
                  serverCertPEM: String?, appVersion: String?, gfeVersion: String?,
                  apps: [PairedApp]) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "hosts.size")

        // Find an existing slot for this uuid; else the first empty slot; else append.
        var slot = 0
        var firstEmpty = 0
        if count > 0 {
            for i in 1...count {
                let slotUUID = defaults.string(forKey: "hosts.\(i).uuid") ?? ""
                let slotHostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
                if slotUUID == uuid { slot = i; break }
                if firstEmpty == 0, slotUUID.isEmpty, slotHostname.isEmpty { firstEmpty = i }
            }
        }
        if slot == 0 { slot = firstEmpty }
        if slot == 0 { slot = count + 1; defaults.set(slot, forKey: "hosts.size") }

        let prefix = "hosts.\(slot)"
        defaults.set(hostname, forKey: "\(prefix).hostname")
        defaults.set(uuid, forKey: "\(prefix).uuid")
        defaults.set(address, forKey: "\(prefix).localaddress")
        defaults.set(address, forKey: "\(prefix).manualaddress")
        if let pem = serverCertPEM { defaults.set(pem, forKey: "\(prefix).srvcert") }
        if let appVersion { defaults.set(appVersion, forKey: "\(prefix).appversion") }
        if let gfeVersion { defaults.set(gfeVersion, forKey: "\(prefix).gfeversion") }
        // Don't clobber a user's custom name on re-pair.
        if defaults.object(forKey: "\(prefix).customname") == nil {
            defaults.set(false, forKey: "\(prefix).customname")
        }

        // Apps: write fresh, clearing any stale higher-index entries.
        let oldApps = defaults.integer(forKey: "\(prefix).apps.size")
        if oldApps > apps.count {
            for j in (apps.count + 1)...oldApps {
                for sub in ["name", "id", "hdr", "hidden"] {
                    defaults.removeObject(forKey: "\(prefix).apps.\(j).\(sub)")
                }
            }
        }
        defaults.set(apps.count, forKey: "\(prefix).apps.size")
        for (k, app) in apps.enumerated() {
            let j = k + 1
            defaults.set(app.name, forKey: "\(prefix).apps.\(j).name")
            defaults.set(app.id, forKey: "\(prefix).apps.\(j).id")
            defaults.set(app.hdr, forKey: "\(prefix).apps.\(j).hdr")
            defaults.set(app.hidden, forKey: "\(prefix).apps.\(j).hidden")
        }

        // Pin the cert under the canonical uuid key too (belt-and-braces; the
        // pairing flow already file-store-pins, but keep them in lockstep).
        if let pem = serverCertPEM { try? PinnedCertStore.store(pem: pem, forHostID: uuid) }

        loadHosts()
    }

    func selectHost(_ host: MoonlightHost) {
        selectedHost = host
        UserDefaults.standard.set(host.id, forKey: "glimmer.selectedHostID")
        // Wipe the cached chip status so the UI doesn't briefly show the
        // previous host's "Streaming X" tag during the first poll for the
        // newly-selected machine. Then kick a fresh poll.
        hostLiveStatus = nil
        // Clear any stale stream error so a prior host's red banner doesn't linger
        // and name the wrong machine after switching hosts.
        nativeStreamError = nil
        restartHostStatusPolling()
    }

    // MARK: - Unpair / cert recovery

    /// Drop a paired host from local storage. This is the user-visible
    /// inverse of `pair(hostnameOrIP:pin:)` - we wipe the UserDefaults
    /// entries that `loadHosts` reads, plus any pinned cert keyed by
    /// uniqueId, plus the per-host last-connected timestamp. We do NOT call
    /// the host's `/unpair` endpoint here: the host treats our client cert
    /// as the pairing token, so dropping it on our side is enough for our
    /// purposes. If the host still lists us, the user can clear that from
    /// the host's own UI; a stale entry there is harmless without our key.
    /// Forget a host and leave the client in a fully clean state for it.
    /// Deliberately idempotent / bulletproof: every cleanup keyed by the host
    /// id runs UNCONDITIONALLY (pinned cert, last-connected, selection), and we
    /// wipe ALL matching UserDefaults slots, not just the first - so a partial,
    /// duplicated, or corrupt record (e.g. left over from the namespace
    /// migration) still ends up gone. Safe to call repeatedly; a no-op once the
    /// host is already clean.
    func unpair(_ host: MoonlightHost) {
        let defaults = UserDefaults.standard

        // --- Unconditional, id-keyed cleanup (runs even if no slot matches) ---
        // File-store + legacy UserDefaults pinned cert.
        PinnedCertStore.delete(forHostID: host.id)
        defaults.removeObject(forKey: "glimmer.lastConnected.\(host.id)")
        HostCodecPreference.forget(hostID: host.id)
        if defaults.string(forKey: "glimmer.selectedHostID") == host.id {
            defaults.removeObject(forKey: "glimmer.selectedHostID")
        }

        // --- Wipe every matching host slot ---
        let count = defaults.integer(forKey: "hosts.size")
        if count > 0 {
            for i in 1...count {
                let uuid = defaults.string(forKey: "hosts.\(i).uuid") ?? ""
                let hostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
                // Match by UUID; fall back to hostname for pre-UUID migrations.
                guard uuid == host.id || (uuid.isEmpty && hostname == host.id) else { continue }
                let prefix = "hosts.\(i)"
                let appsCount = defaults.integer(forKey: "\(prefix).apps.size")
                if appsCount > 0 {
                    for j in 1...appsCount {
                        for sub in ["name", "id", "hdr", "hidden"] {
                            defaults.removeObject(forKey: "\(prefix).apps.\(j).\(sub)")
                        }
                    }
                }
                for key in ["hostname", "uuid", "name", "customname",
                            "localaddress", "manualaddress",
                            "srvcert", "appversion", "gfeversion", "apps.size"] {
                    defaults.removeObject(forKey: "\(prefix).\(key)")
                }
                // Leave the hole; `loadHosts` skips empty slots and other
                // hosts' indices stay stable. (No break - wipe duplicates too.)
            }
        }

        loadHosts()
    }
}
