// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  HostsPersistenceTests.swift
//
//  The paired-PC store, the per-PC codec choice and the typed settings readers,
//  all against a scratch UserDefaults suite and a temp directory so nothing
//  touches the developer's real preferences or Application Support.
//

import Foundation
import Testing
@testable import Glimmer

/// A scratch suite plus a temp directory, removed by `remove()`. Each test names its own
/// suite so a crashed run leaves at most one known plist behind.
struct IsolatedStore {
    let domain: String
    let defaults: UserDefaults
    let directory: URL

    init(_ name: String) throws {
        domain = "io.ugfugl.Glimmer.tests.persistence-\(name)"
        defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glimmer-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct HostsPersistenceTests {

    private typealias App = AppModel.PairedApp
    private static let desktop = App(id: 1, name: "Desktop", hdr: false, hidden: false)
    private static let pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"

    private func settle(_ model: AppModel) {
        model.hostStatusTask?.cancel()
        model.hostPolling.movedHostSearch?.cancel()
    }

    private func save(_ model: AppModel, _ store: IsolatedStore, uuid: String, name: String,
                      pem: String? = nil, mac: String? = nil) throws {
        try model.saveHost(uuid: uuid, hostname: name, address: "192.0.2.5", serverCertPEM: pem,
                           appVersion: "7.1", apps: [Self.desktop], macAddress: mac,
                           defaults: store.defaults, supportBase: store.directory)
    }

    private func pinFile(_ store: IsolatedStore, _ id: String) -> URL {
        store.directory.appendingPathComponent("Glimmer/PinnedHosts/\(id).pem")
    }

    private func bareHost(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil, apps: [],
             lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    @Test func savingAPCWritesItsSlotAndLoadsIt() throws {
        let store = try IsolatedStore("save")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "tower", mac: "AA:BB:CC:DD:EE:FF")
        #expect(store.defaults.integer(forKey: "hosts.size") == 1)
        #expect(store.defaults.string(forKey: "hosts.1.uuid") == "AAA")
        #expect(store.defaults.string(forKey: "hosts.1.mac") == "aa:bb:cc:dd:ee:ff")
        #expect(app.hosts.map(\.id) == ["AAA"])
        #expect(app.hosts.first?.apps.map(\.name) == ["Desktop"])
    }

    @Test func rePairingReusesTheSlotAndKeepsTheCustomName() throws {
        let store = try IsolatedStore("repair")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "tower")
        let host = try #require(app.hosts.first)
        app.renameHost(host, to: "Den PC", defaults: store.defaults)
        try save(app, store, uuid: "AAA", name: "tower-2")
        #expect(store.defaults.integer(forKey: "hosts.size") == 1)
        #expect(app.hosts.first?.customName == "Den PC")
        #expect(store.defaults.string(forKey: "hosts.1.hostname") == "tower-2")
    }

    @Test func aNewPCTakesTheSlotAnUnpairLeftEmptyWithoutInheritingItsWakeTarget() throws {
        let store = try IsolatedStore("slot-reuse")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "one", mac: "AA:BB:CC:DD:EE:01")
        try save(app, store, uuid: "BBB", name: "two")
        let first = try #require(app.hosts.first { $0.id == "AAA" })
        app.setWakeOnLAN(first, enabled: false, defaults: store.defaults)
        app.unpair(first, defaults: store.defaults, supportBase: store.directory)
        #expect(app.hosts.map(\.id) == ["BBB"])
        try save(app, store, uuid: "CCC", name: "three")
        #expect(store.defaults.integer(forKey: "hosts.size") == 2)
        #expect(store.defaults.string(forKey: "hosts.1.uuid") == "CCC")
        #expect(store.defaults.string(forKey: "hosts.1.mac") == nil)
        #expect(store.defaults.object(forKey: "hosts.1.wol") == nil)
        #expect(Set(app.hosts.map(\.id)) == ["BBB", "CCC"])
    }

    @Test func unpairingForgetsThePCEverywhere() throws {
        let store = try IsolatedStore("unpair")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "tower", pem: Self.pem)
        HostCodecPreference.save(.hevc, for: "AAA", defaults: store.defaults)
        store.defaults.set(Date(), forKey: "glimmer.lastConnected.AAA")
        let host = try #require(app.hosts.first)
        app.selectHost(host, defaults: store.defaults)
        #expect(FileManager.default.fileExists(atPath: pinFile(store, "AAA").path))
        app.unpair(host, defaults: store.defaults, supportBase: store.directory)
        #expect(app.hosts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pinFile(store, "AAA").path))
        #expect(HostCodecPreference.load(for: "AAA", defaults: store.defaults) == .auto)
        #expect(store.defaults.object(forKey: "glimmer.lastConnected.AAA") == nil)
        #expect(store.defaults.string(forKey: "glimmer.selectedHostID") == nil)
        #expect(store.defaults.string(forKey: "hosts.1.uuid") == nil)
        #expect(store.defaults.object(forKey: "hosts.1.apps.size") == nil)
    }

    @Test func unpairingWipesEveryDuplicateSlot() throws {
        let store = try IsolatedStore("unpair-dupes")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        for slot in 1...2 {
            store.defaults.set("DUP", forKey: "hosts.\(slot).uuid")
            store.defaults.set("dup", forKey: "hosts.\(slot).hostname")
        }
        store.defaults.set(2, forKey: "hosts.size")
        app.unpair(bareHost("DUP"), defaults: store.defaults, supportBase: store.directory)
        #expect(store.defaults.string(forKey: "hosts.1.uuid") == nil)
        #expect(store.defaults.string(forKey: "hosts.2.uuid") == nil)
    }

    @Test func renamingSetsAndClearsTheCustomName() throws {
        let store = try IsolatedStore("rename")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "tower")
        let host = try #require(app.hosts.first)
        app.renameHost(host, to: "  Den PC ", defaults: store.defaults)
        #expect(app.hosts.first?.customName == "Den PC")
        #expect(store.defaults.bool(forKey: "hosts.1.customname"))
        app.renameHost(host, to: "   ", defaults: store.defaults)
        #expect(app.hosts.first?.customName == nil)
        #expect(store.defaults.string(forKey: "hosts.1.name") == nil)
        app.renameHost(bareHost("nope"), to: "ghost", defaults: store.defaults)
        #expect(app.hosts.first?.customName == nil)
    }

    @Test func aMacRefreshIgnoresZeroedAddressesAndKeepsTheRealOne() throws {
        let store = try IsolatedStore("mac")
        defer { store.remove() }
        let app = AppModel()
        defer { settle(app) }
        try save(app, store, uuid: "AAA", name: "tower", mac: "AA:BB:CC:DD:EE:FF")
        app.updateHostMac(hostID: "AAA", mac: "00:00:00:00:00:00", defaults: store.defaults)
        #expect(app.hosts.first?.macAddress == "aa:bb:cc:dd:ee:ff")
        app.updateHostMac(hostID: "AAA", mac: "11:22:33:44:55:66", defaults: store.defaults)
        #expect(app.hosts.first?.macAddress == "11:22:33:44:55:66")
        app.updateHostMac(hostID: "missing", mac: "11:22:33:44:55:77", defaults: store.defaults)
        #expect(store.defaults.integer(forKey: "hosts.size") == 1)
    }

    @Test func moonlightQtHostsAreCopiedOnceAndTheFlagLatches() throws {
        let store = try IsolatedStore("mq-hosts")
        let qt = try IsolatedStore("mq-source")
        defer { store.remove(); qt.remove() }
        qt.defaults.set(1, forKey: "hosts.size")
        qt.defaults.set("qt-tower", forKey: "hosts.1.hostname")
        qt.defaults.set("QT-ID", forKey: "hosts.1.uuid")
        qt.defaults.set(true, forKey: "hosts.1.customname")
        qt.defaults.set("Qt Den", forKey: "hosts.1.name")
        qt.defaults.set(1, forKey: "hosts.1.apps.size")
        qt.defaults.set("Steam", forKey: "hosts.1.apps.1.name")
        qt.defaults.set(7, forKey: "hosts.1.apps.1.id")
        let app = AppModel()
        defer { settle(app) }
        app.migrateFromMoonlightQtIfNeeded(defaults: store.defaults, moonlightSuite: qt.domain)
        app.loadHosts(defaults: store.defaults)
        #expect(app.hosts.first?.id == "QT-ID")
        #expect(app.hosts.first?.customName == "Qt Den")
        #expect(app.hosts.first?.apps.map(\.id) == [7])
        #expect(store.defaults.bool(forKey: "glimmer.hostsMigratedFromMoonlightQt"))
        store.defaults.set("changed", forKey: "hosts.1.hostname")
        app.migrateFromMoonlightQtIfNeeded(defaults: store.defaults, moonlightSuite: qt.domain)
        #expect(store.defaults.string(forKey: "hosts.1.hostname") == "changed")
    }

    @Test func aMoonlightQtSuiteWithNoHostsLatchesWithoutCopying() throws {
        let store = try IsolatedStore("mq-empty")
        let qt = try IsolatedStore("mq-empty-source")
        defer { store.remove(); qt.remove() }
        let app = AppModel()
        defer { settle(app) }
        app.migrateFromMoonlightQtIfNeeded(defaults: store.defaults, moonlightSuite: qt.domain)
        #expect(store.defaults.bool(forKey: "glimmer.hostsMigratedFromMoonlightQt"))
        #expect(store.defaults.object(forKey: "hosts.size") == nil)
    }

    // MARK: - Codec preference

    @Test func aCodecChoiceRoundTripsAndAutoClearsTheKey() throws {
        let store = try IsolatedStore("codec")
        defer { store.remove() }
        #expect(HostCodecPreference.load(for: "AAA", defaults: store.defaults) == .auto)
        HostCodecPreference.save(.h264, for: "AAA", defaults: store.defaults)
        #expect(HostCodecPreference.load(for: "AAA", defaults: store.defaults) == .h264)
        #expect(HostCodecPreference.load(for: "BBB", defaults: store.defaults) == .auto)
        HostCodecPreference.save(.auto, for: "AAA", defaults: store.defaults)
        #expect(store.defaults.string(forKey: "glimmer.codecPreference.AAA") == nil)
        HostCodecPreference.save(.hevc, for: "AAA", defaults: store.defaults)
        HostCodecPreference.forget(hostID: "AAA", defaults: store.defaults)
        #expect(HostCodecPreference.load(for: "AAA", defaults: store.defaults) == .auto)
        store.defaults.set("av2", forKey: "glimmer.codecPreference.AAA")
        #expect(HostCodecPreference.load(for: "AAA", defaults: store.defaults) == .auto)
    }

    // MARK: - Persisted setting readers

    @Test func settingReadersFallBackWhenAKeyIsAbsentOrOutOfRange() throws {
        let store = try IsolatedStore("readers")
        defer { store.remove() }
        let defaults = store.defaults
        #expect(AppModel.persistedPositiveInt("customWidth", defaults: defaults) == nil)
        defaults.set(-5, forKey: "customWidth")
        #expect(AppModel.persistedPositiveInt("customWidth", defaults: defaults) == nil)
        defaults.set(2560, forKey: "customWidth")
        #expect(AppModel.persistedPositiveInt("customWidth", defaults: defaults) == 2560)
        #expect(AppModel.persistedBool("streamHDR", defaults: defaults) == nil)
        defaults.set(false, forKey: "streamHDR")
        #expect(AppModel.persistedBool("streamHDR", defaults: defaults) == false)
        defaults.set("nonsense", forKey: "statsOverlayPreset")
        #expect(AppModel.persistedRawValue("statsOverlayPreset", StatsOverlayPreset.self,
                                           defaults: defaults) == nil)
        defaults.set(Data("not json".utf8), forKey: "quitHotkey")
        #expect(AppModel.persistedDecoded("quitHotkey", HotkeyChord.self, defaults: defaults) == nil)
        let chord = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: true, keyChar: "q")
        defaults.set(try JSONEncoder().encode(chord), forKey: "quitHotkey")
        #expect(AppModel.persistedDecoded("quitHotkey", HotkeyChord.self, defaults: defaults) == chord)
    }

    @Test func aRetiredQualityPresetIsRewrittenOnceToItsSurvivor() throws {
        let store = try IsolatedStore("preset")
        defer { store.remove() }
        #expect(AppModel.persistedQualityPreset(defaults: store.defaults) == nil)
        store.defaults.set("maximum", forKey: "qualityPreset")
        #expect(AppModel.persistedQualityPreset(defaults: store.defaults) == .matchDisplay)
        #expect(store.defaults.string(forKey: "qualityPreset") == QualityPreset.matchDisplay.rawValue)
    }

    @Test func customStatsRowsDropUnknownNamesAndAnEmptySetMeansDefault() throws {
        let store = try IsolatedStore("rows")
        defer { store.remove() }
        #expect(AppModel.persistedCustomRows(defaults: store.defaults) == nil)
        store.defaults.set(["latency", "bogus", "jitter"], forKey: "statsOverlayCustomRows")
        #expect(AppModel.persistedCustomRows(defaults: store.defaults) == [.latency, .jitter])
        store.defaults.set(["bogus"], forKey: "statsOverlayCustomRows")
        #expect(AppModel.persistedCustomRows(defaults: store.defaults) == nil)
    }
}
