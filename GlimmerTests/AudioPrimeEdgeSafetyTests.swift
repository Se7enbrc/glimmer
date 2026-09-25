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

@Suite(.serialized)
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

    /// A running engine cannot repair an unattached player's play() failure by
    /// restarting. Space play attempts and preserve the engine restart ladder.
    @Test func playFailuresAreSpacedWithoutConsumingEngineRestartRetries() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = AVAudioPlayerNode()
        decoder.engine.attach(source)
        decoder.engine.connect(source, to: decoder.engine.mainMixerNode, format: format)
        try decoder.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        decoder.stateLock.lock()
        defer { decoder.stateLock.unlock() }
        try #require(decoder.startEngineSafely() == nil)
        #expect(!decoder.startPlayoutAtPrimeEdge())
        let firstRetry = decoder.primeEdgeRetryAtNanos
        #expect(firstRetry != 0)
        #expect(decoder.engine.isRunning)
        #expect(decoder.primeEdgeFailureStreak)
        #expect(decoder.engineRestartRetries == 0)
        #expect(!decoder.startPlayoutAtPrimeEdge())
        #expect(decoder.primeEdgeRetryAtNanos == firstRetry)
        #expect(decoder.engineRestartRetries == 0)
        decoder.primeEdgeRetryAtNanos = 0
        #expect(!decoder.startPlayoutAtPrimeEdge())
        let secondRetry = decoder.primeEdgeRetryAtNanos
        #expect(secondRetry >= firstRetry)
        #expect(decoder.engineRestartRetries == 0)
        // Repair the player so a premature play() would succeed, proving the
        // spacing gate skips the call itself, not just its error breadcrumb.
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.connect(decoder.playerNode, to: decoder.engine.mainMixerNode, format: format)
        #expect(!decoder.startPlayoutAtPrimeEdge())
        #expect(!decoder.playerNode.isPlaying)
        #expect(decoder.primeEdgeRetryAtNanos == secondRetry)
        decoder.primeEdgeRetryAtNanos = 0
        #expect(decoder.startPlayoutAtPrimeEdge())
        #expect(!decoder.primeEdgeFailureStreak)
        #expect(decoder.primeEdgeRetryAtNanos == 0)
        decoder.playerNode.pause()
        #expect(decoder.startPlayoutAtPrimeEdge())
    }

    /// Repeated packets must not burn through the restart ladder while the
    /// output is unavailable. The empty graph deterministically rejects start.
    @Test func consecutivePrimeEdgesShareOneRestartAttempt() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.stateLock.lock()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.framesScheduled = 48_000
        decoder.playoutTargetMs = 40
        decoder.audioMeterLock.unlock()
        let errorsBefore = LogStore.shared.snapshot().filter {
            $0.category == "Stream.Audio" && $0.message.contains("at prime edge FAILED")
        }.count
        #expect(!decoder.startPlayoutAtPrimeEdge())
        let firstRetry = decoder.primeEdgeRetryAtNanos
        let retriesAfterFirst = decoder.engineRestartRetries
        #expect(!decoder.startPlayoutAtPrimeEdge())
        let errorsAfter = LogStore.shared.snapshot().filter {
            $0.category == "Stream.Audio" && $0.message.contains("at prime edge FAILED")
        }.count
        #expect(errorsAfter - errorsBefore == 1)
        #expect(decoder.engineRestartRetries == 1)
        #expect(decoder.engineRestartRetries == retriesAfterFirst)
        #expect(decoder.primeEdgeRetryAtNanos == firstRetry)
        #expect(firstRetry != 0)
        #expect(decoder.primeEdgeFailureStreak)
        // A later packet retries the engine without restarting the ladder.
        decoder.primeEdgeRetryAtNanos = 0
        decoder.maybePrime(format: format)
        #expect(decoder.primeEdgeRetryAtNanos >= firstRetry)
        #expect(decoder.engineRestartRetries == 1)
        decoder.audioMeterLock.lock()
        #expect(!decoder.primed)
        decoder.audioMeterLock.unlock()
        decoder.stateLock.unlock()
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
