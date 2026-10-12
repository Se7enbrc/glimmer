// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import CoreMedia
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerDisplayTests {
    static let fixedRates = [60.0, 75, 144, 165, 240, 360, 59.94, 119.88, 23.976]
    static let variableRates = [(24.0, 120.0), (48, 240), (40, 120), (48, 144), (48, 60)]

    @Test(arguments: fixedRates)
    func fixedModesNeverEngageVariablePacing(rate: Double) {
        for maximumInterval in [1 / rate, 4 / rate] {
            let minimum = FramePacer.variableMinimumHz(
                minimumInterval: 1 / rate, maximumInterval: maximumInterval, granularity: 1 / rate)
            #expect(minimum == nil)
            let maximum = FramePacer.panelMaxHz(minimumInterval: 1 / rate, maximumFramesPerSecond: Int(rate))
            #expect(abs(maximum - rate) < 1e-10)
            let range = FramePacer.preferredRange(
                forStreamIntervalSeconds: 2 / rate, panelMaxHz: maximum, variableMinimumHz: minimum)
            #expect(range.minimum == Float(rate / 2))
            #expect(range.maximum == Float(rate))
            #expect(range.preferred == Float(rate))
        }
    }

    @Test(arguments: variableRates)
    func variableModesUseTheirReportedRange(minimum: Double, maximum: Double) {
        let floor = FramePacer.variableMinimumHz(
            minimumInterval: 1 / maximum, maximumInterval: 1 / minimum, granularity: 0)
        #expect(floor == minimum)
        let range = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / 23.976, panelMaxHz: maximum, variableMinimumHz: floor)
        #expect(range.minimum == Float(max(minimum, maximum * 0.75)))
        #expect(range.preferred == range.minimum)
        #expect(range.maximum == Float(maximum))
    }

    @Test(arguments: [59.94, 119.88, 23.976])
    func fractionalRatesStayExactWithoutDriftRetargeting(rate: Double) throws {
        let maximum = rate / 0.8
        let range = FramePacer.preferredRange(
            forStreamIntervalSeconds: 1 / rate, panelMaxHz: maximum, variableMinimumHz: rate / 2)
        #expect(range.preferred == Float(rate))
        #expect(range.maximum == Float(maximum))
        var hint = FramePacer.RateHint(appliedAt: 0, preferredHz: Double(try #require(range.preferred)))
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: Int32(rate.rounded()))
        pacer.running = true
        let sample = try emptySampleBuffer()
        for index in 0...3600 {
            // Exact rational timestamps avoid a whole-Hz approximation accumulating phase error.
            let time = Double(index) / rate
            pacer.submit(sample, hostPTS: CMTime(seconds: time, preferredTimescale: 60_000_000))
            let measured = FramePacer.preferredRange(
                forStreamIntervalSeconds: pacer.contentFrameIntervalSeconds,
                panelMaxHz: maximum, variableMinimumHz: rate / 2)
            #expect(hint.needsUpdate(to: measured, current: range, now: time) == false)
        }
        #expect(abs(1 / pacer.contentFrameIntervalSeconds - rate) < 0.0001)
    }

    @Test(arguments: fixedRates)
    func fixedModesKeepEvenRepeatSpacing(rate: Double) throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: Int32(rate.rounded()))
        let fps = rate * 0.8
        pacer.contentFrameIntervalSeconds = 1 / fps
        let sample = try emptySampleBuffer()
        var releaseTicks: [Int] = []
        pacer.lock.lock()
        for tick in 0..<3600 {
            while pacer.queue.count < 2 {
                pacer.queue.append(FramePacer.Entry(sampleBuffer: sample, hostPTSSeconds: 0))
            }
            let result = pacer.dequeueDueFrameLocked(
                targetTimestamp: Double(tick) / rate, vsyncInterval: 1 / rate, effectiveTarget: 1)
            if result.toPresent != nil { releaseTicks.append(tick) }
        }
        pacer.lock.unlock()
        let holds = zip(releaseTicks, releaseTicks.dropFirst()).map { $1 - $0 }
        #expect(abs(Double(releaseTicks.count) - 2880) <= 1)
        #expect(holds.allSatisfy { $0 == 1 || $0 == 2 })
        let repeats = releaseTicks.indices.dropFirst().filter { holds[$0 - 1] == 2 }
        #expect(zip(repeats, repeats.dropFirst()).allSatisfy { $1 - $0 == 4 })
        #expect(!pacer.variableRefreshEnabled)
    }

    @MainActor @Test(arguments: variableRates)
    func suppressionReleasesAndRestoresOnlyAfterFreshDwell(minimum: Double, maximum: Double) throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: Int32(maximum))
        let link = NSView().displayLink(
            target: DisplayLinkProxy { _ in }, selector: #selector(DisplayLinkProxy.tick(_:)))
        defer { link.invalidate() }
        pacer.displayLink = link
        pacer.running = true
        let fps = maximum * 0.9
        pacer.contentFrameIntervalSeconds = 1 / fps
        pacer.rateHint = FramePacer.RateHint(appliedAt: 0, preferredHz: fps)
        pacer.configurePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum)
        pacer.setPresentSuppressed(true)
        expectDefault(link.preferredFrameRateRange)
        #expect(pacer.tickDeficit.pinnedFloorHz == 0)
        #expect(!pacer.variableRefreshEnabled)
        pacer.configurePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum)
        expectDefault(link.preferredFrameRateRange)
        pacer.setPresentSuppressed(false)
        pacer.updatePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum, now: 10)
        expectDefault(link.preferredFrameRateRange)
        for index in 0...Int(ceil(fps * 2.2)) {
            let now = 11 + Double(index) / fps
            pacer.rateHintSamples.observe(pts: now, now: now, interval: 1 / fps)
            pacer.updatePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum, now: now)
            if now < 13 { expectDefault(link.preferredFrameRateRange) }
        }
        #expect(link.preferredFrameRateRange.preferred == Float(fps))
        #expect(link.preferredFrameRateRange.minimum == Float(max(minimum, maximum * 0.75)))
        #expect(pacer.variableRefreshEnabled)
    }

    @MainActor @Test func movesReevaluateLimitsAndFixedVariableTransitions() {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 240)
        let link = NSView().displayLink(
            target: DisplayLinkProxy { _ in }, selector: #selector(DisplayLinkProxy.tick(_:)))
        defer { link.invalidate() }
        pacer.rateHint = FramePacer.RateHint(appliedAt: 0, preferredHz: 190)
        let destinations: [(Double, Double?, Double)] = [
            (240, 48, 190), (120, 24, 120), (60, nil, 60), (144, nil, 144),
            (240, 48, 180), (119.88, nil, 119.88), (120, 40, 119.88)
        ]
        var previousSignature = ""
        for (maximum, minimum, preferred) in destinations {
            pacer.configurePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum)
            #expect(link.preferredFrameRateRange.maximum == Float(maximum))
            #expect(link.preferredFrameRateRange.preferred == Float(preferred))
            #expect(pacer.variableRefreshEnabled == (minimum != nil))
            let signature = FramePacer.screenSignature(
                displayID: "same", maximumHz: maximum, minimumHz: minimum, scale: 2)
            #expect(signature != previousSignature)
            previousSignature = signature
        }
        let fixed = FramePacer.screenSignature(displayID: "same", maximumHz: 120, minimumHz: nil, scale: 2)
        #expect(fixed != previousSignature)
        #expect(fixed != FramePacer.screenSignature(displayID: "other", maximumHz: 120, minimumHz: nil, scale: 2))
        #expect(fixed == FramePacer.screenSignature(displayID: "same", maximumHz: 120, minimumHz: nil, scale: 2))
    }

    @MainActor @Test func movesDuringResumeCannotRestoreBeforeTheDwell() {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        let link = NSView().displayLink(
            target: DisplayLinkProxy { _ in }, selector: #selector(DisplayLinkProxy.tick(_:)))
        defer { link.invalidate() }
        pacer.displayLink = link
        pacer.running = true
        pacer.contentFrameIntervalSeconds = 1 / 120
        pacer.configurePreferredRange(link: link, panelMax: 120, panelMinimum: 24)
        pacer.setPresentSuppressed(true)
        pacer.configurePreferredRange(link: link, panelMax: 240, panelMinimum: 48)
        expectDefault(link.preferredFrameRateRange)
        pacer.setPresentSuppressed(false)
        for tick in 0...240 {
            let now = 10 + Double(tick) / 120
            pacer.rateHintSamples.observe(pts: now, now: now, interval: 1 / 120)
            if tick == 120 {
                pacer.configurePreferredRange(link: link, panelMax: 60, panelMinimum: nil)
                expectDefault(link.preferredFrameRateRange)
            }
            let maximum = tick < 120 ? 240.0 : 60.0
            let minimum: Double? = tick < 120 ? 48 : nil
            pacer.updatePreferredRange(link: link, panelMax: maximum, panelMinimum: minimum, now: now)
            expectDefault(link.preferredFrameRateRange)
        }
        for tick in 241...361 {
            let now = 10 + Double(tick) / 120
            pacer.rateHintSamples.observe(pts: now, now: now, interval: 1 / 120)
            pacer.updatePreferredRange(link: link, panelMax: 60, panelMinimum: nil, now: now)
        }
        #expect(link.preferredFrameRateRange.preferred == 60)
        #expect(!pacer.variableRefreshEnabled)
        pacer.setPresentSuppressed(true)
        expectDefault(link.preferredFrameRateRange)
    }

    @Test func unavailableCapabilitiesUseTheSystemDefault() {
        #expect(FramePacer.panelMaxHz(minimumInterval: .nan, maximumFramesPerSecond: 75) == 75)
        #expect(FramePacer.panelMaxHz(minimumInterval: 0, maximumFramesPerSecond: 0) == 0)
        expectDefault(FramePacer.preferredRange(forStreamIntervalSeconds: 1 / 120, panelMaxHz: 0))
        expectDefault(FramePacer.preferredRange(forStreamIntervalSeconds: .nan, panelMaxHz: .nan))
    }

    private func expectDefault(_ range: CAFrameRateRange) {
        #expect(range.minimum == CAFrameRateRange.default.minimum)
        #expect(range.maximum == CAFrameRateRange.default.maximum)
        #expect(range.preferred == CAFrameRateRange.default.preferred)
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
