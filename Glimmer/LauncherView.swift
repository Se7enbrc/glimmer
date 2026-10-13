// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

@MainActor
struct LauncherView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controllers = ControllerMonitor()
    @State private var showingDisplay = false
    private let engine = EngineLink()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Your PC games, on iPhone and iPad", systemImage: "display")
                    Text("Pairing and streaming are not available in this development build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Controllers") {
                    if controllers.controllers.isEmpty {
                        Text("Connect a controller to get started.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controllers.controllers) { controller in
                        LabeledContent(controller.name,
                                       value: controller.hasExtendedGamepad ? "Ready" : "Unsupported controls")
                    }
                }
                Section {
                    Button("Preview display", systemImage: "rectangle.expand.vertical") {
                        showingDisplay = true
                    }
                    .accessibilityHint("Opens a landscape display preview. No connection to the PC is made.")
                } footer: {
                    Text("GlimmerEngine · Protocol version \(engine.protocolVersion)" +
                         " · \(engine.request.count) bytes ready")
                }
            }
            .navigationTitle("Glimmer")
        }
        .tint(Color("AccentColor"))
        .fullScreenCover(isPresented: $showingDisplay) {
            StreamPreview()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { controllers.start() } else { controllers.stop() }
        }
    }
}
