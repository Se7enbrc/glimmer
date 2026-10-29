// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

/// Glimmer must never remove anything it did not just write (#138).
struct IdentityKeychainCleanupTests {
    @Test(arguments: [IdentityStorageError.incompleteIdentity, .invalidIdentity])
    func damagedIdentityExplainsRestorationAcrossMacSurfaces(error: IdentityStorageError) {
        let expected = StreamFailureCopy.identityNeedsRestore("Den PC")
        #expect(PairingFailure.from(error, fallback: .unreachable) == .identityNeedsRestore)
        #expect(PairingFailure.from(error, fallback: .rejected) == .identityNeedsRestore)
        #expect(PairingFailure.identityNeedsRestore.message(pc: "Den PC") == expected)
        #expect(GlimmerCLI.pairFailureMessage(.identityNeedsRestore, pc: "Den PC") == expected)
        #expect(AppModel.connectFailure(for: error, hostName: "Den PC").message == expected)
    }

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
