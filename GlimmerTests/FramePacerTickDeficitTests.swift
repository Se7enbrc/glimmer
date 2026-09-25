import CoreMedia
import Dispatch
import Foundation
import os
import Testing
@testable import Glimmer

struct FramePacerTickDeficitTests {
    @Test func deficitEngagesHoldsAndRecovers() throws {
        let pacer = try makePacer()
        var now = 100.0
        #expect(service(pacer, now: &now).isEmpty)
        let engaged = service(pacer, now: &now, ticks: 3, releases: 2)
        #expect(engaged.count == 1)
        #expect(pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince == 100)
        #expect(pacer.tickDeficit.measuredTicksPerSecond == 12)
        #expect(pacer.tickDeficit.measuredReleasesPerSecond == 8)

        #expect(service(pacer, now: &now, ticks: 18).isEmpty)
        #expect(pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince == 100)

        let recovered = service(pacer, now: &now, ticks: 24, releases: 5)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
        #expect(pacer.tickDeficit.deficitEngagedAt.isNaN)
        #expect(pacer.tickDeficit.lastRepaintHostTime.isNaN)
        guard case let .deficitDisengaged(_, duration, releases, _, ticksPerS) = try #require(recovered.first) else {
            Issue.record("Expected a deficit recovery event")
            return
        }
        #expect(duration == 2 * FramePacer.rateWindowSeconds)
        #expect(releases == 5)
        #expect(ticksPerS == 96)
    }

    @Test func hysteresisDoesNotEngageFromHealthyState() throws {
        let pacer = try makePacer()
        var now = 100.0
        _ = service(pacer, now: &now)
        #expect(service(pacer, now: &now, ticks: 18).isEmpty)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
    }

    @Test func emptyQueueDoesNotEngageDeficit() throws {
        let pacer = try makePacer(queued: false)
        var now = 100.0
        _ = service(pacer, now: &now)
        #expect(service(pacer, now: &now, ticks: 3).isEmpty)
        #expect(pacer.tickDeficit.tickDeficitSince.isFinite)
        #expect(!pacer.tickDeficit.deficitModeActive)
    }

    @Test func expectedTicksAreCappedAtPanelRate() throws {
        let pacer = try makePacer(fps: 240)
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 60
        var now = 100.0
        _ = service(pacer, now: &now)
        #expect(service(pacer, now: &now, ticks: 15).isEmpty)
        #expect(pacer.tickDeficit.lastExpectedTickHz == 60)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
    }

    @Test func suppressionClearsDeficitAndFloorState() throws {
        let pacer = try makePacer()
        pacer.tickDeficit.pinnedFloorHz = 120
        var now = 100.0
        _ = service(pacer, now: &now)
        // First engage the assist, then collapse far enough to engage the deficit too.
        for _ in 0..<4 { _ = service(pacer, now: &now, ticks: 18) }
        #expect(pacer.tickDeficit.floorAssistActive)
        #expect(pacer.tickDeficit.floorViolationLogged)
        _ = service(pacer, now: &now, ticks: 3)
        #expect(pacer.tickDeficit.deficitModeActive)
        pacer.tickDeficit.warmHealthyWindowStreak = 1
        pacer.tickDeficit.lastRepaintHostTime = now
        os_unfair_lock_lock(&pacer.lock)
        let events = pacer.clearForSuppressionLocked(now: now)
        os_unfair_lock_unlock(&pacer.lock)
        #expect(events.count == 2)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(!pacer.tickDeficit.floorAssistActive)
        #expect(!pacer.tickDeficit.floorViolationLogged)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
        #expect(pacer.tickDeficit.floorViolationSince.isNaN)
        #expect(pacer.tickDeficit.assistShortSince.isNaN)
        #expect(pacer.tickDeficit.deficitEngagedAt.isNaN)
        #expect(pacer.tickDeficit.floorAssistEngagedAt.isNaN)
        #expect(pacer.tickDeficit.floorAssistHealthySince.isNaN)
        #expect(pacer.tickDeficit.lastRepaintHostTime.isNaN)
        #expect(pacer.tickDeficit.warmHealthyWindowStreak == 0)
        pacer.presentSuppressed = true
        #expect(service(pacer, now: &now, ticks: 0).isEmpty)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
    }

    @Test func oversizedServiceGapReseedsWithoutVerdict() throws {
        let pacer = try makePacer()
        var now = 100.0
        _ = service(pacer, now: &now)
        _ = service(pacer, now: &now, ticks: 30, releases: 30)
        now += FramePacer.rateWindowSeconds * FramePacer.rateWindowDiscardFactor
        #expect(service(pacer, now: &now, ticks: 1).isEmpty)
        #expect(pacer.tickDeficit.rateWindowStartHostTime == now)
        #expect(pacer.tickDeficit.rateWindowStartTicks == pacer.liveness.tickCount)
        #expect(pacer.tickDeficit.rateWindowStartReleases == pacer.liveness.releaseCount)
        #expect(pacer.tickDeficit.measuredTicksPerSecond.isNaN)
        #expect(pacer.tickDeficit.measuredReleasesPerSecond.isNaN)
        #expect(!pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince.isNaN)
        _ = service(pacer, now: &now, ticks: 3)
        #expect(pacer.tickDeficit.deficitModeActive)
        #expect(pacer.tickDeficit.tickDeficitSince == now - FramePacer.rateWindowSeconds)
    }

    @Test func warmHandoverDiscardsRetainedFrameAfterConsecutiveHealthyWindows() async throws {
        let pacer = try makePacer()
        pacer.armWarmHandover()
        pacer.lastPresentMediaTime = 99
        var now = 100.0
        _ = service(pacer, now: &now)
        _ = service(pacer, now: &now, ticks: 30)
        _ = service(pacer, now: &now, ticks: 3)
        #expect(pacer.tickDeficit.warmHealthyWindowStreak == 0)
        #expect(pacer.tickDeficit.warmingUp)
        #expect(!pacer.tickDeficit.deficitModeActive)
        for _ in 1..<FramePacer.warmHandoverHealthyWindows {
            #expect(service(pacer, now: &now, ticks: 30).isEmpty)
            #expect(pacer.tickDeficit.warmingUp)
            #expect(pacer.queue.count == 1)
        }
        let events = service(pacer, now: &now, ticks: 30)
        #expect(!pacer.tickDeficit.warmingUp)
        #expect(pacer.tickDeficit.warmHealthyWindowStreak == 0)
        #expect(pacer.queue.isEmpty)
        #expect(pacer.lastPresentMediaTime.isNaN)
        guard case let .warmHandoverComplete(_, discarded) = try #require(events.first) else {
            Issue.record("Expected a warm handover event")
            return
        }
        #expect(discarded == 1)
        #expect(pacer.stats.presentationLateDropCount() == 0)
        pacer.handleTickDeficitEvents(events)
        await pacer.pacingQueue.drainForTest()
        #expect(pacer.stats.presentationLateDropCount() == 1)
    }

    @Test func directDrainPresentsOnPacingQueue() async throws {
        let pacer = try makePacer()
        let key = OSAllocatedUnfairLock(initialState: DispatchSpecificKey<Bool>())
        pacer.pacingQueue.setSpecific(key: key.withLock { $0 }, value: true)
        let observations = OSAllocatedUnfairLock(initialState: [Bool]())
        pacer.willPresent = { _ in
            let onQueue = key.withLock { DispatchQueue.getSpecific(key: $0) != nil }
            observations.withLock { $0.append(onQueue) }
            return true
        }
        pacer.drainHeadDirectly(reason: "test")
        await pacer.pacingQueue.drainForTest()
        #expect(observations.withLock { $0 } == [true])
        #expect(pacer.queue.isEmpty)
        #expect(pacer.liveness.releaseCount == 1)
    }

    private func service(
        _ pacer: FramePacer, now: inout Double, ticks: UInt64 = 0, releases: UInt64 = 0
    ) -> [FramePacer.TickDeficitEvent] {
        os_unfair_lock_lock(&pacer.lock)
        defer { os_unfair_lock_unlock(&pacer.lock) }
        if pacer.tickDeficit.rateWindowStartHostTime.isFinite {
            now += FramePacer.rateWindowSeconds
        }
        pacer.liveness.tickCount += ticks
        pacer.liveness.releaseCount += releases
        return pacer.serviceTickDeficitLocked(now: now)
    }

    private func makePacer(fps: Int32 = 120, queued: Bool = true) throws -> FramePacer {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: fps)
        pacer.running = true
        pacer.liveness.tickCount = 1
        if queued {
            var buffer: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
                sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &buffer)
            pacer.queue.append(FramePacer.Entry(sampleBuffer: try #require(buffer), hostPTSSeconds: 0))
        }
        return pacer
    }
}
