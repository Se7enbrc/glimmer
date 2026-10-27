// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct StreamControlsHelp: View {
    let model: StreamSessionModel
    let keyboardConnected: Bool

    var body: some View {
        Form {
            Section("Touch") {
                Text("Tap \(Image(systemName: "ellipsis.circle")) to open the stream menu. \(Self.menuHint)")
                    .accessibilityLabel("Tap Show controls to open the stream menu. \(Self.menuHint)")
                Text("""
                    Play with the on-screen controller. Its \(Image(systemName: "rectangle.on.rectangle")) Options \
                    and \(Image(systemName: "line.3.horizontal")) Menu buttons go to the game. Choose Edit controls… \
                    to move, resize or hide controls.
                    """)
                    .accessibilityLabel(Self.gamepadHint)
                if model.launch.touchMouseEnabled {
                    Text("Drag to move the pointer. Tap to click.")
                    Text("Use two fingers to scroll or tap for a secondary click.")
                }
                Text("With VoiceOver, select the video and choose Show controls.")
            }
            Section("Controller") {
                Text("Change Stop streaming and Stats shortcuts in Controller layouts. "
                     + "Hold a shortcut, then release to use it.")
                ControllerMouseDiagram(bindings: ControllerLayoutsModel.shared.mouse).tint(.primary)
                Text("Hold the mouse-mode toggle for a second and release to switch modes.")
            }
            if let hint = Self.keyboardHint(connected: keyboardConnected,
                                            stats: model.shortcuts.stats.displayString,
                                            stop: model.shortcuts.quit.displayString) {
                Section("Keyboard") { Text(hint) }
            }
        }
    }

    static let menuHint = "If it's hidden, tap the top of the picture to reveal it, or tap with three fingers."
    static let gamepadHint = "Play with the on-screen controller. Its Options and Menu buttons go to the game. "
        + "Choose Edit controls… to move, resize or hide controls."

    static func keyboardHint(connected: Bool, stats: String, stop: String) -> String? {
        connected ? "\(stats) shows stream stats. \(stop) disconnects. Control-/ opens the stream menu." : nil
    }
}
