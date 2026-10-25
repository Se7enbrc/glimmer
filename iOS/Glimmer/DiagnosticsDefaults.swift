// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

@MainActor
enum DiagnosticsDefaults {
    static func register(defaults: UserDefaults = .standard) {
        #if GLIMMER_DIAGNOSTICS
        defaults.register(defaults: ["telemetryEnabled": true, AdaptiveBandwidth.defaultsKey: true])
        #endif
    }

    static var directory: URL? {
        #if GLIMMER_DIAGNOSTICS
        URL.applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        #else
        nil
        #endif
    }
}
