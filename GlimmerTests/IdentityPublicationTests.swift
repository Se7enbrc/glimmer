// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Synchronization
import Testing

struct IdentityPublicationTests {
    enum StoreState: CaseIterable, Sendable {
        case absent, empty, stagingOnly, complete, missingCert, missingKey, missingID, invalid, unrelated

        var permitsCreation: Bool { self == .absent || self == .empty || self == .stagingOnly }
        var permitsLoad: Bool { permitsCreation || self == .complete }
    }

    @Test(arguments: StoreState.allCases, [false, true])
    func storeStatesPreserveEstablishedBytes(state: StoreState, migrating: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = try await fixture.manager().generateKeyPairAndCert()
        let identity = IdentityManager.Identity(uniqueID: "ESTABLISHED", certPEM: pair.certPEM, keyPEM: pair.keyPEM)
        try fixture.prepare(state, identity: identity)
        let before = try fixture.snapshot()
        if migrating {
            fixture.defaults.set(pair.certPEM, forKey: IdentityKey.certificate)
            fixture.defaults.set(pair.keyPEM, forKey: IdentityKey.privateKey)
            fixture.defaults.set("LEGACY", forKey: IdentityKey.uniqueID)
        }
        let creations = Mutex(0)
        let manager = fixture.manager { _ in creations.withLock { $0 += 1 }; return nil }
        if state.permitsLoad {
            let loaded = try await manager.load()
            _ = try PEM.identity(certPEM: loaded.certPEM, keyPEM: loaded.keyPEM)
            if state == .complete { #expect(loaded.uniqueID == "ESTABLISHED") }
            if migrating && state.permitsCreation { #expect(loaded.uniqueID == "LEGACY") }
            let published = try fixture.snapshot()
            let next = try await fixture.manager().load()
            let reloaded = try fixture.snapshot()
            let stable = loaded.uniqueID == next.uniqueID && loaded.certPEM == next.certPEM
                && loaded.keyPEM == next.keyPEM && published == reloaded
            #expect(stable)
        } else {
            await #expect(throws: (any Error).self) { _ = try await manager.uniqueID() }
        }
        #expect(creations.withLock { $0 } == (state.permitsCreation && !migrating ? 1 : 0))
        if !state.permitsCreation {
            let preserved = try fixture.snapshot() == before
            #expect(preserved)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    @Test(arguments: [false, true])
    func failedPublicationRemovesItsStagingImmediately(renameFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = try await fixture.manager().generateKeyPairAndCert()
        let identity = IdentityManager.Identity(uniqueID: "NEW", certPEM: pair.certPEM, keyPEM: pair.keyPEM)
        var reachedKey = false
        let failure = #expect(throws: (any Error).self) {
            try FileIdentityStore.withExclusiveAccess(base: fixture.root) {
                try FileIdentityStore.publish(identity, base: fixture.root) {
                    reachedKey = true
                    #expect(FileManager.default.fileExists(atPath:
                        fixture.staging.appendingPathComponent(FileIdentityStore.keyFileName).path))
                    if renameFails {
                        try fixture.prepare(.unrelated, identity: identity)
                    } else {
                        throw PublicationFailure.injected
                    }
                }
            }
        }
        #expect((failure is PublicationFailure) == !renameFails)
        #expect(reachedKey)
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        let expected = renameFails ? ["unrelated": Data("KEEP".utf8)] : [:]
        let preserved = try fixture.snapshot() == expected
        #expect(preserved)
    }

    @Test func concurrentLoadsPublishExactlyOneIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let creations = Mutex(0)
        let first = fixture.manager { _ in creations.withLock { $0 += 1 }; return nil }
        let second = fixture.manager { _ in creations.withLock { $0 += 1 }; return nil }
        let gate = LoadGate()
        async let left = load(first, after: gate)
        async let right = load(second, after: gate)
        let (one, two) = try await (left, right)
        let same = one.uniqueID == two.uniqueID && one.certPEM == two.certPEM && one.keyPEM == two.keyPEM
        #expect(same)
        #expect(creations.withLock { $0 } == 1)
        let next = try await fixture.manager().load()
        let stable = next.uniqueID == one.uniqueID && next.certPEM == one.certPEM && next.keyPEM == one.keyPEM
        #expect(stable)
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    private func load(_ manager: IdentityManager, after gate: LoadGate) async throws -> IdentityManager.Identity {
        await gate.arrive()
        return try await manager.load()
    }

    private enum PublicationFailure: Error { case injected }

    private actor LoadGate {
        var first: CheckedContinuation<Void, Never>?
        func arrive() async {
            await withCheckedContinuation { continuation in
                if let first { first.resume(); continuation.resume() } else { first = continuation }
            }
        }
    }

    private struct Fixture {
        let root = URL.temporaryDirectory.appendingPathComponent("identity-publication-" + UUID().uuidString)
        let suite = "identity-publication-" + UUID().uuidString
        let defaults: UserDefaults
        var destination: URL { root.appendingPathComponent("Glimmer/Identity") }
        var staging: URL { root.appendingPathComponent("Glimmer/.identity-staging") }

        init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }

        func manager(migrate: @escaping @Sendable (String?) throws -> IdentityManager.AdoptedQtIdentity? = { _ in nil })
            -> IdentityManager {
            let root = root
            return IdentityManager(defaultsSuite: suite, storageRoot: { root }, migrateIdentity: migrate)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func prepare(_ state: StoreState, identity: IdentityManager.Identity) throws {
            if state == .absent { return }
            let directory = state == .stagingOnly ? staging : destination
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if state == .empty { return }
            if state == .unrelated {
                try Data("KEEP".utf8).write(to: directory.appendingPathComponent("unrelated"))
                return
            }
            let components = [
                (FileIdentityStore.certFileName, state == .invalid ? "invalid" : identity.certPEM, StoreState.missingCert),
                (FileIdentityStore.keyFileName, identity.keyPEM, StoreState.missingKey),
                (FileIdentityStore.uidFileName, identity.uniqueID, StoreState.missingID)
            ]
            for (name, value, missing) in components where state != missing {
                try Data(value.utf8).write(to: directory.appendingPathComponent(name))
            }
        }

        func snapshot() throws -> [String: Data] {
            guard FileManager.default.fileExists(atPath: destination.path) else { return [:] }
            let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
    }
}
