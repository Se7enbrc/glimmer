// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

extension LauncherModel {
    func prepareControllerLayoutGames() {
        guard let pc = controllerLayoutPC else { return }
        let current = apps.compactMap { app -> ControllerLayoutGame? in
            guard let appID = UInt32(exactly: app.id) else { return nil }
            return .init(pcID: pc.id, appID: appID, pcName: pc.name, name: app.name)
        }
        let layouts = ControllerLayoutsModel.shared
        layouts.games = layouts.games.filter { $0.pcID != pc.id } + current
    }
}

struct IOSControllerLayoutAppMenu: ViewModifier {
    let model: LauncherModel
    let app: HostApp
    @State private var presented = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Controller layout…", systemImage: "gamecontroller") { presented = true }
                .disabled(model.controllerLayoutPC == nil)
        }
        .sheet(isPresented: $presented) {
            if let pc = model.controllerLayoutPC {
                NavigationStack {
                    ControllerLayoutsView(initialScope: .game(pcID: pc.id, appID: UInt32(clamping: app.id)))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = false } }
                        }
                }
                .onAppear { model.prepareControllerLayoutGames() }
            }
        }
    }
}
