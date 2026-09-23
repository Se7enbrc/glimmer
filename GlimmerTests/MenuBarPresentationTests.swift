//
//  MenuBarPresentationTests.swift
//
//  The menu bar item's decisions: which mark, which first row, and how the
//  readings are worded.
//

import Accessibility
import Foundation
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

    private func action(_ phase: StreamPhase = .idle, reconnecting: Bool = false,
                        chip: ChipPresentation = .ready(rttMs: nil), canWake: Bool = true,
                        waking: Bool = false) -> MenuBarPrimaryAction {
        MenuBarPresentation.primaryAction(phase: phase, reconnecting: reconnecting,
                                          host: MenuBarHost(chip: chip, canWake: canWake, waking: waking),
                                          heroApp: "Desktop")
    }

    @Test func primaryActionIsTheLaunchersButton() {
        #expect(action() == .stream(app: "Desktop"))
        #expect(MenuBarPresentation.primaryAction(phase: .idle, reconnecting: false, host: nil, heroApp: "D") == .none)
        #expect(action(chip: .asleep) == .wake)
        #expect(action(chip: .asleep, canWake: false) == .stream(app: "Desktop"))
        #expect(action(chip: .asleep, waking: true) == .waking)
        #expect(action(chip: .certMismatch) == .pairAgain)
        #expect(action(.error("x"), chip: .certMismatch) == .pairAgain)
        #expect(action(chip: .streamingElsewhere(appName: "Elden Ring")) == .stream(app: "Desktop"))
        #expect(action(.streaming) == .backToStream)
    }

    @Test func aReconnectStopsRatherThanCancels() {
        #expect(action(.connecting(stage: "x")) == .cancelConnection)
        #expect(action(.connecting(stage: "Reconnecting to Tower…"), reconnecting: true) == .stopStreaming)
    }

    @Test func theAttentionCardRecoversOnlyUnderAPlainStreamButton() {
        #expect(action().allowsRecovery)
        #expect(!action(chip: .asleep).allowsRecovery)
        #expect(!action(chip: .certMismatch).allowsRecovery)
        #expect(!action(.streaming).allowsRecovery)
    }

    @Test func aFailedWakeSaysWhy() {
        #expect(AppModel.WakeFailureReason.couldNotSend.line == "Couldn't send the wake signal. Check this Mac's network.")
        #expect(AppModel.WakeFailureReason.noAnswer.line.hasPrefix("No answer."))
        #expect(!AppModel.WakeFailureReason.couldNotSend.line.contains("Tailscale"))
    }

    @Test func thePCReadsAsItDoesInTheLauncher() {
        let now = Date()
        func chip(_ state: HostLiveStatus.State, age: TimeInterval = 0) -> ChipPresentation {
            ChipPresentation(live: HostLiveStatus(hostID: "a", state: state, rttMs: 4, sunshineVersion: nil,
                                                  capturedAt: now.addingTimeInterval(-age)), now: now)
        }
        #expect(chip(.idle) == .ready(rttMs: 4))
        #expect(chip(.streamingApp(name: "Elden Ring")) == .streamingElsewhere(appName: "Elden Ring"))
        #expect(chip(.streamingUnknownApp(id: 9)) == .streamingElsewhere(appName: nil))
        #expect(chip(.certMismatch) == .certMismatch)
        #expect(chip(.asleep) == .asleep)
        #expect(chip(.asleep, age: HostLiveStatus.stale + 1) == .unknown)
        #expect(ChipPresentation(live: nil) == .unknown)
    }

    @Test func everyPadShowsOnceWithOrWithoutABattery() {
        let dualSense = MenuBarController(name: "DualSense", percent: 80, charging: true)
        let wired = MenuBarController(name: "Xbox Controller", percent: nil, charging: false)
        let raw = MenuBarController(name: "8BitDo", percent: 25, charging: false)
        let yielded = MenuBarController(name: "DualSense", percent: nil, charging: false)
        let pads = MenuBarPresentation.controllers(gameController: [dualSense, wired], rawHID: [yielded, raw])
        #expect(pads == [dualSense, wired, raw])
        #expect(pads.map(\.status) == ["80%, charging", "Connected", "25%"])
    }

    @Test func readingsAreWordedPlainly() {
        #expect(MenuBarPresentation.modeLine(width: 3024, height: 1964, fps: 120, hdr: true) == "3024 × 1964 · 120 Hz · HDR")
        #expect(MenuBarPresentation.modeLine(width: 1920, height: 1080, fps: 60, hdr: false) == "1920 × 1080 · 60 Hz")
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
