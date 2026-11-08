// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct MacStreamControlsView: View {
    @Bindable var model: MacStreamControls
    @FocusState private var focus: MacStreamControls.Action?

    var body: some View {
        GeometryReader { geometry in
            let scale = Self.scale(for: geometry.size)
            ZStack {
                Button { model.handle(.dismiss) } label: { Color.black.opacity(0.16) }
                    .buttonStyle(.plain).focusable(false).accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    pane(scale: scale).fixedSize(horizontal: false, vertical: true)
                    scrollingPane(scale: scale)
                }
                .frame(width: min(520 * scale, max(0, geometry.size.width - 48)))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

    static func scale(for size: CGSize) -> CGFloat {
        min(2, max(1, min(size.width / 1280, size.height / 900)))
    }

    private func pane(scale: CGFloat) -> some View {
        paneContents(scale: scale)
            .modifier(MacStreamGlassSurface(radius: 28 * scale))
    }

    private func scrollingPane(scale: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView { paneContents(scale: scale) }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.selection, initial: true) { _, action in proxy.scrollTo(action, anchor: .center) }
        }
        .modifier(MacStreamGlassSurface(radius: 28 * scale))
    }

    private func paneContents(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text(model.title).streamFont(.largeTitle, scale: scale).bold().lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(model.pcName).streamFont(.title3, scale: scale).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12 * scale).padding(.bottom, 8 * scale)
            if model.page == .help {
                VStack(alignment: .leading, spacing: 16 * scale) {
                    Label("Stream controls", systemImage: "gamecontroller").streamFont(.title2, scale: scale).bold()
                    Text("Hold Menu for 2 seconds, then release to open stream controls.")
                    Text("Use the directional pad or left stick to move, the bottom button to choose, "
                         + "and the right button to close.")
                    Text("Mouse mode uses your controller's mouse controls. Choose Controller layout… to change them.")
                }.streamFont(.title3, scale: scale).padding(12 * scale)
            } else if model.page == .quit {
                VStack(alignment: .leading, spacing: 12 * scale) {
                    Text("Quit \(model.title) on \(model.pcName)?").streamFont(.title2, scale: scale).bold()
                    Text("Unsaved progress may be lost. Other streams from \(model.pcName) will stop.")
                        .streamFont(.title3, scale: scale).foregroundStyle(.secondary)
                }.padding(12 * scale)
            }
            VStack(spacing: 4 * scale) {
                ForEach(model.actions, id: \.self) { action in
                    if action == .quit { Divider().padding(.vertical, 8 * scale) }
                    Button(role: action == .confirm || action == .quit ? .destructive : nil) {
                        model.perform(action)
                    } label: {
                        Label(label(action), systemImage: symbol(action))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(MacStreamActionStyle(selected: model.selection == action, scale: scale))
                    .labelStyle(MacStreamActionLabelStyle(scale: scale))
                    .focusable(true, interactions: .edit)
                    .focused($focus, equals: action)
                    .accessibilityIdentifier(identifier(action))
                    .id(action)
                }
            }
            HStack(spacing: 16 * scale) {
                Label("Choose", systemImage: model.chooseSymbol)
                Label(model.page == .actions ? "Resume" : "Back", systemImage: model.backSymbol)
            }
            .streamFont(.title3, scale: scale).foregroundStyle(.secondary)
            .padding(.horizontal, 12 * scale).padding(.top, 8 * scale)
            .accessibilityLabel("Bottom button to choose. Right button to go back.")
        }
        .padding(24 * scale)
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

private struct MacStreamActionLabelStyle: LabelStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12 * scale) {
            configuration.icon.frame(width: 28 * scale)
            configuration.title
        }
    }
}

struct MacStreamGlassSurface: ViewModifier {
    var radius: CGFloat = 28
    @Environment(\.accessibilityReduceTransparency) private var opaque

    func body(content: Content) -> some View {
        content.background {
            Group {
                if opaque {
                    RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Color.clear.glassSurface(in: .rect(cornerRadius: radius))
                }
            }
            .ignoresSafeArea()
        }
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }
}

private struct MacStreamActionStyle: ButtonStyle {
    let selected: Bool
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .streamFont(.title1, scale: scale)
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            .padding(.horizontal, 16 * scale)
            .frame(minHeight: 56 * scale, alignment: .leading)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : selected ? 0.09 : 0),
                        in: .rect(cornerRadius: 14 * scale))
            .overlay {
                RoundedRectangle(cornerRadius: 14 * scale)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(.rect(cornerRadius: 14 * scale))
    }
}
