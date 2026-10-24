// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct ScrollQuantizer {
    package static let notch = 120

    package init() {}

    private var vertical = 0
    private var horizontal = 0

    /// Units to send now: whole notches of a precise device's running total
    /// (same sign), or a wheel's units as they came.
    package mutating func consumeVertical(_ units: Int, precise: Bool) -> Int {
        precise ? Self.consume(units, residual: &vertical) : units
    }

    package mutating func consumeHorizontal(_ units: Int, precise: Bool) -> Int {
        precise ? Self.consume(units, residual: &horizontal) : units
    }

    /// A finished gesture never banks into the next one.
    package mutating func reset() {
        vertical = 0
        horizontal = 0
    }

    private static func consume(_ units: Int, residual: inout Int) -> Int {
        // A direction change drops what the other direction had banked.
        if units != 0, residual != 0, (units < 0) != (residual < 0) { residual = 0 }
        residual += units
        let notches = residual / notch
        residual -= notches * notch
        return notches * notch
    }
}
