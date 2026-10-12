// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerContentRateTests {
    @Test func hintLogsOnlyAppliedChanges() {
        var log = FramePacer.RateHintLog()
        #expect(log.shouldLog(preferred: 240, variable: true, now: 0) == true)
        for index in 1...600 {
            #expect(log.shouldLog(preferred: 240, variable: true, now: Double(index) / 10) == false)
        }
        #expect(log.shouldLog(preferred: 190, variable: true, now: 61) == true)
        #expect(log.shouldLog(preferred: 190, variable: true, now: 62) == false)
        #expect(log.shouldLog(preferred: 240, variable: false, now: 63) == true)
        #expect(log.shouldLog(preferred: 240, variable: true, now: 70) == true)
    }

    @Test(arguments: [183.0, 190.0, 195.0, 199.4, 202.7, 300.0, 30.0])
    func variableRangeFollowsContentWithinPanelLimits(fps: Double) {
        let range = variableRange(fps)
        #expect(range.minimum == 180)
        #expect(range.maximum == 240)
        #expect(range.preferred == Float(min(max(fps.rounded(), 180), 240)))
    }

    @Test(arguments: [(240.0, 180.0), (144, 120), (120, 120), (60, 60)])
    func variableFloorStaysWithinPanelLimits(panel: Double, floor: Double) {
        for fps in [30.0, 59, 120, 150, 190, 240, 480] {
            let range = FramePacer.preferredRange(
                forStreamIntervalSeconds: 1 / fps, panelMaxHz: panel, variableMinimumHz: 24)
            #expect(range.minimum == Float(floor))
            #expect(range.maximum == Float(panel))
            #expect(Double(range.preferred ?? 0) >= floor)
            #expect(Double(range.preferred ?? 0) <= panel)
        }
        let narrower = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / 190, panelMaxHz: 240, variableMinimumHz: 200)
        #expect(narrower.minimum == 200)
        #expect(narrower.preferred == 200)
    }

    @Test func capabilityRequiresAVariableCurrentMode() {
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: 1 / 240, maximumInterval: 1 / 48, granularity: 0) == 48)
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: 1 / 120, maximumInterval: 1 / 24, granularity: 0.001) == 24)
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: 1 / 240, maximumInterval: 1 / 48, granularity: 1 / 240) == nil)
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: 1 / 60, maximumInterval: 1 / 60, granularity: 1 / 60) == nil)
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: .nan, maximumInterval: 0, granularity: 0) == nil)
        #expect(FramePacer.variableMinimumHz(
            minimumInterval: 1 / 240, maximumInterval: .infinity, granularity: 0) == nil)
    }

    @Test func steadyJitterNeverRetargets() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 201)
        let current = variableRange(201)
        var retargets = 0
        for index in 1...600 {
            let range = variableRange(199 + Double(index % 5))
            if hint.needsUpdate(to: range, current: current, now: Double(index) / 10) { retargets += 1 }
        }
        #expect(retargets == 0)
    }

    @Test func sustainedSlowdownRetargetsOnceAfterTwoSeconds() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        var current = variableRange(240)
        var changes: [Double] = []
        for index in 0...600 {
            let now = Double(index) / 10
            let range = variableRange(190)
            if hint.needsUpdate(to: range, current: current, now: now) {
                changes.append(now)
                current = range
                hint.appliedAt = now
                hint.preferredHz = Double(range.preferred ?? 0)
            }
        }
        #expect(changes == [2])
        #expect(current.preferred == 190)
    }

    @Test func hysteresisRequiresMoreThanTenPercentAndContinuousDwell() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        let current = variableRange(240)
        #expect(hint.needsUpdate(to: variableRange(216), current: current, now: 0) == false)
        #expect(hint.needsUpdate(to: variableRange(216), current: current, now: 3) == false)
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 4) == false)
        #expect(hint.needsUpdate(to: variableRange(240), current: current, now: 5.9) == false)
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 6) == false)
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 7.9) == false)
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 8) == true)
    }

    @Test func changedDestinationRestartsDwellAndFasterContentRecovers() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        let current = variableRange(240)
        #expect(hint.needsUpdate(to: variableRange(215), current: current, now: 0) == false)
        #expect(hint.needsUpdate(to: variableRange(180), current: current, now: 1.9) == false)
        #expect(hint.needsUpdate(to: variableRange(180), current: current, now: 2) == false)
        #expect(hint.needsUpdate(to: variableRange(180), current: current, now: 4) == true)
        hint = FramePacer.RateHint(appliedAt: 4, preferredHz: 180)
        #expect(hint.needsUpdate(to: current, current: variableRange(180), now: 5) == false)
        #expect(hint.needsUpdate(to: current, current: variableRange(180), now: 7) == true)
    }

    @Test func stallsBurstsAndResetsCannotLowerTheHeldTarget() {
        var samples = FramePacer.RateHintSamples()
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        let current = variableRange(240)
        var now = 0.0
        var pts = 0.0
        var retargets = 0
        for index in 0..<2400 {
            // Alternate a decode drought, catch-up burst and PTS resync between normal frames.
            let phase = index % 120
            now += phase == 0 ? 0.2 : (phase < 8 ? 0.0001 : 1 / 190)
            pts += phase == 60 ? -1 : 1 / 190
            samples.observe(pts: pts, now: now, interval: 1 / 190)
            let range = variableRange([59.0, 120, 150, 190, 480][index % 5])
            #expect(range.minimum == 180)
            #expect((range.preferred ?? 0) >= 180)
            if hint.needsUpdate(to: range, current: current, now: now,
                                contentSince: samples.eligibleSince(now: now, interval: 1 / 190)) {
                retargets += 1
            }
        }
        #expect(retargets == 0)
        #expect(samples.eligibleSince(now: now + 1, interval: 1 / 190) == nil)
        #expect(hint.needsUpdate(to: variableRange(59), current: current, now: now + 10, contentSince: nil) == false)
    }

    @Test(arguments: [(0.1, 0.005), (0.0001, 0.005), (0.005, -1.0), (0.005, Double.nan), (0.005, 0.5)])
    func eachDeliveryInterruptionRestartsObservation(arrivalGap: Double, ptsGap: Double) {
        var samples = FramePacer.RateHintSamples()
        for index in 0...400 {
            let time = Double(index) / 190
            samples.observe(pts: time, now: time, interval: 1 / 190)
        }
        let previous = 400.0 / 190
        #expect(samples.eligibleSince(now: previous, interval: 1 / 190) == 0)
        let now = previous + arrivalGap
        samples.observe(pts: previous + ptsGap, now: now, interval: 1 / 190)
        #expect(samples.eligibleSince(now: now, interval: 1 / 190) == now)
    }

    @Test func healthyDeliveryAfterAnInterruptionCanRetarget() {
        var samples = FramePacer.RateHintSamples()
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        let current = variableRange(240)
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 0) == false)
        samples.observe(pts: 0, now: 1.9, interval: 1 / 190)
        for index in 0..<380 {
            let now = 1.9 + Double(index) / 190
            samples.observe(pts: Double(index) / 190, now: now, interval: 1 / 190)
            #expect(hint.needsUpdate(to: variableRange(190), current: current, now: now,
                                     contentSince: samples.eligibleSince(now: now, interval: 1 / 190)) == false)
        }
        samples.observe(pts: 2.1, now: 4, interval: 1 / 190)
        // The fresh gap restarts observation even if no main-actor check ran during it.
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: 4,
                                 contentSince: samples.eligibleSince(now: 4, interval: 1 / 190)) == false)
        for index in 1...400 {
            let now = 4 + Double(index) / 190
            samples.observe(pts: 2.1 + Double(index) / 190, now: now, interval: 1 / 190)
        }
        let now = 4 + 400.0 / 190
        #expect(hint.needsUpdate(to: variableRange(190), current: current, now: now,
                                contentSince: samples.eligibleSince(now: now, interval: 1 / 190)) == true)
    }

    @Test func hideAndShowDiscardHintEvidence() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.running = true
        pacer.rateHintSamples.observe(pts: 0, now: 0, interval: 1 / 240)
        pacer.setPresentSuppressed(true)
        #expect(pacer.rateHintSamples.eligibleSince(now: 0, interval: 1 / 240) == nil)
        pacer.submit(try emptySampleBuffer(), hostPTS: .zero)
        pacer.setPresentSuppressed(false)
        #expect(pacer.rateHintSamples.eligibleSince(now: CACurrentMediaTime(), interval: 1 / 240) == nil)
    }

    @Test func decoderResyncDiscardsHintEvidence() {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.running = true
        pacer.rateHintSamples.observe(pts: 0, now: 0, interval: 1 / 240)
        pacer.clearQueue(reason: "discontinuity")
        #expect(pacer.rateHintSamples.eligibleSince(now: 0, interval: 1 / 240) == nil)
    }

    @Test func linkRebindKeepsHeldTargetWithinTheNewPanelLimits() {
        let initial = FramePacer.RateHint().rangeForRebind(
            configuredInterval: 1 / 240, panelMaxHz: 240, variableMinimumHz: 48)
        #expect(initial.preferred == 240)
        let hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 190)
        let samePanel = hint.rangeForRebind(
            configuredInterval: 1 / 240, panelMaxHz: 240, variableMinimumHz: 48)
        #expect(samePanel.minimum == 180)
        #expect(samePanel.preferred == 190)
        let slowerPanel = hint.rangeForRebind(
            configuredInterval: 1 / 240, panelMaxHz: 144, variableMinimumHz: 48)
        #expect(slowerPanel.minimum == 120)
        #expect(slowerPanel.preferred == 144)
        let fixed = hint.rangeForRebind(configuredInterval: 1 / 240, panelMaxHz: 240, variableMinimumHz: nil)
        #expect(fixed.minimum == 240)
        #expect(fixed.preferred == 240)
    }

    @Test func fixedPanelRangeIsUnchanged() {
        for panel in [60.0, 120, 144, 240] {
            for fps in [30.0, 59.94, 120, 190, 240] {
                let range = FramePacer.preferredRange(forStreamIntervalSeconds: 1 / fps, panelMaxHz: panel)
                #expect(range.minimum == Float(min(fps, panel)))
                #expect(range.maximum == Float(panel))
                #expect(range.preferred == Float(panel))
            }
        }
    }

    private func variableRange(_ fps: Double) -> CAFrameRateRange {
        FramePacer.preferredRange(forStreamIntervalSeconds: 1 / fps, panelMaxHz: 240, variableMinimumHz: 48)
    }

    @Test func fallbackFloorChangesCannotBypassPreferredDwell() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 190)
        let content = variableRange(190)
        let fallback = FramePacer.preferredRange(forStreamIntervalSeconds: 1 / 240, panelMaxHz: 240)
        #expect(hint.needsUpdate(to: fallback, current: content, now: 1) == false)
        #expect(hint.needsUpdate(to: fallback, current: content, now: 3) == true)
        hint = FramePacer.RateHint(appliedAt: 3, preferredHz: 240)
        #expect(hint.needsUpdate(to: content, current: fallback, now: 6) == false)
        #expect(hint.needsUpdate(to: content, current: fallback, now: 7.9) == false)
        #expect(hint.needsUpdate(to: content, current: fallback, now: 8) == true)
    }

    @Test func ignoredHintFallsBackThenRetries() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 190)
        let grace = hint.followsContent(now: 0.5, measuredHz: 120, contentHz: 190)
        let fallback = hint.followsContent(now: 1.5, measuredHz: 120, contentHz: 190)
        let held = hint.followsContent(now: 6.4, measuredHz: 240, contentHz: 190)
        let retry = hint.followsContent(now: 6.5, measuredHz: 240, contentHz: 190)
        let recovered = hint.followsContent(now: 7, measuredHz: 190, contentHz: 190)
        #expect(grace)
        #expect(!fallback)
        #expect(!held)
        #expect(retry)
        #expect(recovered)
    }

    @Test func contentSlowdownIsNotAnIgnoredHint() {
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: 240)
        for time in [1.0, 2, 3] {
            let follows = hint.followsContent(now: time, measuredHz: 185, contentHz: 190)
            #expect(follows)
        }
    }

    @Test func underDeliveryMovesContentCadenceWithoutPoisoningRecovery() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.running = true
        let sample = try emptySampleBuffer()
        var ticks = 0
        for index in 0...64 {
            pacer.submit(sample, hostPTS: CMTime(value: Int64(ticks * 375), timescale: 90_000))
            ticks += index.isMultiple(of: 4) ? 2 : 1
        }
        #expect(abs(pacer.streamFrameIntervalSeconds - 1 / 240) < 1e-8)
        #expect(abs(pacer.contentFrameIntervalSeconds - 1 / 192) < 1e-8)
        #expect(FramePacer.contentInterval([1 / 240, 0.5], base: 1 / 240) < 1 / 120)
        for index in 1...64 {
            pacer.submit(sample, hostPTS: CMTime(value: Int64((ticks - 2 + index) * 375), timescale: 90_000))
        }
        #expect(abs(pacer.contentFrameIntervalSeconds - 1 / 240) < 1e-8)
    }

    @Test(arguments: [183.0, 190.0, 195.0])
    func trimSlackPreservesEvenRepeatSpacing(fps: Double) throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.contentFrameIntervalSeconds = 1 / fps
        let sample = try emptySampleBuffer()
        var repeatTicks: [Int] = []
        var presents = 0
        pacer.lock.lock()
        for tick in 0..<2400 {
            // Model ready frames within the permitted one-frame trim slack, not a forced backlog.
            while pacer.queue.count < 2 {
                pacer.queue.append(FramePacer.Entry(sampleBuffer: sample, hostPTSSeconds: 0))
            }
            let gate = pacer.dequeueDueFrameLocked(
                targetTimestamp: Double(tick) / 240, vsyncInterval: 1 / 240, effectiveTarget: 1)
            if gate.toPresent != nil { presents += 1 } else { repeatTicks.append(tick) }
        }
        pacer.lock.unlock()
        let ideal = 240 / (240 - fps)
        let gaps = zip(repeatTicks, repeatTicks.dropFirst()).map { $1 - $0 }
        #expect(abs(Double(presents) - fps * 10) <= 1)
        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0 == Int(ideal.rounded(.down)) || $0 == Int(ideal.rounded(.up)) })
    }

    @Test func unevenArrivalsAddAtMostOneContentFrameOfWait() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        let interval = 1.0 / 192
        pacer.contentFrameIntervalSeconds = interval
        let sample = try emptySampleBuffer()
        var arrival = 0.0
        var index = 0
        var maximumWait = 0.0
        pacer.lock.lock()
        for tick in 0..<2400 {
            let now = Double(tick) / 240
            while arrival <= now {
                pacer.queue.append(FramePacer.Entry(sampleBuffer: sample, hostPTSSeconds: arrival))
                index += 1
                arrival += index.isMultiple(of: 4) ? 2 / 240 : 1 / 240
            }
            let gate = pacer.dequeueDueFrameLocked(
                targetTimestamp: now, vsyncInterval: 1 / 240, effectiveTarget: 1)
            if let entry = gate.toPresent { maximumWait = max(maximumWait, now - entry.hostPTSSeconds) }
        }
        let queued = pacer.queue.count
        pacer.lock.unlock()
        #expect(queued <= 1)
        #expect(maximumWait <= interval + 1e-8)
    }

    @Test func variableScanoutUsesTheTargetAndEnqueuesEachFrameOnce() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.running = true
        pacer.variableRefreshEnabled = true
        pacer.lastPresentMediaTime = 10
        pacer.liveness.lastTickTargetMediaTime = 20
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1 / 240
        let sample = try emptySampleBuffer()
        pacer.submit(sample, hostPTS: .zero)
        #expect(pacer.queue.count == 1)
        pacer.lock.lock()
        let interval = FramePacer.releaseInterval(variable: true, target: 20, timestamp: 20 - 1 / 190, nominal: 1 / 240)
        let first = pacer.dequeueDueFrameLocked(targetTimestamp: 20, vsyncInterval: interval, effectiveTarget: 1)
        let again = pacer.dequeueDueFrameLocked(targetTimestamp: 20, vsyncInterval: interval, effectiveTarget: 1)
        pacer.lock.unlock()
        #expect(abs(interval - 1 / 190) < 1e-8)
        #expect(first.toPresent != nil)
        #expect(again.toPresent == nil)
        #expect(FramePacer.releaseInterval(variable: false, target: 20, timestamp: 19, nominal: 1 / 240) == 1.0 / 240)
        #expect(FramePacer.releaseInterval(variable: true, target: .nan, timestamp: 19, nominal: 1 / 240) == 1.0 / 240)
    }

    @Test func measuredContentDoesNotTriggerFalseDeficitAssist() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        pacer.running = true
        pacer.contentFrameIntervalSeconds = 1 / 192
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1 / 240
        pacer.tickDeficit.pinnedFloorHz = 48
        pacer.queue = [FramePacer.Entry(sampleBuffer: try emptySampleBuffer(), hostPTSSeconds: 0)]
        pacer.lock.lock()
        _ = pacer.serviceTickDeficitLocked(now: 10)
        for window in 1...12 {
            pacer.liveness.tickCount += 48
            pacer.liveness.releaseCount += 48
            _ = pacer.serviceTickDeficitLocked(now: 10 + Double(window) / 4)
        }
        pacer.lock.unlock()
        #expect(pacer.tickDeficit.lastExpectedTickHz == 192)
        #expect(!pacer.tickDeficit.floorAssistActive)
        #expect(!pacer.tickDeficit.deficitModeActive)
    }

    private func emptySampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}
