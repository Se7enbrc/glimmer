// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum StreamSizeBounds {
    package static let width = 640...7680
    package static let height = 480...4320
    package static let fps = 30...240

    package static func clampWidth(_ value: Int) -> Int { min(max(value, width.lowerBound), width.upperBound) }
    package static func clampHeight(_ value: Int) -> Int { min(max(value, height.lowerBound), height.upperBound) }
    package static func clampFPS(_ value: Int) -> Int { min(max(value, fps.lowerBound), fps.upperBound) }

    /// What a Settings field may hand the model: the digits of `text` as a
    /// number, only once they sit inside `range`. Nil for a half-typed value.
    package static func acceptedValue(from text: String, in range: ClosedRange<Int>) -> Int? {
        guard let value = Int(text.filter(\.isNumber)), range.contains(value) else { return nil }
        return value
    }
}
