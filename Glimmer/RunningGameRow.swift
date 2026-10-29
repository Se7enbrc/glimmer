// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct RunningGameMenu: View {
    let host: Host
    let app: LibraryApp
    let requestSize: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.launcherAppIsRunning(app, on: host) {
            Button("Resume") { model.requestStream(app: app, on: host) }
            Button("Quit \(app.name)…", role: .destructive) { model.requestQuitGame(on: host, app: app) }
                .disabled(model.menuStopInProgress)
            if model.leaveGamesRunning, !model.isStreaming {
                Button(model.screenSizeNeedsRestart(app: app, host: host)
                       ? "Restart at this screen's size…" : "Use this screen's size…", action: requestSize)
            }
            if let trial = model.pictureTrial, trial.host.id == host.id, trial.app.id == app.id {
                Text("Does \(app.name) look right?")
                Button("Keep this size", action: model.keepPictureSize)
                Button("Use the previous size", action: model.restorePictureSize)
            }
            Divider()
        }
    }
}

struct RunningGameSizeConfirmation: ViewModifier {
    let host: Host
    let app: LibraryApp
    @Binding var presented: Bool
    @Environment(AppModel.self) private var model

    private var restart: Bool { model.screenSizeNeedsRestart(app: app, host: host) }

    func body(content: Content) -> some View {
        content.confirmationDialog(restart ? "Restart \(app.name) at this screen's size?"
                                   : "Change the size for \(app.name)?", isPresented: $presented,
                                   titleVisibility: .visible) {
            if !restart {
                Button("Use this screen's size") { model.confirmScreenSize(app: app, host: host, restart: false) }
            }
            Button("Quit \(app.name) and restart", role: .destructive) {
                model.confirmScreenSize(app: app, host: host, restart: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Some games may close or display incorrectly when the PC's screen size changes. Save your progress first.")
        }
    }
}

struct LauncherTakeoverConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
        .alert(
            model.pendingTakeover.map {
                TakeoverDialogCopy.title(occupantApp: $0.occupantApp, targetApp: $0.app.name)
            } ?? "",
            isPresented: Binding(
                get: { model.pendingTakeover != nil },
                set: { if !$0 { model.pendingTakeover = nil } }
            ),
            presenting: model.pendingTakeover
        ) { pending in
            Button("Quit \(pending.occupantApp ?? "the running app") and start \(pending.app.name)", role: .destructive) {
                model.confirmPendingTakeover()
            }
            Button("Cancel", role: .cancel) { model.pendingTakeover = nil }
        } message: { _ in
            Text(TakeoverDialogCopy.message)
        }
    }
}

struct DisconnectSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Leave games running when you disconnect", isOn: $model.leaveGamesRunning)
        } footer: {
            Text("For games and PCs that handle a change in screen size. Otherwise, disconnecting quits the game.")
        }
    }
}
