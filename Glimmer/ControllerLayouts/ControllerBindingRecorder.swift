// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerBindingRecorder: View {
    enum Target {
        case shortcut(ControllerShortcutAction)
        case mouse(ControllerMouseAction)
        var title: String {
            switch self {
            case .shortcut(let action): action.title
            case .mouse(let action): action.title
            }
        }
        var isStick: Bool {
            if case .mouse(let action) = self { return action.isStick }
            return false
        }
    }
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    let target: Target
    @State private var sources: Set<ControllerLayoutSource> = []
    @State var capture: ControllerLayoutCapture?
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var problem: String? {
        switch target {
        case .mouse(let action): return model.mouseProblem(sources, action: action, device: device)
        case .shortcut(let action):
            var value = model.shortcuts(device)
            value[action] = sources
            if model.mouse.overrides.values.contains(where: { ControllerMouseBindings.overlaps($0, sources) }) {
                return "Already used for Controller mouse. Change that binding first."
            }
            return value.recordingProblem(for: action, available: Set(device.controls.map(\.id)))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ControllerLayoutDiagram(family: device.diagramFamily, controls: device.controls,
                        highlighted: sources) { toggle($0.id) }
                    LabeledContent(target.title, value: ControllerMouseHelp.describe(sources, device: device))
                    if target.isStick { stickPicker } else { buttonChoices }
                }
                if let capture { Section { Text(capture.message) } }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
                if let warning = ControllerLayoutShortcuts.warning(for: sources) {
                    Section { Text(warning).font(.footnote).foregroundStyle(.secondary) }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Change \(target.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(problem != nil || saving || capture?.finished == false)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            switch target {
            case .mouse(let action): sources = model.mouse[action]
            case .shortcut(let action): sources = capture?.finished == true ? capture?.chord ?? [] : model.shortcuts(device)[action]
            }
        }
        .onDisappear { capture?.stop() }
        .onChange(of: capture?.finished) { _, finished in
            if finished == true, let capture { sources = capture.chord; capture.stop() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { capture?.stop(); capture = nil } }
        .onChange(of: model.current(device).connected) { _, connected in
            if !connected { capture?.stop(); capture = nil }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560)
        #endif
    }

    private var stickPicker: some View {
        Picker("Stick", selection: $sources) {
            Text("Not set").tag(Set<ControllerLayoutSource>())
            Text("Left stick").tag(ControllerMouseMapping.stick(right: false))
            Text("Right stick").tag(ControllerMouseMapping.stick(right: true))
        }
    }

    private var buttonChoices: some View {
        Group {
            Text("Select buttons in the diagram or record them on your controller.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Record buttons…") { record() }.disabled(device.captureSource == nil || !device.connected)
            Button("Clear binding") { capture?.stop(); capture = nil; sources = [] }
            ForEach(device.controls.filter { allowed($0.id) }) { control in
                Toggle(control.name, isOn: Binding(get: { sources.contains(control.id) }, set: { _ in toggle(control.id) }))
            }
        }
    }

    private func allowed(_ source: ControllerLayoutSource) -> Bool {
        switch target {
        case .mouse: source.isMouseButton
        case .shortcut: source.isChordButton
        }
    }

    private func toggle(_ source: ControllerLayoutSource) {
        if target.isStick {
            switch source {
            case .axis(.leftX), .axis(.leftY): sources = ControllerMouseMapping.stick(right: false)
            case .axis(.rightX), .axis(.rightY): sources = ControllerMouseMapping.stick(right: true)
            default: break
            }
        } else if allowed(source) {
            capture?.stop(); capture = nil
            if sources.contains(source) { sources.remove(source) } else { sources.insert(source) }
        }
    }

    private func record() {
        guard let input = device.captureSource else { return }
        capture?.stop()
        let minimum: Int
        switch target {
        case .mouse: minimum = 1
        case .shortcut: minimum = 3
        }
        let next = ControllerLayoutCapture(input: input, recordingChord: true, minimumButtons: minimum)
        capture = next
        next.start { dismiss() }
    }

    private func save() {
        saving = true
        capture?.stop()
        Task {
            do {
                switch target {
                case .mouse(let action): try model.saveMouse(sources, action: action, device: device)
                case .shortcut(let action): try await model.saveShortcut(sources, action: action, device: device)
                }
                dismiss()
            } catch { failure = "Couldn't save the binding. Try again."; saving = false }
        }
    }
}
