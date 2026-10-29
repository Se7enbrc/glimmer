// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

// Formatting and preferences can block; their work never belongs to the packet or render threads.
package enum AudioDiagnostics {
    package static let queue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.diagnostics", qos: .utility)

    package static func notice(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.notice(message(), category) }
    }

    package static func warn(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.warn(message(), category) }
    }

    package static func error(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.error(message(), category) }
    }

    package static func info(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.info(message(), category) }
    }
}
