// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import SwiftUI
#if os(iOS)
// handlesGameControllerEvents lives in this cross-import overlay, which CodeQL's extractor never loads implicitly.
import _GameController_SwiftUI
#endif

struct ControllerLayoutAssignment: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    let scope: ControllerLayoutScope
    let control: ControllerLayoutControl
    let layout: ControllerLayout
    @State private var destination = ControllerLayoutDestination.disabled
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(control.name, systemImage: control.symbol).font(.title2)
                    Picker("Send to PC", selection: $destination) {
                        ForEach(ControllerLayoutDestination.choices(for: control.id), id: \.self) { choice in
                            Text(choice.layoutName).tag(choice)
                        }
                    }
                    if let duplicate = layout.bindings.first(where: {
                        $0.source != control.id && $0.destination == destination && destination != .disabled
                    }) {
                        Text("\(duplicate.source.layoutName) also sends \(destination.layoutName). Either control will work.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("This layout replaces system button and stick remapping for the selected games.")
                    Text("The controller's own saved profiles still apply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Change control")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { destination = layout.bindings.first { $0.source == control.id }?.destination ?? .disabled }
        .interactiveDismissDisabled(saving)
        .controllerLayoutNavigation()
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
        #endif
    }

    private func save() {
        saving = true
        Task {
            var draft = layout
            reconcileAxes(in: &draft)
            draft.assign(control.id, to: destination)
            do {
                try await model.save(.init(key: .init(owner: device.owner, scope: scope), name: device.name,
                                           layout: draft, controls: device.controls, category: device.category))
                dismiss()
            } catch {
                failure = "Couldn't save the layout. Try again."
                saving = false
            }
        }
    }

    private func reconcileAxes(in draft: inout ControllerLayout) {
        guard destination != .disabled else { return }
        switch control.id {
        case .axis(let axis):
            for positive in [false, true] { draft.assign(.direction(axis, positive: positive), to: .disabled) }
        case .direction(let axis, _): draft.assign(.axis(axis), to: .disabled)
        default: break
        }
    }
}

struct ControllerLayoutCaptureSheet: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    let scope: ControllerLayoutScope
    let layout: ControllerLayout
    @State var capture: ControllerLayoutCapture
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let source = capture.source, let control = device.controls.first(where: { $0.id == source }) {
                ControllerLayoutAssignment(model: model, device: device, scope: scope, control: control, layout: layout)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            Label(capture.message, systemImage: "gamecontroller").font(.title3)
                                .accessibilityAddTraits(.updatesFrequently)
                            Text("Only \(device.name) is being recorded.")
                                .foregroundStyle(.secondary)
                        }
                        if let failure { Section { Text(failure).foregroundStyle(.red) } }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("Press a control")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    }
                }
            }
        }
        .onAppear { capture.start { dismiss() } }
        .onDisappear { capture.stop() }
        .onChange(of: capture.finished) { _, finished in if finished { capture.stop() } }
        .onChange(of: capture.message) { _, message in AccessibilityNotification.Announcement(message).post() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                capture.stop()
                failure = "Recording paused. Close this sheet and try again when you're ready."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { notification in
            guard let controller = device.controller, notification.object as? GCController === controller else { return }
            capture.stop()
            failure = "Controller disconnected. Your changes have been kept. Reconnect to record again."
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: HIDGamepadManager.devicesDidChange)) { _ in
            guard let id = device.hidID, HIDGamepadManager.shared.devices[id] == nil else { return }
            capture.stop()
            failure = "Controller disconnected. Your changes have been kept. Reconnect to record again."
        }
        #else
        .handlesGameControllerEvents(matching: capture.finished ? [] : .gamepad)
        #endif
    }
}
