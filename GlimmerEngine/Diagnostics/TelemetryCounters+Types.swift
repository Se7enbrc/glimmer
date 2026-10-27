// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryCounters+Types.swift
//
//  The nested VALUE TYPES + constants the always-live counter/gauge storage
//  in TelemetryCounters.swift is declared in terms of: the `Counter` itself
//  (one os_unfair_lock-guarded monotonic UInt64), the input idle-edge
//  threshold, the inter-packet-gap distribution snapshot, and the live audio
//  playout state. Split out of that file (pure move, the same idiom that
//  already put `DecodeState` / `FecHealthSnapshot` next to their accessors)
//  to keep it under the length limit - the stored properties themselves stay
//  on the class, because a Swift extension cannot hold stored properties.
//
//  Every type here is a plain value (or a self-locked counter), so it is safe
//  to read and write from any thread exactly as before.
//

import Foundation
import os

extension TelemetryCounters {

    /// Diagnostic totals have no storage in production; control totals explicitly retain it.
    package final class Counter: Sendable {
        private let storage: OSAllocatedUnfairLock<UInt64>?

        package init(operational: Bool = false) {
            #if os(macOS)
            storage = OSAllocatedUnfairLock(initialState: 0)
            #else
            storage = operational ? OSAllocatedUnfairLock(initialState: 0) : nil
            #endif
        }

        package func increment(by amount: UInt64 = 1) { storage?.withLock { $0 &+= amount } }
        package var value: UInt64 { storage?.withLock { $0 } ?? 0 }
        package func reset() { storage?.withLock { $0 = 0 } }
    }

    /// Gap (seconds) of input silence after which the next event is an idle→active
    /// edge. 2s comfortably exceeds normal inter-event spacing during active play
    /// (sub-100ms) yet is short enough to catch a genuine "stepped away, came
    /// back" resume - the exact motivating bug.
    package static let idleGapSeconds: Double = 2.0

    /// Live inter-packet-gap distribution (microseconds) for the microburst
    /// detector. Written once per ~2s receive-metrics window by the RTP path
    /// (computed there off the per-datagram arrival times it ALREADY reads for
    /// jitter, so the hot path gains only a min/max/running-sum update - no clock
    /// read, no alloc) and read at 1Hz by the exporter. A plain value struct behind
    /// an unfair lock: last-writer-wins is fine for a gauge sampled at 1Hz against
    /// the 2s window writer. p95 is an approximation (a 16-bucket log-spaced
    /// histogram, see the writer) - exact enough to spot a microburst, far cheaper
    /// than a per-packet reservoir on the receive path.
    package struct PacketGapSnapshot: Sendable {

        package init(
            p50Us: Double,
            p95Us: Double,
            maxUs: Double
        ) {
            self.p50Us = p50Us
            self.p95Us = p95Us
            self.maxUs = maxUs
        }

        package var p50Us: Double
        package var p95Us: Double
        package var maxUs: Double
    }

    /// Live AUDIO playout STATE (signal: AUDIO - the other stream). What the audio
    /// output path is doing right now: how much decoded audio is scheduled ahead of
    /// the playhead (the buffer level / fill), and the A/V SYNC DRIFT - how far the
    /// audio presentation clock has slipped from the video present clock over time.
    /// Published off the hot path (the audio decode path stamps it under the lock it
    /// already holds, ~200Hz at 5ms packets) and read at 1Hz by the exporter. A
    /// plain value struct behind an unfair lock: last-writer-wins is correct for a
    /// 1Hz-sampled state gauge, and the lock keeps the multi-field read tear-free.
    /// nil before the first decoded audio packet.
    package struct AudioState: Sendable {

        package init(
            bufferFillMs: Double,
            playoutTargetMs: Double? = nil,
            audioClockDriftMs: Double? = nil,
            bufferFillMinMs: Double? = nil,
            rePrimeTotal: UInt64,
            resamplerPpm: Double = 0,
            engineRunning: Bool? = nil,
            cushionMaxMs: Double? = nil
        ) {
            self.bufferFillMs = bufferFillMs
            self.playoutTargetMs = playoutTargetMs
            self.audioClockDriftMs = audioClockDriftMs
            self.bufferFillMinMs = bufferFillMinMs
            self.rePrimeTotal = rePrimeTotal
            self.resamplerPpm = resamplerPpm
            self.engineRunning = engineRunning
            self.cushionMaxMs = cushionMaxMs
        }

        /// Ring fill in milliseconds: a climb is latency creep, a fall toward zero warns of an underrun.
        package var bufferFillMs: Double
        /// ADAPTIVE PLAYOUT TARGET (ms): the cushion the playout path is
        /// currently steering `bufferFillMs` toward. Fill vs target is the
        /// cushion judge (base 30 / cap 150 / ceiling 190): a fill hugging a
        /// flat ceiling is only legible against this - target re-pinned at the
        /// cap through minutes of calm play = the decay is broken (the old
        /// disguised-permanent-give-up failure mode), target ratcheting up
        /// under gaps then decaying toward base = designed behavior. nil until
        /// the playout path stamps it (AudioDecoder publishes alongside fill).
        package var playoutTargetMs: Double?
        /// AUDIO CLOCK DRIFT (ms): the audio playout clock's slip vs WALL CLOCK,
        /// signed and net of the steady buffer cushion. This is audio-clock-vs-
        /// wall-clock drift - NOT a true cross-stream A/V delta (it never compares
        /// against the video present clock). ~0 = the audio device clock is
        /// tracking real time; POSITIVE = audio media has played BEHIND wall time
        /// (the device clock is slow / it's draining late), NEGATIVE = ahead.
        /// Computed as (wall-elapsed − media-played − buffer-cushion) since playout
        /// start, so a steady cushion reads ~0 and only a genuine clock-domain
        /// slip trends over time. nil until audio has begun playing.
        package var audioClockDriftMs: Double?
        /// Windowed MINIMUM buffer fill (ms) since the exporter last read it - the
        /// trough of the scheduled-ahead backlog. The 1Hz `bufferFillMs` gauge is
        /// last-writer-wins and can miss the instantaneous low that precedes an
        /// under-run; this min is the field that PROVES the buffer is (or is no
        /// longer) draining toward 0. RESET-ON-READ by the exporter. nil when no
        /// trough was sampled this window.
        package var bufferFillMinMs: Double?
        /// RE-PRIME count this session (monotonic): pre-roll RE-ARM edges - the
        /// state machine dropping back to un-primed after a full drain. NOT a
        /// count of paused wall-time pre-rolls: the node keeps playing across a
        /// re-arm and the cushion rebuilds via the post-gap catch-up clump (see
        /// AudioDecoder). Directly countable alongside under-runs.
        package var rePrimeTotal: UInt64
        /// RESAMPLER applied rate offset (ppm): the drift-tracking resampler's live
        /// `varispeed.rate − 1` in parts-per-million. 0 when disengaged (pre-roll /
        /// re-prime / drain); when converged it sits at the steady host↔Mac clock
        /// offset (~tens of ppm) - the direct view of the resampler holding the fill
        /// it's steering (vs the av_skew that bounces with video-side timing).
        package var resamplerPpm: Double = 0
        /// Lifecycle mirror, read under the meter lock. Zero while packets arrive exposes dead playout.
        /// Nil before the engine first starts.
        package var engineRunning: Bool?
        /// The cushion cap (ms) for the resolved link (wired 150 / Wi-Fi 200 /
        /// tunnel 300): the ceiling the target grows to, and the dead-air gap bound.
        package var cushionMaxMs: Double?
    }
}
