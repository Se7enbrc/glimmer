//
//  MenuBarPresentationTests.swift
//
//  The menu bar item's decisions: which mark, which first row, and how the
//  readings are worded.
//

import Accessibility
import Testing
@testable import Glimmer

struct MenuBarPresentationTests {

    @Test func iconFollowsThePhaseAndAttentionWins() {
        #expect(MenuBarPresentation.icon(phase: .idle, reconnecting: false, error: nil) == .idle)
        #expect(MenuBarPresentation.icon(phase: .connecting(stage: "x"), reconnecting: false, error: nil) == .connecting)
        #expect(MenuBarPresentation.icon(phase: .connecting(stage: "x"), reconnecting: true, error: nil) == .reconnecting)
        #expect(MenuBarPresentation.icon(phase: .streaming, reconnecting: false, error: nil) == .streaming)
        #expect(MenuBarPresentation.icon(phase: .streaming, reconnecting: false, error: "oops") == .attention)
        #expect(MenuBarPresentation.icon(phase: .error("x"), reconnecting: false, error: nil) == .attention)
    }

    @Test func idleKeepsTheEclipseMark() {
        #expect(MenuBarPresentation.systemImage(for: .idle) == nil)
        #expect(MenuBarPresentation.systemImage(for: .streaming) == "play.fill")
        #expect(MenuBarPresentation.accessibilityLabel(state: .streaming, hostName: "Tower") == "Glimmer, streaming to Tower")
        #expect(MenuBarPresentation.accessibilityLabel(state: .idle, hostName: nil) == "Glimmer")
    }

    @Test func primaryActionIsWhatYouNeedNow() {
        #expect(MenuBarPresentation.primaryAction(phase: .idle, hostSelected: true, heroApp: "Desktop") == .stream(app: "Desktop"))
        #expect(MenuBarPresentation.primaryAction(phase: .idle, hostSelected: false, heroApp: "Desktop") == .none)
        #expect(MenuBarPresentation.primaryAction(phase: .connecting(stage: "x"), hostSelected: true, heroApp: "D") == .cancelConnection)
        #expect(MenuBarPresentation.primaryAction(phase: .streaming, hostSelected: true, heroApp: "D") == .backToStream)
    }

    @Test func readingsAreWordedPlainly() {
        #expect(MenuBarPresentation.batteryRow(name: "DualSense", percent: 25, charging: false) == "DualSense · 25%")
        #expect(MenuBarPresentation.batteryRow(name: "DualSense", percent: 80, charging: true) == "DualSense · 80%, charging")
        #expect(MenuBarPresentation.readiness(.idle, fresh: true) == "Ready")
        #expect(MenuBarPresentation.readiness(.streamingApp(name: "Elden Ring"), fresh: true) == "Busy: Elden Ring")
        #expect(MenuBarPresentation.readiness(.streamingUnknownApp(id: 9), fresh: true) == "Busy")
        #expect(MenuBarPresentation.readiness(.unknown, fresh: true) == "Unavailable")
        #expect(MenuBarPresentation.readiness(.asleep, fresh: false) == nil)
        #expect(MenuBarPresentation.modeLine(width: 3024, height: 1964, fps: 120, hdr: true) == "3024 × 1964 · 120 Hz · HDR")
        #expect(MenuBarPresentation.modeLine(width: 1920, height: 1080, fps: 60, hdr: false) == "1920 × 1080 · 60 Hz")
        #expect(MenuBarPresentation.stateWord(.idle, readiness: "Ready") == "Ready")
        #expect(MenuBarPresentation.stateWord(.idle, readiness: nil) == "Idle")
        #expect(MenuBarPresentation.stateWord(.reconnecting, readiness: "Ready") == "Reconnecting…")
        #expect(MenuBarPresentation.readinessTone(.idle) == .ready)
        #expect(MenuBarPresentation.readinessTone(.streamingApp(name: "x")) == .busy)
        #expect(MenuBarPresentation.readinessTone(.certMismatch) == .trouble)
        #expect(MenuBarPresentation.batterySymbol(percent: 25, charging: false) == "battery.25percent")
        #expect(MenuBarPresentation.batterySymbol(percent: 5, charging: true) == "battery.100percent.bolt")
    }

    @Test func metricsUseWhatArrivesAndDashTheRest() {
        var snap = StreamStatsSnapshot()
        snap.receivedFps = 119.6
        snap.renderedFps = 0
        snap.rttMs = 3.4
        snap.measuredBitrateMbps = 78.2
        let metrics = MenuBarPresentation.metrics(snapshot: snap, link: "Wi-Fi")
        #expect(metrics.map(\.value) == ["120", "3 ms", "78 Mbps", "Wi-Fi"])
        #expect(metrics.map(\.label) == ["Frames/s", "Latency", "Bandwidth", "Network"])
        #expect(metrics[0].spokenLabel == "Frames per second")
        #expect(MenuBarPresentation.metrics(snapshot: nil, link: nil).map(\.value) == ["–", "–", "–", "–"])
    }

    @Test func chartsSummariseTheMinuteForVoiceOver() {
        #expect(MenuBarChartSummary.bandwidth(mbps: [48.2, 80.4, 61], latency: [3, 31.4, 5])
                == "Bandwidth 48 to 80 Mbps, latency peak 31 ms")
        #expect(MenuBarChartSummary.bandwidth(mbps: [80, 80.2], latency: []) == "Bandwidth 80 Mbps")
        #expect(MenuBarChartSummary.bandwidth(mbps: [], latency: []) == "No readings yet")
        #expect(MenuBarChartSummary.frames([120, 119, 100, 120], target: 120) == "1 second below 120 fps")
        #expect(MenuBarChartSummary.frames([60, 40, 30], target: 60) == "2 seconds below 60 fps")
        #expect(MenuBarChartSummary.frames([120], target: 120) == "No seconds below 120 fps")
    }

    @Test func chartDescriptorsReachEverySecond() {
        let stream = StreamChartDescriptor(mbps: [50, 60, 70], latency: [4, 9, 6]).makeChartDescriptor()
        let time = stream.xAxis as? AXNumericDataAxisDescriptor
        #expect(stream.series.first?.dataPoints.count == 3)
        #expect(time?.range == -2...0)
        #expect(time?.valueDescriptionProvider(0) == "now")
        #expect(time?.valueDescriptionProvider(-2) == "2 s ago")
        #expect(stream.yAxis?.range == 0...70)
        #expect(stream.additionalAxes.map(\.title) == ["Latency"])
        let frames = FramesChartDescriptor(values: [120, 90], target: 120).makeChartDescriptor()
        #expect(frames.series.first?.dataPoints.count == 2)
        #expect(frames.summary == "1 second below 120 fps")
    }

    @Test @MainActor func historyKeepsOneMinute() {
        let history = StreamHistory()
        for i in 0..<70 { history.append(mbps: Double(i) / 2, fps: Double(i), rttMs: nil) }
        #expect(history.fps.count == 60)
        #expect(history.fps.first == 10)
        #expect(history.mbps.last == 34.5)
        #expect(history.rttMs.last == 0)
        history.reset()
        #expect(history.mbps.isEmpty)
    }
}
