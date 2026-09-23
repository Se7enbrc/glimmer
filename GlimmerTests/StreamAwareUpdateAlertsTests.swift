//
//  StreamAwareUpdateAlertsTests.swift
//
//  Covers the rule that keeps Sparkle's scheduled update alert off a live
//  stream: held while streaming, brought forward once when the stream ends.
//

#if canImport(Sparkle)
import Observation
import Sparkle
import Testing
@testable import Glimmer

@MainActor
struct StreamAwareUpdateAlertsTests {

    @Test func scheduledAlertShowsNormallyOutsideAStream() {
        let app = FakeApp(isStreaming: false)
        let alerts = app.makeAlerts()
        #expect(alerts.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true))
        #expect(alerts.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: false))
    }

    @Test func scheduledAlertIsHeldDuringAStreamEvenWhenSparkleWantsFocus() {
        let app = FakeApp(isStreaming: true)
        let alerts = app.makeAlerts()
        #expect(alerts.supportsGentleScheduledUpdateReminders)
        #expect(!alerts.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true))
    }

    @Test func heldAlertComesForwardOnceWhenTheStreamEnds() async {
        let app = FakeApp(isStreaming: true)
        let alerts = app.makeAlerts()
        alerts.holdUntilStreamEnds()
        await settle()
        #expect(app.updatesShown == 0)

        app.isStreaming = false
        await waitUntil { app.updatesShown > 0 }
        #expect(app.updatesShown == 1)
        #expect(!alerts.isHoldingUpdate)

        // A later stream cycle doesn't replay an update already brought forward.
        app.isStreaming = true
        app.isStreaming = false
        await settle()
        #expect(app.updatesShown == 1)
    }

    @Test func aStreamRestartedBeforeTheCheckKeepsTheHold() async {
        let app = FakeApp(isStreaming: true)
        let alerts = app.makeAlerts()
        alerts.holdUntilStreamEnds()
        // Back-to-back streams: the flag drops and rises again in one turn.
        app.isStreaming = false
        app.isStreaming = true
        await settle()
        #expect(app.updatesShown == 0)
        #expect(alerts.isHoldingUpdate)

        app.isStreaming = false
        await waitUntil { app.updatesShown > 0 }
        #expect(app.updatesShown == 1)
    }

    @Test func userAttentionDropsTheHold() async {
        let app = FakeApp(isStreaming: true)
        let alerts = app.makeAlerts()
        alerts.holdUntilStreamEnds()
        alerts.standardUserDriverDidReceiveUserAttention(forUpdate: .empty())
        app.isStreaming = false
        await settle()
        #expect(app.updatesShown == 0)
        #expect(!alerts.isHoldingUpdate)
    }
}

/// Stands in for AppModel's observable streaming flag and Sparkle's focus call.
@MainActor
@Observable
private final class FakeApp {
    var isStreaming: Bool
    var updatesShown = 0

    init(isStreaming: Bool) { self.isStreaming = isStreaming }

    func makeAlerts() -> StreamAwareUpdateAlerts {
        StreamAwareUpdateAlerts(
            isStreaming: { self.isStreaming },
            showUpdate: { self.updatesShown += 1 })
    }
}

/// Lets the main-actor hop scheduled by an observation change run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
#endif
