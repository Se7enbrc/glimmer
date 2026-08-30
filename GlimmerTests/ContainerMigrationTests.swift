//
//  ContainerMigrationTests.swift
//
//  Covers the copy-not-move migrations: ContainerMigration.copyTree, and the
//  moonlight-qt identity import (which must leave the foreign plist intact so
//  moonlight-qt keeps its own pairings). The full runIfNeeded() / load()
//  paths touch the real home dir and real preference domains, so the unit
//  scope stays on the pure tree copy and the pure suite read.
//

import Foundation
import Testing
@testable import Glimmer

struct ContainerMigrationTests {

    private func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmtest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ s: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(s.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func copiesNestedTreeIntoEmptyDestination() {
        let root = tmpDir()
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        write("cert", to: src.appendingPathComponent("Identity/client-cert.pem"))
        write("uid", to: src.appendingPathComponent("Identity/client-uniqueid.txt"))

        ContainerMigration.copyTree(from: src, to: dst)

        #expect(read(dst.appendingPathComponent("Identity/client-cert.pem")) == "cert")
        #expect(read(dst.appendingPathComponent("Identity/client-uniqueid.txt")) == "uid")
        // copy-not-move: source survives.
        #expect(read(src.appendingPathComponent("Identity/client-cert.pem")) == "cert")
    }

    @Test func neverClobbersExistingDestinationFiles() {
        let root = tmpDir()
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        write("OLD", to: src.appendingPathComponent("Identity/client-cert.pem"))
        write("NEW", to: dst.appendingPathComponent("Identity/client-cert.pem"))

        ContainerMigration.copyTree(from: src, to: dst)

        // Destination wins - we must not overwrite live host data.
        #expect(read(dst.appendingPathComponent("Identity/client-cert.pem")) == "NEW")
    }

    @Test func missingSourceIsANoOp() {
        let root = tmpDir()
        let src = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)

        #expect(ContainerMigration.copyTree(from: src, to: dst) == 0)
        #expect(FileManager.default.fileExists(atPath: dst.path) == false)
    }

    @Test func idempotentOnRepeat() {
        let root = tmpDir()
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        write("v", to: src.appendingPathComponent("a/b.txt"))

        let first = ContainerMigration.copyTree(from: src, to: dst)
        let second = ContainerMigration.copyTree(from: src, to: dst)
        #expect(first > 0)
        #expect(second == 0)   // everything already present → nothing new copied
        #expect(read(dst.appendingPathComponent("a/b.txt")) == "v")
    }
}

/// The cross-app identity import out of moonlight-qt's UserDefaults suite.
/// Runs against a throwaway preference domain, never the real
/// `com.moonlight-stream.Moonlight` one.
struct MoonlightQtIdentityImportTests {

    /// Scratch domain names are fixed, not per-run UUIDs: CFPreferences leaves
    /// the (now empty) plist behind after `removePersistentDomain`, so a fresh
    /// name per run would litter ~/Library/Preferences a file at a time. One
    /// stable name per test also keeps the two tests off each other's domain
    /// when the suite runs in parallel.
    private static let copyDomain = "io.ugfugl.Glimmer.tests.moonlightqt-copy"
    private static let skipDomain = "io.ugfugl.Glimmer.tests.moonlightqt-skip"

    @Test func importCopiesAndLeavesTheSourceSuiteUntouched() throws {
        let domain = Self.copyDomain
        let suite = try #require(UserDefaults(suiteName: domain))
        suite.removePersistentDomain(forName: domain)   // no crumbs from a prior run
        defer { suite.removePersistentDomain(forName: domain) }

        // QSettings writes the cert as a String and the key as Data; mirror
        // both shapes so the reader's Data → String path is exercised too.
        let certPEM = "-----BEGIN CERTIFICATE-----\nqt-cert\n-----END CERTIFICATE-----\n"
        let keyPEM  = "-----BEGIN PRIVATE KEY-----\nqt-key\n-----END PRIVATE KEY-----\n"
        let keyData = Data(keyPEM.utf8)
        suite.set(certPEM, forKey: "certificate")
        suite.set(keyData, forKey: "key")
        suite.set("qtuniqueid00", forKey: "uniqueid")

        let adopted = try #require(
            IdentityManager.adoptedIdentity(fromMoonlightQt: suite, currentID: "ours"))
        #expect(adopted.certPEM == certPEM)
        #expect(adopted.keyPEM == keyPEM)
        #expect(adopted.uniqueID == "qtuniqueid00")

        // The point of the test: copy only. moonlight-qt still holds its own
        // identity, so it keeps every host it had paired with.
        #expect(suite.string(forKey: "certificate") == certPEM)
        #expect(suite.data(forKey: "key") == keyData)
        #expect(suite.string(forKey: "uniqueid") == "qtuniqueid00")
    }

    @Test func aSuiteWithoutAKeyPairIsSkippedAndStillUntouched() throws {
        let domain = Self.skipDomain
        let suite = try #require(UserDefaults(suiteName: domain))
        suite.removePersistentDomain(forName: domain)
        defer { suite.removePersistentDomain(forName: domain) }

        // Cert but no key - moonlight-qt installed, never paired.
        suite.set("cert-only", forKey: "certificate")

        #expect(IdentityManager.adoptedIdentity(fromMoonlightQt: suite, currentID: nil) == nil)
        #expect(suite.string(forKey: "certificate") == "cert-only")
    }
}
