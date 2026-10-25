// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Observation
import Synchronization
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct LauncherTests {
    @Test func artworkStopsAtStreamAndBackgroundBoundaries() async {
        let fixture = LauncherFixture()
        let requests = Mutex(0)
        fixture.artwork = { _, _ in requests.withLock { $0 += 1 }; return Data() }
        let model = fixture.model()
        #expect(await model.artwork(for: fixture.app) == nil)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(requests.withLock { $0 } == 0)
        #expect(model.artworkRevision != nil)
        #expect(await model.artwork(for: fixture.app) == nil)
        #expect(requests.withLock { $0 } == 1)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.artworkRevision == nil)
        #expect(await model.artwork(for: fixture.app) == nil)
        #expect(requests.withLock { $0 } == 1)
        model.streamClosed()
        await model.waitUntilStreamClosed()
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        #expect(model.artworkRevision == nil)
        #expect(await model.artwork(for: fixture.app) == nil)
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func artworkFromAnOldSelectionCannotReachNewPC() async throws {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        let imageData = try #require(UIGraphicsImageRenderer(size: CGSize(width: 3, height: 4))
            .image { context in context.fill(CGRect(x: 0, y: 0, width: 3, height: 4)) }.pngData())
        fixture.artwork = { _, _ in await gate.wait(); return imageData }
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        let revision = model.artworkRevision
        let image = Task { await model.artwork(for: fixture.app) }
        await gate.waitUntilEntered()
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(model.artworkRevision != revision)
        await gate.release()
        #expect(await image.value == nil)
    }

    @Test func singlePairedPCLoadsOnceWithoutAnExtraSelectionStep() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.selectInitialPCIfNeeded()
        #expect(fixture.prepares == 0)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.selectInitialPCIfNeeded()
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        model.selectInitialPCIfNeeded()
        #expect(model.selectedName == "Test PC" && model.apps.count == 1)
        #expect(fixture.prepares == 1 && fixture.appRequests == 1 && fixture.pairs == 0)
    }

    @Test func reopeningRestoresLastConnectedAmongMultiplePCs() async {
        let fixture = LauncherFixture()
        fixture.additionalPCs = [SavedPC(server: ServerInfo(address: "other.invalid", uniqueId: "other",
                                                          serverName: "Other PC"))]
        let first = fixture.model()
        first.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        first.select(fixture.saved)
        await first.waitUntilOperationFinishes()
        let reopened = fixture.model()
        reopened.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        reopened.selectInitialPCIfNeeded()
        reopened.selectInitialPCIfNeeded()
        await reopened.waitUntilOperationFinishes()
        #expect(reopened.selectedName == "Test PC" && reopened.apps.count == 1)
        #expect(fixture.prepares == 2 && fixture.appRequests == 2 && fixture.pairs == 0)
    }

    @Test func unknownRememberedPCDoesNotChooseAnUnrelatedPC() async {
        let fixture = LauncherFixture()
        fixture.additionalPCs = [SavedPC(server: ServerInfo(address: "other.invalid", uniqueId: "other",
                                                          serverName: "Other PC"))]
        fixture.lastConnectedID = "removed"
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 0 && model.selectedName == nil)
    }

    @Test func backgroundDisconnectRefreshesOnlyAfterReturning() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        model.streamClosed()
        await model.waitUntilStreamClosed()
        model.selectInitialPCIfNeeded()
        #expect(fixture.prepares == 1)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 2 && model.apps.count == 1)
        #expect(model.stream == nil)
    }

    @Test func failedAutomaticRefreshDoesNotLoopOrForgetThePC() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        fixture.prepareFailure = LauncherServices.Failure.unavailable
        model.streamClosed()
        await model.waitUntilStreamClosed()
        await model.waitUntilOperationFinishes()
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 2 && model.apps.isEmpty && model.message != nil)
        #expect(fixture.lastConnectedID == fixture.pcID && model.selectedName == "Test PC")
    }

    @Test func nestedSessionCompletionUpdatesAppLevelStreamActivity() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        let changes = Mutex(0)
        withObservationTracking {
            #expect(model.hasActiveStream)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        model.stream?.start(surface: StreamSurface())
        #expect(model.stream != nil && !model.hasActiveStream)
        #expect(changes.withLock { $0 } == 1)
        var disabled = true
        let activity = AppDisplayActivity(development: false) { disabled = $0 }
        activity.update(.active, streamActive: model.hasActiveStream)
        #expect(!disabled)
    }

    @Test func manualAddressUsesExistingPreparePairAndAppListFlow() async {
        let fixture = LauncherFixture()
        fixture.paired = false
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(address: " 192.0.2.50 ")
        await model.waitUntilOperationFinishes()
        #expect(fixture.preparedAddress == "192.0.2.50" && fixture.preparedSaved == false)
        #expect(fixture.prepares == 1 && fixture.pairs == 1 && fixture.appRequests == 1 && fixture.remembers == 1)
        #expect(model.apps.count == 1)
    }

    @Test func manualSavedAddressKeepsPinAndInvalidEntryDoesNothing() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(address: "https://pc.invalid/path")
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 0)
        model.select(address: "PC.INVALID")
        await model.waitUntilOperationFinishes()
        #expect(fixture.preparedSaved == true && fixture.pairs == 0)
        #expect(fixture.prepares == 1)
    }

    @Test func nativeResolutionIsTheInitialLaunchDefault() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        #expect(model.streamProfile == .native120)
        #expect(model.touchMouseEnabled)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream?.launch.profile == .native120)
        #expect(model.stream?.launch.touchMouseEnabled == true)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test func launchCapturesProfileBeforeLaterPickerChanges() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.streamProfile = .native120
        model.mouseStick = .left
        model.touchMouseEnabled = false
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        model.streamProfile = .fullHD60
        model.mouseStick = .right
        model.touchMouseEnabled = true
        #expect(model.stream?.launch.profile == .native120)
        #expect(model.stream?.launch.mouseStick == .left)
        #expect(model.stream?.launch.touchMouseEnabled == false)
        #expect(fixture.prepares == 1)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test func authenticatedPCLoadsAppsAndStartsWithoutAnotherProbe() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 1)
        #expect(fixture.pairs == 0)
        #expect(fixture.remembers == 1)
        #expect(model.apps.map(\.id) == [1])
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream?.launch.appID == 1)
        #expect(fixture.prepares == 1)
        model.streamClosed()
        await model.waitUntilStreamClosed()
        await model.waitUntilOperationFinishes()
        #expect(model.selectedName == "Test PC" && model.apps.count == 1)
        #expect(model.message == nil)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream != nil)
        #expect(fixture.prepares == 2)
    }

    @Test func systemDismissalWaitsForTransportBeforeAnotherSelection() async {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.makeSession = { launch in
            StreamSessionModel(launch: launch, makePlayback: { _, _, _ in
                StreamPlayback(id: UUID(), events: AsyncStream { _ in }, start: { nil },
                               stop: { await gate.wait() }, screenChanged: {})
            })
        }
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.hasActiveStream)
        model.stream?.start(surface: StreamSurface())
        model.stream = nil
        model.streamClosed()
        await gate.waitUntilEntered()
        #expect(model.hasActiveStream)
        model.select(fixture.saved)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream == nil)
        #expect(fixture.prepares == 1)
        await gate.release()
        await model.waitUntilStreamClosed()
        #expect(!model.hasActiveStream)
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 2)
    }

    @Test func lockedDeviceCannotPrepareOrLaunch() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: false)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(fixture.prepares == 0)
        #expect(model.stream == nil)
    }

    @Test func staleDiscoverySelectionCannotPublishOrPersist() async {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.prepareGate = gate
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await gate.waitUntilEntered()
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        await gate.release()
        await model.waitUntilOperationFinishes()
        #expect(fixture.remembers == 0)
        #expect(fixture.appRequests == 0)
        #expect(model.apps.isEmpty)
        #expect(!model.busy)
    }

    @Test func redundantPairingDismissalDoesNotCancelAppList() async {
        let fixture = LauncherFixture()
        fixture.paired = false
        let gate = StreamTestGate()
        fixture.appGate = gate
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await gate.waitUntilEntered()
        #expect(model.pairing == nil)
        model.dismissPairing()
        await gate.release()
        await model.waitUntilOperationFinishes()
        #expect(model.apps.count == 1)
        #expect(fixture.remembers == 1)
    }

    @Test(arguments: [false, true])
    func cancelledPreparationCannotReplaceASecondPC(waitingForApps: Bool) async {
        let gate = StreamTestGate()
        let network = testLaunch().network
        let first = ServerInfo(address: "first.invalid", uniqueId: "first", serverName: "First PC")
        var second = first
        second.address = "second.invalid"
        second.uniqueId = "second"
        second.serverName = "Second PC"
        let saved = [SavedPC(server: first), SavedPC(server: second)]
        var remembered: [String] = []
        var requestedApps: [String] = []
        let model = LauncherModel(calls: .init(savedPCs: { saved }, prepare: { server, _ in
            if server.uniqueId == "first", !waitingForApps { await gate.wait() }
            var prepared = server
            prepared.pairStatus = .paired
            prepared.serverCertPEM = "test placeholder, never sent to a transport"
            return PreparedPC(network: network, server: prepared)
        }, pair: { pc, _ in
            Issue.record("Both fixtures are already paired.")
            return pc
        }, apps: { pc in
            requestedApps.append(pc.server.uniqueId)
            if pc.server.uniqueId == "first", waitingForApps { await gate.wait() }
            return [HostApp(id: pc.server.uniqueId == "first" ? 1 : 2, name: pc.server.serverName,
                            hdrCapable: false, hidden: false)]
        }, remember: { pc in
            remembered.append(pc.server.uniqueId)
            return saved
        }, protectedDataChanged: { _ in }), discoveryEnabled: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(saved[0])
        let replacement = Task { @MainActor in
            await gate.waitUntilEntered()
            #expect(model.busy)
            model.cancelOperation()
            #expect(model.busy == false && model.canForgetPC)
            model.select(saved[1])
            await model.waitUntilOperationFinishes()
            #expect(model.selectedName == "Second PC" && model.apps.map(\.id) == [2])
            await gate.release()
        }
        // No suspension follows select until this captures the first operation; replacement waits on its gate.
        await model.waitUntilOperationFinishes()
        await replacement.value
        #expect(model.busy == false && model.pairing == nil && model.message == nil)
        #expect(model.selectedName == "Second PC" && model.apps.map(\.id) == [2])
        #expect(remembered == ["second"])
        #expect(requestedApps == (waitingForApps ? ["first", "second"] : ["second"]))
    }

    @Test func cancelledPairingCannotPublishAppsOrRememberPC() async {
        let fixture = LauncherFixture()
        fixture.paired = false
        let gate = StreamTestGate()
        fixture.pairGate = gate
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await gate.waitUntilEntered()
        #expect(model.pairing?.pin.count == 4)
        model.cancelOperation()
        await gate.release()
        await model.waitUntilOperationFinishes()
        #expect(model.pairing == nil)
        #expect(fixture.remembers == 0)
        #expect(fixture.appRequests == 0)
    }

    @Test func pinStorageFailureDoesNotBeginPairing() async {
        let fixture = LauncherFixture()
        fixture.prepareFailure = LauncherServices.Failure.missingPin
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(fixture.pairs == 0)
        #expect(fixture.remembers == 0)
        #expect(model.pairing == nil)
        #expect(model.message != nil)
    }

    @Test func missingSavedPinFailsBeforeNetworkOrPairing() async throws {
        let fixture = LauncherFixture()
        let suiteName = "io.ugfugl.Glimmer.launcher-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let services = LauncherServices(defaults: defaults, base: base,
            protectedData: ProtectedDataState(true), deviceName: "Test device")
        await #expect(throws: LauncherServices.Failure.self) {
            try await services.prepare(server: fixture.saved.server, saved: true)
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Glimmer/Identity").path))
    }

    @Test func successfulPCPreferenceSurvivesServiceRecreation() throws {
        let fixture = LauncherFixture()
        let suiteName = "io.ugfugl.Glimmer.last-pc-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let protection = ProtectedDataState(true)
        let services = LauncherServices(defaults: defaults, base: base, protectedData: protection)
        #expect(services.lastConnectedPCID() == nil)
        try PinnedCertStore.store(pem: "test placeholder, never sent to a transport",
                                 forHostID: fixture.pcID, defaults: defaults, base: base,
                                 protectedDataAvailable: { true })
        _ = try services.remember(PreparedPC(network: testLaunch().network, server: fixture.server))
        let reopened = LauncherServices(defaults: defaults, base: base, protectedData: protection)
        #expect(reopened.lastConnectedPCID() == fixture.pcID)
        var unpaired = fixture.server
        unpaired.uniqueId = "unpaired"
        #expect(throws: LauncherServices.Failure.self) {
            try reopened.remember(PreparedPC(network: testLaunch().network, server: unpaired))
        }
        #expect(reopened.lastConnectedPCID() == fixture.pcID)
        protection.update(false)
        #expect(reopened.lastConnectedPCID() == nil)
    }

    @Test func protectedDataRequiredEvenForMetadata() throws {
        let defaults = try #require(UserDefaults(suiteName: "io.ugfugl.Glimmer.metadata-tests"))
        let services = LauncherServices(defaults: defaults, base: URL(fileURLWithPath: "/unused"),
            protectedData: ProtectedDataState(false), deviceName: "Test device")
        #expect(throws: LauncherServices.Failure.self) { try services.savedPCs() }
    }
}

@MainActor
final class LauncherFixture {
    let pcID = UUID().uuidString
    let app = HostApp(id: 1, name: "Game", hdrCapable: false, hidden: false)
    let hidden = HostApp(id: 2, name: "Hidden", hdrCapable: false, hidden: true)
    var artwork: @Sendable (PreparedPC, Int) async throws -> Data = { _, _ in Data() }
    var additionalPCs: [SavedPC] = []
    var lastConnectedID: String?
    var forgotten: Set<String> = []
    var forgetFailure: Error?
    var savedFailure: Error?
    var prepares = 0
    var pairs = 0
    var remembers = 0
    var appRequests = 0
    var makeSession: @MainActor (StreamLaunch) -> StreamSessionModel = { StreamSessionModel(launch: $0) }
    var runningAppID = 0
    var quitIDs: [Int] = []
    var paired = true
    var pairGate: StreamTestGate?
    var appGate: StreamTestGate?
    var prepareGate: StreamTestGate?
    var prepareFailure: Error?
    var preparedAddress: String?
    var preparedSaved: Bool?
    var server: ServerInfo {
        var server = ServerInfo(address: "pc.invalid", uniqueId: pcID, serverName: "Test PC")
        server.currentGameID = runningAppID
        server.pairStatus = paired ? .paired : .unpaired
        server.serverCertPEM = paired ? "test placeholder, never sent to a transport" : nil
        return server
    }
    var saved: SavedPC { SavedPC(server: server) }
    var storedPCs: [SavedPC] { (additionalPCs + [saved]).filter { !forgotten.contains($0.id) } }

    func model() -> LauncherModel {
        LauncherModel(calls: LauncherModel.Calls(savedPCs: { [self] in
            if let savedFailure { throw savedFailure }
            return storedPCs
        },
            prepare: { [self] server, saved in
                prepares += 1
                preparedAddress = server.address
                preparedSaved = saved
                if let prepareFailure { throw prepareFailure }
                await prepareGate?.wait()
                return PreparedPC(network: testLaunch().network, server: self.server)
            }, pair: { [self] pc, _ in
                pairs += 1
                await pairGate?.wait()
                var server = pc.server
                server.pairStatus = .paired
                server.serverCertPEM = "test placeholder, never sent to a transport"
                return PreparedPC(network: pc.network, server: server)
            }, apps: { [self] _ in
                appRequests += 1
                await appGate?.wait()
                return [app, hidden]
            }, remember: { [self] pc in
                remembers += 1
                lastConnectedID = pc.server.uniqueId
                forgotten.remove(pc.server.uniqueId)
                return storedPCs
            },
            protectedDataChanged: { _ in }, lastConnectedPCID: { [self] in lastConnectedID },
            forget: { [self] id in
                if let forgetFailure { throw forgetFailure }
                forgotten.insert(id)
                if lastConnectedID == id { lastConnectedID = nil }
                return storedPCs
            },
            artwork: artwork, status: { [self] _ in server }, quit: { [self] _, appID in
                quitIDs.append(appID)
                runningAppID = 0
            }, makeSession: makeSession),
            discoveryEnabled: false)
    }
}

@MainActor
func testLaunch() -> StreamLaunch {
    let server = ServerInfo(address: "pc.invalid", uniqueId: "test-pc", serverName: "Test PC")
    let identity = IdentityManager(defaultsSuite: "io.ugfugl.Glimmer.tests.unused",
                                   supportBase: URL(fileURLWithPath: "/unused"), protectedDataAvailable: { false })
    return StreamLaunch(network: NetworkClient(server: server, identity: identity, deviceName: "Test device"),
                        pcID: server.uniqueId, pcName: server.serverName, appID: 1, appName: "Test game")
}
