// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AVFAudio
import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct AudioPrimeEdgeSafetyTests {
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
        decoder.primeEdgeRetryAtNanos = .max
        #expect(!decoder.startPlayoutAtPrimeEdge())
        let errorsAfter = LogStore.shared.snapshot().filter {
            $0.category == "Stream.Audio" && $0.message.contains("at prime edge FAILED")
        }.count
        #expect(errorsAfter - errorsBefore == 1)
        #expect(decoder.engineRestartRetries == 1)
        #expect(decoder.engineRestartRetries == retriesAfterFirst)
        #expect(decoder.primeEdgeRetryAtNanos == .max)
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
