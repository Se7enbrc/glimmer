//
//  HostRouteMonitorTests.swift
//
//  A route socket that keeps failing backs off to a minute between retries
//  instead of spinning, and never stops retrying.
//

import Testing
@testable import Glimmer

struct HostRouteMonitorTests {

    @Test func retryDelayDoublesUntilTheCap() {
        #expect((0...7).map { HostRouteMonitor.retryDelay(afterFailures: $0) }
                == [1, 2, 4, 8, 16, 32, 64, 64])
        #expect(HostRouteMonitor.retryDelay(afterFailures: 10_000) == 64)
    }
}
