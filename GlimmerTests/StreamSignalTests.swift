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

    // MARK: Stats HUD

    /// With Differentiate Without Color on, warning and critical values are
    /// heavier than healthy ones; off, weight carries nothing.
    @Test func warningValuesAreHeavierWithoutColor() {
        func weight(_ health: StatsRow.Health, _ differentiate: Bool) -> Int {
            NSFontManager.shared.weight(
                of: StatsOverlayLayer.valueFont(for: health, differentiateWithoutColor: differentiate))
        }
        let regular = weight(.healthy, true)
        #expect(weight(.warning, true) > regular)
        #expect(weight(.critical, true) > regular)
        #expect(weight(.neutral, true) == regular)
        #expect(weight(.critical, false) == regular)
        #expect(StatsOverlayLayer.valueFont(for: .critical, differentiateWithoutColor: true).isFixedPitch)
    }
}
