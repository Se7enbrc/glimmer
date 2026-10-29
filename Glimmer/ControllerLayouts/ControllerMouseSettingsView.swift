// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerMouseSettingsSection: View {
    var model = ControllerLayoutsModel.shared

    var body: some View {
        Section("Controller mouse") {
            NavigationLink {
                ControllerMouseSettingsView(model: model)
            } label: {
                LabeledContent("Controller mouse", value: model.mouse.title)
            }
        }
    }
}

struct ControllerMouseSettingsView: View {
    var model = ControllerLayoutsModel.shared
    var previewDevice: ControllerLayoutDevice?
    @State private var deviceID: String?
    @State private var action: ControllerMouseAction?
    @State private var resetting = false
    @State private var failure: String?
    @State private var editingID = UUID()

    private var device: ControllerLayoutDevice {
        previewDevice ?? model.devices.first { $0.id == deviceID } ?? model.devices.first ?? Self.generic
    }

    private var effective: ControllerMouseBindings { model.mouse.resolving(model.shortcuts(device)) }

    static var generic: ControllerLayoutDevice {
        let controls = ControllerLayout.standard(buttons: ControllerMappedButton.allCases).bindings.map {
            ControllerLayoutControl(id: $0.source, name: $0.source.layoutName, symbol: $0.source.layoutSymbol)
        }
        return ControllerLayoutDevice(id: "mouse", name: "Controller", identity: nil,
            owner: .type("mouse"), reader: nil, controller: nil, controls: controls, nintendoLabels: false)
    }

    var body: some View {
        Form {
            Section {
                ControllerSettingsPicker(title: "Preset", value: model.mouse.preset.title,
                    selection: Binding(get: { model.mouse.preset }, set: { selectPreset($0) })) {
                    ForEach(ControllerMouseMapping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.mouse.isCustom {
                    LabeledContent("Mapping", value: "Custom")
                    Text("Your custom bindings are kept when you choose a preset.")
                        .controllerSettingsFootnote().foregroundStyle(.secondary)
                }
                ControllerSettingsRow(title: "Reset to \(model.mouse.preset.title)…") { resetting = true }
            }
            if model.devices.count > 1 {
                Section {
                    ControllerSettingsPicker(title: "Controller", value: device.name,
                        selection: Binding(get: { device.id }, set: { deviceID = $0 })) {
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                    }
                }
            }
            Section {
                ControllerMouseDiagram(bindings: effective, device: device)
            }
            Section {
                ForEach(ControllerMouseAction.allCases) { item in
                    ControllerSettingsRow(title: item.title,
                        value: ControllerMouseHelp.describe(effective[item], device: device)) { action = item }
                        .accessibilityHint("Changes this mouse binding.")
                }
            } header: { Text("Mouse controls").foregroundStyle(.secondary) }
            Section {
                #if os(iOS)
                Text("Hold the mouse-mode toggle for 2 seconds to open stream controls, then choose a mode.")
                #else
                Text("Hold the mouse-mode toggle for a second and release to switch between the game and the mouse.")
                #endif
                Text("Bindings use physical controls in every game. A control already in use must be changed first.")
            }.controllerSettingsFootnote().foregroundStyle(.secondary)
            if let failure = failure ?? model.loadError { Section { Text(failure).foregroundStyle(.red) } }
        }
        .controllerSettingsForm()
        .disabled(!model.loaded)
        .navigationTitle("Controller mouse")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $action) {
            ControllerBindingRecorder(model: model, device: device, target: .mouse($0))
        }
        .confirmationDialog("Reset to \(model.mouse.preset.title)?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset to preset", role: .destructive) {
                do { try model.resetMouseToPreset() } catch { failure = "Couldn't save the controls. Try again." }
            }
        } message: { Text("This replaces your custom mouse bindings. Glimmer shortcuts are kept.") }
        .task { await model.load() }
        .onAppear { ControllerLayoutEditing.begin(editingID); model.beginObserving() }
        .onDisappear { model.endObserving(); ControllerLayoutEditing.end(editingID) }
    }

    private func selectPreset(_ preset: ControllerMouseMapping) {
        do { try model.selectMousePreset(preset) } catch { failure = "Couldn't save the controls. Try again." }
    }
}

struct ControllerMouseDiagram: View {
    let bindings: ControllerMouseBindings
    var device = ControllerMouseSettingsView.generic
    @State private var selected = ControllerMouseAction.pointer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControllerSettingsPicker(title: "Show control", value: selected.title, selection: $selected) {
                ForEach(ControllerMouseAction.allCases) { Text($0.title).tag($0) }
            }
            ControllerLayoutDiagram(family: device.diagramFamily, controls: device.controls,
                highlighted: Set(ControllerMouseAction.allCases.flatMap { bindings[$0] }),
                annotations: ControllerDiagramAnnotation.mouse(bindings), focused: bindings[selected]) { control in
                    if let action = ControllerMouseAction.allCases.first(where: { bindings[$0].contains(control.id) }) {
                        selected = action
                    }
                }
            Text("\(selected.title): \(ControllerMouseHelp.describe(bindings[selected], device: device))")
                .controllerSettingsFootnote().foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum ControllerMouseHelp {
    static func describe(_ sources: Set<ControllerLayoutSource>, device: ControllerLayoutDevice) -> String {
        if sources == ControllerMouseMapping.stick(right: true) { return "Right stick" }
        if sources == ControllerMouseMapping.stick(right: false) { return "Left stick" }
        return ControllerLayoutShortcutSummary.describe(sources, controls: device.controls)
    }
}
