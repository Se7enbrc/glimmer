//
//  AudioCushionDeadAirTests.swift
//
//  An under-run after an arrival gap no cushion could bridge (dead air) must
//  not deepen the cushion or teach its floor, one drain episode grows it at most
//  once per window, and a quiet window walks a learned floor back down.
//

import Foundation
import Testing
@testable import Glimmer

// Same serialized suite as the stall tests: these drains bump the shared
// under-run counter that suite's evidence-gate pair brackets.
extension AudioPlayoutStallTests {

    /// A primed, playing meter one 5ms buffer from empty on a Wi-Fi-sized cap,
    /// whose newest packet ended an arrival gap of `arrivalGapMs`.
    private func drainingDecoder(targetMs: Double, arrivalGapMs: Double) -> AudioDecoder {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.playoutDrained = false
        decoder.framesScheduled = 240
        decoder.framesPlayed = 0
        decoder.playoutTargetMs = targetMs
        decoder.effectiveCushionMaxMs = 200
        decoder.cushionLinkResolved = true
        decoder.audioMeterLock.unlock()
        decoder.noteArrivalGap(nanos: UInt64(arrivalGapMs * 1_000_000))
        return decoder
    }

    /// The 6s-blackout shape: a 625ms gap outlasts the 200ms cap, so the drain
    /// is counted (and flagged dead air) but the cushion and floor stay put.
    @Test func deadAirDrainLeavesCushionAndFloorAlone() {
        let decoder = drainingDecoder(targetMs: 170, arrivalGapMs: 625)
        let before = TelemetryCounters.shared.audioUnderrunDeadairTotal.value
        decoder.meterCompleteOnePlayout(frames: 240)
        #expect(decoder.playoutTargetMs == 170)
        #expect(decoder.learnedFloorMs == 0)
        #expect(TelemetryCounters.shared.audioUnderrunDeadairTotal.value == before + 1)
    }

    /// Control: the same drain after a normal 5ms gap is real depth evidence.
    @Test func drainAfterBridgeableGapGrowsAndLearnsTheFloor() {
        let decoder = drainingDecoder(targetMs: 170, arrivalGapMs: 5)
        decoder.meterCompleteOnePlayout(frames: 240)
        #expect(decoder.playoutTargetMs == 180)
        #expect(decoder.learnedFloorMs == 170)
    }

    /// A second drain inside the grow window counts but doesn't grow again.
    @Test func secondDrainInsideTheGrowWindowDoesNotGrow() {
        let decoder = drainingDecoder(targetMs: 100, arrivalGapMs: 5)
        decoder.lastCushionGrowNanos = DispatchTime.now().uptimeNanoseconds
        decoder.meterCompleteOnePlayout(frames: 240)
        #expect(decoder.playoutTargetMs == 100)
    }

    /// A target one step above its learned floor, at the end of a quiet window whose trough
    /// stayed `minFillMs` above empty. Only wired links used to release the floor here; the
    /// rest waited ~10 min a step, holding Wi-Fi targets near 105 ms over 75 ms troughs.
    @Test(arguments: [("wifi", 25.0, true), ("tunnel", 25.0, true), ("unknown", 25.0, true),
                      ("wired", 15.0, true), ("wifi", 15.0, false)])
    func quietWindowReleasesTheFloor(link: String, minFillMs: Double, releases: Bool) {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = link
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 110
        decoder.learnedFloorMs = 105
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = minFillMs
        #expect((decoder.cushionQuietAdjustLocked(now: now) != nil) == releases)
        #expect(decoder.playoutTargetMs == (releases ? 100 : 110))
        #expect(decoder.learnedFloorMs == (releases ? 95 : 105))
    }

    /// For the floor's decay window after an under-run, a quiet window won't walk the target back
    /// below a step above the level that failed; once the window passes, it may.
    @Test func walkDownHoldsAboveARecentFailure() {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = "wifi"
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 54
        decoder.learnedFloorMs = 50
        decoder.lastFailedTargetMs = 44
        decoder.lastUnderrunNanos = now &- 60_000_000_000
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = 25
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 54)

        decoder.lastUnderrunNanos = now &- AudioDecoder.cushionFloorDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) != nil)
        #expect(decoder.playoutTargetMs == 44)
    }

    /// The ordinary walk-down, far above the floor, holds a step above a recent failure too: a grow
    /// that never taught the floor must not walk straight back to the level that under-ran.
    @Test func ordinaryWalkDownHoldsAboveARecentFailure() {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = "wifi"
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 70
        decoder.learnedFloorMs = 45
        decoder.lastFailedTargetMs = 60
        decoder.lastUnderrunNanos = now &- 60_000_000_000
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = 25
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 70)

        decoder.lastUnderrunNanos = now &- AudioDecoder.cushionFloorDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) != nil)
        #expect(decoder.playoutTargetMs == 60)
    }
}
