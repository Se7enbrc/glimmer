// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StoragePersistenceTests.swift
//
//  Identity, pinned certificates, the sandbox-container rescue, session receipts, the audio
//  cushion memory and the frame trace file, each on a scratch suite and temp directory.
//

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

struct IdentityPersistenceTests {

    /// Each manager owns only its fixture files and named preferences.
    private func manager(_ store: IsolatedStore, qt: String? = nil) -> IdentityManager {
        IdentityManager(defaultsSuite: store.domain, supportBase: store.directory,
                        moonlightQtSuite: qt ?? "io.ugfugl.Glimmer.tests.persistence-qt-none")
    }

    private func identityFile(_ store: IsolatedStore, _ name: String) -> URL {
        store.directory.appendingPathComponent("Glimmer/Identity/\(name)")
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.posixPermissions] as? Int) & 0o777
    }

    @Test(arguments: [false, true])
    func interruptedFirstPublicationCanRetry(migrating: Bool) async throws {
        let store = try IsolatedStore("id-interrupted-first")
        defer { store.remove() }
        let pair = try await manager(store).generateKeyPairAndCert()
        // Simulate termination after the first component was published, before caching or setting the flag.
        try FileIdentityStore.write(Data(pair.certPEM.utf8), account: IdentityManager.accountCert,
                                    base: store.directory)
        if migrating {
            store.defaults.set(pair.certPEM, forKey: IdentityKey.certificate)
            store.defaults.set(pair.keyPEM, forKey: IdentityKey.privateKey)
            store.defaults.set("MIGRATED", forKey: IdentityKey.uniqueID)
        }
        let retry = manager(store)
        let certificate = try await retry.clientCertPEM()
        let key = try await retry.clientKeyPEM()
        _ = try PEM.identity(certPEM: certificate, keyPEM: key)
        let uniqueID = try await retry.uniqueID()
        if migrating {
            #expect(certificate == pair.certPEM && key == pair.keyPEM && uniqueID == "MIGRATED")
        }
        let next = manager(store)
        #expect(try await next.clientCertPEM() == certificate)
        #expect(try await next.uniqueID() == uniqueID)
    }

    @Test func filesSurviveMissingMigrationFlagAndConflictingDefaults() async throws {
        let store = try IsolatedStore("id-missing-flag")
        defer { store.remove() }
        let first = manager(store)
        let cert = try await first.clientCertPEM()
        let key = try await first.clientKeyPEM()
        let uid = try await first.uniqueID()
        store.defaults.removeObject(forKey: IdentityManager.fileStorageFlag)
        store.defaults.set("stale-id", forKey: IdentityKey.uniqueID)
        let second = manager(store)
        #expect(try await second.clientCertPEM() == cert)
        #expect(try await second.clientKeyPEM() == key)
        #expect(try await second.uniqueID() == uid)
    }

    @Test func fileStoreCannotReplaceExistingIdentity() async throws {
        let store = try IsolatedStore("id-no-replacement")
        defer { store.remove() }
        let cert = try await manager(store).clientCertPEM()
        #expect(throws: (any Error).self) {
            try FileIdentityStore.write(Data("replacement".utf8), account: IdentityManager.accountCert,
                                        base: store.directory)
        }
        #expect(try await manager(store).clientCertPEM() == cert)
    }

    @Test func aFreshInstallGeneratesAndKeepsOneIdentity() async throws {
        let store = try IsolatedStore("id-fresh")
        defer { store.remove() }
        let first = manager(store)
        let uid = try await first.uniqueID()
        let cert = try await first.clientCertPEM()
        #expect(uid.count == 32)
        #expect(try mode(identityFile(store, "client-key.pem")) == 0o600)
        #expect(store.defaults.integer(forKey: IdentityManager.fileStorageFlag) == 1)
        let second = manager(store)
        #expect(try await second.uniqueID() == uid)
        #expect(try await second.clientCertPEM() == cert)
    }

    @Test func plaintextDefaultsMoveToFilesAndAreWiped() async throws {
        let store = try IsolatedStore("id-plaintext")
        defer { store.remove() }
        let pair = try await IdentityManager.shared.generateKeyPairAndCert()
        store.defaults.set(pair.certPEM, forKey: IdentityKey.certificate)
        store.defaults.set(pair.keyPEM, forKey: IdentityKey.privateKey)
        store.defaults.set("OLDUID", forKey: IdentityKey.uniqueID)
        let loaded = manager(store)
        #expect(try await loaded.uniqueID() == "OLDUID")
        #expect(try await loaded.clientKeyPEM() == pair.keyPEM)
        #expect(store.defaults.string(forKey: IdentityKey.privateKey) == nil)
        #expect(store.defaults.string(forKey: IdentityKey.uniqueID) == nil)
        let onDisk = try String(contentsOf: identityFile(store, "client-uniqueid.txt"), encoding: .utf8)
        #expect(onDisk == "OLDUID")
    }

    @Test func moonlightQtIdentityIsCopiedAndTheSourceLeftAlone() async throws {
        let store = try IsolatedStore("id-qt")
        let qt = try IsolatedStore("id-qt-source")
        defer { store.remove(); qt.remove() }
        let pair = try await IdentityManager.shared.generateKeyPairAndCert()
        qt.defaults.set(Data(pair.certPEM.utf8), forKey: "certificate")
        qt.defaults.set(Data(pair.keyPEM.utf8), forKey: "key")
        qt.defaults.set("QTUID", forKey: "uniqueid")
        let loaded = manager(store, qt: qt.domain)
        #expect(try await loaded.clientCertPEM() == pair.certPEM)
        #expect(try await loaded.uniqueID() == "QTUID")
        #expect(qt.defaults.data(forKey: "key") != nil)
        #expect(qt.defaults.string(forKey: "uniqueid") == "QTUID")
    }

    @Test func aMissingUniqueIDFileIsSynthesisedAndStaysStable() async throws {
        let store = try IsolatedStore("id-uid")
        defer { store.remove() }
        _ = try await manager(store).uniqueID()
        try FileManager.default.removeItem(at: identityFile(store, "client-uniqueid.txt"))
        let repaired = try await manager(store).uniqueID()
        #expect(repaired.count == 32)
        #expect(try await manager(store).uniqueID() == repaired)
    }

    @Test func aWipedFileStoreWithTheFlagSetRegenerates() async throws {
        let store = try IsolatedStore("id-wiped")
        defer { store.remove() }
        let before = try await manager(store).clientCertPEM()
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("Glimmer"))
        let after = try await manager(store).clientCertPEM()
        #expect(after != before)
        #expect(FileManager.default.fileExists(atPath: identityFile(store, "client-cert.pem").path))
    }

    @Test func aCorruptCertificateFileCanRecover() async throws {
        let store = try IsolatedStore("id-corrupt")
        defer { store.remove() }
        _ = try await manager(store).uniqueID()
        try Data("not a pem".utf8).write(to: identityFile(store, "client-cert.pem"))
        let recovered = manager(store)
        _ = try PEM.identity(certPEM: await recovered.clientCertPEM(), keyPEM: await recovered.clientKeyPEM())
    }

    @Test(arguments: ["client-cert.pem", "client-key.pem"])
    func incompleteIdentityCanRecoverWithoutBlockingPairing(missing: String) async throws {
        let store = try IsolatedStore("id-partial")
        defer { store.remove() }
        _ = try await manager(store).uniqueID()
        let remaining = missing == "client-cert.pem" ? "client-key.pem" : "client-cert.pem"
        let original = try Data(contentsOf: identityFile(store, remaining))
        try FileManager.default.removeItem(at: identityFile(store, missing))
        let recovered = manager(store)
        _ = try PEM.identity(certPEM: await recovered.clientCertPEM(), keyPEM: await recovered.clientKeyPEM())
        #expect(try Data(contentsOf: identityFile(store, remaining)) != original)
        #expect(FileManager.default.fileExists(atPath: identityFile(store, missing).path))
    }

    @Test func theFileStoreRefusesUnknownAccountsAndDeletesIdempotently() throws {
        let store = try IsolatedStore("id-filestore")
        defer { store.remove() }
        #expect(throws: (any Error).self) {
            try FileIdentityStore.write(Data("x".utf8), account: "bogus", base: store.directory)
        }
        #expect(try FileIdentityStore.read(account: IdentityManager.accountUID, base: store.directory) == nil)
        try FileIdentityStore.write(Data("abc".utf8), account: IdentityManager.accountUID, base: store.directory)
        #expect(try FileIdentityStore.read(account: IdentityManager.accountUID, base: store.directory)
                == Data("abc".utf8))
        FileIdentityStore.delete(account: IdentityManager.accountUID, base: store.directory)
        FileIdentityStore.delete(account: IdentityManager.accountUID, base: store.directory)
        #expect(try FileIdentityStore.read(account: IdentityManager.accountUID, base: store.directory) == nil)
    }
}

struct PinnedCertPersistenceTests {

    private func pin(_ store: IsolatedStore, _ id: String) -> URL {
        store.directory.appendingPathComponent("Glimmer/PinnedHosts/\(id).pem")
    }

    @Test func aStoredPinLoadsBackAndIsOwnerOnly() throws {
        let store = try IsolatedStore("pin-roundtrip")
        defer { store.remove() }
        try PinnedCertStore.store(pem: "PEM-A", forHostID: "AAA", defaults: store.defaults, base: store.directory)
        #expect(PinnedCertStore.load(forHostID: "AAA", defaults: store.defaults, base: store.directory) == "PEM-A")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: pin(store, "AAA").path)[.posixPermissions]
            as? Int)
        #expect(mode & 0o777 == 0o600)
        #expect(PinnedCertStore.load(forHostID: "BBB", defaults: store.defaults, base: store.directory) == nil)
    }

    @Test func storingReplacesThePinAndClearsAnyLegacyHint() throws {
        let store = try IsolatedStore("pin-replace")
        defer { store.remove() }
        store.defaults.set("LEGACY", forKey: "glimmer.pinnedCert.AAA")
        try PinnedCertStore.store(pem: "PEM-A", forHostID: "AAA", defaults: store.defaults, base: store.directory)
        try PinnedCertStore.store(pem: "PEM-B", forHostID: "AAA", defaults: store.defaults, base: store.directory)
        #expect(PinnedCertStore.load(forHostID: "AAA", defaults: store.defaults, base: store.directory) == "PEM-B")
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.AAA") == nil)
    }

    @Test func aFailedPermissionCheckLeavesTheOldPinAndNoTempFile() throws {
        let store = try IsolatedStore("pin-verify")
        defer { store.remove() }
        try PinnedCertStore.store(pem: "PEM-A", forHostID: "AAA", defaults: store.defaults, base: store.directory)
        #expect(throws: (any Error).self) {
            try PinnedCertStore.writePEM("PEM-B", forHostID: "AAA", base: store.directory) { _ in
                throw StreamError.crypto("refused")
            }
        }
        #expect(PinnedCertStore.load(forHostID: "AAA", defaults: store.defaults, base: store.directory) == "PEM-A")
        let names = try FileManager.default.contentsOfDirectory(atPath: pin(store, "AAA").deletingLastPathComponent().path)
        #expect(names == ["AAA.pem"])
    }

    @Test func aLegacyDefaultsPinMigratesToTheFileOnFirstRead() throws {
        let store = try IsolatedStore("pin-legacy")
        defer { store.remove() }
        store.defaults.set("LEGACY", forKey: "glimmer.pinnedCert.AAA")
        #expect(PinnedCertStore.load(forHostID: "AAA", defaults: store.defaults, base: store.directory) == "LEGACY")
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.AAA") == nil)
        #expect(try String(contentsOf: pin(store, "AAA"), encoding: .utf8) == "LEGACY")
    }

    @Test func unavailableMacPathRetainsLegacyAuthenticationAndRejectsUnpair() throws {
        let store = try IsolatedStore("pin-unavailable-path")
        defer { store.remove() }
        store.defaults.set("LEGACY", forKey: "glimmer.pinnedCert.AAA")
        let unavailable: (URL?) throws -> URL = { _ in throw CocoaError(.fileReadNoPermission) }
        #expect(PinnedCertStore.load(forHostID: "AAA", defaults: store.defaults,
                                    base: store.directory, resolveBase: unavailable) == "LEGACY")
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.AAA") == "LEGACY")
        #expect(throws: CocoaError(.fileReadNoPermission)) {
            try PinnedCertStore.delete(forHostID: "AAA", defaults: store.defaults,
                                       base: store.directory, resolveBase: unavailable)
        }
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.AAA") == "LEGACY")
    }

    @Test func deletingWipesBothStoresAndAHostIDCannotEscapeTheDirectory() throws {
        let store = try IsolatedStore("pin-delete")
        defer { store.remove() }
        try PinnedCertStore.store(pem: "PEM-A", forHostID: "../../evil", defaults: store.defaults, base: store.directory)
        #expect(FileManager.default.fileExists(atPath: pin(store, ".._.._evil").path))
        store.defaults.set("LEGACY", forKey: "glimmer.pinnedCert.AAA")
        try PinnedCertStore.delete(forHostID: "AAA", defaults: store.defaults, base: store.directory)
        try PinnedCertStore.delete(forHostID: "../../evil", defaults: store.defaults, base: store.directory)
        #expect(store.defaults.string(forKey: "glimmer.pinnedCert.AAA") == nil)
        #expect(PinnedCertStore.load(forHostID: "../../evil", defaults: store.defaults, base: store.directory) == nil)
    }
}

struct ContainerMigrationPersistenceTests {

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func theSandboxContainerIsCopiedWithoutClobberingAndLatched() throws {
        let store = try IsolatedStore("container")
        defer { store.remove() }
        let home = store.directory
        let container = home.appendingPathComponent("Library/Containers/io.ugfugl.Glimmer/Data/Library")
        try write("pin", container.appendingPathComponent("Application Support/Glimmer/PinnedHosts/A.pem"))
        try write("old", container.appendingPathComponent("Application Support/Glimmer/Identity/uid.txt"))
        try write("keep", home.appendingPathComponent("Library/Application Support/Glimmer/Identity/uid.txt"))
        ContainerMigration.runIfNeeded(defaults: store.defaults, home: home)
        let hostSupport = home.appendingPathComponent("Library/Application Support/Glimmer")
        #expect(read(hostSupport.appendingPathComponent("PinnedHosts/A.pem")) == "pin")
        #expect(read(hostSupport.appendingPathComponent("Identity/uid.txt")) == "keep")
        #expect(store.defaults.bool(forKey: ContainerMigration.didMigrateKey))
        try write("late", container.appendingPathComponent("Application Support/Glimmer/PinnedHosts/B.pem"))
        ContainerMigration.runIfNeeded(defaults: store.defaults, home: home)
        #expect(read(hostSupport.appendingPathComponent("PinnedHosts/B.pem")) == nil)
    }

    @Test func noContainerLatchesWithoutCreatingAnything() throws {
        let store = try IsolatedStore("container-none")
        defer { store.remove() }
        ContainerMigration.runIfNeeded(defaults: store.defaults, home: store.directory)
        #expect(store.defaults.bool(forKey: ContainerMigration.didMigrateKey))
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(entries.isEmpty)
    }
}

@Suite(.serialized)
struct SessionReceiptPersistenceTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ store: IsolatedStore, seconds: TimeInterval, host: String = "AAA") -> SessionReceipt? {
        SessionReceiptStore.markStreamStart(hostId: host, width: 2560, height: 1440, refreshHz: 120)
        SessionReceiptStore.markSessionLive(at: epoch)
        SessionReceiptStore.captureStreamEnd(rttMs: 12.5, collector: nil, at: epoch.addingTimeInterval(seconds))
        return SessionReceiptStore.finalizeSession(defaults: store.defaults)
    }

    private func stored(_ store: IsolatedStore, host: String = "AAA") -> SessionReceipt? {
        SessionReceiptStore.load(hostId: host, width: 2560, height: 1440, refreshHz: 120, defaults: store.defaults)
    }

    @Test func aLongSessionIsStashedAndReadsBack() throws {
        let store = try IsolatedStore("receipt-long")
        defer { store.remove() }
        let receipt = try #require(run(store, seconds: 600))
        #expect(receipt.durationSeconds == 600)
        #expect(receipt.medianRttMs == 12.5)
        #expect(stored(store) == receipt)
        #expect(stored(store, host: "BBB") == nil)
    }

    @Test func aShortSessionLeavesNothingBehind() throws {
        let store = try IsolatedStore("receipt-short")
        defer { store.remove() }
        #expect(run(store, seconds: 120) == nil)
        #expect(stored(store) == nil)
    }

    @Test func finalizingConsumesTheLatchAndANeverLiveSessionYieldsNothing() throws {
        let store = try IsolatedStore("receipt-latch")
        defer { store.remove() }
        _ = try #require(run(store, seconds: 600))
        #expect(SessionReceiptStore.finalizeSession(defaults: store.defaults) == nil)
        SessionReceiptStore.markStreamStart(hostId: "AAA", width: 1, height: 1, refreshHz: 1)
        SessionReceiptStore.captureStreamEnd(rttMs: nil, collector: nil, at: epoch.addingTimeInterval(900))
        #expect(SessionReceiptStore.finalizeSession(defaults: store.defaults) == nil)
    }

    @Test func aCorruptStashReadsAsNoReceipt() throws {
        let store = try IsolatedStore("receipt-corrupt")
        defer { store.remove() }
        let key = SessionReceiptStore.key(hostId: "AAA", width: 2560, height: 1440, refreshHz: 120)
        store.defaults.set(Data("{broken".utf8), forKey: key)
        #expect(stored(store) == nil)
    }
}

struct CushionMemoryPersistenceTests {

    @Test func aPersistedRecordRoundTripsThroughTheSuite() throws {
        let store = try IsolatedStore("cushion-roundtrip")
        defer { store.remove() }
        let key = AudioDecoder.cushionMemoryKey(host: "den", link: "wifi")
        AudioDecoder.persistCushionMemory(key: key, targetMs: 90, floorMs: 40, defaults: store.defaults)
        let record = try #require(AudioDecoder.readCushionMemory(key: key, defaults: store.defaults))
        #expect(abs(record.targetMs - 90) < 0.5)
        #expect(abs(record.floorMs - 40) < 0.5)
        #expect(AudioDecoder.readCushionMemory(key: key) == nil)
    }

    @Test func anEmptyKeyIsNeverPersisted() throws {
        let store = try IsolatedStore("cushion-empty")
        defer { store.remove() }
        AudioDecoder.persistCushionMemory(key: "", targetMs: 90, floorMs: 40, defaults: store.defaults)
        #expect(!store.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("audioCushion") })
    }

    @Test func aHandEditedRecordIsClampedOrIgnored() throws {
        let store = try IsolatedStore("cushion-edited")
        defer { store.remove() }
        let wired = AudioDecoder.cushionMemoryKey(host: "den", link: "wired")
        store.defaults.set(["target_ms": 9_000.0, "floor_ms": 10.0,
                            "saved_at": Date().timeIntervalSinceReferenceDate + 100], forKey: wired)
        let clamped = try #require(AudioDecoder.readCushionMemory(key: wired, defaults: store.defaults))
        #expect(clamped.targetMs == AudioDecoder.cushionMaxMs(forLink: "wired"))
        let bad = AudioDecoder.cushionMemoryKey(host: "den", link: "wifi")
        store.defaults.set(["target_ms": Double.nan], forKey: bad)
        #expect(AudioDecoder.readCushionMemory(key: bad, defaults: store.defaults) == nil)
        #expect(AudioDecoder.readCushionMemory(key: "audioCushionMemory.none|wifi", defaults: store.defaults) == nil)
    }

    @Test func aWeldedFloorDropsBackToBase() throws {
        let store = try IsolatedStore("cushion-weld")
        defer { store.remove() }
        let key = AudioDecoder.cushionMemoryKey(host: "den", link: "wifi")
        store.defaults.set(["target_ms": 190.0, "floor_ms": 190.0,
                            "saved_at": Date().timeIntervalSinceReferenceDate + 100], forKey: key)
        let record = try #require(AudioDecoder.readCushionMemory(key: key, defaults: store.defaults))
        #expect(record.floorMs == AudioDecoder.playoutCushionBaseMs)
    }

    @Test func anOldRecordAgesBackTowardBase() throws {
        let store = try IsolatedStore("cushion-aged")
        defer { store.remove() }
        let key = AudioDecoder.cushionMemoryKey(host: "den", link: "wifi")
        let threeDays = AudioDecoder.cushionMemoryAgeHalfLifeSeconds
        store.defaults.set(["target_ms": 130.0, "floor_ms": 0.0,
                            "saved_at": Date().timeIntervalSinceReferenceDate - threeDays], forKey: key)
        let record = try #require(AudioDecoder.readCushionMemory(key: key, defaults: store.defaults))
        let expected = AudioDecoder.playoutCushionBaseMs + (130 - AudioDecoder.playoutCushionBaseMs) / 2
        #expect(abs(record.targetMs - expected) < 1)
    }

    @Test func aSeedWithNoMemoryStartsColdFromTheBase() throws {
        let store = try IsolatedStore("cushion-seed")
        defer { store.remove() }
        let seed = AudioDecoder.loadCushionSeed(
            environment: AudioEnvironment(host: "den", link: "unknown", jitterMs: 0), defaults: store.defaults)
        #expect(!seed.fromMemory)
        #expect(seed.floorMs == 0)
        #expect(seed.targetMs >= AudioDecoder.playoutCushionBaseMs)
    }
}

struct FrameTraceFilePersistenceTests {

    private func traceFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasSuffix("-manifest.json") }.sorted()
    }

    private func traceRows(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func failedWritesAreCountedAndCannotProduceACompleteCapture() throws {
        let store = try IsolatedStore("trace-write-failure")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory, sessionId: "failure", write: { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        writer.start(isoStamp: "failure")
        writer.append("{}")
        writer.stop()
        #expect(writer.status.acceptedRecords == 1)
        #expect(writer.status.unwrittenRecords == 1)
        #expect(writer.status.writtenRecords == 0)
        #expect(writer.status.writeFailures == 1)
        #expect(!writer.status.complete)
        let data = try Data(contentsOf: store.directory.appendingPathComponent("telemetry-frames-failure-manifest.json"))
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(row["closed"] as? Bool == true)
        #expect(row["complete"] as? Bool == false)
        #expect(row["first_unwritten_sequence"] as? Int == 1)
    }

    @Test func retentionPreservesTheFirstSegmentAndReportsRemovedSequences() throws {
        let store = try IsolatedStore("trace-retention")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory, maxFileBytes: 1, maxRetainedSegments: 2)
        writer.start(isoStamp: "retention")
        for _ in 0..<3 { writer.append("{}"); writer.flush() }
        writer.stop()
        #expect(writer.status.segments.map(\.index) == [0, 3])
        #expect(writer.status.prunedRecords == 2)
        #expect(writer.status.firstPrunedSequence == 2)
        #expect(writer.status.lastPrunedSequence == 3)
        #expect(!writer.status.complete)
        #expect(try traceFiles(store.directory).count == 2)
    }

    @Test func linesLandInOrderInTheNamedFile() throws {
        let store = try IsolatedStore("trace")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory)
        writer.start(isoStamp: "T1")
        for index in 0..<5 { writer.append("{\"n\":\(index)}") }
        writer.stop()
        #expect(try traceFiles(store.directory) == ["telemetry-frames-T1.ndjson"])
        let text = try String(contentsOf: store.directory.appendingPathComponent("telemetry-frames-T1.ndjson"),
                              encoding: .utf8)
        let rows = try traceRows(text)
        #expect(rows.compactMap { $0["n"] as? Int } == Array(0..<5))
        #expect(rows.compactMap { $0["trace_seq"] as? Int } == Array(1...5))
        #expect(writer.status.closed && writer.status.complete)
    }

    @Test func typedFramesKeepTheirPlaceAmongEvents() throws {
        let store = try IsolatedStore("trace-typed")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory)
        writer.append("{\"event\":\"before\"}")
        writer.appendFrame(FrameTimingTracker.TraceRecord(
            frameIndex: 42, rtpTimestamp: 900, frameBytes: 200, isIDR: false,
            presentUptimeMs: 123.25, isResumePresent: false, submitToOutput: 1.5), sessionId: "typed")
        writer.append("{\"event\":\"after\"}")
        writer.start(isoStamp: "typed")
        writer.stop()
        let file = store.directory.appendingPathComponent("telemetry-frames-typed.ndjson")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.first?.contains("\"event\":\"before\"") == true)
        #expect(lines.last?.contains("\"event\":\"after\"") == true)
        let row = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(row["session"] as? String == "typed")
        #expect(row["frame"] as? Int == 42)
        #expect(row["submit_to_output_ms"] as? Double == 1.5)
    }

    @Test func overflowReportsLostRecordsAndPreservesSurvivorOrder() throws {
        let store = try IsolatedStore("trace-overflow")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory)
        for index in 0..<10_003 { writer.append("{\"n\":\(index)}") }
        writer.start(isoStamp: "overflow")
        writer.stop()
        let file = store.directory.appendingPathComponent("telemetry-frames-overflow.ndjson")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 10_001)
        let rows = try traceRows(lines.joined(separator: "\n"))
        #expect(rows.first?["dropped_records"] as? Int == 3)
        #expect(rows.first?["first_lost_seq"] as? Int == 1)
        #expect(rows.first?["last_lost_seq"] as? Int == 3)
        #expect(rows.dropFirst().compactMap { $0["n"] as? Int } == Array(3..<10_003))
        #expect(writer.status.overflowRecords == 3)
        #expect(!writer.status.complete)
    }

    @Test func stoppingDrainsAcceptedRecordsAndRejectsLaterAppends() throws {
        let store = try IsolatedStore("trace-stop")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory)
        writer.append("{\"event\":\"accepted\"}")
        writer.start(isoStamp: "stop")
        writer.stop()
        writer.append("{\"event\":\"late\"}")
        writer.stop()
        let file = store.directory.appendingPathComponent("telemetry-frames-stop.ndjson")
        let text = try String(contentsOf: file, encoding: .utf8)
        let rows = try traceRows(text)
        #expect(rows.count == 1)
        #expect(rows.first?["event"] as? String == "accepted")
        #expect(writer.status.acceptedRecords == 1)
        #expect(writer.status.complete)
    }

    @Test func crossingTheSizeCapOpensTheNextSegment() throws {
        let store = try IsolatedStore("trace-rollover")
        defer { store.remove() }
        let writer = FrameTraceWriter(directory: store.directory, maxFileBytes: 16)
        writer.start(isoStamp: "T2")
        for index in 0..<4 { writer.append("{\"frame\":\(index)}") }
        writer.stop()
        #expect(try traceFiles(store.directory) == ["telemetry-frames-T2-1.ndjson", "telemetry-frames-T2.ndjson"])
    }

    @Test func anUnusableDirectoryWritesNothingAndDoesNotCrash() throws {
        let store = try IsolatedStore("trace-bad")
        defer { store.remove() }
        let blocker = store.directory.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let writer = FrameTraceWriter(directory: blocker.appendingPathComponent("logs"))
        writer.start(isoStamp: "T3")
        writer.append("{}")
        writer.stop()
        #expect(try traceFiles(store.directory) == ["file"])
    }
}

struct PersistentStorageTests {
    @Test func testProcessCannotResolveInstallationStorage() throws {
        let root = try #require(PersistentStorage.testRoot)
        #expect(PersistentStorage.isTesting)
        let paths = [PersistentStorage.applicationSupport, PersistentStorage.caches,
                     PersistentStorage.logs, PersistentStorage.home,
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/Identity"),
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/PinnedHosts"),
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/Covers")]
        for path in paths {
            #expect(path.path == root.path || path.path.hasPrefix(root.path + "/"))
        }
        #expect(PersistentStorage.defaults !== UserDefaults.standard)
    }
}
