// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Network
import os
import Testing
@testable import GlimmerEngine

struct PCCommunicationTests {
    @Test func unavailableIdentityDoesNotGenerateOrMigrate() async throws {
        let store = try Store()
        defer { store.remove() }
        store.defaults.set("existing-id", forKey: "uniqueid")
        let manager = IdentityManager(defaultsSuite: store.suite, supportBase: store.root,
                                      protectedDataAvailable: { false })
        await #expect(throws: IdentityStorageError.self) { try await manager.uniqueID() }
        #expect(store.defaults.string(forKey: "uniqueid") == "existing-id")
        #expect(store.defaults.integer(forKey: "glimmer.identityFileStorageVersion") == 0)
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    @Test func protectedDataRecoveryRetainsIdentity() async throws {
        let store = try Store()
        defer { store.remove() }
        let available = OSAllocatedUnfairLock(initialState: true)
        let manager = IdentityManager(defaultsSuite: store.suite, supportBase: store.root,
                                      protectedDataAvailable: { available.withLock { $0 } })
        let original = try await manager.uniqueID()
        let keyURL = store.root.appendingPathComponent("Glimmer/Identity/client-key.pem")
        let originalKey = try Data(contentsOf: keyURL)
        available.withLock { $0 = false }
        await #expect(throws: IdentityStorageError.self) { try await manager.uniqueID() }
        #expect(try Data(contentsOf: keyURL) == originalKey)
        available.withLock { $0 = true }
        #expect(try await manager.uniqueID() == original)
        let reloaded = IdentityManager(defaultsSuite: store.suite, supportBase: store.root,
                                       protectedDataAvailable: { true })
        #expect(try await reloaded.uniqueID() == original)
    }

    @Test func inaccessibleStorageDoesNotInvokeMigration() async throws {
        let store = try Store()
        defer { store.remove() }
        let migrated = OSAllocatedUnfairLock(initialState: false)
        let manager = IdentityManager(defaultsSuite: store.suite, storageRoot: {
            throw CocoaError(.fileReadNoPermission)
        }, migrateIdentity: { _ in
            migrated.withLock { $0 = true }
            return nil
        })
        await #expect(throws: CocoaError.self) { try await manager.uniqueID() }
        #expect(!migrated.withLock { $0 })
        #expect(store.defaults.integer(forKey: "glimmer.identityFileStorageVersion") == 0)
    }

    @Test func unavailableDefaultsDoesNotUseStandardOrTouchStorage() async throws {
        let store = try Store()
        defer { store.remove() }
        let root = store.root
        let suite = store.suite
        let manager = IdentityManager(defaultsSuite: suite, storageRoot: {
            Issue.record("An unavailable defaults suite must stop before storage access")
            return root
        }, migrateIdentity: { _ in
            Issue.record("An unavailable defaults suite must not migrate an identity")
            return nil
        }, makeDefaults: { requested in
            #expect(requested == suite)
            return nil
        })
        await #expect(throws: IdentityStorageError.defaultsUnavailable) { try await manager.uniqueID() }
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    @Test func unavailablePinStorePreservesSavedAndLegacyPins() throws {
        let store = try Store()
        defer { store.remove() }
        try PinnedCertStore.storeAvailable(pem: "saved-pin", forHostID: "pc",
                                          defaults: store.defaults, base: store.root)
        store.defaults.set("legacy-pin", forKey: "glimmer.pinnedCert.pc")
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.loadAvailable(forHostID: "pc", defaults: store.defaults,
                                             base: store.root, protectedDataAvailable: { false })
        }
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.storeAvailable(pem: "replacement", forHostID: "pc", defaults: store.defaults,
                                              base: store.root, protectedDataAvailable: { false })
        }
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.deleteAvailable(forHostID: "pc", defaults: store.defaults,
                                               base: store.root, protectedDataAvailable: { false })
        }
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.pc") == "legacy-pin")
        #expect(try PinnedCertStore.loadAvailable(forHostID: "pc", defaults: store.defaults,
                                                base: store.root) == "saved-pin")
    }

    @Test func deniedDiscoveryPublishesPermissionFailure() async throws {
        let discovery = HostDiscovery()
        let browsing = await discovery.start(startBrowser: { browser in
            browser.stateUpdateHandler?(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        })
        let update = try await StreamAttempt.run(until: Date().addingTimeInterval(2)) {
            var iterator = browsing.stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(update?.denied == true)
        #expect(update?.hosts.isEmpty == true)
        await discovery.stop(run: browsing.run)
    }

    @Test func obsoleteDiscoveryRunCannotStopReplacement() async throws {
        let discovery = HostDiscovery()
        let first = await discovery.start(startBrowser: { _ in })
        let second = await discovery.start(startBrowser: { _ in })
        await discovery.stop(run: first.run)
        await discovery.recordResolved(.init(id: "pc", displayName: "PC", host: "192.0.2.1", port: 47989))
        let update = try await StreamAttempt.run(until: Date().addingTimeInterval(2)) {
            var iterator = second.stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(update?.hosts.first?.id == "pc")
        await discovery.stop(run: second.run)
    }

    @Test func unpairedPollMakesOneRequestAndDoesNotPin() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let server = ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "PC")
        let transport: ControlTransport.Get = { _, _, target, _, tls, credential, _ in
            calls.withLock { $0 += 1 }
            #expect(!tls)
            #expect(credential.pinnedCertPEM == nil)
            #expect(target.contains("uniqueid=stable-id"))
            return .init(status: 200, body: Data("""
                <root status_code="200"><uniqueid>pc</uniqueid><hostname>PC</hostname>
                <PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state><currentgame>0</currentgame></root>
                """.utf8))
        }
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let client = NetworkClient(server: server, deviceName: {
            lookups.withLock { $0 += 1 }
            return "Test client"
        }, transport: transport,
                                   identity: { ("", "", "stable-id") })
        let info = try await client.fetchServerInfo()
        #expect(info.uniqueId == "pc")
        #expect(info.pairStatus == .unpaired)
        #expect(info.serverCertPEM == nil)
        #expect(HostReadiness.isReadyForStream(info))
        #expect(calls.withLock { $0 } == 1)
        #expect(lookups.withLock { $0 } == 0)
    }

    @Test func wakePacketRetainsWireLayout() throws {
        let packet = try #require(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:ab"))
        #expect(packet.count == 102)
        #expect(packet.prefix(6) == Data(repeating: 255, count: 6))
        for index in 0..<16 {
            #expect(packet[(6 + index * 6)..<(12 + index * 6)] == Data([1, 35, 69, 103, 137, 171]))
        }
    }

    @Test func publicPinStorageRequiresAvailabilityAndKeepsSavedPin() throws {
        let store = try Store()
        defer { store.remove() }
        try PinnedCertStore.store(pem: "saved-pin", forHostID: "pc", defaults: store.defaults,
                                  base: store.root, protectedDataAvailable: { true })
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                     base: store.root, protectedDataAvailable: { false })
        }
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.store(pem: "replacement", forHostID: "pc", defaults: store.defaults,
                                      base: store.root, protectedDataAvailable: { false })
        }
        #expect(throws: IdentityStorageError.self) {
            try PinnedCertStore.delete(forHostID: "pc", defaults: store.defaults,
                                       base: store.root, protectedDataAvailable: { false })
        }
        #expect(try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                        base: store.root, protectedDataAvailable: { true }) == "saved-pin")
    }

    @Test func publicPinStorageDistinguishesMissingFromUnreadable() throws {
        let store = try Store()
        defer { store.remove() }
        #expect(try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                        base: store.root, protectedDataAvailable: { true }) == nil)
        try PinnedCertStore.store(pem: "saved-pin", forHostID: "pc", defaults: store.defaults,
                                  base: store.root, protectedDataAvailable: { true })
        let pin = store.root.appendingPathComponent("Glimmer/PinnedHosts/pc.pem")
        try Data([0xFF]).write(to: pin)
        store.defaults.set("legacy-pin", forKey: "glimmer.pinnedCert.pc")
        #expect(throws: StreamError.self) {
            try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                     base: store.root, protectedDataAvailable: { true })
        }
        #expect(try Data(contentsOf: pin) == Data([0xFF]))
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.pc") == "legacy-pin")
    }

    @Test func publicPinStorageReportsReadFailureWithoutReplacingIt() throws {
        let store = try Store()
        defer { store.remove() }
        let pin = store.root.appendingPathComponent("Glimmer/PinnedHosts/pc.pem", isDirectory: true)
        try FileManager.default.createDirectory(at: pin, withIntermediateDirectories: true)
        store.defaults.set("legacy-pin", forKey: "glimmer.pinnedCert.pc")
        #expect(throws: (any Error).self) {
            try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                     base: store.root, protectedDataAvailable: { true })
        }
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.pc") == "legacy-pin")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pin.path).isEmpty)
    }

    @Test func publicPinStorageReportsDeletionFailureAndKeepsLegacyPin() throws {
        let store = try Store()
        defer { store.remove() }
        try PinnedCertStore.store(pem: "saved-pin", forHostID: "pc", defaults: store.defaults,
                                  base: store.root, protectedDataAvailable: { true })
        store.defaults.set("legacy-pin", forKey: "glimmer.pinnedCert.pc")
        let directory = store.root.appendingPathComponent("Glimmer/PinnedHosts", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) {
            try PinnedCertStore.delete(forHostID: "pc", defaults: store.defaults,
                                       base: store.root, protectedDataAvailable: { true })
        }
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.pc") == "legacy-pin")
        #expect(try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                        base: store.root, protectedDataAvailable: { true }) == "saved-pin")
    }

    @Test func publicPinStorageMigratesAndDeletesBothStores() throws {
        let store = try Store()
        defer { store.remove() }
        store.defaults.set("legacy-pin", forKey: "glimmer.pinnedCert.pc")
        #expect(try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                        base: store.root, protectedDataAvailable: { true }) == "legacy-pin")
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.pc") == nil)
        store.defaults.set("stale-pin", forKey: "glimmer.pinnedCert.pc")
        try PinnedCertStore.delete(forHostID: "pc", defaults: store.defaults,
                                   base: store.root, protectedDataAvailable: { true })
        try PinnedCertStore.delete(forHostID: "pc", defaults: store.defaults,
                                   base: store.root, protectedDataAvailable: { true })
        #expect(try PinnedCertStore.load(forHostID: "pc", defaults: store.defaults,
                                        base: store.root, protectedDataAvailable: { true }) == nil)
    }

    private struct Store {
        let suite: String
        let defaults: UserDefaults
        let root: URL

        init() throws {
            suite = "io.ugfugl.Glimmer.tests.engine-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
