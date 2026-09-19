//
//  MenuBarPresentationTests.swift
//
//  The menu bar item's decisions: which mark, which first row, and how the
//  readings are worded.
//

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
        #expect(MenuBarPresentation.statusLine(hostName: "Tower", width: 3840, height: 2160, fps: 120) == "Streaming to Tower · 4K 120")
        #expect(MenuBarPresentation.statusLine(hostName: "Tower", width: 1920, height: 1080, fps: 60) == "Streaming to Tower · 1080p 60")
    }

    @Test func detailLinesUseWhatTheSnapshotHas() {
        var snap = StreamStatsSnapshot()
        snap.renderedFps = 119.6
        snap.rttMs = 3.4
        snap.measuredBitrateMbps = 78.2
        let lines = MenuBarPresentation.detailLines(snapshot: snap, link: "Wi-Fi")
        #expect(lines == ["Frames: 120 per second", "Latency: 3 ms", "Bitrate: 78 Mbps", "Network: Wi-Fi"])
        #expect(MenuBarPresentation.detailLines(snapshot: nil, link: nil) == ["Waiting for the first second of video"])
    }
}
