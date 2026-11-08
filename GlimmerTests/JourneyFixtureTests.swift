// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct JourneyFixtureTests {
    @Test func sharedReceiptsDoNotDependOnTheAppsTemporaryDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Glimmer-journey-" + UUID().uuidString, isDirectory: true)
        let resolved = try #require(JourneyMacPC.receiptDirectory(directory.path))
        #expect(resolved == directory.resolvingSymlinksInPath())
        #expect(PersistentStorage.testRoot != resolved)
        let appRoot = try #require(PersistentStorage.testRoot)
        #expect(PersistentStorage.applicationSupport.path.hasPrefix(appRoot.path))
    }

    @Test(arguments: ["/tmp/Glimmer-journey-invalid", "/tmp/00000000-0000-0000-0000-000000000001",
                     "/tmp/nested/Glimmer-journey-00000000-0000-0000-0000-000000000001",
                     "/Users/Glimmer-journey-00000000-0000-0000-0000-000000000001"])
    func receiptsRejectUnconfinedOrAmbiguousDirectories(path: String) {
        #expect(JourneyMacPC.receiptDirectory(path) == nil)
    }

    @Test func receiptDirectoryCannotEscapeThroughASymlink() throws {
        let link = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Glimmer-journey-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(JourneyMacPC.receiptDirectory(link.path) == nil)
    }
}
