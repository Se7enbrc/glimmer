// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing

actor FakeBandwidthActuator: BandwidthActuator {
    private(set) var requests: [(Int, BandwidthReason)] = []
    private var entered: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<BandwidthActuatorOutcome, Never>?
    private let immediate: BandwidthActuatorOutcome?

    init(immediate: BandwidthActuatorOutcome? = nil) { self.immediate = immediate }

    func request(rate: Int, reason: BandwidthReason) async -> BandwidthActuatorOutcome {
        requests.append((rate, reason))
        if let immediate { return immediate }
        return await withCheckedContinuation { continuation in
            completion = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish(_ outcome: BandwidthActuatorOutcome) {
        completion?.resume(returning: outcome)
        completion = nil
    }
}

struct BandwidthActuatorTests {
    @Test func failedQueuedTransitionCanRetry() async throws {
        var replay = BandwidthReplay()
        replay.distress()
        let request = try #require(replay.policy.pending)
        let actuator = FakeBandwidthActuator(immediate: .accepted)
        let driver = BandwidthPolicyDriver(policy: replay.policy, actuator: actuator)
        _ = await driver.evaluate(try #require(replay.tick().window))
        await driver.recordOutcome(.rejected, for: request)
        #expect(await driver.confirmApplied(request) == false)
        for _ in 0..<90 { _ = await driver.evaluate(try #require(replay.tick().window)) }
        #expect(await actuator.requests.count == 2)
        #expect(await driver.policy.appliedKbps == 40_000)
    }

    @Test(arguments: [false, true])
    func stopOrPathReplacementDuringAwaitCannotApply(retirePath: Bool) async throws {
        var replay = BandwidthReplay()
        replay.distress()
        let old = try #require(replay.policy.pending)
        let actuator = FakeBandwidthActuator()
        let driver = BandwidthPolicyDriver(policy: replay.policy, actuator: actuator)
        let health = try #require(replay.tick().window)
        async let result = driver.evaluate(health)
        await actuator.waitForRequest()
        if retirePath {
            var path = replay.policy.path
            path.generation += 1
            path.interface = .cellular
            await driver.replacePath(path)
        } else { await driver.stop() }
        await actuator.finish(.accepted)
        _ = await result
        #expect(await driver.confirmApplied(old) == false)
        #expect(await driver.policy.appliedKbps == 40_000)
    }

    @Test func concurrentEvaluationsCoalesceAndAcceptanceIsNotApplication() async throws {
        var replay = BandwidthReplay()
        replay.distress()
        let request = try #require(replay.policy.pending)
        let actuator = FakeBandwidthActuator()
        let driver = BandwidthPolicyDriver(policy: replay.policy, actuator: actuator)
        let firstWindow = try #require(replay.tick().window)
        async let first = driver.evaluate(firstWindow)
        await actuator.waitForRequest()
        _ = await driver.evaluate(try #require(replay.tick().window))
        #expect(await actuator.requests.count == 1)
        await actuator.finish(.accepted)
        _ = await first
        #expect(await driver.policy.appliedKbps == 40_000)
        #expect(await driver.confirmApplied(request))
        #expect(await driver.policy.appliedKbps == 24_000)
        #expect(await driver.confirmApplied(request) == false)
    }

    @Test(arguments: [BandwidthActuatorOutcome.deferred, .rejected])
    func unsuccessfulRequestsRetryWithoutStorms(outcome: BandwidthActuatorOutcome) async throws {
        var replay = BandwidthReplay()
        replay.distress()
        let actuator = FakeBandwidthActuator(immediate: outcome)
        let driver = BandwidthPolicyDriver(policy: replay.policy, actuator: actuator)
        for _ in 0..<91 { _ = await driver.evaluate(try #require(replay.tick().window)) }
        #expect(await actuator.requests.count == 2)
        #expect(await driver.policy.appliedKbps == 40_000)
    }
}
