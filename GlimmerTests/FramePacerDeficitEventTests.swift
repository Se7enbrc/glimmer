//
//  FramePacerDeficitEventTests.swift
//
//  Tick-deficit transitions and what they emit (Diag lines, timer reconciles), the
//  floor-assist lifecycle, the warm re-enable cadence stash, depth steps and the link range.
//

import AppKit
import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerDeficitEventTests {

    struct EventCase: Sendable, CustomTestStringConvertible {
        let event: FramePacer.TickDeficitEvent
        let line: String
        let reconciles: Bool
        var testDescription: String { line }
    }

    static let eventCases: [EventCase] = [
        EventCase(event: .deficitEngaged(ticksPerS: 41.3, expectedHz: 117, depth: 3),
                  line: "measured ticks 41.3/s vs expected 117.0Hz, depth=3", reconciles: true),
        EventCase(event: .deficitDisengaged(reason: "case-a", durationSeconds: 1.234, releases: 17,
                                            repaints: 4, ticksPerS: 99),
                  line: "DISENGAGED (case-a) after 1234ms - released 17 frames off-tick, 4 governor repaints",
                  reconciles: true),
        EventCase(event: .floorViolation(ticksPerS: 52.7, floorHz: 118),
                  line: "realized ticks 52.7/s below the pinned 118.0Hz floor", reconciles: false),
        EventCase(event: .floorRecovered(durationSeconds: 1.357, ticksPerS: 77.7),
                  line: "cleared after 1357ms - ticks back at 77.7/s", reconciles: false),
        EventCase(event: .floorAssistEngaged(ticksPerS: 83.9, floorHz: 119, depth: 2),
                  line: "ASSIST engaged - ticks 83.9/s vs 119.0Hz floor, depth=2", reconciles: true),
        EventCase(event: .floorAssistDisengaged(reason: "case-b", durationSeconds: 2.468, releases: 9,
                                                ticksPerS: 116.9),
                  line: "ASSIST disengaged (case-b) after 2468ms - 9 releases during assist, ticks 116.9/s",
                  reconciles: true),
        EventCase(event: .warmHandoverComplete(ticksPerS: 97.3, discarded: 2),
                  line: "rebuilt link healthy at 97.3 ticks/s", reconciles: true)
    ]

    /// Each transition leaves its Diag line; only the ones that change the wanted off-tick
    /// timer state reconcile it, which a pacer in deficit mode shows as a live timer.
    @Test(arguments: eventCases)
    func transitionLogsAndReconcilesTheTimer(_ testCase: EventCase) async throws {
        let pacer = try makeTestPacer()
        pacer.tickDeficit.deficitModeActive = true
        pacer.handleTickDeficitEvents([testCase.event])
        await pacer.pacingQueue.drainForTest()
        let timerArmed = pacer.pacingQueue.sync { pacer.tickDeficit.deficitTimer != nil }
        pacer.tickDeficit.deficitModeActive = false
        pacer.pacingQueue.sync { pacer.reconcileDeficitTimer() }
        #expect(timerArmed == testCase.reconciles)
        #expect(LogStore.shared.snapshot().contains {
            $0.category == "Stream.Pacer" && $0.message.contains(testCase.line)
        })
        if case let .warmHandoverComplete(_, discarded) = testCase.event {
            #expect(pacer.stats.presentationLateDropCount() == UInt64(discarded))
        }
    }

    /// A sustained shortfall raises the floor violation and the assist together; the first
    /// healthy window clears the violation, and the assist leaves only after 3 s fully healthy.
    @Test func floorAssistLeavesOnlyAfterThreeHealthySeconds() throws {
        let pacer = try makeTestPacer(queued: 1)
        pacer.liveness.tickCount = 1
        pacer.tickDeficit.pinnedFloorHz = 120
        var now = 100.0
        _ = service(pacer, now: &now)
        for _ in 0..<3 { #expect(service(pacer, now: &now, ticks: 18).isEmpty) }
        #expect(service(pacer, now: &now, ticks: 18).map(label) == ["floorViolation", "floorAssistEngaged"])
        #expect(pacer.tickDeficit.floorAssistActive)

        let recovered = service(pacer, now: &now, ticks: 30, releases: 5)
        guard case let .floorRecovered(duration, ticksPerS) = try #require(recovered.first) else {
            Issue.record("Expected a floor recovery")
            return
        }
        #expect(recovered.count == 1)
        #expect(duration == 1.25)
        #expect(ticksPerS == 120)

        // 116/s sits between the engage and exit ratios: still assisted, healthy clock restarts.
        for ticks: UInt64 in [30, 30, 29] { #expect(service(pacer, now: &now, ticks: ticks).isEmpty) }
        #expect(pacer.tickDeficit.floorAssistHealthySince.isNaN)
        while now < 104.75 { #expect(service(pacer, now: &now, ticks: 30).isEmpty) }
        #expect(pacer.tickDeficit.floorAssistActive)
        let left = service(pacer, now: &now, ticks: 30)
        guard case let .floorAssistDisengaged(reason, assisted, releases, _) = try #require(left.first) else {
            Issue.record("Expected the assist to disengage")
            return
        }
        #expect(reason == "ticks recovered")
        #expect(assisted == 4)
        #expect(releases == 5)
        #expect(!pacer.tickDeficit.floorAssistActive)
    }

    /// A stopped pacer with enough cadence samples stashes its refined interval; only a warm
    /// handover adopts it, and only while it is fresh.
    @MainActor @Test func warmReenableAdoptsOnlyAFreshStashedCadence() throws {
        let savedInterval = FramePacer.stashedRefinedIntervalSeconds
        let savedAt = FramePacer.stashedRefinedIntervalAt
        defer {
            FramePacer.stashedRefinedIntervalSeconds = savedInterval
            FramePacer.stashedRefinedIntervalAt = savedAt
        }
        FramePacer.stashedRefinedIntervalSeconds = .nan
        let sparse = try makeTestPacer()
        sparse.ptsDeltas = Array(repeating: 1.0 / 90, count: FramePacer.refinedCadenceStashMinSamples - 1)
        sparse.streamFrameIntervalSeconds = 1.0 / 90
        sparse.stashRefinedCadenceForWarmReenable()
        #expect(FramePacer.stashedRefinedIntervalSeconds.isNaN)

        let refined = try makeTestPacer()
        refined.ptsDeltas = Array(repeating: 1.0 / 90, count: FramePacer.refinedCadenceStashMinSamples)
        refined.streamFrameIntervalSeconds = 1.0 / 90
        refined.stashRefinedCadenceForWarmReenable()
        #expect(FramePacer.stashedRefinedIntervalSeconds == 1.0 / 90)

        func adopted(warming: Bool) throws -> Double {
            let pacer = try makeTestPacer()
            if warming { pacer.armWarmHandover() }
            pacer.lock.lock()
            pacer.adoptStashedRefinedCadenceLocked()
            pacer.lock.unlock()
            return pacer.streamFrameIntervalSeconds
        }
        #expect(try adopted(warming: true) == 1.0 / 90)
        #expect(try adopted(warming: false) == 1.0 / 120)
        FramePacer.stashedRefinedIntervalAt = CFAbsoluteTimeGetCurrent()
            - FramePacer.refinedCadenceStashMaxAgeSeconds - 1
        #expect(try adopted(warming: true) == 1.0 / 120)
    }

    // MARK: - Depth steps

    /// The window tick grows one frame per call up to the justified depth, never past it.
    @Test func windowTickGrowsOneFrameAtATime() throws {
        let pacer = try makeTestPacer()
        pacer.adaptiveDepth.reconciledDecisionGeneration = EnvSignalController.shared.decision.generation
        pacer.adaptiveDepth.reconciledTargetDepth = 3
        pacer.growDepthTowardTarget()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 2)
        #expect(pacer.adaptiveDepth.lastTargetShrinkTime.isFinite)
        pacer.growDepthTowardTarget()
        pacer.growDepthTowardTarget()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 3)
    }

    /// A new decision generation replaces the snapshot with 1 + headroom level, capped.
    @Test func refreshPullsOnlyANewDecisionGeneration() throws {
        let pacer = try makeTestPacer()
        let decision = EnvSignalController.shared.decision
        pacer.adaptiveDepth.reconciledDecisionGeneration = decision.generation
        pacer.adaptiveDepth.reconciledTargetDepth = 5
        pacer.refreshReconciledTarget()
        #expect(pacer.adaptiveDepth.reconciledTargetDepth == 5)
        pacer.adaptiveDepth.reconciledDecisionGeneration = decision.generation &+ 1
        pacer.refreshReconciledTarget()
        #expect(pacer.adaptiveDepth.reconciledDecisionGeneration == decision.generation)
        #expect(pacer.adaptiveDepth.reconciledTargetDepth
                == min(FramePacer.maxTargetDepth, max(1, 1 + decision.headroomLevel)))
    }

    /// The first unjustified decay only arms the shrink clock; it never drops a frame at once.
    @Test func firstDecayArmsTheShrinkClock() throws {
        let pacer = try makeTestPacer()
        pacer.adaptiveDepth.adaptiveTargetDepth = 3
        pacer.lock.lock()
        let target = pacer.decayTargetLocked()
        pacer.lock.unlock()
        #expect(target == 3)
        #expect(pacer.adaptiveDepth.lastTargetShrinkTime.isFinite)
    }

    /// Only a present after three empty ticks opens the post-gap window.
    @Test func gapWindowOpensAfterThreeEmptyTicks() throws {
        let pacer = try makeTestPacer()
        pacer.lock.lock()
        defer { pacer.lock.unlock() }
        for _ in 0..<2 { pacer.updateGapRecoveryLocked(presented: false, empty: true, now: 50) }
        pacer.updateGapRecoveryLocked(presented: true, empty: true, now: 51)
        #expect(pacer.liveness.lastGapRecoveryTime == 0)
        #expect(pacer.liveness.emptyTickStreak == 0)
        for _ in 0..<FramePacer.gapRecoveryTickThreshold {
            pacer.updateGapRecoveryLocked(presented: false, empty: true, now: 52)
        }
        pacer.updateGapRecoveryLocked(presented: true, empty: true, now: 53)
        #expect(pacer.liveness.lastGapRecoveryTime == 53)
        #expect(pacer.inGapRecoveryLocked(now: 53.1))
    }

    // MARK: - Link frame-rate range

    /// The floor is the stream rate clamped to the panel; preferred and maximum stay at the panel.
    @Test(arguments: [
        (1.0 / 120, 240.0, Float(120), Float(240)), (1.0 / 240, 60.0, Float(60), Float(60)),
        (1.0 / 30, 120.0, Float(30), Float(120)), (Double.nan, Double.nan, Float(60), Float(60))
    ])
    func preferredRangePinsTheFloorBelowThePanel(
        interval: Double, panel: Double, floor: Float, top: Float
    ) {
        let range = FramePacer.preferredRange(forStreamIntervalSeconds: interval, panelMaxHz: panel)
        #expect(range.minimum == floor)
        #expect(range.maximum == top)
        #expect(range.preferred == top)
    }

    @MainActor @Test func windowlessViewFallsBackToTheMainScreen() {
        let expected = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        #expect(FramePacer.panelMaxHz(for: NSView()) == (expected > 0 ? expected : 60))
    }

    private func label(_ event: FramePacer.TickDeficitEvent) -> String {
        switch event {
        case .deficitEngaged: "deficitEngaged"
        case .deficitDisengaged: "deficitDisengaged"
        case .floorViolation: "floorViolation"
        case .floorRecovered: "floorRecovered"
        case .floorAssistEngaged: "floorAssistEngaged"
        case .floorAssistDisengaged: "floorAssistDisengaged"
        case .warmHandoverComplete: "warmHandoverComplete"
        }
    }

    private func service(
        _ pacer: FramePacer, now: inout Double, ticks: UInt64 = 0, releases: UInt64 = 0
    ) -> [FramePacer.TickDeficitEvent] {
        pacer.lock.lock()
        defer { pacer.lock.unlock() }
        if pacer.tickDeficit.rateWindowStartHostTime.isFinite { now += FramePacer.rateWindowSeconds }
        pacer.liveness.tickCount += ticks
        pacer.liveness.releaseCount += releases
        return pacer.serviceTickDeficitLocked(now: now)
    }
}
