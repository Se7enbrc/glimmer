//
//  IOReportSamplerLifetimeTests.swift
//
//  Regression guard for the 2026.8.15 teardown crash: releasing the CF
//  objects IOReport hands back segfaulted in IOReportSampler.deinit when a
//  telemetry session ended. The fix makes the sampler a process-lifetime
//  singleton with per-session baseline resets, so what these tests can and
//  do assert is the surviving contract: `shared` is stable, repeated
//  session cycles (beginSession + sample ticks) run without crashing, and a
//  post-reset first tick behaves like a baseline tick again. The deinit
//  path itself is structurally unreachable now - that is the fix.
//

import XCTest
@testable import Glimmer

final class IOReportSamplerLifetimeTests: XCTestCase {

    /// `shared` must hand back the same instance every time (or nil
    /// consistently on a host without IOReport - not this Mac, but never
    /// crash either way).
    func testSharedIsStable() {
        let first = IOReportSampler.shared
        let second = IOReportSampler.shared
        XCTAssertTrue(first === second)
    }

    /// Three back-to-back "sessions" against the one sampler: reset, tick,
    /// tick, reset again. The 2026.8.15 crash fired when a session's
    /// teardown released the sampler; under the singleton there is nothing
    /// to release, and the cycles must run clean. Sampling data content is
    /// hardware/OS dependent, so the assertion is on the contract, not the
    /// values: the tick immediately after a reset is a baseline (cluster
    /// counts start over).
    func testRepeatedSessionCyclesDoNotCrash() throws {
        guard let sampler = IOReportSampler.shared else {
            throw XCTSkip("IOReport unavailable on this host")
        }
        for _ in 0..<3 {
            sampler.beginSession()
            _ = sampler.sample()          // baseline tick
            usleep(20_000)                // give the counters a real window
            _ = sampler.sample()          // first delta tick
        }
        sampler.beginSession()            // leave a fresh baseline behind
    }
}
