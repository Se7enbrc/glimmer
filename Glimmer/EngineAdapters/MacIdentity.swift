// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import os.log

extension URL {
    /// `~/Library/Application Support`, or `base` when a caller supplies its own root.
    static func supportRoot(base: URL?) throws -> URL {
        if let base { return base }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    }
}

extension IdentityManager {
    static let shared = IdentityManager()
    static let moonlightQtSuiteName = "com.moonlight-stream.Moonlight"

    init(defaultsSuite: String? = nil, supportBase: URL? = nil,
         moonlightQtSuite: String = IdentityManager.moonlightQtSuiteName) {
        self.init(defaultsSuite: defaultsSuite, storageRoot: { try URL.supportRoot(base: supportBase) },
                  migrateIdentity: { try Self.adoptMoonlightQtIdentity(suite: moonlightQtSuite, currentID: $0) })
    }

    func aesKey(forPIN pin: String, salt: Data) -> Data {
        Self.aesKey(forPIN: pin, salt: salt)
    }

    private static func adoptMoonlightQtIdentity(suite: String, currentID: String?) throws -> AdoptedQtIdentity? {
        guard let moonlight = UserDefaults(suiteName: suite),
              let adopted = try Self.adoptedIdentity(fromMoonlightQt: moonlight,
                                                 currentID: currentID) else {
            return nil
        }
        Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Identity").info("""
            Copying moonlight-qt client identity \
            (\(adopted.certPEM.count) byte cert, \(adopted.keyPEM.count) byte key) \
            → file store; source plist left untouched
            """)
        return adopted
    }

    /// Read and validate without modifying the source suite. QSettings stores PEMs as String or Data.
    static func adoptedIdentity(fromMoonlightQt moonlight: UserDefaults,
                                currentID: String?) throws -> AdoptedQtIdentity? {
        func readPEM(_ key: String) -> String? {
            if let str = moonlight.string(forKey: key), !str.isEmpty { return str }
            if let data = moonlight.data(forKey: key),
               let str = String(data: data, encoding: .utf8), !str.isEmpty {
                return str
            }
            return nil
        }

        guard let mCert = readPEM("certificate"), let mKey = readPEM("key") else {
            return nil
        }
        _ = try PEM.identity(certPEM: mCert, keyPEM: mKey)
        let mID = moonlight.string(forKey: "uniqueid")
                 ?? moonlight.data(forKey: "uniqueid").flatMap { String(data: $0, encoding: .utf8) }

        // Preserve the caller's existing ID unless qt offers a non-empty one.
        let resolvedID = (mID?.isEmpty == false) ? mID : currentID
        return AdoptedQtIdentity(certPEM: mCert, keyPEM: mKey, uniqueID: resolvedID)
    }
}
