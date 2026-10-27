// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerLayoutShortcutSummary: View {
    var shortcuts = ControllerLayoutShortcuts()
    var controls: [ControllerLayoutControl] = []

    var body: some View {
        ForEach(ControllerShortcutAction.allCases) { action in
            LabeledContent(action.title, value: Self.describe(shortcuts[action], controls: controls))
        }
        ControllerLayoutShortcutHelp()
    }

    static func describe(_ chord: Set<ControllerLayoutSource>, controls: [ControllerLayoutControl]) -> String {
        guard !chord.isEmpty else { return "Not set" }
        return chord.map { source in
            controls.first { $0.id == source }?.name ?? source.layoutName
        }.sorted().joined(separator: " + ")
    }
}

struct ControllerLayoutShortcutHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hold all the buttons for a moment, then release. Shortcuts use physical buttons in every game.")
            Text("The PC sees the buttons until the hold completes. Normal game input is never delayed.")
            #if os(iOS)
            Text("Open stream controls and tap Disconnect to stop streaming.")
            #else
            Text("Stop with the keyboard shortcut (⌃Q by default), or use the stream controls.")
            #endif
            Text("Restore shortcuts with Reset to defaults in General.")
        }.controllerSettingsFootnote().foregroundStyle(.secondary)
    }
}
