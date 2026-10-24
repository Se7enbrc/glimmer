// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamSession {
    /// Shadow targets cannot alter ANNOUNCE or request a reconnect before actuator acceptance.
    package func seedBandwidth(config: StreamRequest, appliedKbps: Int, rtt: RttStats?, preLaunch: Bool) {
        guard let snapshot = services.bandwidthInputs?.snapshot() else { return }
        let codec: BandwidthDemand.Codec
        switch config.videoFormats.topCodec {
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        case .av1: codec = .av1
        }
        let demand = BandwidthDemand(width: config.width, height: config.height, fps: config.fps, codec: codec)
        bandwidthPolicy = BandwidthPolicy(demand: demand, path: snapshot.path,
            environment: snapshot.environment, appliedKbps: appliedKbps)
        bandwidthLastObservation = uptimeSeconds
        bandwidthConnectRTT = preLaunch && bandwidthProbeGeneration == snapshot.path.generation ? rtt : nil
    }

    package func observeBandwidth(at time: Double, attempt: UUID) {
        guard attemptID == attempt, !publicTerminal, !isTearingDown,
              var policy = bandwidthPolicy, let snapshot = services.bandwidthInputs?.snapshot() else { return }
        policy.replacePath(snapshot.path)
        policy.setEnvironment(snapshot.environment)
        var health = BandwidthHealth(start: bandwidthLastObservation ?? time, end: time,
                                     generation: snapshot.path.generation)
        bandwidthLastObservation = time
        // Core health must arrive from fresh interval producers at actuator integration, not cached gauges.
        health.coverage = 0
        health.missingReason = .producerUnavailable
        let decision = policy.evaluate(health)
        bandwidthPolicy = policy
        TelemetryExporter.recordLiveEvent(bandwidthFields(decision))
    }

    private func bandwidthFields(_ decision: BandwidthDecision) -> [String] {
        let context = BandwidthLedgerContext(session: id, attempt: attemptID,
            connectRTT: bandwidthConnectRTT.map {
                BandwidthConnectRTT(count: $0.count, p50Ms: $0.p50Ms, p95Ms: $0.p95Ms, steadyMs: $0.steadyMs)
            })
        guard let data = try? JSONEncoder().encode(BandwidthLedger(context: context, decision: decision)),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["\"event\":\"bandwidth_policy\"", "\"bandwidth\":\(json)"]
    }
}
