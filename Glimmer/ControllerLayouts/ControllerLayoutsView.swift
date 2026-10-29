// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerLayoutsView: View {
    var model = ControllerLayoutsModel.shared
    var initialScope: ControllerLayoutScope = .allGames
    @State private var editingID = UUID()
    @ScaledMetric(relativeTo: .caption) private var statusTextSize = 12.0

    var body: some View {
        Form {
            if let error = model.loadError {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            if model.devices.isEmpty {
                ContentUnavailableView("Connect a controller", systemImage: "gamecontroller",
                    description: Text("Connected controllers and saved layouts appear here."))
            }
            Section {
                ForEach(model.devices) { device in
                    NavigationLink {
                        ControllerLayoutEditor(model: model, device: device, scope: initialScope)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label { Text(device.name) } icon: {
                                Image(systemName: "gamecontroller").foregroundStyle(Color.accentColor)
                            }
                            Text(device.connected ? "Connected" : "Not connected")
                                .font(.system(size: statusTextSize)).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Layouts are saved on this device.").controllerSettingsFootnote()
            }
        }
        .controllerSettingsForm()
        .navigationTitle("Controller layouts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .controllerLayoutNavigation()
        .onAppear { ControllerLayoutEditing.begin(editingID); model.beginObserving() }
        .task { await model.load() }
        .onDisappear { model.endObserving(); ControllerLayoutEditing.end(editingID) }
    }
}

struct ControllerLayoutEditor: View {
    let model: ControllerLayoutsModel
    private let originalDevice: ControllerLayoutDevice
    private var device: ControllerLayoutDevice { model.current(originalDevice) }
    @State var scope: ControllerLayoutScope
    @State private var editingID = UUID()
    @State private var selected: ControllerLayoutControl?
    @State private var shortcut: ControllerShortcutAction?
    @State private var capturing = false
    @State private var resetting = false
    @State private var standardReset = false
    @State private var failure: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var record: ControllerLayoutRecord? { model.resolved(device, scope: scope) }
    private var layout: ControllerLayout { model.baseline(device, scope: scope) }
    private var key: ControllerLayoutKey { .init(owner: device.owner, scope: scope) }
    private var canEdit: Bool { model.loaded && (!device.connected || device.captureSource != nil) }

    init(model: ControllerLayoutsModel, device: ControllerLayoutDevice, scope: ControllerLayoutScope) {
        self.model = model
        originalDevice = device
        _scope = State(initialValue: scope)
    }

    var body: some View {
        Form {
            scopeSection
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            Section {
                ControllerSettingsRow(title: "Change a button…", symbol: "hand.point.up.left") { capturing = true }
                    .disabled(device.captureSource == nil || !device.connected)
            }
            if !typeSize.isAccessibilitySize, !device.controls.isEmpty {
                Section {
                    ControllerLayoutDiagram(family: device.diagramFamily, controls: device.controls) { selected = $0 }
                }
                    .accessibilityHidden(true)
            }
            Section {
                ForEach(device.controls) { control in
                    ControllerSettingsRow(title: control.name, value: destination(control.id).layoutName,
                                          symbol: control.symbol) { selected = control }
                    .accessibilityLabel("\(control.name), sends \(destination(control.id).layoutName)")
                    .accessibilityHint("Changes the layout for \(scopeName).")
                }
            } header: { Text("Send to PC").foregroundStyle(.secondary) }
            .disabled(!canEdit)
            shortcutsSection
            ControllerMouseSettingsSection(model: model)
            Section {
                ControllerSettingsRow(title: "Reset to standard…") { standardReset = true }.disabled(!canEdit)
                ControllerSettingsRow(title: scope == .allGames ? "Use system layout…" : "Use All games…",
                                      role: .destructive) { resetting = true }
                    .disabled(!model.library.records.contains { $0.key == key })
            } footer: {
                Text("Game layouts change only what the PC receives. Glimmer's controls stay the same.")
                    .controllerSettingsFootnote()
            }
        }
        .controllerSettingsForm()
        .navigationTitle(device.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .controllerLayoutNavigation()
        .onAppear { ControllerLayoutEditing.begin(editingID); model.beginObserving() }
        .onDisappear { model.endObserving(); ControllerLayoutEditing.end(editingID) }
        .sheet(item: $selected) { control in
            ControllerLayoutAssignment(model: model, device: device, scope: scope, control: control, layout: layout)
        }
        .sheet(isPresented: $capturing) {
            captureSheet
        }
        // A lazy Form section cannot own a sheet that must survive its disappearance.
        .sheet(item: $shortcut) { action in
            ControllerBindingRecorder(model: model, device: device, target: .shortcut(action))
        }
        .confirmationDialog(scope == .allGames ? "Use system layout?" : "Use All games?",
                            isPresented: $resetting, titleVisibility: .visible) {
            Button(scope == .allGames ? "Use system layout" : "Use All games", role: .destructive) {
                Task {
                    do { try await model.remove(key) } catch { failure = "Couldn't save the layout. Try again." }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(scope == .allGames ? "Custom game layouts will be kept." : "This game's custom layout will be removed.")
        }
        .confirmationDialog("Reset to standard?", isPresented: $standardReset, titleVisibility: .visible) {
            Button("Reset to standard", role: .destructive) { resetStandard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep a custom layout for this scope, with the standard button positions.")
        }
    }

    private var scopeName: String {
        if scope == .allGames { return "All games" }
        return model.games.first { $0.id == scope }?.title ?? "This game"
    }

    private var scopeSection: some View {
        Section {
            ControllerSettingsPicker(title: "Layout for", value: scopeName, selection: $scope) {
                Text("All games").tag(ControllerLayoutScope.allGames)
                ForEach(model.games) { game in Text(game.title).tag(game.id) }
                if scope != .allGames, !model.games.contains(where: { $0.id == scope }) {
                    Text("This game").tag(scope)
                }
            }
            LabeledContent("Using", value: record == nil ? "System layout" :
                (record?.key.scope == scope ? "Custom layout" : "All games layout"))
            if scope != .allGames, record?.key.scope == scope {
                Label("Changed for this game", systemImage: "app.badge.checkmark")
                    .controllerSettingsFootnote()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(device.isSharedType ? "Controllers of this type share this layout." : "Only this controller uses this layout.")
                if device.connected, device.captureSource == nil {
                    Text("This connection doesn't expose physical controls. The system layout stays active.")
                } else if !device.connected {
                    Text("Connect this controller to capture a button. You can still edit the list.")
                }
            }.controllerSettingsFootnote()
        }
    }

    private var shortcutsSection: some View {
        ControllerShortcutSection(model: model, device: device) { shortcut = $0 }
    }

    private func destination(_ source: ControllerLayoutSource) -> ControllerLayoutDestination {
        layout.bindings.first { $0.source == source }?.destination ?? .disabled
    }

    private func resetStandard() {
        Task {
            let available = Set(device.controls.map(\.id))
            var standard = ControllerLayout.standard(buttons: ControllerMappedButton.allCases.filter {
                available.contains(.button($0))
            }, extras: device.captureSource?.extras ?? [])
            standard.bindings.removeAll { !available.contains($0.source) }
            do {
                try await model.save(.init(key: key, name: device.name, layout: standard,
                                           controls: device.controls, category: device.category))
            } catch {
                failure = "Couldn't save the layout. Try again."
            }
        }
    }

    @ViewBuilder private var captureSheet: some View {
        if let input = device.captureSource {
            ControllerLayoutCaptureSheet(model: model, device: device, scope: scope, layout: layout,
                capture: ControllerLayoutCapture(input: input))
        }
    }
}
