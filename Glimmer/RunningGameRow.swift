// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct RunningGameRow: View {
    let host: Host
    let app: LibraryApp
    let focus: FocusState<LauncherFocus?>.Binding
    @Environment(AppModel.self) private var model
    @State private var confirmingQuit = false
    @State private var confirmingSize = false
    @State private var working = false
    @State private var failure: String?

    private var restartSize: Bool { model.screenSizeNeedsRestart(app: app, host: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(app.name) is running on \(host.displayName).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            if model.leaveGamesRunning, !model.isStreaming {
                Text("Another device may still be connected.").font(.footnote).foregroundStyle(.secondary)
            }
            if let trial = model.pictureTrial, trial.host.id == host.id, !model.isStreaming {
                Text("Does \(trial.app.name) look right?")
                HStack {
                    Button("Keep this size", action: model.keepPictureSize)
                    Button("Use the previous size", action: model.restorePictureSize)
                }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
        }
        .preference(key: LauncherFocusCells.self,
                    value: model.leaveGamesRunning && !model.isStreaming
                        ? [.runningResume, .runningQuit, .runningSize] : [.runningResume, .runningQuit])
        .disabled(working || model.menuStopInProgress)
        .confirmationDialog("Quit \(app.name) on \(host.displayName)?", isPresented: $confirmingQuit,
                            titleVisibility: .visible) {
            Button("Quit \(app.name)", role: .destructive) {
                working = true
                Task {
                    defer { working = false }
                    do { try await model.quitRunningApp(on: host, expectedAppID: app.id) } catch {
                        failure = AppModel.quitFailureMessage(for: error, hostName: host.displayName)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Unsaved progress may be lost. Other streams from \(host.displayName) will stop.") }
        .confirmationDialog(restartSize ? "Restart \(app.name) at this screen's size?"
                            : "Change the size for \(app.name)?", isPresented: $confirmingSize,
                            titleVisibility: .visible) {
            if !restartSize {
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

    @ViewBuilder private var actions: some View {
        Button(model.continuationTitle(on: host, app: app)) { model.requestStream(app: app, on: host) }
            .modifier(LauncherControlFocus(focus: focus, target: .runningResume) {
                model.requestStream(app: app, on: host)
            })
            .accessibilityHint("Continues \(app.name) from \(host.displayName) on this Mac.")
        Button("Quit \(app.name)…", role: .destructive) { confirmingQuit = true }
            .modifier(LauncherControlFocus(focus: focus, target: .runningQuit) { confirmingQuit = true })
        if model.leaveGamesRunning, !model.isStreaming {
            Button(restartSize ? "Restart at this screen's size…" : "Use this screen's size…") {
                confirmingSize = true
            }
            .modifier(LauncherControlFocus(focus: focus, target: .runningSize) { confirmingSize = true })
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
