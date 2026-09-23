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
            case .cancelConnection, .stopStreaming: connectingCard
            case .stream, .wake, .waking, .pairAgain, .none: pcCard
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
                Text(label)
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityAddTraits(.isHeader)
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
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    // MARK: Cards

    private func attentionCard(_ message: String) -> some View {
        card("Attention") {
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if model.menuBarPrimaryAction.allowsRetry {
                actionRow("Try Again", systemImage: "arrow.clockwise") {
                    model.nativeStreamError = nil
                    model.retryLastLaunch()
                    activate()
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
                bigNumber(metrics[1], dot: .pink)
                bigNumber(metrics[0], dot: .green)
            }
            VStack(spacing: 6) {
                StreamChart(mbps: StreamHistory.shared.mbps, latency: StreamHistory.shared.rttMs,
                            asked: model.menuDetails?.negotiatedBitrateMbps ?? Double(model.displayBitrateKbps) / 1000)
                    .frame(height: 54)
                FramesChart(values: StreamHistory.shared.fps,
                            target: model.menuDetails?.hostFps ?? Double(model.effectiveFPS))
                    .frame(height: 22)
            }
            .padding(.top, 2)
            Text("\(model.menuBarModeLine) · \(metrics[3].value)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Divider()
            actionRow("Back to Stream", systemImage: "play.fill") {
                if model.isMiniPlayer { model.toggleMiniPlayer() } else { model.resumeStreamWindow() }
                activate()
            }
            if !model.isMiniPlayer {
                actionRow("Mini Player", systemImage: "pip.enter") { model.toggleMiniPlayer() }
            }
            stopRow
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
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
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
            card("PC") {
                HStack {
                    Text(host.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let chip = model.menuBarHost?.chip { readinessPill(chip) }
                }
                primaryControl(host: host)
                pcRows(host: host)
            }
        } else {
            card("PC") {
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
            prominentButton("Stream \(app)", systemImage: "play.fill") {
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
        let apps = host.apps.filter { !$0.hidden }
        if apps.count > 1 || model.hosts.count > 1 { Divider() }
        if apps.count > 1 {
            row("Stream App", systemImage: "square.grid.2x2") {
                ForEach(apps) { app in
                    Button(app.name) { model.requestStream(app: app, on: host); activate() }
                }
            }
        }
        if model.hosts.count > 1 {
            // A Picker, not checkmark images: macOS 27 hides symbols in menus.
            row("PCs", systemImage: "desktopcomputer") {
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
            .buttonBorderShape(.circle)
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

/// Sixty seconds on one baseline: bandwidth bars above it (scaled to the asked
/// bitrate or the minute's peak), latency as a line below it (30 ms or the peak),
/// so a hitch is a pink spike under a blue dip. Hovering reads any second back.
private struct StreamChart: View {
    let mbps: [Double]
    let latency: [Double]
    let asked: Double
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(StreamHistory.capacity)
            let index = hoverX.flatMap {
                ChartGeometry.barIndex(atX: $0, pitch: pitch, width: geo.size.width, count: mbps.count)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(in: &context, size: size, pitch: pitch, highlight: index)
                }
                if let index, let readout = readout(at: index) {
                    ChartReadout(text: readout, x: hoverX ?? 0, width: geo.size.width)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bandwidth and latency over the last minute")
        .accessibilityValue(MenuBarChartSummary.bandwidth(mbps: mbps, latency: latency))
        .accessibilityChartDescriptor(StreamChartDescriptor(mbps: mbps, latency: latency))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, pitch: CGFloat, highlight: Int?) {
        let width = max(pitch * 0.55, 1)
        let baseline = size.height * 0.64
        let upScale = max(asked, mbps.max() ?? 0, 1)
        let downScale = max(30, latency.max() ?? 0)
        for (index, value) in mbps.enumerated() {
            let x = size.width - CGFloat(mbps.count - index) * pitch
            let height = max(baseline * CGFloat(min(value / upScale, 1)), value > 0 ? 1 : 0)
            let rect = CGRect(x: x, y: baseline - height, width: width, height: height)
            let color = Color.accentColor.opacity(highlight == nil || highlight == index ? 1 : 0.45)
            context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(color))
        }
        let room = size.height - baseline - 2
        if latency.count > 1 {
            var line = Path()
            var area = Path()
            for (index, value) in latency.enumerated() {
                let x = size.width - CGFloat(latency.count - index) * pitch + width / 2
                let y = baseline + 2 + room * CGFloat(min(value / downScale, 1))
                if index == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                    area.move(to: CGPoint(x: x, y: baseline + 1))
                    area.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                    area.addLine(to: CGPoint(x: x, y: y))
                }
                if index == latency.count - 1 { area.addLine(to: CGPoint(x: x, y: baseline + 1)) }
            }
            area.closeSubpath()
            context.fill(area, with: .color(.pink.opacity(0.22)))
            context.stroke(line, with: .color(.pink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: baseline + 0.5))
        base.addLine(to: CGPoint(x: size.width, y: baseline + 0.5))
        context.stroke(base, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
        if let highlight {
            ChartGeometry.hairline(in: &context, size: size, pitch: pitch, width: width,
                                   count: mbps.count, index: highlight)
        }
    }

    private func readout(at index: Int) -> String? {
        guard mbps.indices.contains(index) else { return nil }
        let ms = latency.indices.contains(index) ? Int(latency[index].rounded()) : 0
        let when = MenuBarChartSummary.when(ago: mbps.count - 1 - index)
        return "\(Int(mbps[index].rounded())) Mbps · \(ms) ms · \(when)"
    }
}

/// Sixty seconds of frames arriving against the session's rate, newest at
/// the right; a short second is drawn orange. Hovering reads it.
private struct FramesChart: View {
    let values: [Double]
    let target: Double
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(StreamHistory.capacity)
            let index = hoverX.flatMap {
                ChartGeometry.barIndex(atX: $0, pitch: pitch, width: geo.size.width, count: values.count)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let width = max(pitch * 0.55, 1)
                    let scale = max(target, values.max() ?? 0, 1)
                    for (bar, value) in values.enumerated() {
                        let x = size.width - CGFloat(values.count - bar) * pitch
                        let height = max(size.height * CGFloat(min(value / scale, 1)), value > 0 ? 1 : 0)
                        let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
                        let low = MenuBarChartSummary.isShort(value, target: target)
                        let dim = index != nil && index != bar
                        let color = (low ? Color.orange : Color.green).opacity(dim ? 0.45 : 1)
                        context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(color))
                    }
                    if let index {
                        ChartGeometry.hairline(in: &context, size: size, pitch: pitch, width: width,
                                               count: values.count, index: index)
                    }
                }
                if let index, values.indices.contains(index) {
                    let when = MenuBarChartSummary.when(ago: values.count - 1 - index)
                    ChartReadout(text: "\(Int(values[index].rounded())) fps · \(when)", x: hoverX ?? 0, width: geo.size.width)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frames per second over the last minute")
        .accessibilityValue(MenuBarChartSummary.frames(values, target: target))
        .accessibilityChartDescriptor(FramesChartDescriptor(values: values, target: target))
    }
}

/// The hover pill above a chart, kept inside the chart's width.
private struct ChartReadout: View {
    let text: String
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .position(x: min(max(x, 52), width - 52), y: 9)
            .allowsHitTesting(false)
    }
}

/// Shared bar arithmetic: bars are right-aligned, the newest last.
private enum ChartGeometry {
    static func barIndex(atX x: CGFloat, pitch: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard pitch > 0, count > 0 else { return nil }
        let index = count - 1 - Int((width - x) / pitch)
        return (0..<count).contains(index) ? index : nil
    }

    static func hairline(in context: inout GraphicsContext, size: CGSize, pitch: CGFloat, width: CGFloat,
                         count: Int, index: Int) {
        let x = size.width - CGFloat(count - index) * pitch + width / 2
        var hair = Path()
        hair.move(to: CGPoint(x: x, y: 0))
        hair.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(hair, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
    }
}
