// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Observation
import SwiftUI

@MainActor
@Observable
final class StreamOverlayAppearance {
    private(set) var colorScheme: ColorScheme?

    func update(luminance: Double) {
        guard luminance.isFinite, (0...1).contains(luminance) else { return }
        let darkInk = StatsOverlayLayer.shouldUseDarkInk(luminance: luminance, currentlyDark: colorScheme == .light)
        let next: ColorScheme = darkInk ? .light : .dark
        if colorScheme != next { colorScheme = next }
    }
}
