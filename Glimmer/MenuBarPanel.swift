//
//  MenuBarPanel.swift
//
//  The menu bar item's panel: card groups with an accent label and a value at
//  the right, big numbers and a one-minute chart while streaming, chevron rows
//  for the PC, a battery bar for the controller, and a footer of round buttons.
//

import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.nativeStreamError { attentionCard(error) }
            switch model.menuBarPrimaryAction {
            case .backToStream: streamCard
            case .cancelConnection: connectingCard
            case .stream, .none: pcCard
            }
            controllerCard
            footer
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { model.startMenuBarRefresh() }
        .onDisappear { model.stopMenuBarRefresh() }
    }

    // MARK: Card chrome

    private func card<Content: View>(_ label: String, trailing: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private func attentionCard(_ message: String) -> some View {
        card("Attention") {
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if message.localizedCaseInsensitiveContains("pair") {
                actionRow("Open Glimmer", systemImage: "macwindow") { openLauncher() }
            } else {
                actionRow("Try Again", systemImage: "arrow.clockwise") {
                    model.nativeStreamError = nil
                    model.retryLastLaunch()
                }
            }
        }
    }

    private var streamCard: some View {
        card("Stream", trailing: model.selectedHost?.displayName) {
            let metrics = model.menuBarMetrics
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(metrics.prefix(2), id: \.label) { metric in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(metric.value)
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(metric.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            FrameChart(values: StreamHistory.shared.fps, target: Double(model.effectiveFPS))
                .frame(height: 40)
            HStack {
                Text(model.menuBarModeLine)
                if metrics.count > 3 {
                    Text("·")
                    Text("\(metrics[2].value) · \(metrics[3].value)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Divider()
            actionRow("Back to Stream", systemImage: "play.fill") {
                model.resumeStreamWindow()
                activate()
            }
            actionRow(model.menuStopInProgress ? "Stopping…" : "Stop Streaming", systemImage: "stop.fill") {
                model.stopStreamFromMenu()
            }
            .disabled(model.menuStopInProgress)
            Toggle(isOn: Binding(
                get: { model.statsOverlayShown },
                set: { _ in model.toggleStatsOverlayFromMenu() })) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text("Stats overlay")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var connectingCard: some View {
        card("Stream", trailing: model.selectedHost?.displayName) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.menuBarConnectingLine ?? "Connecting…")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Divider()
            actionRow("Cancel Connection", systemImage: "xmark.circle") { model.cancelConnect() }
        }
    }

    @ViewBuilder private var pcCard: some View {
        if let host = model.selectedHost {
            card("PC", trailing: nil) {
                HStack {
                    Text(host.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let readiness = model.menuBarReadiness {
                        readinessPill(readiness, tone: model.menuBarReadinessTone)
                    }
                }
                if case .stream(let app) = model.menuBarPrimaryAction {
                    Button {
                        model.streamHeroApp()
                        activate()
                    } label: {
                        Label("Stream \(app)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                Divider()
                pcRows(host: host)
            }
        } else {
            card("PC") {
                Text("No PC paired yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                actionRow("Add a PC", systemImage: "plus.circle") { openLauncher() }
            }
        }
    }

    @ViewBuilder private func pcRows(host: Host) -> some View {
        let apps = host.apps.filter { !$0.hidden }
        if apps.count > 1 {
            row("Stream App", systemImage: "square.grid.2x2") {
                ForEach(apps) { app in
                    Button(app.name) { model.requestStream(app: app, on: host); activate() }
                }
            }
        }
        if model.hosts.count > 1 {
            row("PCs", systemImage: "desktopcomputer") {
                ForEach(model.hosts) { candidate in
                    Button {
                        model.selectHost(candidate)
                    } label: {
                        if candidate.id == host.id {
                            Label(candidate.displayName, systemImage: "checkmark")
                        } else {
                            Text(candidate.displayName)
                        }
                    }
                }
            }
        }
        if let device = LunaPower.shared.gatedDevice(for: host) {
            if LunaPower.shared.actionInFlight[host.id] == "on" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).frame(width: 18)
                    Text("Waking \(host.displayName)…")
                    Spacer()
                    Button("Stop Waiting") { model.cancelWake(host) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else if model.menuBarHostAsleep {
                actionRow("Wake and Connect", systemImage: "power") {
                    model.wakeHost(host, device: device, thenConnect: true)
                }
            }
        }
    }

    private func readinessPill(_ text: String, tone: MenuBarReadinessTone) -> some View {
        HStack(spacing: 5) {
            Circle().fill(toneColor(tone)).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: Capsule())
    }

    private func toneColor(_ tone: MenuBarReadinessTone) -> Color {
        switch tone {
        case .ready: .green
        case .busy: .orange
        case .off: .secondary
        case .trouble: .red
        }
    }

    @ViewBuilder private var controllerCard: some View {
        let pads = model.menuBarControllers
        if let first = pads.first {
            card(pads.count > 1 ? "Controllers" : "Controller",
                 trailing: pads.count == 1 ? "\(first.percent)%" + (first.charging ? ", charging" : "") : nil) {
                ForEach(Array(pads.enumerated()), id: \.offset) { _, pad in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "gamecontroller.fill")
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(pad.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            if pads.count > 1 {
                                Text("\(pad.percent)%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: Double(pad.percent), total: 100)
                            .progressViewStyle(.linear)
                            .tint(pad.percent <= 20 && !pad.charging ? .red : .accentColor)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Glimmer")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                openSettings()
                activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .help("Settings")
            Menu {
                Button("Open Glimmer") { openLauncher() }
                #if canImport(Sparkle)
                Button("Check for Updates…") {
                    UpdaterController.shared.updater.checkForUpdates()
                    activate()
                }
                #endif
                Divider()
                Button("Quit Glimmer") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .clipShape(Circle())
        }
        .controlSize(.small)
        .padding(.horizontal, 4)
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

/// Sixty bars, newest at the right, each one second of frames arriving
/// against the requested rate. Dips are hitches, at a glance.
private struct FrameChart: View {
    let values: [Double]
    let target: Double

    var body: some View {
        Canvas { context, size in
            let slots = Double(StreamHistory.capacity)
            let pitch = size.width / slots
            let width = max(pitch - 1.5, 1)
            let scale = max(target, 1)
            for (index, value) in values.enumerated() {
                let x = size.width - CGFloat(values.count - index) * pitch
                let height = max(size.height * CGFloat(min(value / scale, 1)), value > 0 ? 1.5 : 0)
                let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
                let low = value < scale * 0.9
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(low ? .pink : .accentColor))
            }
        }
        .accessibilityLabel("Frames arriving over the last minute")
    }
}
