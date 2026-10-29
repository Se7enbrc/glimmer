// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

extension AppModel {
    func controllerLayoutGames() -> [ControllerLayoutGame] {
        hosts.flatMap { pc in
            pc.apps.compactMap { app in
                guard let appID = UInt32(exactly: app.id) else { return nil }
                return ControllerLayoutGame(pcID: pc.id, appID: appID, pcName: pc.displayName, name: app.name)
            }
        }
    }
}

struct ControllerLayoutAppMenu: ViewModifier {
    let host: Host
    let app: LibraryApp
    @Environment(AppModel.self) private var model
    @State private var presented = false
    @State private var confirmingSize = false

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.contextMenu { menu }
        .background {
            LauncherContextMenu(appID: app.id, requestedAppID: $model.launcherMenuAppID) { menu.environment(model) }
        }
        .modifier(RunningGameSizeConfirmation(host: host, app: app, presented: $confirmingSize))
        .sheet(isPresented: $presented) {
            NavigationStack {
                ControllerLayoutsView(initialScope: .game(pcID: host.id, appID: UInt32(clamping: app.id)))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { presented = false } }
                    }
            }
            .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 680)
            .onAppear { ControllerLayoutsModel.shared.games = model.controllerLayoutGames() }
        }
    }

    @ViewBuilder private var menu: some View {
        RunningGameMenu(host: host, app: app) { confirmingSize = true }
        Button("Controller layout…", systemImage: "gamecontroller") { presented = true }
    }
}
