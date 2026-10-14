// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct LauncherTests {
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
        #expect(model.stream?.launch.appID == 1)
        #expect(fixture.prepares == 1)
        model.streamClosed()
        await model.waitUntilStreamClosed()
        model.launch(fixture.app)
        #expect(model.stream == nil)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        #expect(model.stream != nil)
        #expect(fixture.prepares == 2)
    }

    @Test func systemDismissalWaitsForTransportBeforeAnotherSelection() async {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.makeSession = { launch in
            StreamSessionModel(launch: launch, makePlayback: { _, _, _ in
                StreamPlayback(id: UUID(), connect: {}, stop: { await gate.wait() }, teardown: {},
                               screenChanged: {}, setHDR: { _ in })
            }, readIdleTimer: { false }, writeIdleTimer: { _ in })
        }
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        model.stream?.start(surface: StreamSurface())
        model.stream = nil
        model.streamClosed()
        await gate.waitUntilEntered()
        model.select(fixture.saved)
        model.launch(fixture.app)
        #expect(model.stream == nil)
        #expect(fixture.prepares == 1)
        await gate.release()
        await model.waitUntilStreamClosed()
        model.select(fixture.saved)
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

    @Test func protectedDataRequiredEvenForMetadata() throws {
        let defaults = try #require(UserDefaults(suiteName: "io.ugfugl.Glimmer.metadata-tests"))
        let services = LauncherServices(defaults: defaults, base: URL(fileURLWithPath: "/unused"),
            protectedData: ProtectedDataState(false), deviceName: "Test device")
        #expect(throws: LauncherServices.Failure.self) { try services.savedPCs() }
    }
}

@MainActor
private final class LauncherFixture {
    let app = HostApp(id: 1, name: "Game", hdrCapable: false, hidden: false)
    let hidden = HostApp(id: 2, name: "Hidden", hdrCapable: false, hidden: true)
    var prepares = 0
    var pairs = 0
    var remembers = 0
    var appRequests = 0
    var makeSession: @MainActor (StreamLaunch) -> StreamSessionModel = { StreamSessionModel(launch: $0) }
    var paired = true
    var pairGate: StreamTestGate?
    var appGate: StreamTestGate?
    var prepareGate: StreamTestGate?
    var prepareFailure: Error?
    var server: ServerInfo {
        var server = ServerInfo(address: "pc.invalid", uniqueId: "test-pc", serverName: "Test PC")
        server.pairStatus = paired ? .paired : .unpaired
        server.serverCertPEM = paired ? "test placeholder, never sent to a transport" : nil
        return server
    }
    var saved: SavedPC { SavedPC(server: server) }

    func model() -> LauncherModel {
        LauncherModel(calls: LauncherModel.Calls(savedPCs: { [self] in [saved] },
            prepare: { [self] _, _ in
                prepares += 1
                if let prepareFailure { throw prepareFailure }
                await prepareGate?.wait()
                return PreparedPC(network: testLaunch().network, server: server)
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
            }, remember: { [self] _ in remembers += 1; return [saved] },
            protectedDataChanged: { _ in }, makeSession: makeSession),
            discoveryEnabled: false)
    }
}
