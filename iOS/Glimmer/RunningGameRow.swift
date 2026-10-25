// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct RunningGameRow: View {
    let model: LauncherModel

    var body: some View {
        if let ended = model.endedGame {
            Button(model.endedFormat == nil ? "Start \(ended.name)" : "Start \(ended.name) at the previous size",
                   action: model.startEndedGame)
                .buttonStyle(.bordered).disabled(model.busy)
        }
        if let app = model.runningApp, let pc = model.selectedName {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(app.name) is running on \(pc).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { actions(app: app) }
                    VStack(alignment: .leading) { actions(app: app) }
                }
                if model.leaveGamesRunning {
                    Text("Another device may still be connected.").font(.footnote).foregroundStyle(.secondary)
                }
                if let trial = model.pictureTrial {
                    Text("Does \(trial.app.name) look right?")
                    Button("Keep this size", action: model.keepPictureSize)
                    Button("Use the previous size", action: model.restorePictureSize)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.busy)
        }
    }

    @ViewBuilder private func actions(app: HostApp) -> some View {
        Button(model.continuationTitle, action: model.continueGame)
            .accessibilityHint("Continues \(app.name) from the PC on this device.")
        Button("Quit \(app.name)…", role: .destructive, action: model.requestQuit)
        if model.leaveGamesRunning {
            Button(model.screenSizeNeedsRestart ? "Restart at this screen's size…" : "Use this screen's size…",
                   action: model.requestScreenSize)
        }
        Button("Refresh", action: model.refreshPC)
    }
}

struct RunningGameConfirmation: ViewModifier {
    @Bindable var model: LauncherModel

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(
            get: { model.pendingGameAction != nil }, set: { if !$0 { model.pendingGameAction = nil } }),
            titleVisibility: .visible, presenting: model.pendingGameAction) { action in
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
        if let target = action.target { return "Start \(target.name) on \(model.selectedName ?? "the PC")?" }
        return "Quit \(action.running.name) on \(model.selectedName ?? "the PC")?"
    }

    private func button(_ action: LauncherModel.GameAction) -> String {
        if action.resize && !action.restart { return "Use this screen's size" }
        if action.restart { return "Quit \(action.running.name) and restart" }
        if let target = action.target { return "Quit \(action.running.name) and start \(target.name)" }
        return "Quit \(action.running.name)"
    }
}
