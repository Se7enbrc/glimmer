// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
import os
@testable import Glimmer

struct RendererTelemetryTests {
    // Callbacks and provider changes can cross queues; all fake state is lock-protected.
    private final class Probe: @unchecked Sendable {
        final class Identity: Sendable {}

        struct State {
            var identity: Identity? = Identity()
            var probes = 0
            var loads = 0
            var callbacks: [@Sendable (RendererPerformanceValues?) -> Void] = []
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        func source() -> RendererPerformanceSource? {
            let identity = state.withLock { value in
                value.probes += 1
                return value.identity
            }
            guard let identity else { return nil }
            return RendererPerformanceSource(identity: identity) { [self] completion in
                state.withLock { value in
                    value.loads += 1
                    value.callbacks.append(completion)
                }
            }
        }

        func complete(_ values: RendererPerformanceValues?) {
            let callback = state.withLock { $0.callbacks.removeFirst() }
            callback(values)
        }
    }

    private func values(_ frames: UInt64, dropped: UInt64 = 0, optimized: UInt64 = 0,
                        delay: Double = 0) -> RendererPerformanceValues {
        RendererPerformanceValues(frames: frames, dropped: dropped, optimized: optimized, delaySeconds: delay)
    }

    @Test func disabledExporterNeverQueriesRenderer() {
        let probe = Probe()
        let source = TelemetrySource(
            videoStats: { StreamStatsSnapshot() }, decoderDrops: { 0 }, backpressureDrops: { 0 },
            presentationLateDrops: { 0 }, presentationGaps: { 0 }, estimatedRtt: { nil },
            enetHealth: { nil }, pacingLiveness: { nil }, inFlightDecodeBacklog: { 0 },
            refreshWindow: { nil }, displayProbe: { nil }, rendererProbe: { probe.source() })
        let exporter = TelemetryExporter.makeIfEnabled(source: source, serverName: "test", enabled: false)
        #expect(exporter == nil)
        #expect(probe.state.withLock { $0.probes } == 0)
        #expect(probe.state.withLock { $0.loads } == 0)
    }

    @Test func firstResultIsBaselineThenCountersProduceDeltas() {
        let queue = DispatchQueue(label: "renderer-baseline-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        #expect(queue.sync { sampler.sample().status } == .unavailable)
        probe.complete(values(100, dropped: 2, optimized: 80, delay: 0.4))
        let baseline = queue.sync { sampler.sample() }
        #expect(baseline.status == .baseline)
        #expect(baseline.cumulative?.frames == 100)
        #expect(baseline.delta == nil)
        #expect(baseline.intervalSeconds == nil)
        probe.complete(values(160, dropped: 3, optimized: 120, delay: 0.6))
        let next = queue.sync { sampler.sample() }
        #expect(next.status == .ready)
        #expect(next.delta?.frames == 60)
        #expect(next.delta?.dropped == 1)
        #expect(next.delta?.optimized == 40)
        #expect(abs((next.delta?.delaySeconds ?? 0) - 0.2) < 0.0001)
        #expect((next.intervalSeconds ?? 0) > 0)
        #expect((next.ageSeconds ?? -1) >= 0)
        #expect(next.resets == 0)
        let pending = queue.sync { sampler.sample() }
        #expect(pending.status == .pending)
        #expect(pending.delta == nil)
        #expect(pending.intervalSeconds == nil)
        #expect(pending.cumulative?.frames == 160)
    }

    @Test func requestsStayBoundedAndLateReplacedRendererCannotPublish() {
        let queue = DispatchQueue(label: "renderer-replacement-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        _ = queue.sync { sampler.sample() }
        for _ in 0..<10 { _ = queue.sync { sampler.sample() } }
        #expect(probe.state.withLock { $0.loads } == 1)
        probe.state.withLock { $0.identity = Probe.Identity() }
        #expect(queue.sync { sampler.sample().status } == .pending)
        #expect(probe.state.withLock { $0.loads } == 1)
        probe.complete(values(900))
        let replaced = queue.sync { sampler.sample() }
        #expect(replaced.cumulative == nil)
        #expect(replaced.resets == 1)
        #expect(probe.state.withLock { $0.loads } == 2)
        probe.complete(values(5))
        let fresh = queue.sync { sampler.sample() }
        #expect(fresh.status == .baseline)
        #expect(fresh.cumulative?.frames == 5)
        #expect(fresh.delta == nil)
    }

    @Test func completionDetectsReplacementBeforeNextTick() {
        let queue = DispatchQueue(label: "renderer-callback-replacement-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        _ = queue.sync { sampler.sample() }
        probe.state.withLock { $0.identity = Probe.Identity() }
        probe.complete(values(500))
        let sample = queue.sync { sampler.sample() }
        #expect(sample.cumulative == nil)
        #expect(sample.resets == 1)
    }

    @Test func teardownInvalidatesCallbackAndStopsAllProbes() {
        let queue = DispatchQueue(label: "renderer-stop-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        _ = queue.sync { sampler.sample() }
        queue.sync { sampler.stop() }
        let probes = probe.state.withLock { $0.probes }
        probe.complete(values(500))
        let sample = queue.sync { sampler.sample() }
        #expect(sample.status == .unavailable)
        #expect(sample.cumulative == nil)
        #expect(probe.state.withLock { $0.probes } == probes)
        #expect(probe.state.withLock { $0.loads } == 1)
    }

    @Test func unavailableReplyDoesNotFabricateZeroAndCounterRollbackRebaselines() {
        let queue = DispatchQueue(label: "renderer-reset-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        _ = queue.sync { sampler.sample() }
        probe.complete(values(100, dropped: 2, delay: 0.4))
        _ = queue.sync { sampler.sample() }
        probe.complete(nil)
        let unavailable = queue.sync { sampler.sample() }
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.cumulative == nil)
        #expect(unavailable.delta == nil)
        probe.complete(values(120, dropped: 3, delay: 0.5))
        #expect(queue.sync { sampler.sample().delta?.frames } == 20)
        probe.complete(values(2))
        let reset = queue.sync { sampler.sample() }
        #expect(reset.status == .baseline)
        #expect(reset.cumulative?.frames == 2)
        #expect(reset.delta == nil)
        #expect(reset.resets == 1)
        probe.complete(values(3, delay: .nan))
        #expect(queue.sync { sampler.sample().status } == .unavailable)
    }

    @Test func exportsCarrySameValuesAndOmitUnavailableCounts() throws {
        var snap = TelemetrySnapshot()
        let extras = TelemetrySnapshot.Extras()
        let withoutRenderer = TelemetryRenderer.ndjson(snap, extras: extras)
        #expect(!withoutRenderer.contains("renderer_metrics_status"))
        snap.rendererPerformance = RendererPerformanceSnapshot()
        let unavailable = TelemetryRenderer.ndjson(snap, extras: extras)
        #expect(unavailable.contains("\"renderer_metrics_status\":\"unavailable\""))
        #expect(!unavailable.contains("renderer_frames_total"))
        snap.rendererPerformance = RendererPerformanceSnapshot(
            status: .ready, cumulative: values(100, dropped: 4, optimized: 80, delay: 0.5),
            delta: values(60, dropped: 1, optimized: 40, delay: 0.2),
            intervalSeconds: 1.1, ageSeconds: 0.9, resets: 2)
        let prom = TelemetryRenderer.prometheus(snap, extras: extras)
        let json = TelemetryRenderer.ndjson(snap, extras: extras)
        let row = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(row["renderer_metrics_status"] as? String == "ready")
        for (key, expected) in [("frames_total", 100), ("dropped_frames_total", 4),
                                 ("optimized_frames_total", 80), ("frames_delta", 60),
                                 ("dropped_frames_delta", 1), ("optimized_frames_delta", 40),
                                 ("metrics_resets_total", 2)] {
            #expect((row["renderer_" + key] as? NSNumber)?.intValue == expected)
            #expect(prom.split(separator: "\n").contains {
                $0.hasPrefix("glimmer_renderer_" + key + "{") && $0.hasSuffix(" " + String(expected))
            })
        }
        #expect((row["renderer_accumulated_frame_delay_s"] as? NSNumber)?.doubleValue == 0.5)
        #expect((row["renderer_frame_delay_delta_s"] as? NSNumber)?.doubleValue == 0.2)
        #expect(prom.split(separator: "\n").contains {
            $0.hasPrefix("glimmer_renderer_frame_delay_delta_seconds{") && $0.hasSuffix(" 0.200")
        })
    }
}
