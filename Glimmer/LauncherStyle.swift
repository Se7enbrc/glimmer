// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

enum LauncherStyle: String, CaseIterable {
    case buttons, covers

    private static func key(for pcID: String) -> String { "glimmer.launcherStyle.\(pcID)" }

    static func load(for pcID: String, defaults: UserDefaults = PersistentStorage.defaults) -> Self {
        persisted(rawValue: defaults.string(forKey: key(for: pcID)))
    }

    static func save(_ style: Self, for pcID: String, defaults: UserDefaults = PersistentStorage.defaults) {
        defaults.set(style.rawValue, forKey: key(for: pcID))
    }

    static func forget(pcID: String, defaults: UserDefaults = PersistentStorage.defaults) {
        defaults.removeObject(forKey: key(for: pcID))
    }

    static func offersChoice(apps: [LibraryApp]) -> Bool {
        !customApps(in: apps).isEmpty
    }

    static func customApps(in apps: [LibraryApp]) -> [LibraryApp] {
        apps.filter { !$0.hidden && !["desktop", "steam big picture"].contains($0.name.lowercased()) }
    }

    static func persisted(rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .buttons
    }

    var title: String { self == .buttons ? "Buttons" : "Covers" }
}

enum LauncherLayout {
    static let contentWidth: CGFloat = 532
    static let horizontalPadding: CGFloat = 24
    static var windowWidth: CGFloat { contentWidth + 2 * horizontalPadding }
    static let coverPadding: CGFloat = 12

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
        return (contentWidth - 2 * coverPadding - CGFloat(count - 1) * 10) / CGFloat(count)
    }

    static func coverHeight(appCount: Int) -> CGFloat {
        min(coverWidth(appCount: appCount), 180) * 4 / 3
    }
}

@MainActor
extension AppModel {
    var launcherStyle: LauncherStyle { selectedHost?.launcherStyle ?? .buttons }

    func setLauncherStyle(_ style: LauncherStyle, for host: Host) {
        LauncherStyle.save(style, for: host.id, defaults: hostsDefaults)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index].launcherStyle = style }
        if selectedHost?.id == host.id { selectedHost?.launcherStyle = style }
    }
}
