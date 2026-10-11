// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

/// Shared pacing keeps SwiftUI state changes and AppKit presentation in step.
enum Motion {
    static let short = 0.18
    static let structural = 0.3
    static let fade = Animation.easeOut(duration: short)

    static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: structural)
    }

    static func press(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: short)
    }

    static func pressedScale(_ pressed: Bool, reduceMotion: Bool) -> CGFloat {
        pressed && !reduceMotion ? 0.985 : 1
    }

    static func overlay(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : .snappy(duration: structural, extraBounce: 0.1)
    }

    static func overlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}
