// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Beta switch for live adaptation. Each app registers its default; Diagnostics owns the toggle.
public enum AdaptiveBandwidth {
    public static let defaultsKey = "adaptiveBandwidthEnabled"

    /// Read once per stream so a before/after trial never changes mid-session.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

/// Turns the always-live receive counters into one-second policy windows. The receive path folds loss
/// and FEC counts about every two seconds, so a tick between folds reuses the last fold's fractions.
package struct BandwidthHealthSampler {
    package struct Counters: Equatable, Sendable {
        var packets: UInt64, lost: UInt64, frames: UInt64, recovered: UInt64
        var unrecoverable: UInt64, gaps50: UInt64, gaps100: UInt64, overflows: UInt64, bytes: UInt64

        static func live(receivedBytes: UInt64) -> Self {
            let shared = TelemetryCounters.shared
            return Self(packets: shared.videoPacketsTotal.value, lost: shared.videoPacketsLostPreFecTotal.value,
                        frames: shared.videoFramesTotal.value, recovered: shared.fecRecoveredFramesTotal.value,
                        unrecoverable: shared.unrecoverableFrameTotal.value,
                        gaps50: shared.videoGapOver50msTotal.value, gaps100: shared.videoGapOver100msTotal.value,
                        overflows: shared.backlogOverflowTotal.value, bytes: receivedBytes)
        }

        var all: [UInt64] { [packets, lost, frames, recovered, unrecoverable, gaps50, gaps100, overflows, bytes] }
    }

    /// Two missed folds mean the receive path went quiet; the frame watchdog owns that, not bitrate.
    package static let foldStaleSeconds: Double = 2.5
    private var last: Counters?
    private struct Fold { var expected: Int, lost: Int, frames: Int, recovered: Int }
    private var fold: Fold?
    private var foldAt: Double?

    package init() {}

    package mutating func window(start: Double, end: Double, generation: UInt64, counters: Counters,
                                 rttSamplesMs: [Double],
                                 receive: ReceivePolicyWindow = .init()) -> BandwidthHealth {
        var health = BandwidthHealth(start: start, end: end, generation: generation)
        defer { last = counters }
        guard let previous = last else { return Self.unavailable(health) }
        guard zip(counters.all, previous.all).allSatisfy({ $0 >= $1 }) else {
            fold = nil
            health.counterReset = true
            return health
        }
        let delta = { (path: KeyPath<Counters, UInt64>) in Int(clamping: counters[keyPath: path] - previous[keyPath: path]) }
        if delta(\.packets) + delta(\.lost) > 0 || delta(\.frames) > 0 {
            fold = Fold(expected: delta(\.packets) + delta(\.lost), lost: delta(\.lost),
                        frames: delta(\.frames), recovered: delta(\.recovered))
            foldAt = end
        }
        guard let fold, let foldAt, end - foldAt <= Self.foldStaleSeconds else { return Self.unavailable(health) }
        health.expectedPackets = fold.expected
        health.lostPackets = fold.lost
        health.totalFrames = fold.frames
        health.recoveredFrames = fold.recovered
        health.unrecoverableFrames = delta(\.unrecoverable)
        // Gap counters resolve only the 50 and 100 ms thresholds the policy uses; values are bucket floors.
        health.gapMs = delta(\.gaps100) > 0 ? 101 : (delta(\.gaps50) > 0 ? 51 : 0)
        health.decoderBacklog = delta(\.overflows) > 0
        health.rttSamplesMs = Array(rttSamplesMs.suffix(256))
        health.localQueueMs = receive.queueDelayP50Ms
        health.jitterP95Ms = receive.jitterP95Ms
        if end > start { health.encodedKbps = Double(delta(\.bytes)) * 8 / 1_000 / (end - start) }
        return health
    }

    private static func unavailable(_ health: BandwidthHealth) -> BandwidthHealth {
        var health = health
        health.coverage = 0
        health.missingReason = .producerUnavailable
        return health
    }
}

extension StreamSession {
    @discardableResult
    package nonisolated func scheduleBandwidthObservation() -> Task<Void, Never>? {
        guard adaptiveBandwidth, services.bandwidthInputs != nil else { return nil }
        let time = uptimeSeconds
        return Task { [weak self] in
            guard let self else { return }
            let attempt = await self.attemptID
            await self.observeBandwidth(at: time, attempt: attempt)
        }
    }

    /// The first connect seeds the policy; later builds keep it, so dwell and backoff survive reconnects.
    /// Returns the ANNOUNCE rate: public clients start from the policy's current-path rate when enabled.
    package func seedBandwidth(config: StreamRequest, appliedKbps: Int, rtt: RttStats?, preLaunch: Bool) -> Int {
        guard adaptiveBandwidth, bandwidthPolicy == nil,
              let snapshot = services.bandwidthInputs?.snapshot() else { return appliedKbps }
        let demand = Self.bandwidthDemand(config)
        var ask = appliedKbps
        if adaptiveBandwidth, publicMedia != nil {
            ask = BandwidthPolicy.startRate(demand: demand, path: snapshot.path)
            adaptiveStartKbps = ask
            reconnectConfig?.bitrateKbps = ask
            reconnectConfig?.bitrateBoost = 1
        }
        bandwidthPolicy = BandwidthPolicy(demand: demand, path: snapshot.path,
            environment: snapshot.environment, appliedKbps: ask)
        bandwidthLastObservation = nil
        bandwidthConnectRTT = preLaunch && bandwidthProbeGeneration == snapshot.path.generation ? rtt : nil
        return ask
    }

    static func bandwidthDemand(_ config: StreamRequest) -> BandwidthDemand {
        let codec: BandwidthDemand.Codec
        switch config.videoFormats.topCodec {
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        case .av1: codec = .av1
        }
        return BandwidthDemand(width: config.width, height: config.height, fps: config.fps, codec: codec)
    }

    /// One 1 Hz watchdog tick. Transitions own the link while they run, so no window spans one.
    package func observeBandwidth(at time: Double, attempt: UUID) {
        guard adaptiveBandwidth, attemptID == attempt, !publicTerminal, !isTearingDown, isStreaming,
              var policy = bandwidthPolicy, let snapshot = services.bandwidthInputs?.snapshot() else { return }
        guard !isReconnecting, let decoder = videoDecoder else {
            bandwidthLastObservation = nil
            bandwidthSampler = BandwidthHealthSampler()
            _ = ReceivePolicyWindow.takeVideo()
            return
        }
        policy.replacePath(snapshot.path)
        policy.setEnvironment(snapshot.environment)
        if bandwidthTransition == nil, let applied = appliedBitrateKbps { policy.adoptApplied(applied) }
        let health = bandwidthSampler.window(start: bandwidthLastObservation ?? time, end: time,
            generation: snapshot.path.generation,
            counters: .live(receivedBytes: decoder.statsCollector.receivedBytesSnapshot()),
            rttSamplesMs: backend.drainRttSamples(), receive: ReceivePolicyWindow.takeVideo())
        bandwidthLastObservation = time
        var decision = policy.evaluate(health)
        if adaptiveBandwidth, bandwidthTransition == nil, bitrateTask == nil {
            actuateBandwidth(&policy, at: time, lowData: snapshot.path.constrained)
            decision = policy.decision(decision.reason, health: health)
        }
        bandwidthPolicy = policy
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        TelemetryExporter.recordLiveEvent(bandwidthFields(decision))
        #endif
    }

    /// A Low Data Mode edge also moves the encoder size, carrying any pending rate in the same transition.
    private func actuateBandwidth(_ policy: inout BandwidthPolicy, at time: Double, lowData: Bool?) {
        let request = policy.submission(at: time)
        let admission: BitrateAdmission
        if let lowData, let size = dataModeTarget(lowData: lowData), let applied = appliedBitrateKbps,
           time - bandwidthSizeAttemptAt >= BandwidthFlapGuard.minDwellSeconds {
            bandwidthSizeAttemptAt = time
            admission = beginTransition(rate: request?.rateKbps ?? applied, reason: .resize, size: size)
        } else if let request {
            admission = self.request(rate: request.rateKbps, reason: Self.bitrateReason(request.reason))
        } else { return }
        guard let request else { return }
        let outcome: BandwidthActuatorOutcome = switch admission {
        case .accepted: .accepted
        case .deferred: .deferred
        case .rejected: .rejected
        }
        policy.recordOutcome(outcome, for: request)
        if outcome == .accepted { bandwidthTransition = request }
    }

    func dataModeTarget(lowData: Bool) -> (width: Int, height: Int)? {
        guard let config = reconnectConfig, let sizes = config.dataModeSizes else { return nil }
        let target = sizes.size(lowData: lowData)
        return target == (config.width, config.height) ? nil : target
    }

    /// Completion of any transition. Only the policy's own request confirms; failures stay retryable.
    package func finishBandwidthTransition(applied: Bool) {
        guard let request = bandwidthTransition else { return }
        bandwidthTransition = nil
        guard var policy = bandwidthPolicy else { return }
        if applied { policy.confirmApplied(request) } else { policy.recordOutcome(.rejected, for: request) }
        bandwidthPolicy = policy
    }

    static func bitrateReason(_ reason: BandwidthReason) -> BitrateReason {
        switch reason {
        case .promotion: .trial
        case .recovery: .recovery
        case .rollback: .rollback
        default: .congestion
        }
    }

    private func bandwidthFields(_ decision: BandwidthDecision) -> [String] {
        let context = BandwidthLedgerContext(session: id, attempt: attemptID,
            connectRTT: bandwidthConnectRTT.map {
                BandwidthConnectRTT(count: $0.count, p50Ms: $0.p50Ms, p95Ms: $0.p95Ms, steadyMs: $0.steadyMs)
            })
        guard let data = try? JSONEncoder().encode(BandwidthLedger(context: context, decision: decision)),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["\"event\":\"bandwidth_policy\"", "\"bandwidth\":\(json)", "\"adaptive\":\(adaptiveBandwidth)"]
    }
}
