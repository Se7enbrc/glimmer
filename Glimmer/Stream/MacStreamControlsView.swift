// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct MacStreamControlsView: View {
    @Bindable var model: MacStreamControls
    @FocusState private var focus: MacStreamControls.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title).font(.headline).lineLimit(2).accessibilityAddTraits(.isHeader)
            Text(model.pcName).font(.subheadline).foregroundStyle(.secondary)
            if model.page == .help {
                Text("Hold Menu for 2 seconds, then release to open stream controls.")
                Text("Use the directional pad or left stick to move, the bottom button to choose, "
                     + "and the right button to close.")
                Text("Mouse mode uses your controller's mouse controls. Choose Controller layout… to change them.")
            } else if model.page == .quit {
                Text("Quit \(model.title) on \(model.pcName)?").font(.headline)
                Text("Unsaved progress may be lost. Other streams from \(model.pcName) will stop.")
            }
            ForEach(model.actions, id: \.self) { action in
                Button(role: action == .confirm ? .destructive : nil) { model.perform(action) } label: {
                    Label(label(action), systemImage: symbol(action)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .focusable(true, interactions: .edit)
                .focused($focus, equals: action)
                .accessibilityIdentifier(identifier(action))
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focus = model.selection }
        .onChange(of: model.selection) { _, value in focus = value }
        .onChange(of: focus) { _, value in if let value { model.selection = value } }
        .onMoveCommand { direction in
            model.handle(direction == .up || direction == .left ? .up : .down)
        }
        .onKeyPress(.space) { model.perform(model.selection); return .handled }
        .onKeyPress(.return) { model.perform(model.selection); return .handled }
        .onExitCommand { model.handle(.dismiss) }
    }

    private func label(_ action: MacStreamControls.Action) -> String {
        switch action {
        case .resume: "Resume"
        case .stats: model.statsShown ? "Hide stream stats" : "Show stream stats"
        case .mouse: model.mouseMode ? "Use gamepad mode" : "Use mouse mode"
        case .layouts: "Controller layout…"
        case .help: "Help"
        case .quit: "Quit \(model.title)…"
        case .disconnect: "Disconnect"
        case .cancel: "Cancel"
        case .confirm: "Quit \(model.title)"
        case .done: "Done"
        }
    }

    private func identifier(_ action: MacStreamControls.Action) -> String {
        switch action {
        case .stats: "stream-stats-toggle"
        case .mouse: "stream-controller-mode"
        case .layouts: "stream-controller-layouts"
        default: "stream-\(action.rawValue)"
        }
    }

    private func symbol(_ action: MacStreamControls.Action) -> String {
        switch action {
        case .resume: "play.fill"
        case .stats: "chart.xyaxis.line"
        case .mouse: "computermouse"
        case .layouts: "gamecontroller"
        case .help: "questionmark.circle"
        case .quit, .confirm: "stop"
        case .disconnect, .cancel: "xmark"
        case .done: "checkmark"
        }
    }
}
