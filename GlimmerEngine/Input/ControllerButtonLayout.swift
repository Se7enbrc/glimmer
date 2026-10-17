// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum ControllerButtonLayout {
    package static let defaultsKey = "nintendoButtonLayout"

    package static func usesLabels(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }

    // GameController and SDL's macOS DB both expose position; swap only the outgoing PC buttons.
    package static func apply(_ buttons: Int32, useNintendoLabels: Bool) -> Int32 {
        guard useNintendoLabels else { return buttons }
        let pairs = [(StreamProtocol.A_FLAG, StreamProtocol.B_FLAG), (StreamProtocol.X_FLAG, StreamProtocol.Y_FLAG)]
        let faceMask = pairs.reduce(Int32(0)) { $0 | $1.0 | $1.1 }
        return pairs.reduce(buttons & ~faceMask) { result, pair in
            result | (buttons & pair.0 != 0 ? pair.1 : 0) | (buttons & pair.1 != 0 ? pair.0 : 0)
        }
    }
}
