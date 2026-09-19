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
                bigNumber(metrics[2], dot: .accentColor)
                bigNumber(metrics[1], dot: .pink)
                bigNumber(metrics[0], dot: .green)
            }
            StreamChart(mbps: StreamHistory.shared.mbps, latency: StreamHistory.shared.rttMs,
                        asked: Double(model.effectiveBitrateKbps) / 1000)
                .frame(height: 56)
            FramesChart(values: StreamHistory.shared.fps, target: Double(model.effectiveFPS))
                .frame(height: 34)
            Text("\(model.menuBarModeLine) · \(metrics[3].value)")
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

    /// A big value with its chart color under it, iStat style.
    private func bigNumber(_ metric: MenuBarMetric, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(metric.label.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Sixty seconds, newest at the right, on one baseline: bandwidth in rises
/// above it (full height is the asked bitrate, or the minute's peak) and
/// latency hangs below it (30 ms, or the minute's peak), so a hitch is a
/// pink spike under a blue dip. Hovering reads any second back.
private struct StreamChart: View {
    let mbps: [Double]
    let latency: [Double]
    let asked: Double
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(StreamHistory.capacity)
            let index = hoverX.flatMap { barIndex(atX: $0, pitch: pitch, width: geo.size.width) }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(in: &context, size: size, pitch: pitch, highlight: index)
                }
                seriesLabels
                if let index, let readout = readout(at: index) {
                    Text(readout)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .position(x: min(max(hoverX ?? 0, 48), geo.size.width - 48), y: 9)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
        }
        .accessibilityLabel("Bandwidth and latency over the last minute")
    }

    private var seriesLabels: some View {
        VStack(alignment: .leading) {
            Text("Bandwidth").foregroundStyle(Color.accentColor)
            Spacer()
            Text("Latency").foregroundStyle(.pink)
        }
        .font(.caption2.weight(.medium))
        .padding(4)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, pitch: CGFloat, highlight: Int?) {
        let width = max(pitch - 1.5, 1)
        let baseline = size.height * 0.62
        let upScale = max(asked, mbps.max() ?? 0, 1)
        let downScale = max(30, latency.max() ?? 0)
        for (index, value) in mbps.enumerated() {
            let x = size.width - CGFloat(mbps.count - index) * pitch
            let height = max(baseline * CGFloat(min(value / upScale, 1)), value > 0 ? 1.5 : 0)
            let rect = CGRect(x: x, y: baseline - height, width: width, height: height)
            let color = Color.accentColor.opacity(highlight == nil || highlight == index ? 1 : 0.55)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }
        for (index, value) in latency.enumerated() {
            let x = size.width - CGFloat(latency.count - index) * pitch
            let room = size.height - baseline - 1
            let height = max(room * CGFloat(min(value / downScale, 1)), value > 0 ? 1.5 : 0)
            let rect = CGRect(x: x, y: baseline + 1, width: width, height: height)
            let color = Color.pink.opacity(highlight == nil || highlight == index ? 1 : 0.55)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }
        var line = Path()
        line.move(to: CGPoint(x: 0, y: baseline + 0.5))
        line.addLine(to: CGPoint(x: size.width, y: baseline + 0.5))
        context.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        if let highlight {
            let x = size.width - CGFloat(mbps.count - highlight) * pitch + width / 2
            var hair = Path()
            hair.move(to: CGPoint(x: x, y: 0))
            hair.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(hair, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
        }
    }

    /// The bar under the cursor; bars are right-aligned, newest last.
    private func barIndex(atX x: CGFloat, pitch: CGFloat, width: CGFloat) -> Int? {
        guard pitch > 0, !mbps.isEmpty else { return nil }
        let slotsFromRight = Int((width - x) / pitch)
        let index = mbps.count - 1 - slotsFromRight
        return (0..<mbps.count).contains(index) ? index : nil
    }

    private func readout(at index: Int) -> String? {
        guard mbps.indices.contains(index) else { return nil }
        let ago = mbps.count - 1 - index
        let when = ago == 0 ? "now" : "\(ago) s ago"
        let ms = latency.indices.contains(index) ? Int(latency[index].rounded()) : 0
        return "\(Int(mbps[index].rounded())) Mbps · \(ms) ms · \(when)"
    }
}

/// Sixty seconds of frames arriving against the requested rate, newest at
/// the right; a second under 90 % of it is drawn orange. Hover reads it.
private struct FramesChart: View {
    let values: [Double]
    let target: Double
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(StreamHistory.capacity)
            let index = hoverX.flatMap { barIndex(atX: $0, pitch: pitch, width: geo.size.width) }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let width = max(pitch - 1.5, 1)
                    let scale = max(target, values.max() ?? 0, 1)
                    for (bar, value) in values.enumerated() {
                        let x = size.width - CGFloat(values.count - bar) * pitch
                        let height = max(size.height * CGFloat(min(value / scale, 1)), value > 0 ? 1.5 : 0)
                        let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
                        let low = value < target * 0.9
                        let color = (low ? Color.orange : Color.green).opacity(index == nil || index == bar ? 1 : 0.55)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                    }
                    if let index {
                        let x = size.width - CGFloat(values.count - index) * pitch + width / 2
                        var hair = Path()
                        hair.move(to: CGPoint(x: x, y: 0))
                        hair.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(hair, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    }
                }
                Text("Frames / s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(4)
                    .allowsHitTesting(false)
                if let index, values.indices.contains(index) {
                    let ago = values.count - 1 - index
                    Text("\(Int(values[index].rounded())) fps · \(ago == 0 ? "now" : "\(ago) s ago")")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .position(x: min(max(hoverX ?? 0, 44), geo.size.width - 44), y: 9)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
        }
        .accessibilityLabel("Frames per second over the last minute")
    }

    private func barIndex(atX x: CGFloat, pitch: CGFloat, width: CGFloat) -> Int? {
        guard pitch > 0, !values.isEmpty else { return nil }
        let index = values.count - 1 - Int((width - x) / pitch)
        return (0..<values.count).contains(index) ? index : nil
    }
}
