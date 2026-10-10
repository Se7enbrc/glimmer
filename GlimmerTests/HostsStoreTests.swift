//
//  HostsStoreTests.swift
//
//  The paired-PC store and the poller's asks of it: app lists refreshed after
//  pairing, an address healed after a DHCP move, when /applist is fetched, and
//  what a PC that replaces the selection gets.
//

import AppKit
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

    @MainActor @Test func endingAStreamRefreshesTheVisibleLastPlayedDate() throws {
        let domain = "io.ugfugl.Glimmer.tests.hosts-last-played"
        let defaults = try pairedTower(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel()
        defer {
            model.hostStatusTask?.cancel()
            model.hostPolling.movedHostSearch?.cancel()
        }
        model.loadHosts(defaults: defaults)
        #expect(model.selectedHost?.lastConnected == nil)
        let ended = Date(timeIntervalSince1970: 1_700_000_000)
        model.recordLastPlayed(hostID: "TOWER-ID", at: ended, defaults: defaults)
        #expect(model.selectedHost?.lastConnected == ended)
        #expect(model.hosts.first?.lastConnected == ended)
        #expect(defaults.object(forKey: "glimmer.lastConnected.TOWER-ID") as? Date == ended)
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

    private static func host(_ id: String, address: String, mac: String? = nil) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: address, manualAddress: nil, apps: [],
                     lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: mac)
    }

    /// With the launcher closed a second miss lands up to two cycles (interval, 2 s
    /// tolerance, 2 s probe) after the last good status. It's still held; a third shows Asleep.
    @MainActor @Test func theClosedLauncherPollHoldsASecondMiss() async {
        let model = AppModel()
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.hostStatusTask?.cancel()
        defer { model.hostPolling.movedHostSearch?.cancel() }
        let cycle = AppModel.idleHostStatusPollSeconds + 2 + 2
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        model.hostLiveStatus = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3, sunshineVersion: nil,
                                              capturedAt: now.addingTimeInterval(-2 * cycle))
        model.hostUnreachableStreak = 1
        let publishMiss: (String, String) async -> Void = { hostID, expected in
            await model.publishUnreachable(hostID: hostID, expectedHostID: expected, now: now)
        }
        _ = await model.pollHostStatusOnce(for: "tower", appListFor: nil,
                                           probe: { _, _, _ in .unreachable }, macHasRoute: true, publishMiss: publishMiss)
        #expect(model.hostLiveStatus?.state == .idle)
        _ = await model.pollHostStatusOnce(for: "tower", appListFor: nil,
                                           probe: { _, _, _ in .unreachable }, macHasRoute: true, publishMiss: publishMiss)
        #expect(model.hostLiveStatus?.state == .asleep)
        #expect(model.hostLiveStatus?.capturedAt == now)
    }

    @MainActor @Test(arguments: [HostLiveStatus.stale, HostLiveStatus.stale + 1])
    func aSecondMissPublishesAsleepOnlyAfterTheGoodAnswerExpires(age: TimeInterval) async {
        let model = AppModel()
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.hostStatusTask?.cancel()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let live = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3, sunshineVersion: nil,
                                  capturedAt: now.addingTimeInterval(-age))
        model.hostLiveStatus = live
        model.hostUnreachableStreak = 1
        await model.publishUnreachable(hostID: "tower", expectedHostID: "tower", now: now)
        #expect(model.hostUnreachableStreak == 2)
        if age <= HostLiveStatus.stale {
            #expect(model.hostLiveStatus == live)
        } else {
            #expect(model.hostLiveStatus?.state == .asleep)
            #expect(model.hostLiveStatus?.capturedAt == now)
        }
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

    @Test func noRouteIsNotEvidenceOfSleep() {
        #expect(!AppModel.missPublishesAsleep(streak: 1, holdsGoodStatus: false, macHasRoute: false))
        #expect(AppModel.missPublishesAsleep(streak: 1, holdsGoodStatus: false, macHasRoute: true))
        #expect(!AppModel.missPublishesAsleep(streak: 2, holdsGoodStatus: true, macHasRoute: true))
        #expect(AppModel.missPublishesAsleep(streak: 3, holdsGoodStatus: true, macHasRoute: true))
    }

    @Test func aRecentStreamHoldsAnOldSampleOnlyForItsOwnPC() {
        let now = Date()
        let live = HostLiveStatus(hostID: "pc", state: .idle, rttMs: 3, sunshineVersion: nil,
                                  capturedAt: now.addingTimeInterval(-300))
        #expect(AppModel.holdsGoodStatus(live: live, provenAwake: ("pc", now.addingTimeInterval(-3)),
                                         hostID: "pc", now: now))
        #expect(!AppModel.holdsGoodStatus(live: live, provenAwake: ("pc", now.addingTimeInterval(-61)),
                                          hostID: "pc", now: now))
        #expect(!AppModel.holdsGoodStatus(live: live, provenAwake: ("other", now), hostID: "pc", now: now))
    }

    @MainActor @Test(arguments: [true, false])
    func wakeNotificationsClearOnlyTheirOwnPause(systemWakesFirst: Bool) {
        let model = AppModel()
        let center = NotificationCenter()
        model.observeHostPollingSleep(center: center)
        defer {
            model.hostStatusTask?.cancel()
            for token in model.workspaceTokens { center.removeObserver(token) }
        }
        model.selectedHost = Self.host("pc", address: "192.0.2.10")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: systemWakesFirst ? NSWorkspace.didWakeNotification : NSWorkspace.screensDidWakeNotification,
                    object: nil)
        #expect(model.hostPollingPausedForSleep)
        #expect(model.hostStatusTask == nil)
        center.post(name: systemWakesFirst ? NSWorkspace.screensDidWakeNotification : NSWorkspace.didWakeNotification,
                    object: nil)
        #expect(!model.hostPollingPausedForSleep)
        #expect(model.hostStatusTask != nil)
        #expect(model.hostPolling.settleUntil > Date())
        #expect(model.hostPolling.provenAwake == nil)
    }

    @MainActor @Test func backgroundSleepPostCancelsNetworkWorkBeforeReturning() async {
        let model = AppModel()
        let center = SynchronousSleepNotificationCenter()
        model.observeHostPollingSleep(center: center)
        let gates = [PollerCancellationGate(), PollerCancellationGate(), PollerCancellationGate()]
        let tasks = gates.map { gate in Task { _ = await gate.wait() } }
        model.hostStatusTask = tasks[0]
        model.hostPolling.movedHostSearch = tasks[1]
        model.wakeWork.operations[UUID()] = { tasks[2].cancel() }
        defer {
            for task in tasks { task.cancel() }
            for token in model.workspaceTokens { center.removeObserver(token) }
        }
        for gate in gates { #expect(await gate.started.waitAsync(for: .seconds(5)) == .success) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                center.post(name: NSWorkspace.willSleepNotification, object: nil)
                for task in tasks { #expect(task.isCancelled) }
                for gate in gates { #expect(gate.cancelled.isSet) }
                continuation.resume()
            }
        }
        #expect(model.hostPolling.systemSleeping)
        #expect(model.hostStatusTask == nil)
        #expect(model.hostPolling.movedHostSearch == nil)
    }

    @MainActor @Test func systemSleepDoesNotReportADirectWakeWaitAsNoAnswer() async throws {
        let model = AppModel()
        let host = Self.host("pc", address: "192.0.2.10", mac: "aa:bb:cc:dd:ee:ff")
        let poll = PollerCancellationGate()
        let caller = Task {
            await model.sendWakeAndWait(host, waitSeconds: 90, send: { _, _ in 1 },
                                        waitForAnswer: { _, _ in await poll.wait() })
        }
        defer { caller.cancel() }
        // The real three-burst send takes at least three seconds under suite load.
        try #require(await poll.started.waitAsync(for: .seconds(15)) == .success)
        model.setHostPollingSleep(system: true, sleeping: true)
        let outcome = await caller.value
        #expect(!caller.isCancelled)
        #expect(poll.cancelled.isSet)
        #expect(outcome == .cancelled)
        #expect(throws: CancellationError.self) {
            try WakePCIntent.checkOutcome(outcome, pc: host.displayName)
        }
        #expect(outcome.failureReason == nil)
        #expect(PCIntentError(outcome, pc: host.displayName) == nil)
        #expect(model.wakeWork.operations.isEmpty)
    }

    @MainActor @Test func displaySleepCancelsMovedHostSearchAndLeavesWakeWorkRunning() async {
        let model = AppModel()
        let center = NotificationCenter()
        model.observeHostPollingSleep(center: center)
        let movedHostProbe = PollerCancellationGate()
        let movedHostSearch = Task { _ = await movedHostProbe.wait() }
        model.hostPolling.movedHostSearch = movedHostSearch
        let wake = Task {}
        let search = Task {}
        model.wakeWork.buttonTask = wake
        let id = UUID()
        model.wakeWork.operations[id] = { search.cancel() }
        defer {
            wake.cancel()
            search.cancel()
            movedHostSearch.cancel()
            for token in model.workspaceTokens { center.removeObserver(token) }
        }
        #expect(await movedHostProbe.started.waitAsync(for: .seconds(5)) == .success)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(movedHostSearch.isCancelled)
        #expect(movedHostProbe.cancelled.isSet)
        #expect(model.hostPolling.movedHostSearch == nil)
        #expect(!wake.isCancelled)
        #expect(!search.isCancelled)
        #expect(model.hostPollingPausedForSleep)
    }

    @MainActor @Test func activationPreservesAndConsumesTheSettleDeadline() async {
        let model = AppModel()
        model.selectedHost = Self.host("pc", address: "192.0.2.10")
        defer { model.hostStatusTask?.cancel() }
        let firstSleep = PollerCancellationGate()
        let activationSleep = PollerCancellationGate()
        // Keep the deadline ahead of any suite scheduling delay; the sleeps are controlled.
        model.hostPolling.settleUntil = Date().addingTimeInterval(60)
        model.restartHostStatusPolling(afterStream: true, sleep: { _ in
            _ = await firstSleep.wait()
            try Task.checkCancellation()
        })
        let deadline = model.hostPolling.settleUntil
        #expect(await firstSleep.started.waitAsync(for: .seconds(5)) == .success)
        model.restartHostStatusPolling(sleep: { remaining in
            #expect(remaining > 0)
            _ = await activationSleep.wait()
            try Task.checkCancellation()
        })
        #expect(firstSleep.cancelled.isSet)
        #expect(model.hostPolling.settleUntil == deadline)
        #expect(await activationSleep.started.waitAsync(for: .seconds(5)) == .success)
        model.hostStatusTask?.cancel()
        #expect(activationSleep.cancelled.isSet)
    }

    @MainActor @Test func failedConnectionsDoNotProveTheSelectedPCIsAwake() {
        let model = AppModel()
        model.selectedHost = Self.host("pc", address: "192.0.2.10")
        defer { model.hostStatusTask?.cancel() }
        model.restartHostStatusPolling(afterStream: true)
        #expect(model.hostPolling.provenAwake == nil)
    }

    @MainActor @Test func aStreamProvesItsPCDespiteASelectionChange() {
        let model = AppModel()
        let streamed = Self.host("streamed", address: "192.0.2.10")
        model.selectedHost = streamed
        defer { model.hostStatusTask?.cancel() }
        model.handleNativeEvent(.connectionEstablished, host: streamed)
        model.selectedHost = Self.host("selected", address: "192.0.2.20")
        model.restartHostStatusPolling(afterStream: true)
        #expect(model.hostPolling.provenAwake?.hostID == streamed.id)
        #expect(model.hostPolling.establishedHostID == nil)
    }

    @MainActor @Test func anUnreachablePollWithoutARouteDoesNothing() async {
        let model = AppModel()
        model.selectedHost = Self.host("pc", address: "192.0.2.10")
        model.hostStatusTask?.cancel()
        model.hostUnreachableStreak = 2
        let live = HostLiveStatus(hostID: "pc", state: .idle, rttMs: 3, sunshineVersion: nil,
                                  capturedAt: Date().addingTimeInterval(-300))
        model.hostLiveStatus = live
        let result = await model.pollHostStatusOnce(for: "pc", appListFor: 7,
                                                    probe: { _, _, _ in .unreachable }, macHasRoute: false)
        #expect(result.appListFor == 7)
        #expect(result.noPath)
        #expect(model.hostLiveStatus == live)
        #expect(model.hostUnreachableStreak == 2)
        #expect(model.hostPolling.movedHostSearch == nil)
    }

    @MainActor @Test func sleepDuringMissPublicationCannotStartANewSearch() async {
        let model = AppModel()
        model.selectedHost = Self.host("pc", address: "192.0.2.10")
        model.hostStatusTask?.cancel()
        let entered = DispatchSemaphore(value: 0)
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            await model.pollHostStatusOnce(for: "pc", appListFor: nil,
                                           probe: { _, _, _ in .unreachable }, macHasRoute: true, publishMiss: { hostID, expected in
                await model.publishUnreachable(hostID: hostID, expectedHostID: expected)
                entered.signal()
                for await _ in release.stream {}
            })
        }
        model.hostStatusTask = Task { _ = await task.value }
        #expect(await entered.waitAsync(for: .seconds(5)) == .success)
        #expect(model.hostLiveStatus?.state == .asleep)
        model.setHostPollingSleep(system: true, sleeping: true)
        task.cancel()
        release.continuation.finish()
        _ = await task.value
        #expect(model.hostPolling.movedHostSearch == nil)
    }

    @MainActor @Test func cancellationDuringTheSavedAddressProbeCannotPersistOrReload() async throws {
        let domain = "io.ugfugl.Glimmer.tests.cancel-address-probe"
        let defaults = try pairedTower(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel()
        let host = Self.host("TOWER-ID", address: "192.0.2.10")
        model.selectedHost = host
        model.hostStatusTask?.cancel()
        let task = Task {
            await model.saveHealedAddress(of: host, moved: "192.0.2.77", saved: "192.0.2.10",
                                          port: 47989, defaults: defaults) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .unreachable
            }
        }
        #expect(await task.value == false)
        #expect(defaults.string(forKey: "hosts.1.localaddress") == "192.0.2.10")
        #expect(model.selectedHost?.id == host.id)
    }

    @MainActor @Test func systemSleepCancelsADirectWakeAfterItsPCDisappears() async {
        let model = AppModel()
        let host = Self.host("pc", address: "192.0.2.10", mac: "aa:bb:cc:dd:ee:ff")
        let sent = DispatchSemaphore(value: 0)
        let task = Task {
            await model.sendWakeAndWait(host, waitSeconds: 90) { _, _ in
                sent.signal()
                return 1
            }
        }
        #expect(await sent.waitAsync(for: .seconds(5)) == .success)
        #expect(model.wakeWork.operations.count == 1)
        let button = Task {}
        let search = Task {}
        model.wakeWork.buttonTask = button
        model.hostPolling.movedHostSearch = search
        model.wakingHostID = host.id
        model.hosts = []
        model.setHostPollingSleep(system: true, sleeping: true)
        #expect(button.isCancelled)
        #expect(search.isCancelled)
        #expect(model.wakingHostID == nil)
        #expect(await task.value == .cancelled)
        #expect(model.wakeWork.operations.isEmpty)
    }

    @MainActor @Test func overlappingWaitsCancelEveryAddressSearchSynchronously() async throws {
        let model = AppModel()
        let host = Self.host("pc", address: "192.0.2.10", mac: "aa:bb:cc:dd:ee:ff")
        let searches = [PollerCancellationGate(), PollerCancellationGate()]
        let polls = [PollerCancellationGate(), PollerCancellationGate()]
        let tasks = (0..<2).map { index in
            Task {
                await model.sendWakeAndWait(host, waitSeconds: 90, send: { _, _ in 1 }, waitForAnswer: { host, seconds in
                    await model.waitForSunshine(host: host, budgetSeconds: seconds,
                                                 searchAddress: { await searches[index].wait() },
                                                 poll: { await polls[index].wait() })
                })
            }
        }
        defer { for task in tasks { task.cancel() } }
        for gate in searches + polls {
            try #require(await gate.started.waitAsync(for: .seconds(15)) == .success)
        }
        model.setHostPollingSleep(system: true, sleeping: true)
        for gate in searches + polls { #expect(gate.cancelled.isSet) }
        for task in tasks { _ = await task.value }
        #expect(model.wakeWork.operations.isEmpty)
    }

    @MainActor @Test func cancellingAWaitPropagatesImmediatelyToItsSearch() async {
        let model = AppModel()
        let search = PollerCancellationGate()
        let poll = PollerCancellationGate()
        let task = Task {
            await model.waitForSunshine(host: Self.host("pc", address: "192.0.2.10"), budgetSeconds: 90,
                                         searchAddress: { await search.wait() }, poll: { await poll.wait() })
        }
        #expect(await search.started.waitAsync(for: .seconds(5)) == .success)
        #expect(await poll.started.waitAsync(for: .seconds(5)) == .success)
        task.cancel()
        #expect(search.cancelled.isSet)
        _ = await task.value
    }
}

private struct PollerCancellationGate: Sendable {
    let started = DispatchSemaphore(value: 0)
    let cancelled = ManagedAtomicFlag()
    private let channel = AsyncStream<Void>.makeStream()

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            started.signal()
            for await _ in channel.stream {}
            return false
        } onCancel: {
            cancelled.set()
        }
    }
}

// No mutable state is added; NotificationCenter owns synchronization of observers.
private final class SynchronousSleepNotificationCenter: NotificationCenter, @unchecked Sendable {
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        // A nil queue is the API guarantee that post waits for cancellation.
        if name == NSWorkspace.willSleepNotification { #expect(queue == nil) }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}
