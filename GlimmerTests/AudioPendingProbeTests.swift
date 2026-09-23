//
//  AudioPendingProbeTests.swift
//
//  The silent-audio probe keeps reporting for as long as no audio arrives,
//  instead of warning once at 3s and going quiet for the rest of the stream.
//

import Testing
@testable import Glimmer

struct AudioPendingProbeTests {

    /// 3s warning, a 30s notice (past a normal ~21s cold start), then every
    /// 10 min - a 5.6h silent stream logs ~35 lines, not one.
    @Test func silentStreamKeepsReportingOnASlowingCadence() {
        var elapsed = 0.0
        var schedule: [Double] = []
        for _ in 0..<5 {
            elapsed = RtpAudioReceiver.nextAudioPendingProbeSeconds(after: elapsed)
            schedule.append(elapsed)
        }
        #expect(schedule == [3, 30, 630, 1230, 1830])
    }
}
