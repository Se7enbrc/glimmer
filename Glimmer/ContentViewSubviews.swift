// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  ContentViewSubviews.swift
//
//  Host-hero pieces split out of ContentView.swift: the app-icon and
//  spec-chip rows, plus the empty-pairing and stream-ended states.
//

import Accessibility
import AppKit
import SwiftUI

struct AppIconsRow: View {
    let apps: [LibraryApp]
    let host: Host
    let focus: FocusState<LauncherFocus?>.Binding
    /// The connect is on screen (past the 400 ms hold), so the app being launched shows it.
    var connectingShown = false
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two columns of large app buttons fill the window's width with two apps or
    /// four; past four the last cell is the overflow menu.
    private static let maxInlineTiles = 4
    private static let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// The apps that get a button of their own; the rest are in the overflow menu.
    static func inlineApps(_ apps: [LibraryApp]) -> [LibraryApp] {
        apps.count <= maxInlineTiles ? apps : Array(apps.prefix(maxInlineTiles - 1))
    }

    private var inlineApps: [LibraryApp] { Self.inlineApps(apps) }

    private var overflowApps: [LibraryApp] {
        apps.count <= Self.maxInlineTiles ? [] : Array(apps.dropFirst(Self.maxInlineTiles - 1))
    }

    var body: some View {
        Group {
            if model.launcherStyle == .covers { coverGrid } else { buttonGrid }
        }
        .preference(key: LauncherFocusCells.self, value: navigationCells)
    }

    private var navigationCells: [LauncherFocus] {
        let visible = model.launcherStyle == .covers ? apps : inlineApps
        var cells = visible.filter { !model.isStreaming || tileState($0) != .ready }
            .map { LauncherFocus.app($0.id) }
        if model.launcherStyle == .buttons, !overflowApps.isEmpty { cells.append(.overflow) }
        return cells
    }

    private var buttonGrid: some View {
        // No GlassEffectContainer: it composites its glass above the app buttons' labels.
        LazyVGrid(columns: Self.columns, spacing: 10) {
            ForEach(inlineApps) { app in
                appTile(app)
            }
            // Overflow is a MENU, not more rows: the window is sized to this
            // content, and a menu opens over it at no layout cost.
            if !overflowApps.isEmpty {
                overflowMenu
            }
        }
    }

    /// Return streams the Start with app while the PC is ready; otherwise the
    /// state button (Wake, Pair Again) owns it.
    private func takesReturn(_ app: LibraryApp) -> Bool {
        guard case .stream = model.menuBarPrimaryAction else { return false }
        return app.name == model.heroTargetAppName
    }

    /// What the app that is launching or streaming shows on its own button, so the status
    /// stays on the chip and no second button appears: progress, the way out, the way back.
    enum TileState {
        case ready, connecting, reconnecting, hiddenStream

        var shortcut: KeyboardShortcut? {
            switch self {
            case .ready: nil
            case .connecting, .reconnecting: .cancelAction   // Return never cancels (users mash it)
            case .hiddenStream: .defaultAction
            }
        }

        var help: String? {
            switch self {
            case .ready: nil
            case .connecting: "Cancel the connection"
            case .reconnecting: "End the stream"
            case .hiddenStream: "Back to the stream"
            }
        }

        var spoken: (value: String, hint: String) {
            switch self {
            case .ready: ("", "")
            case .connecting: ("Connecting", "Cancels the connection")
            case .reconnecting: ("Reconnecting", "Ends the stream")
            case .hiddenStream: ("Streaming", "Returns to the stream")
            }
        }
    }

    func tileState(_ app: LibraryApp) -> TileState {
        Self.tileState(app, on: host, model: model, connectingShown: connectingShown)
    }

    /// A hidden stream wins, as the Stream button's roles do; a (re)connect shows once past the hold.
    static func tileState(_ app: LibraryApp, on host: Host, model: AppModel,
                          connectingShown: Bool) -> TileState {
        guard let attempt = model.lastLaunchAttempt, attempt.app.id == app.id,
              attempt.host.id == host.id else { return .ready }
        if model.isStreaming, model.nativeStreamBackgrounded { return .hiddenStream }
        guard connectingShown, case .connecting = model.streamPhase else { return .ready }
        return model.isReconnecting ? .reconnecting : .connecting
    }

    /// Icon, name, and a quiet play glyph: a click streams this app at once. A hidden stream's
    /// tile says where it goes instead, so the way back doesn't look like the way in.
    private func tileLabel(icon: Image, title: String, trailing: String, trailingText: String? = nil,
                           launching: Bool = false) -> some View {
        HStack(spacing: 12) {
            icon
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28, height: 28)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if launching {
                // Dark so the spinner draws light on the violet in both appearances.
                ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
            } else if let trailingText {
                Text(trailingText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(systemName: trailing)
                    .font(.footnote.weight(.bold))
                    .opacity(0.75)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60)
        .contentShape(Rectangle())
    }

    func appTile(_ app: LibraryApp, revision: String = "") -> some View {
        let state = tileState(app)
        return Button { activate(app) } label: {
            if model.launcherStyle == .covers {
                coverLabel(app, revision: revision, connecting: state == .connecting || state == .reconnecting,
                           hiddenStream: state == .hiddenStream)
            } else {
                tileLabel(icon: app.icon, title: app.name, trailing: "play.fill",
                          trailingText: state == .hiddenStream ? "Back to Stream" : nil,
                          launching: state == .connecting || state == .reconnecting)
            }
        }
        .animation(Motion.layout(reduceMotion: reduceMotion), value: state)
        .buttonStyle(LauncherTileStyle(covers: model.launcherStyle == .covers))
        .modifier(LauncherControlFocus(focus: focus, target: .app(app.id), activate: { activate(app) }))
        .keyboardShortcut(state.shortcut ?? (takesReturn(app) ? .defaultAction : nil))
        // Only the streaming app stays live; the overflow menu remains openable,
        // since looking at other apps launches nothing.
        .disabled(model.isStreaming && state == .ready)
        .help(state.help ?? (model.isStreaming
            ? "Finish the current stream first" : "Stream \(app.name)"))
        // One name, not glyph + name + play glyph read in turn.
        .accessibilityLabel(app.name)
        .accessibilityValue(state.spoken.value.isEmpty && isRunning(app) ? "Running" : state.spoken.value)
        .accessibilityHint(state.spoken.hint)
    }

    private func activate(_ app: LibraryApp) {
        switch tileState(app) {
        case .ready: model.requestStream(app: app, on: host)
        case .connecting: model.cancelConnect()
        // A reconnect is a live stream, so its way out ends it rather than cancelling.
        case .reconnecting: model.stopStreamFromMenu(source: "the launcher")
        case .hiddenStream: model.resumeStreamWindow()
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowApps) { app in
                Button {
                    model.requestStream(app: app, on: host)
                } label: {
                    // macOS 27 hides a plain menu-item symbol image by default;
                    // these items name an app, so force the icon back on.
                    Label { Text("Stream \(app.name)") } icon: { app.icon }
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isStreaming)
            }
        } label: {
            tileLabel(icon: Image(systemName: "ellipsis"), title: "\(overflowApps.count) more", trailing: "chevron.down")
        }
        .modifier(LauncherControlFocus(focus: focus, target: .overflow))
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Glass, not violet: it opens a list rather than streaming.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .help(model.isStreaming
            ? "Finish the current stream first"
            : "Show \(overflowApps.count) more app\(overflowApps.count == 1 ? "" : "s")")
        .accessibilityLabel("\(overflowApps.count) more apps")
        .accessibilityHint("Shows the rest of this PC's apps")
    }
}

struct SpecChipsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Facts, not controls: one secondary line, so nothing here looks pressable.
        Text(model.streamSpecChips.joined(separator: " · "))
            .contentTransition(.opacity)
            .animation(Motion.fade, value: model.selectedHost?.id)
            .font(.body)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Empty pairing state

struct EmptyPairingState: View {
    /// Owned by MainWindow so its `.sheet` survives the swap to ConnectSurface
    /// the moment pairing fills `model.hosts` - see MainWindow.showPair.
    @Binding var showPair: Bool

    var body: some View {
        // No leading/trailing Spacers: they centred this state inside a window
        // taller than itself, and the window now sizes to its content, so there
        // is no extra height to centre within - only height they would invent.
        VStack(spacing: 26) {
            Image(systemName: "display")
                .font(.system(size: 60, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 144, height: 144)

            VStack(spacing: 10) {
                Text("Let's find your gaming PC")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                Text("Glimmer plays your PC's games on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Button {
                showPair = true
            } label: {
                Label("Pair a PC…", systemImage: "plus.circle.fill")
                    .frame(minWidth: 260)
            }
            .buttonStyle(StreamButtonStyle())
            .controlSize(.large)
        }
        .padding(40)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Stream-ended toast (disconnect beat)

/// Brief "Stream ended" acknowledgement above the launcher content, driven
/// off `AppModel.streamEndedToastVisible`; auto-dismisses after a
/// short hold (the stream window's own fade is missable from a Cmd-Tab).
/// Thin material, no icon, monochrome - Apple's first-party toasts (AirPods
/// connect, volume HUD) are deliberately understated.
struct StreamEndedToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.streamEndedToastVisible {
                VStack(spacing: 2) {
                    Text("Stream ended")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    // Session receipt - one quiet line ("2h 12m · 12 ms
                    // median"), only when the stash kept one (≥5 min sessions).
                    if let line = model.lastSessionReceiptToastLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .transition(Motion.overlayTransition(reduceMotion: reduceMotion))
                // Announce the receipt as one sentence.
                .accessibilityElement(children: .combine)
                // Keyed on the receipt so a back-to-back end re-arms the hold
                // for the new content; the flag reset in stream() is the other
                // half - the flag actually FALLS between cycles now, so a
                // repeat end gets a fresh task, not a half-spent hold.
                .task(id: model.lastSessionReceipt) {
                    // VoiceOver never reaches a 2-4 s transient by focus
                    // navigation - announce the beat + receipt explicitly.
                    let line = model.lastSessionReceiptToastLine
                    AccessibilityNotification.Announcement(
                        line.map { "Stream ended. \($0)" } ?? "Stream ended"
                    ).post()
                    // Auto-dismiss - 2 s plain, 4 s with the receipt line.
                    let hold: UInt64 = line == nil ? 2_000_000_000 : 4_000_000_000
                    try? await Task.sleep(nanoseconds: hold)
                    if !Task.isCancelled {
                        model.streamEndedToastVisible = false
                    }
                }
            }
        }
        .animation(Motion.overlay(reduceMotion: reduceMotion),
                   value: model.streamEndedToastVisible)
    }
}
