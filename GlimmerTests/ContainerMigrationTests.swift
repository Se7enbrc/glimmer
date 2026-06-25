//
//  ContainerMigrationTests.swift
//
//  Covers ContainerMigration.copyTree (idempotent copy-not-move). The full
//  runIfNeeded() touches the real home dir / CFPreferences, so the unit scope
//  stays on the pure tree copy.
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
