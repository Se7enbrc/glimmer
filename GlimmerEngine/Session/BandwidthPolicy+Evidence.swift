// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension BandwidthPolicy {
    static func quantile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty, sorted.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return sorted[max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }

    func isTransportBad(_ health: BandwidthHealth) -> Bool {
        let median = Self.quantile(health.rttSamplesMs.sorted(), 0.5)
        let rise = baselineMs.flatMap { base in median.map { $0 - base > max(3, base * 0.25) } } ?? false
        let parity = health.parityMargin.map { $0.isFinite && $0 < 0.1 } == true
            && (health.recovered ?? 0) > 0.005
        return (health.loss ?? 0) > 0.01 || rise || parity
    }

    func isHealthy(_ health: BandwidthHealth) -> Bool {
        guard let loss = health.loss, loss < 0.001,
              let recovered = health.recovered, recovered < 0.005,
              health.unrecoverableFrames == 0, health.decoderBacklog == false,
              let gap = health.gapMs, gap.isFinite, gap >= 0, gap <= 50,
              let queue = health.localQueueMs, queue.isFinite, queue >= 0, queue <= 2,
              let encoded = health.encodedKbps, encoded.isFinite, encoded >= 0,
              health.risingQueue == false,
              let median = Self.quantile(health.rttSamplesMs.sorted(), 0.5),
              let high = Self.quantile(health.rttSamplesMs.sorted(), 0.95) else { return false }
        guard let baselineMs else { return true }
        return median - baselineMs <= max(3, baselineMs * 0.25)
            && high - baselineMs <= max(10, baselineMs * 0.5)
    }

    mutating func updateBaseline(_ health: BandwidthHealth) {
        baselineSamples.append((health.end, Array(health.rttSamplesMs.suffix(256))))
        baselineSamples.removeAll { health.end - $0.time >= 10 }
        let samples = baselineSamples.flatMap(\.values).sorted()
        if baselineMs == nil, samples.count >= 10,
           let first = baselineSamples.first, health.end - first.time >= 2 {
            baselineMs = Self.quantile(samples, 0.1)
        }
        guard let first = baselineSamples.first, health.end - first.time >= 9, let median = Self.quantile(samples, 0.5) else { return }
        baselineWindows.append((health.end, median))
        baselineWindows.removeAll { health.end - $0.time > 300 }
        baselineMs = baselineWindows.map(\.median).min()
    }

    mutating func propose(_ rate: Int, reason: BandwidthReason, health: BandwidthHealth) -> BandwidthDecision {
        if pending?.rateKbps != rate || pending?.reason != reason {
            sequence &+= 1
            pending = BandwidthRequest(rateKbps: rate, reason: reason, generation: path.generation, sequence: sequence)
            outcome = nil
        }
        targetKbps = rate
        return decision(reason, health: health)
    }

    public mutating func recordOutcome(_ result: BandwidthActuatorOutcome, for request: BandwidthRequest) {
        guard !stopped, pending == request, path.generation == request.generation else { return }
        outcome = result
    }

    /// Call only after the actuator verifies the negotiated request on this attempt and path.
    @discardableResult public mutating func confirmApplied(_ request: BandwidthRequest) -> Bool {
        guard !stopped, pending == request, outcome == .accepted, path.generation == request.generation else {
            return false
        }
        let wasReduction = request.rateKbps < appliedKbps
        let failedTrial = trial && wasReduction
        if wasReduction {
            recovering = true
            retrySeconds = failedTrial ? min(2_400, retrySeconds * 2) : retrySeconds
            lastCutAt = activeSeconds
            provenKbps = min(provenKbps, request.rateKbps)
            trial = false
        } else {
            provenKbps = appliedKbps
            trial = true
        }
        pathNeedsReseed = false
        appliedKbps = request.rateKbps
        targetKbps = request.rateKbps
        pending = nil
        cleanSeconds = 0
        badSeconds = 0
        windows.removeAll()
        severeTimes.removeAll()
        return true
    }

    func decision(_ reason: BandwidthReason, health: BandwidthHealth) -> BandwidthDecision {
        BandwidthDecision(policyVersion: Self.version, path: path, demand: demand, environment: environment,
            window: health.ledgerValue, displayDemandKbps: demand.baseKbps, baseKbps: baseKbps,
            earnedRung: Double(appliedKbps) / Double(baseKbps),
            state: stopped ? .stopped : (recovering ? .recovering : (trial ? .trial : .observing)),
            ceilingKbps: Self.ceiling(demand: demand, path: path),
            proposedKbps: targetKbps, appliedKbps: appliedKbps, provenKbps: provenKbps,
            baselineMs: baselineMs, activeSeconds: activeSeconds, cleanSeconds: cleanSeconds,
            nextEligibleActiveSeconds: activeSeconds + max(0, qualificationSeconds(health) - cleanSeconds),
            reason: reason, confidence: reason == .missingEvidence ? .unknown : (baselineMs == nil ? .provisional : .measured),
            request: pending, actuatorOutcome: outcome)
    }
}
