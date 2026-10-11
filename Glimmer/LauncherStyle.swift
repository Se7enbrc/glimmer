// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

enum LauncherStyle: String, CaseIterable {
    case buttons, covers

    static let defaultsKey = "launcherStyle"

    static func persisted(rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .buttons
    }

    func loadsArt(streaming: Bool) -> Bool { self == .covers && !streaming }

    var title: String { self == .buttons ? "Buttons" : "Covers" }
}

enum LauncherLayout {
    /// Prefer filled rows, with four columns keeping large libraries compact.
    static func columns(appCount: Int) -> Int {
        guard appCount > 0 else { return 1 }
        if appCount <= 4 { return appCount }
        return (3...4).min {
            let left = ($0 - appCount % $0) % $0
            let right = ($1 - appCount % $1) % $1
            return left == right ? $0 > $1 : left < right
        } ?? 4
    }

    static func coverWidth(appCount: Int) -> CGFloat {
        let count = columns(appCount: appCount)
        return (524 - CGFloat(count - 1) * 10) / CGFloat(count)
    }

    static func coverHeight(appCount: Int) -> CGFloat {
        min(coverWidth(appCount: appCount), 180) * 4 / 3
    }
}
