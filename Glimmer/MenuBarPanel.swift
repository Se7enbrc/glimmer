// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
//  MenuBarPanel.swift
//
//  The menu bar item's panel: titled cards, big numbers and a one-minute chart while
//  streaming, chevron rows for the PC, a controller battery bar, and a footer of round buttons.

import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var isShown = false
    @State private var handingToStream = false

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.nativeStreamError { attentionCard(error) }
            switch model.menuBarPrimaryAction {
            case .backToStream: streamCard
            case .cancelConnection, .stopStreaming: connectingCard
            case .stream, .wake, .waking, .pairAgain, .none: pcCard
            }
            controllerCard
            footer
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { isShown = true; model.startMenuBarRefresh() }
        .onDisappear {
            isShown = false
            model.stopMenuBarRefresh()
            // Closing the panel ends menu tracking, which re-shows the pointer; re-engage
            // the stream (the Cmd-Tab path) once the panel is gone so the cursor hides.
            if handingToStream { handingToStream = false; model.resumeStreamWindow() }
        }
        // Opening the panel mid-stream never fires this, so its stats stay up.
        .onChange(of: model.streamPhase == .streaming) { _, live in
            if live, isShown { handToStream() }
        }
    }

    private func handToStream() { handingToStream = true; dismiss() }

    // MARK: Card chrome

    /// A card titled the way Tahoe's own panels are; the PC card has none, its name is the title.
    private func card<Content: View>(_ label: String?, trailing: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label {
                HStack {
                    Text(label).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A row that opens a menu: icon, title, chevron, like a settings list.
    private func row<Items: View>(_ title: String, systemImage: String,
                                  @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .modifier(RowHighlight())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .modifier(RowHighlight())
        }
        .buttonStyle(.plain)
    }

    private func prominentButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        // The launcher's style: one Stream button across both windows (DESIGN.md, One Violet Rule).
        .buttonStyle(StreamButtonStyle())
    }

    // MARK: Cards

    private func attentionCard(_ message: String) -> some View {
        card("Attention") {
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if model.menuBarPrimaryAction.allowsRecovery {
                let action = model.streamErrorAction
                actionRow(action.title, systemImage: action.systemImage) {
                    model.runStreamErrorAction()
                    if action == .pairAgain { openLauncher() } else if action == .tryAgain { activate() }
                }
            }
            actionRow("Dismiss", systemImage: "xmark") { model.nativeStreamError = nil }
        }
    }

    private var streamCard: some View {
        card("Stream", trailing: model.selectedHost?.displayName) {
            let metrics = model.menuBarMetrics
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bigNumber(metrics[2], dot: .accentColor)
                bigNumber(metrics[1], dot: .secondary)
                bigNumber(metrics[0], dot: .green)
            }
            VStack(spacing: 6) {
                StreamChart(mbps: StreamHistory.shared.mbps, latency: StreamHistory.shared.rttMs,
                            asked: model.menuDetails?.negotiatedBitrateMbps ?? Double(model.displayBitrateKbps) / 1000)
                    .frame(height: 54)
                FramesChart(values: StreamHistory.shared.fps,
                            target: model.menuDetails?.configuredFps ?? Double(model.effectiveFPS))
                    .frame(height: 22)
            }
            .padding(.top, 2)
            Text("\(model.menuBarModeLine) · \(metrics[3].value)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Divider()
            actionRow("Back to Stream", systemImage: "play.tv.fill") {
                if model.isMiniPlayer { model.toggleMiniPlayer() }
                handToStream()
            }
            if !model.isMiniPlayer {
                actionRow("Mini Player", systemImage: "pip.enter") { model.toggleMiniPlayer() }
            }
            stopRow
            if let attempt = model.lastLaunchAttempt {
                QuitRunningAppButton(app: attempt.app, host: attempt.host).buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text("Stream stats")
                Spacer()
                Toggle("Stream stats", isOn: Binding(
                    get: { model.statsOverlayShown },
                    set: { _ in model.toggleStatsOverlayFromMenu() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var stopRow: some View {
        actionRow(model.menuStopInProgress ? "Stopping…" : "Stop Streaming", systemImage: "stop.fill") {
            model.stopStreamFromMenu()
        }
        .disabled(model.menuStopInProgress)
    }

    /// A big value with its chart color under it; the legend for the charts.
    private func bigNumber(_ metric: MenuBarMetric, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.value)
                .font(.title.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.spokenLabel ?? metric.label)
        .accessibilityValue(metric.value)
    }

    /// A first connect can be cancelled; a reconnect is a live stream, so it stops.
    private var connectingCard: some View {
        card("Stream", trailing: model.selectedHost?.displayName) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.menuBarConnectingLine ?? "Connecting…")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Divider()
            if model.menuBarPrimaryAction == .stopStreaming {
                stopRow
            } else {
                actionRow("Cancel Connection", systemImage: "xmark.circle") { model.cancelConnect() }
            }
        }
    }

    @ViewBuilder private var pcCard: some View {
        if let host = model.selectedHost {
            card(nil) {
                HStack {
                    Text(host.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let chip = model.menuBarHost?.chip { readinessPill(chip) }
                }
                primaryControl(host: host)
                pcRows(host: host)
            }
        } else {
            card(nil) {
                Text("No PC paired yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                actionRow("Pair a PC…", systemImage: "plus.circle") { pair(nil) }
            }
        }
    }

    /// The launcher's one button for this PC, in the same words.
    @ViewBuilder private func primaryControl(host: Host) -> some View {
        switch model.menuBarPrimaryAction {
        case .stream(let app):
            prominentButton(model.heroTargetApp.map { model.streamActionTitle($0, on: host) }
                            ?? "Stream \(app)", systemImage: "play.fill") {
                model.streamHeroApp()
                activate()
            }
        case .wake:
            prominentButton("Wake and Connect", systemImage: "power") { model.wakeHost(host, thenConnect: true) }
            if model.wakeFailedHostID == host.id, let reason = model.wakeFailureReason {
                Text(reason.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .waking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waking \(host.displayName)…").lineLimit(1)
                Spacer()
                Button("Stop Waiting") { model.cancelWake(host) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        case .pairAgain:
            prominentButton("Pair Again…", systemImage: "key.fill") { pair(host) }
        case .backToStream, .cancelConnection, .stopStreaming, .none:
            EmptyView()
        }
    }

    @ViewBuilder private func pcRows(host: Host) -> some View {
        if let running = model.runningApp(on: host) {
            QuitRunningAppButton(app: running, host: host).buttonStyle(.plain)
        }
        let apps = host.apps.filter { !$0.hidden }
        if apps.count > 1 || model.hosts.count > 1 { Divider() }
        if apps.count > 1 {
            row("Stream App", systemImage: "square.grid.2x2") {
                ForEach(apps) { app in
                    Button(model.streamActionTitle(app, on: host)) {
                        model.requestStream(app: app, on: host); activate()
                    }
                }
            }
        }
        if model.hosts.count > 1 {
            // A Picker, not checkmark images: macOS 27 hides symbols in menus.
            row("PCs", systemImage: "display") {
                Picker("PCs", selection: Binding(
                    get: { model.selectedHost?.id },
                    set: { id in
                        guard id != model.selectedHost?.id,
                              let pick = model.hosts.first(where: { $0.id == id }) else { return }
                        model.selectHost(pick)
                    })) {
                    ForEach(model.hosts) { candidate in
                        Text(candidate.displayName).tag(Optional(candidate.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private func readinessPill(_ chip: ChipPresentation) -> some View {
        HStack(spacing: 5) {
            Circle().fill(chip.dotColor).frame(width: 6, height: 6)
            Text(chip.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.accessibility)
    }

    @ViewBuilder private var controllerCard: some View {
        let pads = model.menuBarControllers
        if let first = pads.first {
            card(pads.count > 1 ? "Controllers" : "Controller", trailing: pads.count == 1 ? first.status : nil) {
                ForEach(Array(pads.enumerated()), id: \.offset) { _, pad in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "gamecontroller.fill")
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(pad.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            if pads.count > 1 {
                                Text(pad.status)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let percent = pad.percent {
                            ProgressView(value: Double(percent), total: 100)
                                .progressViewStyle(.linear)
                                .tint(percent <= 20 && !pad.charging ? .red : .accentColor)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Written out, the way Control Center does, not hidden in the "…" menu.
            Button("Open Glimmer") { openLauncher() }
                .buttonStyle(.plain)
                .font(.subheadline)
            Spacer()
            Button {
                openSettings()
                activate()
            } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
            Menu {
                #if canImport(Sparkle)
                Button("Check for Updates…") {
                    UpdaterController.shared.updater.checkForUpdates()
                    activate()
                }
                Divider()
                #endif
                Button("Quit Glimmer") { NSApp.terminate(nil) }
            } label: {
                Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .menuIndicator(.hidden)
        }
        .controlSize(.small)
        .padding(.horizontal, 4)
    }

    /// The pair sheet lives on the launcher, so open it there.
    private func pair(_ host: Host?) {
        model.requestPairing(for: host)
        openLauncher()
    }

    private func openLauncher() {
        openWindow(id: "main")
        activate()
    }

    private func activate() {
        // The OS decides foreground policy on macOS 14+; this is the request.
        NSApp.activate()
    }
}

/// The pointer-over highlight Tahoe's own menu bar panels give a row,
/// reaching a little past the text toward the card's edge.
private struct RowHighlight: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if hovering && isEnabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.fill.tertiary)
                }
            }
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
            .onHover { hovering = $0 }
    }
}
