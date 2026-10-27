// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

extension StreamStats {
    // Compare clear rectangles only when touch geometry changes, never on a video frame.
    static func clearStatsArea(in bounds: CGRect, avoiding controls: [CGRect],
                               corner: StatsOverlayCorner = .topLeft, target: CGSize? = nil) -> CGRect {
        guard !controls.isEmpty else { return bounds }
        let short = bounds.height < 500
        let x: CGFloat = switch corner {
        case .topLeft, .bottomLeft: bounds.minX
        case .topCenter, .bottomCenter: bounds.midX
        case .topRight, .bottomRight: bounds.maxX
        }
        let y = [.topLeft, .topCenter, .topRight].contains(corner) ? bounds.minY : bounds.maxY
        return TouchLayout.clearArea(in: bounds, avoiding: controls,
                                     target: target ?? (short ? CGSize(width: 220, height: 90)
                                        : CGSize(width: 192, height: 212)),
                                     anchor: CGPoint(x: x, y: y))
    }
}
