// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

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
struct GlimmerSettings: View {
    @Binding var profile: StreamProfile
    @Binding var stick: ControllerMouseStick
    let model: LauncherModel
    var addPC: () -> Void = {}
    var pairPC: (HostDiscovery.Discovered) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    enum Page: String, CaseIterable, Identifiable {
        case general, quality, pcs, input
        #if GLIMMER_DIAGNOSTICS
        case diagnostics
        #endif
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "General"
            case .quality: "Quality"
            case .pcs: "PCs"
            case .input: "Input"
            #if GLIMMER_DIAGNOSTICS
            case .diagnostics: "Diagnostics"
            #endif
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .quality: "gauge.with.dots.needle.67percent"
            case .pcs: "display"
            case .input: "gamecontroller"
            #if GLIMMER_DIAGNOSTICS
            case .diagnostics: "stethoscope"
            #endif
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Page.allCases) { page in
                        NavigationLink { settingsPage(page) } label: {
                            if dynamicTypeSize.isAccessibilitySize {
                                Text(page.title)
                            } else {
                                Label(page.title, systemImage: page.symbol)
                            }
                        }
                    }
                }
                Section {
                    if let url = URL(string: "https://se7enbrc.github.io/glimmer/support/") {
                        Link("Support", destination: url)
                    }
                    if let url = URL(string: "https://se7enbrc.github.io/glimmer/privacy/") {
                        Link("Privacy Policy", destination: url)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    func settingsPage(_ page: Page) -> some View {
        GlimmerSettingsPage(profile: $profile, stick: $stick, model: model,
                            addPC: addPC, pairPC: pairPC, page: page)
    }
}

@MainActor
private struct GlimmerSettingsPage: View {
    @Binding var profile: StreamProfile
    @Binding var stick: ControllerMouseStick
    let model: LauncherModel
    let addPC: () -> Void
    let pairPC: (HostDiscovery.Discovered) -> Void
    let page: GlimmerSettings.Page
    @AppStorage("launcherStyle") private var launcherStyle: LauncherStyle = .buttons
    @AppStorage("leaveGamesRunning") private var leaveGamesRunning = false
    @AppStorage("touchMouseEnabled") private var touchMouseEnabled = true
    #if GLIMMER_DIAGNOSTICS
    @AppStorage("telemetryEnabled") private var diagnostics = true
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Form {
            switch page {
            case .general:
                Section("Launcher") {
                    Picker("Layout", selection: $launcherStyle) {
                        ForEach(LauncherStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("Leave games running when you disconnect", isOn: $leaveGamesRunning)
                } footer: {
                    Text("For games and PCs that handle a change in screen size. "
                         + "Otherwise, disconnecting quits the game.")
                }
            case .quality: StreamQualitySettings(profile: $profile)
            case .pcs: computerSettings
            case .input: controllerSettings
            #if GLIMMER_DIAGNOSTICS
            case .diagnostics: diagnosticSettings
            #endif
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
                ForEach(model.savedPCs) { PairedPCRow(pc: $0, model: model) }
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

    #if GLIMMER_DIAGNOSTICS
    private var diagnosticSettings: some View {
        Section {
            Toggle("Record diagnostics", isOn: $diagnostics)
        } footer: {
            Text("Saves performance and troubleshooting files on this device for the next stream. "
                 + "Nothing is uploaded. Beta builds turn this on by default.")
        }
    }
    #endif
}

@MainActor
private struct PairedPCRow: View {
    let pc: SavedPC
    let model: LauncherModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let title = Label(pc.name, systemImage: "display")
            .fixedSize(horizontal: false, vertical: true)
        let forget = Button("Forget…", role: .destructive) { model.requestForget(pc) }
            .accessibilityLabel("Forget \(pc.name)")
            .disabled(!model.canForgetPC)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { title; forget }
            } else {
                HStack { title; Spacer(); forget }
            }
        }
    }
}

@MainActor
private struct StreamQualitySettings: View {
    @Binding var profile: StreamProfile
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                streamProfilePicker.pickerStyle(.inline)
            } else {
                streamProfilePicker
            }
        } header: {
            Text("Stream")
        } footer: {
            Text(streamExplanation)
        }
    }

    private var streamProfilePicker: some View {
        Picker("Stream format", selection: $profile) {
            ForEach(StreamProfile.allCases) { option in
                Text(option.label).fixedSize(horizontal: false, vertical: true).tag(option)
            }
        }
    }

    private var streamExplanation: String {
        "Native chooses the closest size from the iPhone and iPad display modes. "
            + "Install those modes on the PC. The whole picture fits the window. "
            + "Some games need 16:9. Choose 1080p if the picture looks wrong. Changes apply to the next stream."
    }
}
