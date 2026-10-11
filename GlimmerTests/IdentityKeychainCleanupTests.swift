// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

/// Glimmer must never remove anything it did not just write (#138).
struct IdentityKeychainCleanupTests {
    @Test func loadingAnIdentityLeavesEarlierBuildsLeftoversAlone() async throws {
        let store = try IsolatedStore("kc-leave")
        defer { store.remove() }
        let oldKeychain = store.directory.appendingPathComponent("Glimmer/identity.keychain")
        try FileManager.default.createDirectory(at: oldKeychain.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: oldKeychain)
        let identity = IdentityManager(defaultsSuite: store.domain, supportBase: store.directory,
                                       moonlightQtSuite: "io.ugfugl.Glimmer.tests.leave-qt-none")

        _ = try await identity.uniqueID()

        #expect(try Data(contentsOf: oldKeychain) == Data([1, 2, 3]))
        #expect(store.defaults.object(forKey: "glimmer.identityCleanupVersion") == nil)
    }
}
