// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct TouchLayoutStore {
    private struct Record: Codable {
        var version = 1
        let layout: TouchLayout
    }
    let defaults: UserDefaults
    private let prefix = "ios.touchLayout."

    func load(pcID: String, appID: Int, family: TouchLayout.Family) -> TouchLayout {
        guard let data = defaults.data(forKey: key(pcID, appID, family)),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
              record.layout.changes.values.allSatisfy(\.valid) else { return TouchLayout() }
        return record.layout
    }

    func save(_ layout: TouchLayout, pcID: String, appID: Int, family: TouchLayout.Family) {
        let key = key(pcID, appID, family)
        guard !layout.changes.isEmpty else { defaults.removeObject(forKey: key); return }
        guard layout.changes.values.allSatisfy(\.valid),
              let data = try? JSONEncoder().encode(Record(layout: layout)) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func forget(pcID: String) {
        let prefix = prefix + Data(pcID.utf8).base64EncodedString() + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(_ pcID: String, _ appID: Int, _ family: TouchLayout.Family) -> String {
        prefix + Data(pcID.utf8).base64EncodedString() + ".\(appID).\(family.rawValue)"
    }
}
