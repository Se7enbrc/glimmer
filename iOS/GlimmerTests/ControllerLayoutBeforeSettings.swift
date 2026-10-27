// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
@testable import Glimmer

enum ControllerMouseStick: String, CaseIterable, Identifiable, Sendable {
    case left, right

    var id: String { rawValue }
    var label: String { self == .right ? "Right" : "Left" }
    var mapping: ControllerMouseMapping { self == .right ? .rightStick : .leftStick }
    var controls: String {
        self == .right ? "Right stick moves. R2 clicks. R1 right-clicks. Left stick scrolls."
            : "Left stick moves. L2 clicks. L1 right-clicks. Right stick scrolls."
    }
}

@MainActor
struct ControllerLayoutBeforeSettings: View {
    @Binding var profile: StreamProfile
    @Binding var stick: ControllerMouseStick
    let model: LauncherModel
    var addPC: () -> Void = {}
    var pairPC: (HostDiscovery.Discovered) -> Void = { _ in }
    @AppStorage("launcherStyle") private var launcherStyle: LauncherStyle = .buttons
    @AppStorage("touchMouseEnabled") private var touchMouseEnabled = true
    @AppStorage("telemetryEnabled") private var diagnostics = false
    @Environment(\.dismiss) private var dismiss
    enum Page: String, CaseIterable, Identifiable {
        case general, quality, pcs, input, diagnostics
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "General"
            case .quality: "Quality"
            case .pcs: "PCs"
            case .input: "Input"
            case .diagnostics: "Diagnostics"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .quality: "gauge.with.dots.needle.67percent"
            case .pcs: "display"
            case .input: "gamecontroller"
            case .diagnostics: "stethoscope"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(Page.allCases) { page in
                NavigationLink { settingsPage(page) } label: {
                    Label(page.title, systemImage: page.symbol)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    func settingsPage(_ page: Page) -> some View {
        Form {
            switch page {
            case .general:
                Section("Launcher") {
                    Picker("Layout", selection: $launcherStyle) {
                        ForEach(LauncherStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
            case .quality: streamSettings
            case .pcs: computerSettings
            case .input: controllerSettings
            case .diagnostics: diagnosticSettings
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget this PC?", isPresented: Binding(
            get: { model.pendingForget != nil },
            set: { if !$0 { model.cancelForget() } }
        ), titleVisibility: .visible, presenting: model.pendingForget) { pc in
            Button("Forget PC", role: .destructive) { model.confirmForget(pc) }
            Button("Cancel", role: .cancel) { model.cancelForget() }
        } message: { pc in
            Text("Remove the saved pairing with \(pc.name) from this device? You'll need to pair again to connect.")
        }
    }

    @ViewBuilder private var computerSettings: some View {
        if !model.savedPCs.isEmpty {
            Section("Paired PCs") {
                ForEach(model.savedPCs) { pc in
                    HStack {
                        Label(pc.name, systemImage: "display")
                        Spacer()
                        Button("Forget…", role: .destructive) { model.requestForget(pc) }
                            .accessibilityLabel("Forget \(pc.name)")
                            .disabled(!model.canForgetPC)
                    }
                }
            }
        }
        if let failure = model.forgetFailure {
            Section { Text(failure).foregroundStyle(.red) }
        }
        Section {
            ForEach(model.discovered.filter { nearby in
                !model.savedPCs.contains { $0.address == nearby.host && $0.httpPort == nearby.port }
            }) { pc in
                Button(pc.displayName, systemImage: "display") { pairPC(pc) }
            }
            Button("Add PC by address…", systemImage: "plus") { addPC() }
        } header: {
            Text("Pair a PC")
        } footer: {
            Text(model.discoveryDenied ? "Allow local network access in Settings to find the PC."
                 : "Open Sunshine on the PC and connect to the same network.")
        }
    }

    private var streamSettings: some View {
        Section {
            Picker("Stream format", selection: $profile) {
                ForEach(StreamProfile.allCases) { option in Text(option.label).tag(option) }
            }
        } header: {
            Text("Stream")
        } footer: {
            Text("Native matches this display's full resolution. The PC needs the same display mode. "
                 + "Some games need 16:9. Choose 1080p if the picture looks wrong. "
                 + "Changes apply to the next stream.")
        }
    }

    @ViewBuilder private var controllerSettings: some View {
        Section {
            Toggle(isOn: $touchMouseEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Touch mouse")
                    Text("Move and click with touch, even with a controller connected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Turn off to avoid accidental touches while playing. Three-finger tap still shows controls. "
                 + "Changes apply to the next stream.")
        }
        Section {
            Picker("Mouse stick", selection: $stick) {
                ForEach(ControllerMouseStick.allCases) { option in Text(option.label).tag(option) }
            }
        } header: {
            Text("Controller")
        } footer: {
            Text("\(stick.controls) Hold Menu for a second and release to switch modes. "
                 + "Changes apply to the next stream.")
        }
    }

    private var diagnosticSettings: some View {
        Section {
            Toggle("Record diagnostics", isOn: $diagnostics)
        } footer: {
            Text("Saves performance and troubleshooting files on this iPhone for the next stream. "
                 + "Nothing is uploaded. Development builds enable this by default.")
        }
    }
}
