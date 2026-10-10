//
//  EnvSignalStateMachineTests.swift
//
//  The env-signal radio baseline, session-relative sag evidence, the
//  CAUTION/DISTRESS ladder and its quiet step-down, the wired reset and the cadence dial.
//

import Foundation
import Testing
@testable import Glimmer

struct EnvSignalStateMachineTests {

    private func associated(rssi: Int?, rate: Double?) -> WiFiSnapshot {
        WiFiSnapshot(linkState: .associated, rssiDbm: rssi, txRateMbps: rate)
    }

    /// A controller whose baseline is warm at -50 dBm and 800 Mbps.
    private func warmController() -> EnvSignalController {
        let controller = EnvSignalController()
        controller.rssiHistogram[50] = EnvSignalController.radioBaselineMinSamples
        controller.rssiSampleCount = EnvSignalController.radioBaselineMinSamples
        controller.txHistogram[32] = EnvSignalController.radioBaselineMinSamples
        controller.txSampleCount = EnvSignalController.radioBaselineMinSamples
        return controller
    }

    private func close(
        _ controller: EnvSignalController, link: EnvSignalController.LinkClass = .wifi,
        rssi: Int? = nil, rate: Double? = nil, coGap100: Bool = false, jitterMs: Double = 0
    ) {
        var window = EnvSignalController.WindowEvidence()
        window.videoArrived = true
        window.rssiDbm = rssi
        window.txRateMbps = rate
        if coGap100 {
            window.netGap50 = 1; window.audioGap50 = 1
            window.netGap100 = 1; window.audioGap100 = 1
        }
        window.maxJitterMs = jitterMs
        controller.window = window
        controller.evaluateWindow(link: link)
    }

    @Test func baselineCountsOnlyAssociatedReadings() {
        let controller = EnvSignalController()
        controller.observeCaptureTick(route: nil, wifi: associated(rssi: -50, rate: 800))
        controller.observeCaptureTick(route: nil, wifi: associated(rssi: -120, rate: 9_000))
        controller.observeCaptureTick(route: nil, wifi: associated(rssi: 0, rate: 0))
        controller.observeCaptureTick(route: nil, wifi: WiFiSnapshot(linkState: .unassociated, rssiDbm: -40))
        #expect(controller.rssiSampleCount == 2)
        #expect(controller.rssiHistogram[50] == 1)
        #expect(controller.rssiHistogram[100] == 1)
        #expect(controller.txSampleCount == 2)
        #expect(controller.txHistogram[32] == 1)
        #expect(controller.txHistogram[240] == 1)
    }

    /// Radio-only evidence needs five sustained windows, judged against this session's p50.
    @Test func rssiSagBelowTheSessionMedianEscalatesAfterFiveWindows() {
        let controller = warmController()
        for _ in 0..<4 { close(controller, rssi: -58) }
        #expect(controller.state == .clear)
        #expect(controller.window.radioArmed)
        #expect(controller.window.rssiP50 == -50)
        #expect(controller.window.txP95 == 812.5)
        close(controller, rssi: -58)
        #expect(controller.state == .caution)
        #expect(controller.stateChangesTotal.value == 1)
    }

    @Test func txRateSagCountsAndAShallowDipDoesNot() {
        let dip = warmController()
        for _ in 0..<5 { close(dip, rssi: -57, rate: 500) }
        #expect(dip.state == .clear)
        let sag = warmController()
        for _ in 0..<5 { close(sag, rate: 400) }
        #expect(sag.state == .caution)
    }

    /// Radio evidence arms only on a Wi-Fi route, and only once the baseline is warm.
    @Test func radioEvidenceNeedsAWifiRouteAndAWarmBaseline() {
        let tunnel = warmController()
        for _ in 0..<6 { close(tunnel, link: .tunnel, rssi: -70) }
        #expect(!tunnel.window.radioArmed)
        #expect(tunnel.state == .clear)
        let cold = warmController()
        cold.rssiSampleCount -= 1
        cold.txSampleCount -= 1
        for _ in 0..<6 { close(cold, rssi: -70) }
        #expect(cold.window.rssiP50 == nil)
        #expect(cold.state == .clear)
    }

    @Test func severeCoGapsClimbToDistressThenBleedOutOneStepAtATime() {
        let controller = EnvSignalController()
        for _ in 0..<EnvSignalController.escalateWindows { close(controller, coGap100: true) }
        #expect(controller.state == .caution)
        for _ in 0..<EnvSignalController.escalateWindows { close(controller, coGap100: true) }
        #expect(controller.state == .distress)
        for _ in 0..<EnvSignalController.quietWindowsPerStepDown - 1 { close(controller) }
        #expect(controller.state == .distress)
        // A neutral window (jitter in the dead band) restarts the quiet dwell.
        close(controller, jitterMs: 6)
        for _ in 0..<EnvSignalController.quietWindowsPerStepDown - 1 { close(controller) }
        #expect(controller.state == .distress)
        close(controller)
        #expect(controller.state == .caution)
        for _ in 0..<EnvSignalController.quietWindowsPerStepDown { close(controller) }
        #expect(controller.state == .clear)
        #expect(controller.stateChangesTotal.value == 4)
    }

    /// Above CLEAR the smoothed jitter maps onto headroom levels, capped at the maximum.
    @Test func headroomFollowsSmoothedJitterOnlyAboveClear() {
        let controller = EnvSignalController()
        close(controller, jitterMs: 20)
        #expect(controller.decision.headroomLevel == 0)
        controller.stateValue = .caution
        close(controller, jitterMs: 20)
        #expect(controller.decision.headroomLevel == 2)
        let generation = controller.decision.generation
        close(controller, jitterMs: 400)
        #expect(controller.decision.headroomLevel == EnvSignalController.maxHeadroomLevel)
        #expect(controller.decision.generation > generation)
    }

    @Test func wiredRouteForcesClearAndRestAtOnce() {
        let controller = EnvSignalController()
        controller.stateValue = .distress
        controller.headroomLevelValue = 2
        controller.smoothedJitterMsValue = 20
        controller.observeCaptureTick(route: StreamRouteSnapshot(linkLabel: "wired"), wifi: nil)
        #expect(controller.state == .clear)
        #expect(controller.streamLink == "wired")
        #expect(controller.decision.headroomLevel == 0)
        #expect(controller.decision.smoothedJitterMs == 0)
        #expect(controller.decision.generation == 1)
        for _ in 0..<EnvSignalController.escalateWindows + 2 { close(controller, link: .wired, coGap100: true) }
        #expect(controller.state == .clear)
    }

    @Test func newSessionStartsFromAnEmptyClearBaseline() {
        let controller = warmController()
        for _ in 0..<EnvSignalController.escalateWindows { close(controller, coGap100: true) }
        #expect(controller.state == .caution)
        controller.resetForNewSession()
        #expect(controller.state == .clear)
        #expect(controller.stateChangesTotal.value == 0)
        #expect(controller.rssiSampleCount == 0 && controller.txSampleCount == 0)
        #expect(controller.degradedRun == 0 && controller.severeRun == 0)
        #expect(controller.decision.headroomLevel == 0)
    }

    /// Without a session's route probe the 2 s tick feeds nothing.
    @Test func streamTickWithoutASessionIsANoOp() {
        let controller = EnvSignalController()
        controller.observeStreamTick()
        controller.feedQueue.sync {}
        #expect(controller.lastFedNanos == 0)
    }

    /// The live cadence wrapper: no fresh route is fast, a fed wired route relaxes,
    /// and a ping-loop restart drops the route claim again.
    @Test func cadenceRelaxesOnlyWhileAWiredRouteClaimIsFresh() {
        let controller = EnvSignalController()
        #expect(controller.steadyPingInterval() == EnvSignalController.fastPingIntervalSeconds)
        controller.observeCaptureTick(route: StreamRouteSnapshot(linkLabel: "wired"), wifi: nil)
        #expect(controller.steadyPingInterval() == EnvSignalController.relaxedPingIntervalSeconds)
        controller.videoPingsSentTotal.increment()
        controller.noteVideoPingLoopStart()
        #expect(controller.videoPingsSentTotal.value == 0)
        #expect(controller.streamLink == "unknown")
        #expect(controller.steadyPingInterval() == EnvSignalController.fastPingIntervalSeconds)
    }

    @Test func vocabularyAndDueMath() {
        #expect(EnvSignalController.LinkClass(label: "wifi") == .wifi)
        #expect(EnvSignalController.LinkClass(label: "ethernet") == .unknown)
        #expect(EnvSignalController.LinkClass(label: nil) == .unknown)
        #expect(EnvSignalController.EnvState.distress.label == "distress")
        #expect(EnvSignalController.dueNanos(for: 0.075) == 70_000_000)
        #expect(EnvSignalController.dueNanos(for: 0.001) == 0)
    }
}
