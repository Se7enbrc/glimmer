// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Prepared controller routing; native capture/actuators remain outside the session actor.
package struct SessionFeedback: Sendable {
    package var activated: @Sendable (NativeBackend?) -> Void = { _ in }
    package var deactivated: @Sendable () -> Void = {}
    package var rumble: @Sendable (UInt16, UInt16, UInt16) -> Void = { _, _, _ in }
    package var triggers: @Sendable (UInt16, UInt16, UInt16) -> Void = { _, _, _ in }
    package var rgb: @Sendable (UInt16, UInt8, UInt8, UInt8) -> Void = { _, _, _, _ in }
    package var player: @Sendable (UInt16, UInt8, UInt8) -> Void = { _, _, _ in }
    package var motion: @Sendable (UInt16, UInt8, UInt16) -> Void = { _, _, _ in }
    package var adaptive: @Sendable (UInt16, UInt8, UInt8, UInt8, [UInt8], [UInt8]) -> Void = { _, _, _, _, _, _ in }
    package init() {}
}
