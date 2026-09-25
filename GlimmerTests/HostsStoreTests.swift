//
//  HostsStoreTests.swift
//
//  The paired-PC store and the poller's asks of it: app lists refreshed after
//  pairing, an address healed after a DHCP move, when /applist is fetched, and
//  what a PC that replaces the selection gets.
//

import Foundation
import Testing
@testable import Glimmer

struct HostsStoreTests {

    private typealias App = AppModel.PairedApp
    private static let desktopStandIn = App(id: 881448767, name: "Desktop", hdr: false, hidden: false)

    /// `domain`, emptied, holding one PC paired as `tower` with `apps` stored. Each test
    /// passes its own fixed name and removes it after: a fresh name per run would leave a
    /// plist behind in ~/Library/Preferences every time (see MoonlightQtIdentityImportTests).
    private func pairedTower(_ domain: String, apps: [App] = [desktopStandIn]) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defaults.set(1, forKey: "hosts.size")
        defaults.set("tower", forKey: "hosts.1.hostname")
        defaults.set("TOWER-ID", forKey: "hosts.1.uuid")
        defaults.set("192.0.2.10", forKey: "hosts.1.localaddress")
        defaults.set("192.0.2.10", forKey: "hosts.1.manualaddress")
        #expect(AppModel.storeApps(apps, hostID: "TOWER-ID", in: defaults))
        return defaults
    }

    private func storedNames(_ defaults: UserDefaults) -> [String] {
        (0..<defaults.integer(forKey: "hosts.1.apps.size")).compactMap {
            defaults.string(forKey: "hosts.1.apps.\($0 + 1).name")
        }
    }

    @Test func aFreshListReplacesThePairingStandIn() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-fresh-list"
        let defaults = try pairedTower(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let fresh = [App(id: 1, name: "Desktop", hdr: false, hidden: false),
                     App(id: 2, name: "Steam Big Picture", hdr: true, hidden: false)]
        #expect(AppModel.storeApps(fresh, hostID: "TOWER-ID", in: defaults))
        #expect(storedNames(defaults) == ["Desktop", "Steam Big Picture"])
        #expect(defaults.integer(forKey: "hosts.1.apps.1.id") == 1)
        #expect(!AppModel.storeApps(fresh, hostID: "TOWER-ID", in: defaults))
    }

    @Test func aShorterListLeavesNoStaleApps() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-shorter-list"
        let defaults = try pairedTower(domain, apps: [App(id: 1, name: "Desktop", hdr: false, hidden: false),
                                                      App(id: 2, name: "Old Game", hdr: false, hidden: false)])
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(AppModel.storeApps([App(id: 1, name: "Desktop", hdr: false, hidden: false)],
                                   hostID: "TOWER-ID", in: defaults))
        #expect(storedNames(defaults) == ["Desktop"])
        #expect(defaults.object(forKey: "hosts.1.apps.2.name") == nil)
    }

    @Test func appsHiddenOnThisMacStayHidden() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-hidden-apps"
        let defaults = try pairedTower(domain, apps: [App(id: 1, name: "Desktop", hdr: false, hidden: true)])
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(AppModel.storeApps([App(id: 1, name: "Desktop", hdr: false, hidden: false),
                                    App(id: 2, name: "Elden Ring", hdr: true, hidden: false)],
                                   hostID: "TOWER-ID", in: defaults))
        #expect(defaults.bool(forKey: "hosts.1.apps.1.hidden"))
        #expect(!defaults.bool(forKey: "hosts.1.apps.2.hidden"))
    }

    @Test func anEmptyListOrUnknownPCChangesNothing() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-empty-list"
        let defaults = try pairedTower(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(!AppModel.storeApps([], hostID: "TOWER-ID", in: defaults))
        #expect(!AppModel.storeApps([App(id: 1, name: "Desktop", hdr: false, hidden: false)],
                                    hostID: "OTHER-ID", in: defaults))
        #expect(storedNames(defaults) == ["Desktop"])
        #expect(defaults.integer(forKey: "hosts.1.apps.1.id") == Self.desktopStandIn.id)
    }

    @Test func aMovedPCKeepsTheAddressTheUserTyped() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-moved-pc"
        let defaults = try pairedTower(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(AppModel.storeAddress("192.0.2.77", hostID: "TOWER-ID", in: defaults))
        #expect(defaults.string(forKey: "hosts.1.localaddress") == "192.0.2.77")
        #expect(defaults.string(forKey: "hosts.1.manualaddress") == "192.0.2.10")
        #expect(!AppModel.storeAddress("192.0.2.77", hostID: "TOWER-ID", in: defaults))
        #expect(!AppModel.storeAddress("192.0.2.99", hostID: "OTHER-ID", in: defaults))
    }

    @Test(arguments: ["10.0.0.20", "172.16.4.2", "172.31.255.1", "192.168.1.20", "169.254.10.3"])
    func aLANLeaseAddressIsHealed(_ address: String) {
        #expect(AppModel.canHealAddress(address))
    }

    /// A PC paired over Tailscale or at a name keeps it, even when its LAN address
    /// answers mDNS first; only a DHCP lease moves.
    @Test(arguments: ["100.64.0.7", "100.127.1.2", "tower.example.ts.net", "pc.example.com", "tower.local",
                      "203.0.113.9", "172.32.0.1", "fd7a:115c:a1e0::7"])
    func aStableAddressIsNeverHealed(_ address: String) {
        #expect(!AppModel.canHealAddress(address))
    }

    @Test func appListIsFetchedOncePerLoopAndForUnknownApps() {
        #expect(AppModel.needsAppList(runningID: 0, known: [1], fetchedFor: nil))
        #expect(!AppModel.needsAppList(runningID: 0, known: [1], fetchedFor: 0))
        #expect(!AppModel.needsAppList(runningID: 1, known: [1], fetchedFor: 0))
        #expect(AppModel.needsAppList(runningID: 7, known: [1], fetchedFor: 0))
        // Still unknown after its fetch (hidden here, say): don't ask again every poll.
        #expect(!AppModel.needsAppList(runningID: 7, known: [1], fetchedFor: 7))
    }

    private static func host(_ id: String, address: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: address, manualAddress: nil, apps: [],
                     lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    /// With the launcher closed a second miss lands up to two cycles (interval, 2 s
    /// tolerance, 2 s probe) after the last good status. It's still held; a third shows Asleep.
    @MainActor @Test func theClosedLauncherPollHoldsASecondMiss() async {
        let model = AppModel()
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.hostStatusTask?.cancel()
        let cycle = AppModel.idleHostStatusPollSeconds + 2 + 2
        model.hostLiveStatus = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3, sunshineVersion: nil,
                                              capturedAt: Date().addingTimeInterval(-2 * cycle))
        model.hostUnreachableStreak = 1
        await model.publishUnreachable(hostID: "tower", expectedHostID: "tower")
        #expect(model.hostLiveStatus?.state == .idle)
        await model.publishUnreachable(hostID: "tower", expectedHostID: "tower")
        #expect(model.hostLiveStatus?.state == .asleep)
    }

    @MainActor @Test func aPCThatReplacesTheSelectionGetsAFreshChipAndPoll() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.hostLiveStatus = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3,
                                              sunshineVersion: "2026.1", capturedAt: Date())
        model.wakeFailedHostID = "tower"
        model.wakeFailureReason = .noAnswer
        let towerPoll = model.hostStatusTask
        // What loadHosts does once tower is unpaired.
        model.selectedHost = Self.host("den", address: "192.0.2.20")
        #expect(model.hostLiveStatus == nil)
        #expect(model.wakeFailedHostID == nil)
        #expect(model.wakeFailureReason == nil)
        #expect(model.hostStatusTask != nil)
        #expect(model.hostStatusTask != towerPoll)
    }

    @MainActor @Test func reloadingTheSamePCKeepsItsChipAndPoll() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        let tower = Self.host("tower", address: "192.0.2.10")
        model.selectedHost = tower
        let status = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3, sunshineVersion: nil, capturedAt: Date())
        model.hostLiveStatus = status
        let poll = model.hostStatusTask
        // Every activation reloads the list and reassigns the same PC.
        model.selectedHost = tower
        #expect(model.hostLiveStatus == status)
        #expect(model.hostStatusTask == poll)
    }

    @MainActor @Test func pairingKeepsThePollPausedUntilCancelled() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        let attempt = model.beginPairing(address: "192.0.2.1")
        model.restartHostStatusPolling()
        #expect(model.hostStatusTask == nil)
        model.cancelPairing(attempt)
        #expect(model.hostStatusTask != nil)
    }

    @MainActor @Test func aWakePausesOnlyItsOwnPCPoll() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.wakingHostID = "tower"
        model.restartHostStatusPolling()
        #expect(model.hostStatusTask == nil)
        model.wakingHostID = "den"
        model.restartHostStatusPolling()
        #expect(model.hostStatusTask != nil)
    }
}
