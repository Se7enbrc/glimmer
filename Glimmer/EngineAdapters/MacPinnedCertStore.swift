// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

extension PinnedCertStore {
    static func load(forHostID hostID: String, defaults: UserDefaults = .standard,
                     base: URL? = nil, resolveBase: (URL?) throws -> URL = URL.supportRoot) -> String? {
        guard let root = try? resolveBase(base) else {
            let legacy = defaults.string(forKey: key(for: hostID))
            return legacy?.isEmpty == false ? legacy : nil
        }
        return try? loadAvailable(forHostID: hostID, defaults: defaults, base: root)
    }

    static func store(pem: String, forHostID hostID: String,
                      defaults: UserDefaults = .standard, base: URL? = nil) throws {
        try storeAvailable(pem: pem, forHostID: hostID, defaults: defaults, base: URL.supportRoot(base: base))
    }

    static func delete(forHostID hostID: String, defaults: UserDefaults = .standard, base: URL? = nil,
                       resolveBase: (URL?) throws -> URL = URL.supportRoot) {
        guard let root = try? resolveBase(base) else {
            defaults.removeObject(forKey: key(for: hostID))
            return
        }
        try? deleteAvailable(forHostID: hostID, defaults: defaults, base: root)
    }
}
