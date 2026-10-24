// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Pure, monotonic-time decisions. The session owns this value and confirms applied requests separately.
public struct BandwidthPolicy: Sendable {
    public static let version = 1
    public internal(set) var path: BandwidthPath
    public internal(set) var demand: BandwidthDemand
    public internal(set) var appliedKbps: Int
    public internal(set) var targetKbps: Int
    public internal(set) var baseKbps: Int
    public internal(set) var activeSeconds: Double = 0
    public internal(set) var cleanSeconds: Double = 0
    public internal(set) var retrySeconds: Double = 300
    public internal(set) var baselineMs: Double?
    public internal(set) var pending: BandwidthRequest?
    public internal(set) var outcome: BandwidthActuatorOutcome?
    var environment: BandwidthEnvironment
    var windows: [BandwidthHealth] = []
    var baselineWindows: [(time: Double, median: Double)] = []
    var baselineSamples: [(time: Double, values: [Double])] = []
    var lastEnd: Double?
    var sequence: UInt64 = 0
    var badSeconds: Double = 0
    var severeTimes: [Double] = []
    var lastCutAt: Double = -.infinity
    var recovering = false
    var trial = false
    var pathNeedsReseed = false
    var provenKbps: Int
    var stopped = false
    var foregroundAt: Double = 0
    var thermalRecoveryRemaining: Double = 0

    public init(demand: BandwidthDemand, path: BandwidthPath, environment: BandwidthEnvironment,
                appliedKbps: Int? = nil) {
        self.demand = demand
        self.path = path
        self.environment = environment
        baseKbps = Self.startRate(demand: demand, path: path)
        self.appliedKbps = max(1, appliedKbps ?? baseKbps)
        targetKbps = baseKbps
        provenKbps = baseKbps
    }

    public static func startRate(demand: BandwidthDemand, path: BandwidthPath) -> Int {
        let multiplier = !demand.saver && demand.customKbps == nil && (path.interface == .wifi || path.interface == .wired) ? 2 : 1
        let start = demand.baseKbps * multiplier
        return min(start, ceiling(demand: demand, path: path))
    }

    static func ceiling(demand: BandwidthDemand, path: BandwidthPath) -> Int {
        // HDR has no validated extra multiplier. The accepted format remains explicit in the ledger.
        let dataMode = path.constrained == true ? 9_000 : 500_000
        let bounds = [dataMode, demand.customKbps, demand.deviceCeilingKbps,
                      demand.encoderCeilingKbps, demand.dataCeilingKbps].compactMap { $0 }
        return max(1, min(500_000, bounds.min() ?? 500_000))
    }

    /// Same-interface replacements also reset every learned transport fact and rollback rung.
    public mutating func replacePath(_ replacement: BandwidthPath) {
        guard replacement.generation >= path.generation else { return }
        let changed = replacement.generation != path.generation
        path = replacement
        baseKbps = Self.startRate(demand: demand, path: path)
        if changed {
            resetEvidence()
            provenKbps = baseKbps
            recovering = false
            retrySeconds = 300
            trial = false
            pending = nil
            outcome = nil
            targetKbps = baseKbps
            pathNeedsReseed = true
        }
    }

    public mutating func setEnvironment(_ value: BandwidthEnvironment) {
        if !environment.foreground && value.foreground {
            resetEvidence()
            foregroundAt = activeSeconds
        }
        if environment.thermal == .serious || environment.thermal == .critical {
            thermalRecoveryRemaining = 300
        }
        environment = value
        if !value.allowsPromotion, let pending, pending.rateKbps > appliedKbps {
            self.pending = nil
            outcome = nil
            targetKbps = appliedKbps
        }
        if !value.foreground { cleanSeconds = 0; windows.removeAll(); badSeconds = 0 }
    }

    public mutating func stop() {
        stopped = true
        pending = nil
        resetEvidence()
    }

    public mutating func evaluate(_ health: BandwidthHealth) -> BandwidthDecision {
        guard !stopped else { return decision(.stopped, health: health) }
        guard environment.foreground else { return decision(.background, health: health) }
        guard health.generation == path.generation else { return decision(.missingEvidence, health: health) }
        if path.ultraConstrained == true || path.satisfied == false {
            return decision(.unsupportedPath, health: health)
        }
        if let constrained = constrainedRequest(health) { return constrained }
        guard health.valid, lastEnd.map({ health.start >= $0 && health.end > $0 }) ?? true else {
            cleanSeconds = 0
            windows.removeAll()
            badSeconds = 0
            if let pending, pending.rateKbps > appliedKbps {
                self.pending = nil
                outcome = nil
                targetKbps = appliedKbps
            }
            return decision(.missingEvidence, health: health)
        }
        if let lastEnd, health.start - lastEnd > 0.5 { cleanSeconds = 0; windows.removeAll(); badSeconds = 0 }
        lastEnd = health.end
        activeSeconds += health.end - health.start
        if let pending, pending.rateKbps > appliedKbps, !isHealthy(health) {
            self.pending = nil
            outcome = nil
            targetKbps = appliedKbps
        }
        if let pending { return decision(pending.reason, health: health) }
        return assess(health)
    }

    mutating func constrainedRequest(_ health: BandwidthHealth) -> BandwidthDecision? {
        let limit = Self.ceiling(demand: demand, path: path)
        let desired = pathNeedsReseed ? min(baseKbps, limit) : limit
        if desired < appliedKbps {
            if pending?.rateKbps == desired { return nil }
            let reason: BandwidthReason = path.constrained == true ? .lowData : .pathChanged
            return propose(desired, reason: reason, health: health)
        }
        return nil
    }

    mutating func assess(_ health: BandwidthHealth) -> BandwidthDecision {
        let transportBad = isTransportBad(health)
        let severe = (health.unrecoverableFrames ?? 0) > 0 || (health.gapMs ?? 0) > 100
        severeTimes.removeAll { health.end - $0 > 10 }
        if severe { severeTimes.append(health.end) }
        let distressed = severe || (health.gapMs ?? 0) > 50
        badSeconds = transportBad && distressed ? badSeconds + health.end - health.start : 0
        if badSeconds >= 3 || (severeTimes.count >= 2 && transportBad) {
            cleanSeconds = 0
            windows.removeAll()
            return cut(health)
        }
        guard isHealthy(health), !severe else {
            cleanSeconds = 0
            windows.removeAll()
            let local = health.decoderBacklog == true || (health.localQueueMs ?? 0) > 2
            return decision(local ? .localOverload : .missingEvidence, health: health)
        }
        updateBaseline(health)
        cleanSeconds += health.end - health.start
        if thermalRecoveryRemaining > 0 { thermalRecoveryRemaining -= health.end - health.start }
        windows.append(health)
        windows.removeAll { health.end - $0.end >= 120 }
        if trial && cleanSeconds >= 120 && busySeconds(last: 60) >= 30 {
            trial = false
            recovering = false
            retrySeconds = 300
            provenKbps = appliedKbps
        }
        return earn(health)
    }

    mutating func cut(_ health: BandwidthHealth) -> BandwidthDecision {
        let rollback = trial && provenKbps < appliedKbps
        guard rollback || activeSeconds - lastCutAt >= 90 else {
            return decision(.transportDistress, health: health)
        }
        let rate = rollback ? provenKbps : max(1, Int(Double(appliedKbps) * 0.6))
        guard rate < appliedKbps else { return decision(.unsupportedPath, health: health) }
        return propose(rate, reason: rollback ? .rollback : .transportDistress, health: health)
    }

    mutating func earn(_ health: BandwidthHealth) -> BandwidthDecision {
        let recovery = appliedKbps < baseKbps
        guard baselineMs != nil, environment.allowsPromotion, thermalRecoveryRemaining <= 0,
              activeSeconds - foregroundAt >= 10, path.source == .destination,
              path.expensive != nil, path.constrained != nil,
              recovery || (path.constrained == false && path.tunnel == false),
              health.end - path.observedAt >= 0 else { return decision(.hold, health: health) }
        let hasRadio = validPHY(at: health.end) != nil || health.train?.budgetIPKbps(at: health.end) != nil
        let dwell = qualificationSeconds(health)
        guard cleanSeconds >= dwell, busySeconds(last: 60) >= 30,
              hasRadio || busySeconds(last: 120) >= 119 else { return decision(.hold, health: health) }
        let wiredClass = windows.count >= 60 && windows.allSatisfy { window in
            let rtts = window.rttSamplesMs.sorted()
            return Self.quantile(rtts, 0.95).map { $0 <= 5 } == true
                && Self.quantile(rtts, 0.95).flatMap { high in
                    Self.quantile(rtts, 0.1).map { high - $0 <= 2 }
                } == true && window.jitterP95Ms.map { $0.isFinite && $0 <= 1 } == true
        }
        let headroom = !demand.saver && demand.customKbps == nil && wiredClass
            && (path.interface == .wifi || path.interface == .wired)
        let cap = min(Self.ceiling(demand: demand, path: path), headroom ? baseKbps * 2 : baseKbps)
        var rate = min(cap, Int((Double(appliedKbps) * (hasRadio ? 1.2 : 1.1)).rounded()))
        if let phy = validPHY(at: health.end) { rate = min(rate, max(1, Int(phy * 350))) }
        if let budget = health.train?.budgetIPKbps(at: health.end) {
            guard budget.isFinite, budget > 0, let ipRate = health.receivedIPKbps,
                  let encoded = health.encodedKbps, encoded > 0,
                  Double(rate) * ipRate / encoded <= budget else { return decision(.hold, health: health) }
        }
        guard rate > appliedKbps else { return decision(.hold, health: health) }
        return propose(rate, reason: recovery ? .recovery : .promotion, health: health)
    }

    func qualificationSeconds(_ health: BandwidthHealth) -> Double {
        let corroborated = validPHY(at: health.end) != nil || health.train?.budgetIPKbps(at: health.end) != nil
        return recovering ? retrySeconds : (corroborated && !trial && appliedKbps == baseKbps ? 60 : 120)
    }

    func busySeconds(last seconds: Double) -> Double {
        guard let end = windows.last?.end else { return 0 }
        return windows.filter { end - $0.end < seconds && ($0.encodedKbps ?? 0) >= Double(appliedKbps) * 0.7 }
            .reduce(0) { $0 + $1.end - $1.start }
    }

    func validPHY(at time: Double) -> Double? {
        guard path.phyMatchesInterface, let phy = path.phyMbps, phy.isFinite, phy > 0,
              let observed = path.phyObservedAt, time - observed >= 0, time - observed <= 10 else { return nil }
        return phy
    }

    mutating func resetEvidence() {
        baselineMs = nil
        baselineWindows.removeAll()
        baselineSamples.removeAll()
        windows.removeAll()
        severeTimes.removeAll()
        lastEnd = nil
        cleanSeconds = 0
        badSeconds = 0
    }
}
