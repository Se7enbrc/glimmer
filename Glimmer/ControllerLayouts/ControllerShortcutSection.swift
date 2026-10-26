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
                .disabled(device.captureSource == nil || !device.connected)
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
    @State private var failure: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        var shortcuts = model.shortcuts(device)
        shortcuts[action] = capture.chord
        return shortcuts.recordingProblem(for: action, available: Set(device.controls.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(capture.message)
                    ControllerLayoutDiagram(family: device.diagramFamily, controls: device.controls,
                        highlighted: capture.chord) { _ in }
                        .allowsHitTesting(false).accessibilityHidden(true)
                    LabeledContent(action.title, value: ControllerLayoutShortcutSummary.describe(
                        capture.chord, controls: device.controls))
                }
                if capture.finished, let problem { Section { Text(problem).foregroundStyle(.red) } }
                if let warning = ControllerLayoutShortcuts.warning(for: capture.chord) {
                    Section { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                if capture.finished {
                    Section {
                        Button("Record again") { failure = nil; capture.restart { dismiss() } }.disabled(saving)
                    }
                }
                Section { ControllerLayoutShortcutHelp() }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Record \(action.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!capture.finished || problem != nil || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { capture.start { dismiss() } }
        .onDisappear { capture.stop() }
        .onChange(of: capture.finished) { _, finished in if finished { capture.stop() } }
        .onChange(of: model.current(device).connected) { _, connected in if !connected { dismiss() } }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560)
        #endif
    }

    private func save() {
        saving = true
        Task {
            do {
                try await model.saveShortcut(capture.chord, action: action, device: device)
                dismiss()
            } catch {
                failure = "Couldn't save the shortcut. Try again."
                saving = false
            }
        }
    }
}
