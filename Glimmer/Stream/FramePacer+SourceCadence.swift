//
//  FramePacer+SourceCadence.swift
//
//  The pacer's SOURCE-CADENCE feed: every consecutive source-timestamp delta
//  the submit path already computes goes into the pure `SourceCadenceDetector`
//  (owned under the pacer lock), and each of its 4x/s window evaluations is
//  published OFF the lock to the exporter gauge. That is ALL the pacer does
//  with it - observability only. The presentation path (due gate, trim,
//  backoff, watchdog, cadence-error metric) does not read any of it: a
//  presentation-side lock onto a slower grid was built on this signal, judged
//  live (a flat 120Hz metronome that felt no better, +8ms glass-to-glass,
//  sample-and-hold on a 240Hz panel) and removed - the judder is in the
//  content, and presentation cannot fix that.
//
//  The pacer also does NOT classify what the signal means. Sustained
//  multi-period gaps alone cannot tell a host that SKIPS captures (encode
//  over the frame budget - the loaded-GPU 4K240 case) from a game that is
//  simply SLOWER than the request (a 101fps game at a 240 request: 99%
//  multi-period gaps, encode well inside budget, every delivered frame a game
//  frame, perfectly smooth). The discriminator is host encode time against
//  the budget, which the pacer never sees and must not depend on; the
//  exporter's 1Hz capture has both inputs, so the classification and the
//  session-log claim live there (TelemetryExporter+SourceCadence.swift).
//
//  Threading: `noteSourceTimestampDeltaLocked` runs on the decode queue under
//  the pacer lock (a handful of integer adds per frame; the window evaluation
//  is 4x per second); the publish runs OFF the lock via the returned sample
//  (the gauge takes its own lock). No allocation per frame anywhere.
//

import CoreMedia
import os

extension FramePacer {

    /// The gauge sample one window evaluation produced, handed OFF the lock.
    typealias SourceCadenceSample = TelemetryCounters.SourceCadenceSnapshot

    // MARK: - Feed (decode queue, under `lock`)

    /// The submit path's single entry point: every consecutive source-
    /// timestamp delta, a >1s stall included (the detector's window veto must
    /// SEE a stall to refuse to read one as under-delivery); a non-positive
    /// delta is a discontinuity the detector resets on. Returns the sample to
    /// publish when this frame crossed a bucket boundary and the window could
    /// judge (4x per second); nil on every other frame.
    func noteSourceTimestampDeltaLocked(_ deltaSeconds: Double) -> SourceCadenceSample? {
        assertLockHeld()
        guard let evaluation = sourceCadence.observe(deltaSeconds: deltaSeconds),
              evaluation.stats.achievedFraction.isFinite else { return nil }
        return SourceCadenceSample(
            achievedFraction: evaluation.stats.achievedFraction,
            multiPeriodFraction: evaluation.stats.multiPeriodFraction,
            maxGapPeriods: evaluation.stats.maxGapPeriods,
            underDelivering: sourceCadence.underDelivering,
            requestedPeriodMs: configuredFrameIntervalSeconds * 1000)
    }

    /// Pacer restart (`stop()`): a fresh detector - a restart is a new source
    /// era, and an inherited window must never judge the next link's frames.
    func resetSourceCadenceLocked() {
        assertLockHeld()
        sourceCadence = SourceCadenceDetector(nominalPeriodSeconds: configuredFrameIntervalSeconds)
    }

    // MARK: - Publish (OFF the lock)

    /// Publish a window sample to the exporter gauge (`source_achieved_frac` /
    /// `source_multi_period_frac` / `source_max_gap_periods`, plus the
    /// detector's sustained-under-delivery verdict and the requested period
    /// the 1Hz classifier reads). Never under the pacer lock (the gauge takes
    /// its own). Takes the optional the submit path carries so the common
    /// no-evaluation frame is one nil check.
    func publishSourceCadence(_ sample: SourceCadenceSample?) {
        guard let sample else { return }
        assertLockNotHeld()
        TelemetryCounters.shared.setSourceCadence(sample)
    }
}
