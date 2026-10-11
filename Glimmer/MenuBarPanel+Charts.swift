// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

/// Sixty seconds on one baseline: bandwidth bars above it (scaled to the asked
/// bitrate or the minute's peak), latency as a line below it (30 ms or the peak),
/// so a hitch is a grey spike under a violet dip. Hovering reads any second back.
struct StreamChart: View {
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
            context.fill(area, with: .color(.secondary.opacity(0.22)))
            context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
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
struct FramesChart: View {
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
                    ChartReadout(text: "\(Int(values[index].rounded())) fps · \(when)",
                                 x: hoverX ?? 0, width: geo.size.width)
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
