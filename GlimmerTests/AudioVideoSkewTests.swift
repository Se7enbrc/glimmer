//
//  AudioVideoSkewTests.swift
//
//  The A/V skew meter: when it may set its epoch, which ticks it measures, and
//  how its session percentiles read the top of the distribution.
//

import Foundation
import Testing
@testable import Glimmer

struct AudioVideoSkewTests {

    private static let msNanos: UInt64 = 1_000_000
    private let start: UInt64 = 10_000 * AudioVideoSkewTests.msNanos

    private func at(_ ms: UInt64) -> UInt64 { start + ms * Self.msNanos }

    /// Both sides noted at `ms`, their positions advanced in step (90 kHz video,
    /// the 1 tick/ms audio clock), so a measured tick reads exactly the fill.
    private func note(_ store: AudioVideoSkewStore, atMs ms: UInt64) {
        store.noteVideoPresented(rtp: 1_000 + UInt32(ms) * 90, now: at(ms))
        store.noteAudioScheduled(rtp: 500 + UInt32(ms), now: at(ms))
    }

    @Test func theEpochWaitsForFreshNotes() {
        let store = AudioVideoSkewStore(videoRecoveryDrops: { 0 })
        note(store, atMs: 0)
        // 300 ms old on both sides: within the 2 s horizon, too stale to anchor on.
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(300)) == nil)
        note(store, atMs: 1_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(1_010)) == nil)
        note(store, atMs: 2_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(2_010)) == 40)
    }

    @Test func noEpochWhileBackfillSilenceIsBufferedOrVideoIsRecovering() {
        let drops = TelemetryCounters.Counter()
        let store = AudioVideoSkewStore(videoRecoveryDrops: { drops.value })
        store.setResidentSilenceMs(190)
        note(store, atMs: 0)
        #expect(store.deriveSkewMs(bufferFillMs: 230, accumulate: true, now: at(10)) == nil)
        store.setResidentSilenceMs(0)
        drops.increment(by: 31)
        note(store, atMs: 1_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(1_010)) == nil)
        note(store, atMs: 2_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(2_010)) == nil)
        note(store, atMs: 3_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(3_010)) == 40)
        #expect(store.rebaseTotal == 0)
    }

    @Test func aDrainedOrStalledAudioTickAddsNoSampleAndKeepsTheEpoch() throws {
        let store = AudioVideoSkewStore(videoRecoveryDrops: { 0 })
        note(store, atMs: 0)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(10)) == nil)
        note(store, atMs: 1_000)
        #expect(store.deriveSkewMs(bufferFillMs: 0, accumulate: true, now: at(1_010)) == nil)
        // Video keeps presenting while the last audio note is a second old.
        store.noteVideoPresented(rtp: 1_000 + 2_000 * 90, now: at(2_000))
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(2_000)) == nil)
        note(store, atMs: 3_000)
        #expect(store.deriveSkewMs(bufferFillMs: 40, accumulate: true, now: at(3_010)) == 40)
        let summary = try #require(store.sessionSummary())
        #expect(summary.samples == 1)
        #expect(summary.rebases == 0)
    }

    @Test func tailPercentilesStayBelowTheMax() throws {
        // 90 samples near 20 ms and 10 in the top bucket, the largest 559.5 ms.
        let bounds = AudioVideoSkewStore.bucketBoundsMs
        var buckets = [UInt64](repeating: 0, count: bounds.count)
        buckets[try #require(bounds.firstIndex(of: 25))] = 90
        buckets[try #require(bounds.firstIndex(of: 600))] = 10
        func quantile(_ rank: Double) -> Double {
            AudioVideoSkewStore.quantile(rank, buckets: buckets, minMs: 20, maxMs: 559.5)
        }
        #expect(quantile(0.95) < quantile(0.99))
        #expect(quantile(0.99) < 559.5)
        #expect(bounds.last == AudioVideoSkewStore.sanityBoundMs)
    }
}
