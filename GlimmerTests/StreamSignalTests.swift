//
//  StreamSignalTests.swift
//
//  The in-stream signals: the codes a video-less bring-up ends with, and the
//  stats HUD's non-color emphasis.
//

import AppKit
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StreamSignalTests {

    // MARK: Watchdog end codes

    /// moonlight-common-c's codes: -100 when no video ever arrived, -101 when
    /// it arrived but never decoded. A stall after video flowed stays -1.
    @Test func aStreamThatNeverShowedVideoSaysWhy() {
        let code = StreamSession.watchdogTerminationCode
        #expect(code(true, .infinity) == -100)
        #expect(code(true, 2.5) == -101)
        #expect(code(false, 2.5) == -1)
        #expect(code(false, .infinity) == -1)
    }
}
