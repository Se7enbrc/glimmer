//
//  MenuBarChartAccessibility.swift
//
//  What VoiceOver gets from the menu bar charts: a one-line summary of the
//  minute, and chart descriptors so Audio Graph and the data table reach
//  every second the hover readout shows.
//

import Accessibility
import SwiftUI

enum MenuBarChartSummary {

    /// A second is short when fewer than 90 % of the asked-for frames arrived.
    static func isShort(_ fps: Double, target: Double) -> Bool {
        fps < target * 0.9
    }

    static func when(ago: Int) -> String {
        ago == 0 ? "now" : "\(ago) s ago"
    }

    static func bandwidth(mbps: [Double], latency: [Double]) -> String {
        guard let low = mbps.min().map(rounded), let high = mbps.max().map(rounded) else {
            return "No readings yet"
        }
        let range = low == high ? "\(high) Mbps" : "\(low) to \(high) Mbps"
        guard let peak = latency.max(), peak > 0 else { return "Bandwidth \(range)" }
        return "Bandwidth \(range), latency peak \(rounded(peak)) ms"
    }

    static func frames(_ values: [Double], target: Double) -> String {
        guard !values.isEmpty else { return "No readings yet" }
        let short = values.count { isShort($0, target: target) }
        let rate = rounded(target)
        switch short {
        case 0: return "No seconds below \(rate) fps"
        case 1: return "1 second below \(rate) fps"
        default: return "\(short) seconds below \(rate) fps"
        }
    }

    /// Seconds ago on a numeric axis: the newest reading sits at 0.
    static func timeAxis(count: Int) -> AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: "Time", range: -Double(max(count - 1, 1))...0, gridlinePositions: []) {
            when(ago: rounded(-$0))
        }
    }

    static func x(index: Int, count: Int) -> Double {
        Double(index - (count - 1))
    }

    private static func rounded(_ value: Double) -> Int {
        Int(value.rounded())
    }
}

/// Bandwidth per second, with that second's latency as a second value.
struct StreamChartDescriptor: AXChartDescriptorRepresentable {
    let mbps: [Double]
    let latency: [Double]

    func makeChartDescriptor() -> AXChartDescriptor {
        let bandwidth = AXNumericDataAxisDescriptor(
            title: "Bandwidth", range: 0...max(mbps.max() ?? 0, 1), gridlinePositions: []) { "\(Int($0.rounded())) Mbps" }
        let delay = AXNumericDataAxisDescriptor(
            title: "Latency", range: 0...max(latency.max() ?? 0, 1), gridlinePositions: []) { "\(Int($0.rounded())) ms" }
        let points = mbps.indices.map { index in
            AXDataPoint(x: MenuBarChartSummary.x(index: index, count: mbps.count), y: mbps[index],
                        additionalValues: latency.indices.contains(index) ? [.number(latency[index])] : [])
        }
        return AXChartDescriptor(
            title: "Bandwidth and latency over the last minute",
            summary: MenuBarChartSummary.bandwidth(mbps: mbps, latency: latency),
            xAxis: MenuBarChartSummary.timeAxis(count: mbps.count), yAxis: bandwidth, additionalAxes: [delay],
            series: [AXDataSeriesDescriptor(name: "Bandwidth", isContinuous: false, dataPoints: points)])
    }
}

/// Frames per second, one point a second.
struct FramesChartDescriptor: AXChartDescriptorRepresentable {
    let values: [Double]
    let target: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let rate = AXNumericDataAxisDescriptor(
            title: "Frames per second", range: 0...max(target, values.max() ?? 0, 1), gridlinePositions: [target]
        ) { "\(Int($0.rounded())) fps" }
        let points = values.indices.map {
            AXDataPoint(x: MenuBarChartSummary.x(index: $0, count: values.count), y: values[$0])
        }
        return AXChartDescriptor(
            title: "Frames per second over the last minute",
            summary: MenuBarChartSummary.frames(values, target: target),
            xAxis: MenuBarChartSummary.timeAxis(count: values.count), yAxis: rate, additionalAxes: [],
            series: [AXDataSeriesDescriptor(name: "Frames per second", isContinuous: false, dataPoints: points)])
    }
}
