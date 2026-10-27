// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct PairingRecoveryTests {
    @Test func changedLANAddressReconnectsWithoutPairingAndSavesOnce() async {
        var server = ServerInfo(address: "192.168.1.20", uniqueId: "saved-pc", serverName: "Den PC")
        server.pairStatus = .paired
        server.serverCertPEM = "test pin, never sent to a transport"
        let saved = SavedPC(server: server)
        var attempts: [String] = []
        var remembers = 0
        var pairs = 0
        let pinned = server
        let network = testLaunch().network
        let calls = LauncherModel.Calls(savedPCs: { [saved] }, prepare: { candidate, saved in
            try await LauncherServices.prepareRecovering(server: candidate, saved: saved, prepare: { value, _ in
                attempts.append(value.address)
                if value.address == pinned.address { throw StreamError.hostUnreachable("test") }
                return PreparedPC(network: network, server: value)
            }, recover: { original in
                #expect(original.uniqueId == pinned.uniqueId)
                var moved = pinned
                moved.address = "192.168.1.30"
                return moved
            })
        }, pair: { pc, _ in pairs += 1; return pc }, apps: { _ in [] }, remember: { pc in
            remembers += 1
            #expect(pc.server.serverCertPEM == pinned.serverCertPEM)
            return [SavedPC(server: pc.server)]
        }, protectedDataChanged: { _ in })
        let model = LauncherModel(calls: calls, discoveryEnabled: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(saved)
        await model.waitUntilOperationFinishes()
        #expect(model.message == nil)
        #expect(attempts == ["192.168.1.20", "192.168.1.30"])
        #expect(model.savedPCs.first?.address == "192.168.1.30")
        #expect(remembers == 1 && pairs == 0)
    }

    @Test(arguments: ["tower.local", "100.64.1.2", "203.0.113.2"])
    func stableRoutesNeverInvokeRecovery(address: String) async {
        let server = ServerInfo(address: address, uniqueId: "pc", serverName: "Den PC")
        do {
            _ = try await LauncherServices.prepareRecovering(server: server, saved: true,
                prepare: { _, _ in throw StreamError.hostUnreachable("test") }, recover: { _ in
                    Issue.record("An explicit stable route must not be replaced")
                    return nil
                })
            Issue.record("The original failure must reach the launcher")
        } catch {}
    }

    @Test func certificateFailureNeverInvokesRecovery() async {
        let server = ServerInfo(address: "192.168.1.20", uniqueId: "pc", serverName: "Den PC")
        do {
            _ = try await LauncherServices.prepareRecovering(server: server, saved: true,
                prepare: { _, _ in throw StreamError.hostCertChanged("test") }, recover: { _ in
                    Issue.record("Certificate failure cannot authorize an address change")
                    return nil
                })
            Issue.record("The certificate failure must reach the launcher")
        } catch {}
    }

    @Test func protectedDataTransitionDoesNotLeaveAnUnlockMessage() {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        fixture.savedFailure = LauncherServices.Failure.unavailable
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: false)
        fixture.savedFailure = nil
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(model.message == nil)
        #expect(model.savedPCs.count == 1)
    }

    @Test func onlyProtectedDataFailuresAskForUnlock() {
        #expect(LauncherFailureCopy.message(IdentityStorageError.unavailable).contains("Unlock"))
        #expect(LauncherFailureCopy.message(LauncherServices.Failure.unavailable).contains("Unlock"))
        #expect(!LauncherFailureCopy.message(IdentityStorageError.defaultsUnavailable).contains("Unlock"))
        #expect(!LauncherFailureCopy.message(LauncherServices.Failure.invalidIdentity).contains("Unlock"))
    }

    @Test func storageRecoveryDistinguishesLockFromIOAndNamesThePC() {
        let message = LauncherFailureCopy.storageMessage(CocoaError(.fileWriteNoPermission), action: "forget Den PC")
        #expect(message == "Glimmer couldn't forget Den PC. Close the app and try again.")
        #expect(LauncherFailureCopy.message(LauncherServices.Failure.invalidIdentity,
                                            pcName: "Den PC").contains("Den PC"))
    }

    @Test func confirmationAndCancelDoNotForgetThePC() {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.requestForget(fixture.saved)
        #expect(model.pendingForget?.id == fixture.pcID)
        #expect(fixture.forgotten.isEmpty && model.savedPCs.count == 1)
        model.cancelForget()
        #expect(model.pendingForget == nil)
        #expect(fixture.forgotten.isEmpty && model.savedPCs.count == 1)
    }

    @Test func forgettingSelectedPCClearsLaunchStateAndAllowsFreshPairing() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.requestForget(fixture.saved)
        model.confirmForget(fixture.saved)
        #expect(model.pendingForget == nil && model.forgetFailure == nil)
        #expect(model.savedPCs.isEmpty && model.apps.isEmpty && model.selectedName == nil)
        #expect(model.artworkRevision == nil && fixture.lastConnectedID == nil)
        model.launch(fixture.app)
        model.selectInitialPCIfNeeded()
        #expect(model.stream == nil && fixture.prepares == 1)
        fixture.paired = false
        model.select(address: fixture.saved.address)
        await model.waitUntilOperationFinishes()
        #expect(fixture.preparedSaved == false && fixture.pairs == 1)
        #expect(model.savedPCs.count == 1 && model.apps.count == 1)
    }

    @Test func forgettingAnotherPCPreservesTheSelectedPC() async {
        let fixture = LauncherFixture()
        let other = SavedPC(server: ServerInfo(address: "other.invalid", uniqueId: "other", serverName: "Other PC"))
        fixture.additionalPCs = [other]
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        let revision = model.artworkRevision
        model.requestForget(other)
        model.confirmForget(other)
        #expect(model.savedPCs.map(\.id) == [fixture.pcID])
        #expect(model.selectedName == fixture.saved.name && model.apps.count == 1)
        #expect(model.artworkRevision == revision && fixture.lastConnectedID == fixture.pcID)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream != nil)
    }

    @Test func storageFailureKeepsPCAndSelectionForRetry() async {
        let fixture = LauncherFixture()
        fixture.forgetFailure = LauncherServices.Failure.unavailable
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.requestForget(fixture.saved)
        model.confirmForget(fixture.saved)
        #expect(model.pendingForget == nil && model.forgetFailure != nil)
        #expect(model.savedPCs.count == 1 && model.apps.count == 1)
        #expect(model.selectedName == fixture.saved.name && fixture.forgotten.isEmpty)
        fixture.forgetFailure = nil
        model.requestForget(fixture.saved)
        #expect(model.forgetFailure == nil)
        model.confirmForget(fixture.saved)
        #expect(model.savedPCs.isEmpty)
    }

    @Test func backgroundDismissesConfirmationAndRejectsDeletion() {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.requestForget(fixture.saved)
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: false)
        #expect(model.pendingForget == nil && !model.canForgetPC)
        model.confirmForget(fixture.saved)
        #expect(fixture.forgotten.isEmpty)
    }

    @Test func busySelectionAndActiveStreamRejectDeletion() async {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.prepareGate = gate
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await gate.waitUntilEntered()
        model.requestForget(fixture.saved)
        model.confirmForget(fixture.saved)
        #expect(!model.canForgetPC && fixture.forgotten.isEmpty && model.pendingForget == nil)
        await gate.release()
        await model.waitUntilOperationFinishes()
        model.requestForget(fixture.saved)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        model.confirmForget(fixture.saved)
        #expect(!model.canForgetPC && fixture.forgotten.isEmpty && model.stream != nil)
    }

    @Test func failedPinnedConnectionCanBeForgottenWithoutAutomaticPairing() async {
        let fixture = LauncherFixture()
        fixture.prepareFailure = StreamError.hostCertChanged("Test PC")
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(fixture.pairs == 0 && model.message != nil && model.savedPCs.count == 1)
        model.requestForget(fixture.saved)
        model.confirmForget(fixture.saved)
        #expect(model.message == nil && model.selectedName == nil && model.savedPCs.isEmpty)
        #expect(fixture.pairs == 0)
    }

    @Test func deletionRemovesOnlyChosenPinAndRememberedSelection() throws {
        try withStorage { services, defaults, base, _ in
            let remaining = try services.forget("second")
            #expect(remaining.map(\.id) == ["first"])
            #expect(services.lastConnectedPCID() == nil)
            #expect(try PinnedCertStore.load(forHostID: "second", defaults: defaults, base: base,
                                            protectedDataAvailable: { true }) == nil)
            #expect(try PinnedCertStore.load(forHostID: "first", defaults: defaults, base: base,
                                            protectedDataAvailable: { true }) == "test pin first")
            let reopened = LauncherServices(defaults: defaults, base: base, protectedData: ProtectedDataState(true))
            #expect(try reopened.savedPCs().map(\.id) == ["first"])
            #expect(reopened.lastConnectedPCID() == nil)
        }
    }

    @Test func deletingOtherPCPreservesLastConnectedAndMissingPinIsRecoverable() throws {
        try withStorage { services, defaults, base, _ in
            try PinnedCertStore.delete(forHostID: "first", defaults: defaults, base: base,
                                       protectedDataAvailable: { true })
            #expect(try services.forget("first").map(\.id) == ["second"])
            #expect(services.lastConnectedPCID() == "second")
            #expect(try services.forget("first").count == 1)
        }
    }

    @Test func unavailableStorageRetainsSavedPCsAndPins() throws {
        try withStorage { services, defaults, base, protection in
            protection.update(false)
            #expect(throws: LauncherServices.Failure.self) { try services.forget("second") }
            protection.update(true)
            let saved = try services.savedPCs()
            let pin = try PinnedCertStore.load(forHostID: "second", defaults: defaults, base: base,
                                               protectedDataAvailable: { true })
            #expect(saved.count == 2 && services.lastConnectedPCID() == "second")
            #expect(pin == "test pin second")
        }
    }

    @Test func pinDeletionFailureRetainsSavedMetadata() throws {
        try withStorage { services, defaults, base, _ in
            let directory = base.appendingPathComponent("Glimmer/PinnedHosts", isDirectory: true)
            try FileManager.default.removeItem(at: directory)
            try Data("not a directory".utf8).write(to: directory)
            #expect(throws: (any Error).self) { try services.forget("second") }
            #expect(try services.savedPCs().count == 2 && services.lastConnectedPCID() == "second")
            #expect(defaults.data(forKey: "ios.savedPCs") != nil)
        }
    }

    @Test(arguments: [false, true])
    func acceptedPairingSurvivesAppListFailureOrCancellation(cancel: Bool) async throws {
        let suite = "io.ugfugl.Glimmer.pairing-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        let services = LauncherServices(defaults: defaults, base: base, protectedData: ProtectedDataState(true))
        var server = ServerInfo(address: "new.invalid", uniqueId: "new", serverName: "New PC")
        let unpaired = PreparedPC(network: testLaunch().network, server: server)
        server.pairStatus = .paired
        server.serverCertPEM = "authenticated fixture pin"
        let pairedServer = server
        let gate = StreamTestGate()
        let model = LauncherModel(calls: .init(
            savedPCs: { try services.savedPCs() }, prepare: { _, _ in unpaired },
            pair: { pc, pin in try await services.pair(pc, pin: pin, authenticate: { _, _ in pairedServer }) },
            apps: { _ in await gate.wait(); throw StreamError.hostUnreachable("fixture failure") },
            remember: { try services.remember($0) }, protectedDataChanged: { services.protectedData.update($0) },
            forget: { try services.forget($0) }), discoveryEnabled: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(address: "new.invalid")
        await gate.waitUntilEntered()
        #expect(model.savedPCs.map(\.id) == ["new"])
        if cancel { model.cancelOperation() }
        await gate.release()
        await model.waitUntilOperationFinishes()
        #expect(model.savedPCs.map(\.id) == ["new"])
        #expect(services.lastConnectedPCID() == nil)
        let reopened = LauncherServices(defaults: defaults, base: base, protectedData: ProtectedDataState(true))
        #expect(try reopened.savedPCs().map(\.id) == ["new"])
        let other = PreparedPC(network: unpaired.network, server: {
            var value = pairedServer
            value.uniqueId = "other"
            return value
        }())
        _ = try await reopened.pair(other, pin: "0000", authenticate: { pc, _ in pc.server })
        let saved = try #require(model.savedPCs.first)
        model.confirmForget(saved)
        #expect(try reopened.savedPCs().map(\.id) == ["other"])
        #expect(try PinnedCertStore.load(forHostID: "new", defaults: defaults, base: base,
                                        protectedDataAvailable: { true }) == nil)
        #expect(try PinnedCertStore.load(forHostID: "other", defaults: defaults, base: base,
                                        protectedDataAvailable: { true }) == pairedServer.serverCertPEM)
    }

    @Test func invalidRecoveryMetadataPreventsPinInstallation() async throws {
        let suite = "io.ugfugl.Glimmer.pairing-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        defaults.set(Data("invalid".utf8), forKey: "ios.savedPCs")
        let services = LauncherServices(defaults: defaults, base: base, protectedData: ProtectedDataState(true))
        var server = ServerInfo(address: "new.invalid", uniqueId: "new", serverName: "New PC")
        server.pairStatus = .paired
        server.serverCertPEM = "authenticated fixture pin"
        let pc = PreparedPC(network: testLaunch().network, server: server)
        await #expect(throws: (any Error).self) {
            try await services.pair(pc, pin: "0000", authenticate: { pc, _ in pc.server })
        }
        #expect(try PinnedCertStore.load(forHostID: "new", defaults: defaults, base: base,
                                        protectedDataAvailable: { true }) == nil)
    }

    private func withStorage(_ body: (LauncherServices, UserDefaults, URL, ProtectedDataState) throws -> Void) throws {
        let suite = "io.ugfugl.Glimmer.forget-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        let protection = ProtectedDataState(true)
        let services = LauncherServices(defaults: defaults, base: base, protectedData: protection)
        for id in ["first", "second"] {
            var server = ServerInfo(address: "\(id).invalid", uniqueId: id, serverName: id)
            server.pairStatus = .paired
            try PinnedCertStore.store(pem: "test pin \(id)", forHostID: id, defaults: defaults, base: base,
                                     protectedDataAvailable: { true })
            _ = try services.remember(PreparedPC(network: testLaunch().network, server: server))
        }
        try body(services, defaults, base, protection)
    }
}
