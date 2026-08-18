//
//  AudioPrimeEdgeSafetyTests.swift
//
//  The 2026-08-17 post-wake crash: system sleep stopped the audio engine
//  mid-stream, and 9 seconds after wake the resume edge's re-prime called
//  `playerNode.play()` - which raises an NSException Swift cannot catch, so
//  the process aborted on the audio receive thread. The fix is layered:
//  `gl_objc_try` (an ObjC @try shim - the belt) and `startPlayoutAtPrimeEdge`
//  (engine-ensure + prime-latch-only-on-success - the suspenders). Both are
//  testable WITHOUT audio hardware: a fresh AudioDecoder's player node is
//  un-attached and its engine un-started, which is exactly the crash's
//  precondition - under the old code, `maybePrime` at a full cushion would
//  abort the test process itself.
//

import AVFAudio
import Foundation
import Testing
@testable import Glimmer

struct AudioPrimeEdgeSafetyTests {

    /// The belt, in isolation: an ObjC exception raised inside the block must
    /// come back as `false`, not a process abort.
    @Test func objcTryCatchesRaisedException() {
        let survived = gl_objc_try {
            NSException(name: .genericException, reason: "test", userInfo: nil).raise()
        }
        #expect(!survived)
    }

    /// And a clean block reports success.
    @Test func objcTryPassesCleanBlock() {
        var ran = false
        let survived = gl_objc_try { ran = true }
        #expect(survived)
        #expect(ran)
    }

    /// THE crash shape, end to end: a decoder whose engine never started and
    /// whose node is un-attached (the post-sleep state) reaches the
    /// target-reached prime edge. Under the old code this call aborted the
    /// process; now it must return with the machine still UN-primed so the
    /// next packet retries. (`engine.start()` on the empty graph fails or the
    /// un-attached `play()` raises - either path must degrade, never crash.)
    @Test func primeEdgeWithDeadEngineStaysUnprimedWithoutCrashing() {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.framesScheduled = 48_000   // fill far above any target
        decoder.framesPlayed = 0
        decoder.playoutTargetMs = 40
        decoder.primed = false
        decoder.audioMeterLock.unlock()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            Issue.record("AVAudioFormat construction failed")
            return
        }
        decoder.maybePrime(format: fmt)
        #expect(!decoder.primed)
    }
}
