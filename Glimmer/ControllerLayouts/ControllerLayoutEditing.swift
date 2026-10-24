// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@MainActor
enum ControllerLayoutEditing {
    static let changed = Notification.Name("ControllerLayoutEditingChanged")
    private(set) static var editors: Set<UUID> = []
    private(set) static var capture: UUID?
    static var active: Bool { !editors.isEmpty }

    static func begin(_ id: UUID) {
        let wasActive = active
        editors.insert(id)
        if !wasActive { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func end(_ id: UUID) {
        editors.remove(id)
        Task { @MainActor in
            guard !active else { return }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func acquireCapture(_ id: UUID) -> Bool {
        guard capture == nil else { return false }
        capture = id
        return true
    }

    static func releaseCapture(_ id: UUID) {
        if capture == id { capture = nil }
    }
}
