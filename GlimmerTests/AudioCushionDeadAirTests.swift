//
//  AudioCushionDeadAirTests.swift
//
//  An under-run after an arrival gap no cushion could bridge (dead air) must
//  not deepen the cushion or teach its floor, and one drain episode grows the
//  cushion at most once per window.
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
}
