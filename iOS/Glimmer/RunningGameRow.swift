// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct RunningGameMenu: View {
    let model: LauncherModel
    let app: HostApp

    var body: some View {
        if model.runningApp?.id == app.id {
            Button("Resume", action: model.continueGame)
            Button("Quit \(app.name)…", role: .destructive, action: model.requestQuitFromMenu)
            if model.leaveGamesRunning {
                Button(model.screenSizeNeedsRestart ? "Restart at this screen's size…" : "Use this screen's size…",
                       action: model.requestScreenSize)
            }
            if let trial = model.pictureTrial, trial.app.id == app.id {
                Text("Does \(app.name) look right?")
                Button("Keep this size", action: model.keepPictureSize)
                Button("Use the previous size", action: model.restorePictureSize)
            }
            Divider()
        }
    }
}

struct RunningGameConfirmation: ViewModifier {
    @Bindable var model: LauncherModel

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { model.pendingGameAction != nil }, set: { if !$0 { model.pendingGameAction = nil } }),
            presenting: model.pendingGameAction) { action in
            Button(button(action), role: action.resize && !action.restart ? nil : .destructive) {
                model.confirmGameAction(action)
            }
            if action.resize && !action.restart {
                Button("Quit \(action.running.name) and restart", role: .destructive) {
                    var restart = action
                    restart.restart = true
                    model.confirmGameAction(restart)
                }
            }
            Button("Cancel", role: .cancel) { model.pendingGameAction = nil }
        } message: { action in
            if action.resize && !action.restart {
                Text("Some games may close or display incorrectly when the PC's screen size changes. "
                     + "Save your progress first.")
            } else if action.target != nil && !action.restart {
                Text(TakeoverDialogCopy.message)
            } else {
                Text("\(action.running.name) is running. Unsaved progress may be lost. "
                     + "Other streams from \(model.selectedName ?? "the PC") will stop.")
            }
        }
    }

    private var title: String {
        guard let action = model.pendingGameAction else { return "" }
        if action.restart { return "Restart \(action.running.name) at this screen's size?" }
        if action.resize { return "Change the size for \(action.running.name)?" }
        if let target = action.target {
            return TakeoverDialogCopy.title(occupantApp: action.running.name, targetApp: target.name)
        }
        return "Quit \(action.running.name) on \(model.selectedName ?? "the PC")?"
    }

    private func button(_ action: LauncherModel.GameAction) -> String {
        if action.resize && !action.restart { return "Use this screen's size" }
        if action.restart { return "Quit \(action.running.name) and restart" }
        if let target = action.target { return "Quit \(action.running.name) and start \(target.name)" }
        return "Quit \(action.running.name)"
    }
}
