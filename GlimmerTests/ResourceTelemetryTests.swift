//
//  ResourceTelemetryTests.swift
//
//  The resource lines have to be comparable across sessions: package power
//  never reads a flat counter window as 0 W, and the main thread's CPU gets
//  its own line instead of hiding in the "unnamed" worker aggregate.
//

import Foundation
import Testing
@testable import Glimmer

struct ResourceTelemetryTests {

    /// Back-to-back samples often see no rail advance (about 1 in 5 did before
    /// the fix). Such a window must read as no sample, not a 0 W row.
    @Test(.enabled(if: IOReportSampler.shared != nil, "IOReport unavailable on this Mac"))
    func flatEnergyWindowIsNotZeroWatts() throws {
        let sampler = try #require(IOReportSampler.shared)
        sampler.beginSession()
        defer { sampler.beginSession() }
        _ = sampler.sample()
        for _ in 0..<40 {
            #expect(sampler.sample()?.packagePowerW != 0)
        }
    }

    /// A busy main thread shows up as "main".
    @MainActor @Test func mainThreadGetsItsOwnLine() {
        let busyUntil = Date().addingTimeInterval(0.3)
        while Date() < busyUntil {}
        let names = ResourceTelemetry.sample().threads.map(\.name)
        #expect(names.contains("main"))
    }
}
