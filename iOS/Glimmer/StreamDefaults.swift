// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

@MainActor
enum StreamDefaults {
    static func register(defaults: UserDefaults = PersistentStorage.defaults) {
        #if GLIMMER_DIAGNOSTICS
        defaults.register(defaults: [AdaptiveBandwidth.defaultsKey: true])
        #endif
    }
}
