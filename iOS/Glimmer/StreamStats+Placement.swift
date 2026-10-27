// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

extension StreamStats {
    // Compare clear rectangles only when touch geometry changes, never on a video frame.
    static func clearStatsArea(in bounds: CGRect, avoiding controls: [CGRect]) -> CGRect {
        guard !controls.isEmpty else { return bounds }
        let obstacles = controls.map { $0.insetBy(dx: -8, dy: -8).intersection(bounds) }.filter { !$0.isNull }
        let edges = Set([bounds.minX, bounds.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        var best = CGRect.zero
        var score: CGFloat = 0
        for (index, left) in edges.enumerated() {
            for right in edges.dropFirst(index + 1) {
                let blocked = obstacles.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
                var top = bounds.minY
                for block in blocked + [CGRect(x: left, y: bounds.maxY, width: right - left, height: 0)] {
                    let gap = CGRect(x: left, y: top, width: right - left, height: max(0, block.minY - top))
                    let short = bounds.height < 500
                    let fit = min(gap.width / (short ? 220 : 192), gap.height / (short ? 90 : 212))
                    if fit > score { best = gap; score = fit }
                    top = max(top, block.maxY)
                }
            }
        }
        return best
    }
}
