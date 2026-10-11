// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Security
import Synchronization
import Testing
@testable import Glimmer

private typealias Query = [String: String]

private final class DeleteLog: Sendable {
    private let queries = Mutex<[Query]>([])
    var all: [Query] { queries.withLock { $0 } }
    func record(_ query: [String: Any]) { queries.withLock { $0.append(query.compactMapValues { $0 as? String }) } }
}

/// The legacy keychain sweeps, recorded as queries; the real keychain is never called.
struct IdentityKeychainCleanupTests {
    private func manager(_ store: IsolatedStore, deletes: DeleteLog) -> IdentityManager {
        IdentityManager(defaultsSuite: store.domain, supportBase: store.directory,
                        keychainService: "io.ugfugl.Glimmer.tests.cleanup",
                        moonlightQtSuite: "io.ugfugl.Glimmer.tests.cleanup-qt-none",
                        deleteKeychainItems: { query in
            deletes.record(query)
            return errSecItemNotFound
        })
    }

    private func password(_ account: String) -> Query {
        [kSecClass as String: kSecClassGenericPassword as String,
         kSecAttrService as String: "io.ugfugl.Glimmer.tests.cleanup",
         kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitAll as String]
    }

    private var legacyPasswords: [Query] {
        [IdentityManager.accountCert, IdentityManager.accountKey, IdentityManager.accountUID].map(password)
    }

    @Test func preflightSweepsOnlyGlimmersOwnItemsOnce() async throws {
        let store = try IsolatedStore("kc-sweep")
        defer { store.remove() }
        let oldKeychain = store.directory.appendingPathComponent("Glimmer/identity.keychain")
        try FileManager.default.createDirectory(at: oldKeychain.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: oldKeychain)
        store.defaults.set("secret", forKey: "glimmer.identityKeychainPassphrase")
        let deletes = DeleteLog()
        let identity = manager(store, deletes: deletes)

        await identity.preflight()

        let expected = legacyPasswords
        #expect(deletes.all == expected)
        // Only Glimmer's own service-and-account passwords: never a certificate, key or identity (#138).
        #expect(deletes.all.allSatisfy { $0[kSecClass as String] == kSecClassGenericPassword as String })
        #expect(!FileManager.default.fileExists(atPath: oldKeychain.path))
        #expect(store.defaults.string(forKey: "glimmer.identityKeychainPassphrase") == nil)
        await identity.preflight()
        await manager(store, deletes: deletes).preflight()
        #expect(deletes.all.count == expected.count)
    }

    @Test func migrationDeletesTheThreeLegacyPasswords() async throws {
        let store = try IsolatedStore("kc-migrate")
        defer { store.remove() }
        let deletes = DeleteLog()
        await manager(store, deletes: deletes).deleteLegacyKeychainItems()
        #expect(deletes.all == legacyPasswords)
    }
}
