// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerShortcutSection: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    @State private var recording: ControllerShortcutAction?

    var body: some View {
        Section {
            ForEach(ControllerShortcutAction.allCases) { action in
                ControllerSettingsRow(title: action.title, value: ControllerLayoutShortcutSummary.describe(
                    model.shortcuts(device)[action], controls: device.controls)) { recording = action }
                .disabled(!model.loaded)
                .accessibilityHint("Records a controller shortcut for all games.")
            }
            if model.shortcuts(device).hasConflict {
                Text("Stats is inactive because it overlaps your saved Stop streaming shortcut. Record a different shortcut.")
                    .controllerSettingsFootnote().foregroundStyle(.secondary)
            }
            ControllerLayoutShortcutHelp()
        } header: { Text("Glimmer controls").foregroundStyle(.secondary) }
        .sheet(item: $recording) { action in
            ControllerBindingRecorder(model: model, device: device, target: .shortcut(action))
        }
    }
}
