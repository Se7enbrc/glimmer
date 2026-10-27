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
                Button { recording = action } label: {
                    LabeledContent(action.title, value: ControllerLayoutShortcutSummary.describe(
                        model.shortcuts(device)[action], controls: device.controls))
                }
                .disabled(!model.loaded)
                .accessibilityHint("Records a controller shortcut for all games.")
            }
            if model.shortcuts(device).hasConflict {
                Text("Stats is inactive because it overlaps your saved Stop streaming shortcut. Record a different shortcut.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ControllerLayoutShortcutHelp()
        } header: { Text("Glimmer controls") }
        .sheet(item: $recording) { action in
            if let input = device.captureSource {
                ControllerShortcutRecorder(model: model, device: device, action: action,
                    capture: ControllerLayoutCapture(input: input, recordingChord: true))
            }
        }
    }
}

struct ControllerShortcutRecorder: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    let action: ControllerShortcutAction
    @State var capture: ControllerLayoutCapture

    var body: some View {
        ControllerBindingRecorder(model: model, device: device, target: .shortcut(action), capture: capture)
    }
}
