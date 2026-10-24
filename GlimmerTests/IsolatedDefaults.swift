// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing

// Immutable suite identity; UserDefaults synchronizes access. Cleanup runs after the last owner releases it.
final class IsolatedDefaults: @unchecked Sendable {
    let name = "io.ugfugl.Glimmer.tests." + UUID().uuidString
    let defaults: UserDefaults

    init() {
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Could not create isolated test defaults")
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
