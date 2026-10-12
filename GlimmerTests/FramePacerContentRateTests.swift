// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerContentRateTests {
    @Test func hintLogsIgnoreJitterAndReportOnlySustainedMoves() {
        var log = FramePacer.RateHintLog()
        #expect(log.shouldLog(preferred: 190, variable: true, now: 0) == true)
        for index in 1..<100 {
            #expect(log.shouldLog(preferred: index.isMultiple(of: 2) ? 192 : 188,
                                   variable: true, now: Double(index) / 10) == false)
        }
        #expect(log.shouldLog(preferred: 193, variable: true, now: 10) == true)
        #expect(log.shouldLog(preferred: 200, variable: true, now: 11) == false)
        #expect(log.shouldLog(preferred: 201, variable: true, now: 12.9) == false)
        #expect(log.shouldLog(preferred: 200, variable: true, now: 13) == true)
        #expect(log.shouldLog(preferred: 206, variable: true, now: 14) == false)
        #expect(log.shouldLog(preferred: 194, variable: true, now: 15) == false)
        #expect(log.shouldLog(preferred: 200, variable: true, now: 16) == false)
        #expect(log.shouldLog(preferred: 200, variable: true, now: 100) == false)
    }

    @Test func hintFallbackAndVariableModeChangesLogImmediately() {
        var log = FramePacer.RateHintLog()
        #expect(log.shouldLog(preferred: 190, variable: true, now: 0) == true)
        #expect(log.shouldLog(preferred: 240, variable: false, now: 0.5) == true)
        #expect(log.shouldLog(preferred: 240, variable: false, now: 1) == false)
        #expect(log.shouldLog(preferred: 190, variable: true, now: 5.5) == true)
    }
    @Test(arguments: [183.0, 190.0, 195.0, 300.0, 30.0])
    func variableRangeFollowsContentWithinPanelLimits(fps: Double) {
        let range = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / fps, panelMaxHz: 240, variableMinimumHz: 48)
        #expect(range.minimum == 48)
        #expect(range.maximum == 240)
        #expect(range.preferred == Float(min(max(fps, 48), 240)))
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

    @Test func hintDeadbandAndDwellAvoidChasingEveryFrame() {
        let current = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / 190, panelMaxHz: 240, variableMinimumHz: 48)
        let near = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / 191, panelMaxHz: 240, variableMinimumHz: 48)
        let changed = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / 200, panelMaxHz: 240, variableMinimumHz: 48)
        let hint = FramePacer.RateHint(appliedAt: 10, preferredHz: 190)
        #expect(!hint.needsUpdate(to: near, current: current, now: 11))
        #expect(!hint.needsUpdate(to: changed, current: current, now: 10.4))
        #expect(hint.needsUpdate(to: changed, current: current, now: 10.5))
        let fixed = FramePacer.preferredRange(forStreamIntervalSeconds: 1 / 240, panelMaxHz: 240)
        #expect(hint.needsUpdate(to: fixed, current: current, now: 10.1))
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
