// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
@testable import GlimmerEngine
import Testing

/// A perfect actuator on the replay clock: every submitted request applies at once.
struct ActuatedReplay {
    var replay = BandwidthReplay()
    var changes: [(at: Double, kbps: Int)] = []

    mutating func run(_ seconds: Int, bad: Bool) {
        for _ in 0..<seconds {
            _ = replay.tick { if bad { $0.lostPackets = 20; $0.gapMs = 80 } }
            guard let request = replay.policy.submission(at: replay.now) else { continue }
            replay.policy.recordOutcome(.accepted, for: request)
            if replay.policy.confirmApplied(request) { changes.append((replay.now, request.rateKbps)) }
        }
    }
}

struct BandwidthFlapGuardTests {
    @Test func alternatingConditionsKeepABoundedChangeRateAndNeverGiveUp() {
        var actuated = ActuatedReplay()
        actuated.run(130, bad: false)
        for _ in 0..<12 {
            actuated.run(400, bad: false)
            actuated.run(5, bad: true)
        }
        let changes = actuated.changes
        #expect(changes.count >= 4)
        for (previous, next) in zip(changes, changes.dropFirst()) {
            let dwell = next.kbps > previous.kbps ? BandwidthFlapGuard.stepUpDwellSeconds : BandwidthFlapGuard.minDwellSeconds
            #expect(next.at - previous.at >= dwell)
        }
        // At most one up/down pair per base backoff: bounded however the link alternates.
        #expect(Double(changes.count) <= 2 * (actuated.replay.now / BandwidthFlapGuard.baseBackoffSeconds) + 2)
        #expect(actuated.replay.policy.flap.failedStepUps > 0)
        #expect(actuated.replay.policy.retrySeconds > BandwidthFlapGuard.baseBackoffSeconds)
        #expect(actuated.replay.policy.retrySeconds <= BandwidthFlapGuard.maxBackoffSeconds)
        let lowered = actuated.replay.policy.appliedKbps
        actuated.run(Int(BandwidthFlapGuard.maxBackoffSeconds) + 400, bad: false)
        #expect(actuated.replay.policy.appliedKbps > lowered)
        #expect(actuated.replay.policy.retrySeconds == BandwidthFlapGuard.baseBackoffSeconds)
    }

    @Test func secondByFlappingWindowsCannotChangeTheRateEverySecond() {
        var actuated = ActuatedReplay()
        for second in 0..<600 { actuated.run(1, bad: second.isMultiple(of: 2)) }
        #expect(actuated.changes.count <= 600 / Int(BandwidthFlapGuard.minDwellSeconds))
        for (previous, next) in zip(actuated.changes, actuated.changes.dropFirst()) {
            #expect(next.at - previous.at >= BandwidthFlapGuard.minDwellSeconds)
        }
    }

    @Test func failedStepUpDoublesBackoffAndLedgerRecordsIt() throws {
        var replay = BandwidthReplay()
        replay.distress()
        try replay.apply()
        replay.run(300)
        try replay.apply()
        replay.run(10) { $0.lostPackets = 20; $0.gapMs = 80 }
        #expect(replay.policy.pending?.reason == .rollback)
        try replay.apply()
        let decision = replay.tick()
        #expect(decision.flap.failedStepUps == 1)
        #expect(decision.flap.backoffSeconds == 600)
        let json = try JSONEncoder().encode(decision)
        #expect(try JSONDecoder().decode(BandwidthDecision.self, from: json).flap == decision.flap)
    }

    @Test func deferredSubmissionRetriesOnlyAfterTheMinimumDwell() throws {
        var replay = BandwidthReplay()
        replay.distress()
        let request = try #require(replay.policy.submission(at: replay.now))
        replay.policy.recordOutcome(.deferred, for: request)
        replay.run(Int(BandwidthFlapGuard.minDwellSeconds) - 1) { $0.lostPackets = 20; $0.gapMs = 80 }
        #expect(replay.policy.submission(at: replay.now) == nil)
        _ = replay.tick { $0.lostPackets = 20; $0.gapMs = 80 }
        #expect(replay.policy.submission(at: replay.now) == request)
        replay.policy.recordOutcome(.accepted, for: request)
        #expect(replay.policy.submission(at: replay.now) == nil)
        #expect(replay.policy.appliedKbps == 40_000)
    }

    @Test func externalRateChangeIsAdoptedAndCountsForDwell() throws {
        var replay = BandwidthReplay()
        replay.distress()
        #expect(replay.policy.pending != nil)
        replay.policy.adoptApplied(30_000)
        #expect(replay.policy.pending == nil && replay.policy.appliedKbps == 30_000)
        replay.distress()
        #expect(replay.policy.pending == nil)
        replay.run(Int(BandwidthFlapGuard.minDwellSeconds)) { $0.lostPackets = 20; $0.gapMs = 80 }
        #expect(replay.policy.pending?.rateKbps == 18_000)
    }

    @Test func savedChoiceOverridesTheBetaDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "BandwidthFlapGuardTests.switch"))
        defaults.removePersistentDomain(forName: "BandwidthFlapGuardTests.switch")
        defaults.set(true, forKey: AdaptiveBandwidth.defaultsKey)
        #expect(AdaptiveBandwidth.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AdaptiveBandwidth.defaultsKey)
        #expect(AdaptiveBandwidth.isEnabled(defaults: defaults) == false)
        defaults.removePersistentDomain(forName: "BandwidthFlapGuardTests.switch")
    }
}

struct BandwidthHeadroomTests {
    @Test func lowDataModeEndingReseedsUpToTheNewPathsStart() throws {
        var replay = BandwidthReplay(constrained: true)
        replay.run(5)
        var path = replay.policy.path
        path.generation += 1
        path.constrained = false
        replay.policy.replacePath(path)
        _ = replay.tick()
        #expect(replay.policy.pending?.rateKbps == 40_000 && replay.policy.pending?.reason == .pathChanged)
    }

    @Test func jitterAboveOneMillisecondNeverEarnsHeadroomButStillRecovers() throws {
        var jittery = BandwidthReplay()
        for _ in 0..<8 {
            jittery.run(120) { $0.jitterP95Ms = 2 }
            if jittery.policy.pending != nil { try jittery.apply() }
        }
        #expect(jittery.policy.appliedKbps == 40_000)
        var missing = BandwidthReplay()
        missing.run(240) { $0.jitterP95Ms = nil }
        #expect(missing.policy.appliedKbps == 40_000)
        missing.distress()
        try missing.apply()
        missing.run(300) { $0.jitterP95Ms = nil }
        #expect(missing.policy.pending?.reason == .recovery)
    }

    #if os(macOS)
    @Test func receivePathFeedsQueueDelayAndJitterWithoutTheExporterDrainingThem() {
        let telemetry = ReceiveTimingTelemetry()
        for delay in [0.2, 0.4, 0.4, 3.0] { telemetry.observe(delayMs: delay, gapMs: nil) }
        for jitter in Array(repeating: 0.3, count: 19) + [6] { telemetry.observeFrameJitter(jitter) }
        _ = telemetry.takeSnapshot()
        let window = telemetry.takePolicyWindow()
        #expect(window.queueDelayP50Ms == 0.5 && window.jitterP95Ms == 0.5)
        #expect(telemetry.takePolicyWindow() == ReceiveTimingTelemetry.PolicyWindow())
    }
    #endif
}

struct BandwidthHealthSamplerTests {
    typealias Counters = BandwidthHealthSampler.Counters

    static func counters(packets: UInt64, lost: UInt64 = 0, frames: UInt64, bytes: UInt64,
                         gaps50: UInt64 = 0, overflows: UInt64 = 0) -> Counters {
        Counters(packets: packets, lost: lost, frames: frames, recovered: 0, unrecoverable: 0,
                 gaps50: gaps50, gaps100: 0, overflows: overflows, bytes: bytes)
    }

    @Test func foldsAreCarriedBetweenTicksAndGoStaleWhenQuiet() {
        var sampler = BandwidthHealthSampler()
        let first = sampler.window(start: 0, end: 1, generation: 1,
                                   counters: Self.counters(packets: 0, frames: 0, bytes: 0), rttSamplesMs: [])
        #expect(first.missingReason == .producerUnavailable)
        let folded = sampler.window(start: 1, end: 2, generation: 1,
            counters: Self.counters(packets: 990, lost: 10, frames: 120, bytes: 5_000_000, gaps50: 1),
            rttSamplesMs: [2, 3], receive: .init(queueDelayP50Ms: 0.25, jitterP95Ms: 0.75))
        #expect(folded.localQueueMs == 0.25 && folded.jitterP95Ms == 0.75)
        #expect(folded.expectedPackets == 1_000 && folded.lostPackets == 10 && folded.totalFrames == 120)
        #expect(folded.gapMs == 51 && folded.decoderBacklog == false && folded.encodedKbps == 40_000)
        #expect(folded.rttSamplesMs == [2, 3] && folded.valid)
        let carried = sampler.window(start: 2, end: 3, generation: 1,
            counters: Self.counters(packets: 990, lost: 10, frames: 120, bytes: 5_000_000, gaps50: 1),
            rttSamplesMs: [])
        #expect(carried.expectedPackets == 1_000 && carried.gapMs == 0 && carried.missingReason == nil)
        let quiet = sampler.window(start: 3, end: 5, generation: 1,
            counters: Self.counters(packets: 990, lost: 10, frames: 120, bytes: 5_000_000, gaps50: 1),
            rttSamplesMs: [])
        #expect(quiet.missingReason == .producerUnavailable)
        let reset = sampler.window(start: 5, end: 6, generation: 1,
            counters: Self.counters(packets: 1, frames: 1, bytes: 1), rttSamplesMs: [])
        #expect(reset.counterReset && !reset.valid)
    }
}
