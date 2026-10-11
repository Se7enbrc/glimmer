// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Sunshine reports currentgame but no owner; retain successful launches across Glimmer restarts.
struct RunningAppOwnership: Codable, Equatable {
    let appID: Int
    let clientID: String

    static func load(pc: String, defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: key(pc)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(pc: String, appID: Int, clientID: String, defaults: UserDefaults = .standard) {
        guard !pc.isEmpty, !clientID.isEmpty,
              let data = try? JSONEncoder().encode(Self(appID: appID, clientID: clientID)) else { return }
        defaults.set(data, forKey: key(pc))
    }

    static func clear(pc: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(pc))
    }

    static func reconcile(pc: String, appID: Int, defaults: UserDefaults = .standard) {
        if load(pc: pc, defaults: defaults)?.appID != appID { clear(pc: pc, defaults: defaults) }
    }

    private static func key(_ pc: String) -> String { "runningAppOwner." + pc }
}
