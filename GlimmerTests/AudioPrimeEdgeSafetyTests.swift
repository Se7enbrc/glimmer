// A stopped engine or detached player can raise Objective-C exceptions on the prime edge.
// Failed playback stays unprimed; retries preserve the engine restart ladder.

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
        let now: UInt64 = 1_000_000_000
        #expect(!decoder.startPlayoutAtPrimeEdge(now: now))
        let firstRetry = decoder.primeEdgeRetryAtNanos
        try #require(firstRetry > now)
        #expect(decoder.engine.isRunning)
        #expect(decoder.primeEdgeFailureStreak)
        #expect(decoder.engineRestartRetries == 0)
        #expect(!decoder.startPlayoutAtPrimeEdge(now: firstRetry - 1))
        #expect(decoder.engineRestartRetries == 0)
        #expect(!decoder.startPlayoutAtPrimeEdge(now: firstRetry))
        let secondRetry = decoder.primeEdgeRetryAtNanos
        try #require(secondRetry > firstRetry)
        #expect(decoder.engineRestartRetries == 0)
        // Repair the player so a premature play() would succeed, proving the
        // spacing gate skips the call itself, not just its error breadcrumb.
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.connect(decoder.playerNode, to: decoder.engine.mainMixerNode, format: format)
        #expect(!decoder.startPlayoutAtPrimeEdge(now: secondRetry - 1))
        #expect(!decoder.playerNode.isPlaying)
        #expect(decoder.startPlayoutAtPrimeEdge(now: secondRetry))
        #expect(decoder.playerNode.isPlaying)
        #expect(!decoder.primeEdgeFailureStreak)
        #expect(decoder.primeEdgeRetryAtNanos == 0)
        decoder.playerNode.pause()
        #expect(decoder.startPlayoutAtPrimeEdge(now: secondRetry + 1))
        #expect(decoder.playerNode.isPlaying)
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
        let now: UInt64 = 1_000_000_000
        #expect(!decoder.startPlayoutAtPrimeEdge(now: now))
        let firstRetry = decoder.primeEdgeRetryAtNanos
        try #require(firstRetry > now)
        let retriesAfterFirst = decoder.engineRestartRetries
        #expect(!decoder.startPlayoutAtPrimeEdge(now: firstRetry - 1))
        #expect(decoder.engineRestartRetries == 1)
        #expect(decoder.engineRestartRetries == retriesAfterFirst)
        #expect(decoder.primeEdgeFailureStreak)
        // A later packet retries the engine without restarting the ladder.
        decoder.primeEdgeRetryAtNanos = 0
        decoder.maybePrime(format: format)
        #expect(decoder.engineRestartRetries == 1)
        decoder.audioMeterLock.lock()
        #expect(!decoder.primed)
        decoder.audioMeterLock.unlock()
        decoder.stateLock.unlock()
    }

    /// A full cushion must not latch primed when the stopped engine or detached player rejects startup.
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
