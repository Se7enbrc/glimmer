// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

@MainActor
struct LauncherView: View {
    static let pcSymbol = "display"

    @Environment(\.scenePhase) private var scenePhase
    @State private var controllers = ControllerMonitor()
    @State private var model: LauncherModel

    init(model: LauncherModel = .make()) { _model = State(initialValue: model) }

    var body: some View {
        NavigationStack {
            List {
                computers
                if let name = model.selectedName {
                    Section(name) {
                        if model.busy { ProgressView("Connecting…") }
                        ForEach(model.apps) { app in
                            Button(app.name, systemImage: "play.fill") { model.launch(app) }
                                .disabled(model.busy)
                        }
                    }
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                Section("Controllers") {
                    if controllers.controllers.isEmpty {
                        Text("Connect a controller to get started.").foregroundStyle(.secondary)
                    }
                    ForEach(controllers.controllers) { controller in
                        LabeledContent(controller.name,
                                       value: controller.hasExtendedGamepad ? "Connected" : "Unsupported controls")
                    }
                }
            }
            .navigationTitle("Glimmer")
        }
        .tint(Color("AccentColor"))
        .sheet(item: Binding(get: { model.pairing }, set: {
            if $0 == nil { model.dismissPairing() }
        })) { prompt in
            PairingView(prompt: prompt, cancel: model.dismissPairing)
        }
        .fullScreenCover(item: $model.stream, onDismiss: model.streamClosed) { session in
            StreamView(model: session) { model.stream = nil }
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { controllers.start() } else { controllers.stop() }
            updateAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            model.availabilityChanged(active: false, background: false, protectedDataAvailable: false)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in updateAvailability() }
    }

    @ViewBuilder private var computers: some View {
        Section("Your PCs") {
            ForEach(model.savedPCs) { pc in
                Button(pc.name, systemImage: Self.pcSymbol) { model.select(pc) }
            }
            if model.savedPCs.isEmpty { Text("Pair with a PC running Sunshine.").foregroundStyle(.secondary) }
        }
        Section("Nearby PCs") {
            ForEach(model.discovered) { pc in
                Button(pc.displayName, systemImage: Self.pcSymbol) { model.select(pc) }
            }
            if model.discoveryDenied {
                Text("Allow local network access in Settings to find the PC.")
            } else if model.discovered.isEmpty {
                Text("Open Sunshine on the PC and connect to the same network.").foregroundStyle(.secondary)
            }
        }
    }

    private func updateAvailability() {
        model.availabilityChanged(active: scenePhase == .active, background: scenePhase == .background,
                                  protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
    }
}

extension StreamSessionModel: Identifiable {
    nonisolated var id: UUID { launch.id }
}
