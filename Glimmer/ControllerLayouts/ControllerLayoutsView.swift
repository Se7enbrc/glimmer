// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct ControllerLayoutsView: View {
    var model = ControllerLayoutsModel.shared
    var initialScope: ControllerLayoutScope = .allGames
    @State private var editingID = UUID()

    var body: some View {
        List {
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
                            Label(device.name, systemImage: "gamecontroller")
                            Text(device.connected ? "Connected" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Layouts are saved on this device.")
            }
        }
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
                Button("Change a button…", systemImage: "hand.point.up.left") { capturing = true }
                    .disabled(device.captureSource == nil || !device.connected)
            }
            if !typeSize.isAccessibilitySize, !device.controls.isEmpty {
                Section { ControllerLayoutDiagram(controls: device.controls) { selected = $0 } }
                    .accessibilityHidden(true)
            }
            Section {
                ForEach(device.controls) { control in
                    Button {
                        selected = control
                    } label: {
                        LabeledContent {
                            Text(destination(control.id).layoutName).foregroundStyle(.secondary)
                        } label: {
                            Label(control.name, systemImage: control.symbol)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(control.name), sends \(destination(control.id).layoutName)")
                    .accessibilityHint("Changes the layout for \(scopeName).")
                }
            } header: { Text("Send to PC") }
            .disabled(!canEdit)
            shortcutsSection
            Section {
                Button("Reset to standard…") { standardReset = true }.disabled(!canEdit)
                Button(scope == .allGames ? "Use system layout…" : "Use All games…", role: .destructive) { resetting = true }
                    .disabled(!model.library.records.contains { $0.key == key })
            } footer: {
                Text("Game layouts change only what the PC receives. Glimmer's controls stay the same.")
            }
        }
        .formStyle(.grouped)
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
            Picker("Layout for", selection: $scope) {
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
                    .font(.footnote)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(device.isSharedType ? "Controllers of this type share this layout." : "Only this controller uses this layout.")
                if device.connected, device.captureSource == nil {
                    Text("This connection doesn't expose physical controls. The system layout stays active.")
                } else if !device.connected {
                    Text("Connect this controller to capture a button. You can still edit the list.")
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section("Glimmer controls") {
            let escape = ControllerLayoutShortcuts.escape(available: Set(device.controls.map(\.id)))
            LabeledContent("Show controls", value: escape.isEmpty ? "Use the keyboard or touch controls" :
                escape.map(\.layoutName).sorted().joined(separator: " + "))
            Text("With a custom layout, hold for one second, then release. This shortcut can't be changed.")
                .font(.footnote).foregroundStyle(.secondary)
            ControllerLayoutShortcutSummary()
        }
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
            do { try await model.save(.init(key: key, name: device.name, layout: standard, controls: device.controls)) } catch {
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

struct ControllerLayoutDiagram: View {
    let controls: [ControllerLayoutControl]
    var select: (ControllerLayoutControl) -> Void

    private let rows: [[ControllerMappedButton]] = [
        [.leftShoulder, .menu, .options, .rightShoulder], [.up, .y], [.left, .down, .right, .x, .a, .b],
        [.leftStick, .rightStick], [.paddle1, .paddle2, .paddle3, .paddle4]
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    ForEach(rows[index], id: \.self) { button in
                        if let control = controls.first(where: { $0.id == .button(button) }) {
                            Button { select(control) } label: {
                                Image(systemName: control.symbol).font(.title2).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .help(control.name)
                        }
                    }
                }
            }
            let extras = controls.filter { if case .extra = $0.id { return true }; return false }
            if !extras.isEmpty {
                Text("Extra buttons").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                    ForEach(extras) { control in
                        Button { select(control) } label: {
                            Label(control.name, systemImage: control.symbol).frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
