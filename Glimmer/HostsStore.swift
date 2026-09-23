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
import Network
import os.log

extension AppModel {

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
            copy("srvcert"); copy("appversion")
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

        var loaded: [Host] = []
        for i in 1...count {
            let hostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
            let stored = Self.readApps(prefix: "hosts.\(i)", defaults: defaults)
            guard !stored.isEmpty, !hostname.isEmpty else { continue }

            let uuid = defaults.string(forKey: "hosts.\(i).uuid") ?? hostname
            let hasCustom = defaults.bool(forKey: "hosts.\(i).customname")
            let customName = hasCustom ? defaults.string(forKey: "hosts.\(i).name") : nil
            let local = defaults.string(forKey: "hosts.\(i).localaddress")
            let manual = defaults.string(forKey: "hosts.\(i).manualaddress")

            let apps = stored.filter { !$0.hidden }.map { LibraryApp(id: $0.id, name: $0.name, hdr: $0.hdr, hidden: false) }

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

            loaded.append(Host(
                id: uuid,
                name: hostname,
                customName: customName,
                localAddress: local,
                manualAddress: manual,
                apps: apps,
                lastConnected: last,
                serverCertPEM: srvCert,
                appVersion: appVer,
                // Backfilled from /serverinfo's `<mac>` on every successful
                // poll/pair (only learnable while the host is online).
                macAddress: defaults.string(forKey: "hosts.\(i).mac"),
                wakeOnLAN: defaults.object(forKey: "hosts.\(i).wol") as? Bool ?? true
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

    /// Find the `hosts.N` slot index for a host id (uuid, hostname fallback) -
    /// the shared lookup renameHost pioneered. 0 = no match.
    nonisolated private static func hostSlot(for hostID: String, defaults: UserDefaults) -> Int {
        let count = defaults.integer(forKey: "hosts.size")
        guard count > 0 else { return 0 }
        for i in 1...count {
            let uuid = defaults.string(forKey: "hosts.\(i).uuid") ?? ""
            let hostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
            if uuid == hostID || (uuid.isEmpty && hostname == hostID) { return i }
        }
        return 0
    }

    func setWakeOnLAN(_ host: Host, enabled: Bool) {
        let defaults = UserDefaults.standard
        let slot = Self.hostSlot(for: host.id, defaults: defaults)
        guard slot > 0 else { return }
        defaults.set(enabled, forKey: "hosts.\(slot).wol")
        loadHosts()
    }

    /// Backfill/refresh a host's MAC from a successful /serverinfo. Zeroed or
    /// empty MACs are rejected so a bad refresh never clobbers a real one.
    func updateHostMac(hostID: String, mac: String?) {
        guard let normalized = WakeOnLAN.normalizeMac(mac) else { return }
        let defaults = UserDefaults.standard
        let slot = Self.hostSlot(for: hostID, defaults: defaults)
        guard slot > 0 else { return }
        let key = "hosts.\(slot).mac"
        guard defaults.string(forKey: key) != normalized else { return }
        defaults.set(normalized, forKey: key)
        loadHosts()
    }

    /// Set (or clear) a user-facing custom name for a host. Persists into the
    /// same `hosts.N.name` + `hosts.N.customname` keys that `loadHosts` reads,
    /// matching the moonlight-qt schema. An empty/whitespace name clears the
    /// override (the tile falls back to the real hostname). Keyed by UUID like
    /// `unpair`, since hostname can differ from displayName for renamed hosts.
    func renameHost(_ host: Host, to newName: String) {
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

    /// Persists a freshly paired PC into the `hosts.N.*` schema `loadHosts` reads, reusing
    /// its slot on a re-pair and appending one otherwise. `apps` come from /applist.
    func saveHost(uuid: String, hostname: String, address: String,
                  serverCertPEM: String?, appVersion: String?,
                  apps: [PairedApp], macAddress: String? = nil) {
        let defaults = UserDefaults.standard
        let prefix = "hosts.\(saveSlot(for: uuid, defaults: defaults))"
        defaults.set(hostname, forKey: "\(prefix).hostname")
        defaults.set(uuid, forKey: "\(prefix).uuid")
        defaults.set(address, forKey: "\(prefix).localaddress")
        defaults.set(address, forKey: "\(prefix).manualaddress")
        if let pem = serverCertPEM { defaults.set(pem, forKey: "\(prefix).srvcert") }
        if let appVersion { defaults.set(appVersion, forKey: "\(prefix).appversion") }
        // Pair-time MAC capture (the host is online right now - the only time
        // it's learnable). Zeroed/absent leaves any earlier value in place.
        if let mac = WakeOnLAN.normalizeMac(macAddress) {
            defaults.set(mac, forKey: "\(prefix).mac")
        }
        // Don't clobber a user's custom name on re-pair.
        if defaults.object(forKey: "\(prefix).customname") == nil {
            defaults.set(false, forKey: "\(prefix).customname")
        }

        Self.writeApps(apps, prefix: prefix, defaults: defaults)

        // Pin the cert under the canonical uuid key too (belt-and-braces; the
        // pairing flow already file-store-pins, but keep them in lockstep).
        if let pem = serverCertPEM { try? PinnedCertStore.store(pem: pem, forHostID: uuid) }

        loadHosts()
    }

    /// Resolve the `hosts.N` slot `saveHost` should write into: the slot that
    /// already holds this uuid, else the first fully-empty slot left by an
    /// unpair, else a freshly appended one (which grows `hosts.size` here, as
    /// the inline version did). Split out of `saveHost` to keep that function
    /// under the complexity limit; behaviour is unchanged.
    private func saveSlot(for uuid: String, defaults: UserDefaults) -> Int {
        let count = defaults.integer(forKey: "hosts.size")
        var firstEmpty = 0
        if count > 0 {
            for i in 1...count {
                let slotUUID = defaults.string(forKey: "hosts.\(i).uuid") ?? ""
                let slotHostname = defaults.string(forKey: "hosts.\(i).hostname") ?? ""
                if slotUUID == uuid { return i }
                if firstEmpty == 0, slotUUID.isEmpty, slotHostname.isEmpty { firstEmpty = i }
            }
        }
        if firstEmpty > 0 { return firstEmpty }
        let appended = count + 1
        defaults.set(appended, forKey: "hosts.size")
        return appended
    }

    /// Rewrite one slot's `apps.N.*` block: clear the stale higher-index
    /// entries a shorter applist would otherwise leave behind, then write the
    /// fresh list. Split out of `saveHost` for the same reason as `saveSlot`.
    nonisolated private static func writeApps(_ apps: [PairedApp], prefix: String, defaults: UserDefaults) {
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
    }

    /// One slot's stored apps, hidden ones included, in stored order.
    nonisolated private static func readApps(prefix: String, defaults: UserDefaults) -> [PairedApp] {
        let count = defaults.integer(forKey: "\(prefix).apps.size")
        guard count > 0 else { return [] }
        return (1...count).map { j in
            PairedApp(id: defaults.integer(forKey: "\(prefix).apps.\(j).id"),
                      name: defaults.string(forKey: "\(prefix).apps.\(j).name") ?? "Untitled",
                      hdr: defaults.bool(forKey: "\(prefix).apps.\(j).hdr"),
                      hidden: defaults.bool(forKey: "\(prefix).apps.\(j).hidden"))
        }
    }

    /// Replace a PC's stored apps with a fresh /applist, pairing's stand-in Desktop
    /// included. A hide carried over from moonlight-qt sticks; an empty list is ignored
    /// because `loadHosts` drops a PC with no apps. True when the stored list changed.
    nonisolated static func storeApps(_ apps: [PairedApp], hostID: String, in defaults: UserDefaults) -> Bool {
        let slot = hostSlot(for: hostID, defaults: defaults)
        guard slot > 0, !apps.isEmpty else { return false }
        let prefix = "hosts.\(slot)"
        let old = readApps(prefix: prefix, defaults: defaults)
        let hiddenIDs = Set(old.filter(\.hidden).map(\.id))
        let merged = apps.map { PairedApp(id: $0.id, name: $0.name, hdr: $0.hdr, hidden: $0.hidden || hiddenIDs.contains($0.id)) }
        guard merged != old else { return false }
        writeApps(merged, prefix: prefix, defaults: defaults)
        return true
    }

    /// Fetch a paired PC's /applist and store it. The chip poller calls this, and so
    /// can anything else that needs the current list. False when the PC didn't answer.
    @discardableResult
    func refreshAppList(for host: Host) async -> Bool {
        let client = NetworkClient(server: nativeServerInfo(for: host))
        let fetched = try? await client.appList()
        await client.shutdown()
        guard let fetched, !fetched.isEmpty else { return false }
        let apps = fetched.map { PairedApp(id: $0.id, name: $0.name, hdr: $0.hdrCapable, hidden: $0.hidden) }
        if Self.storeApps(apps, hostID: host.id, in: .standard) { loadHosts() }
        return true
    }

    /// Save the address a PC answers at after a DHCP move. Only the discovered
    /// address changes; the one the user typed at pairing stays as entered.
    nonisolated static func storeAddress(_ address: String, hostID: String, in defaults: UserDefaults) -> Bool {
        let slot = hostSlot(for: hostID, defaults: defaults)
        let key = "hosts.\(slot).localaddress"
        guard slot > 0, defaults.string(forKey: key) != address else { return false }
        defaults.set(address, forKey: key)
        return true
    }

    /// Only a private-range IPv4 literal moves with a DHCP lease. A hostname or a
    /// Tailscale or public address is the user's stable choice, so it's never healed.
    nonisolated static func canHealAddress(_ address: String) -> Bool {
        guard let raw = IPv4Address(address)?.rawValue else { return false }
        let octets = Array(raw)
        let (first, second) = (octets[0], octets[1])
        return first == 10 || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168) || (first == 169 && second == 254)
    }

    /// A PC on a new DHCP lease still answers mDNS. Browse for up to `seconds` for an
    /// IPv4 address (Wake on LAN sends only IPv4) that proves to be this PC over its pinned
    /// TLS, and save it once the saved address stops answering. True when it changed.
    @discardableResult
    func healAddress(of host: Host, within seconds: Double) async -> Bool {
        var probe = nativeServerInfo(for: host)
        let saved = probe.address
        guard probe.serverCertPEM != nil, Self.canHealAddress(saved) else { return false }
        let discovery = HostDiscovery(ipv4Only: true)
        let results = await discovery.start()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await discovery.stop()
        }
        var moved: String?
        // Every change to the list re-checks it, so a PC still booting gets another try.
        search: for await found in results {
            for address in Set(found.hosts.map(\.host)) where address != saved && IPv4Address(address) != nil {
                probe.address = address
                let client = NetworkClient(server: probe)
                let answer = try? await client.fetchServerInfo()
                await client.shutdown()
                if answer?.uniqueId == host.id {
                    moved = address
                    break search
                }
            }
        }
        deadline.cancel()
        await discovery.stop()
        // A PC with a second LAN interface answers mDNS there too; keep the paired one.
        guard let moved,
              await HostReachability.measureRTT(host: saved, port: probe.httpPort, timeoutMs: 2_000) == .unreachable,
              Self.storeAddress(moved, hostID: host.id, in: .standard) else { return false }
        Diag.notice("\(host.displayName) answered at a new network address; saved it", "Host")
        loadHosts()
        return true
    }

    func selectHost(_ host: Host) {
        // A prior PC's red banner would name the wrong machine after a switch.
        nativeStreamError = nil
        UserDefaults.standard.set(host.id, forKey: "glimmer.selectedHostID")
        selectedHost = host
    }

    /// Every write to `selectedHost` lands here. A different PC (a switch, an unpair,
    /// the launch-time load) gets a fresh chip, wake state and poll; the route monitor
    /// moves only on a real address change, since monitor() drops the PHY samples.
    func selectionChanged(from old: Host?) {
        if old?.id != selectedHost?.id {
            hostLiveStatus = nil
            wakeFailedHostID = nil
            wakeFailureReason = nil
            restartHostStatusPolling()
        }
        if old.map(Self.routeAddress) != selectedHostRouteAddress { refreshHostRoute() }
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
    func unpair(_ host: Host) {
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
                // `mac` and `wol` are slot-indexed too: a new host paired
                // into a recycled slot must not inherit the old wake target.
                for key in ["hostname", "uuid", "name", "customname",
                            "localaddress", "manualaddress",
                            "srvcert", "appversion", "gfeversion", "apps.size",
                            "mac", "wol", "lunadevice"] {
                    defaults.removeObject(forKey: "\(prefix).\(key)")
                }
                // Leave the hole; `loadHosts` skips empty slots and other
                // hosts' indices stay stable. (No break - wipe duplicates too.)
            }
        }

        loadHosts()
    }
}
