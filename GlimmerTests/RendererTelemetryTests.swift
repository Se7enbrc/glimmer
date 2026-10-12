// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import AVFoundation
import Foundation
import QuartzCore
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
            var transitions: [RendererPathTransition] = []
            var presentation = RendererPresentationState()
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        func source() -> RendererPerformanceSource? {
            let identity = state.withLock { value in
                value.probes += 1
                return value.identity
            }
            guard let identity else { return nil }
            return RendererPerformanceSource(identity: identity, presentation: state.withLock { $0.presentation },
                                             reportTransition: { [self] transition in
                state.withLock { $0.transitions.append(transition) }
            }, load: { [self] completion in
                state.withLock { value in
                    value.loads += 1
                    value.callbacks.append(completion)
                }
            })
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

    @Test func resumedSamePathReportsAfterAFullIntervalAndHonorsThrottle() {
        var tracker = RendererPathTracker()
        #expect(tracker.observe(values(100, optimized: 100), now: 0) == nil)
        #expect(tracker.observe(values(100), now: 1) != nil)
        tracker.rebaseline(reportResume: true)
        #expect(tracker.observe(values(100), now: 2) == nil)
        tracker.rebaseline()
        #expect(tracker.observe(values(0), now: 6) == nil)
        let resumed = tracker.observe(values(100), now: 7)
        #expect(resumed?.summary == "resume->composited frames=100 optimized=0 suppressed=0")
        #expect(tracker.observe(values(100), now: 8) == nil)
        tracker.rebaseline(reportResume: true)
        #expect(tracker.observe(values(100, optimized: 100), now: 12)?.isResume == true)
    }

    @Test(arguments: [false, true])
    func resumeDiscardsSpanningReplyAndReportsUnchangedPath(shortHide: Bool) {
        let queue = DispatchQueue(label: "renderer-resume-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        _ = queue.sync { sampler.sample() }
        probe.complete(values(100))
        _ = queue.sync { sampler.sample() }
        if !shortHide {
            probe.state.withLock { $0.presentation = .init(generation: 1, suppressed: true) }
            _ = queue.sync { sampler.sample() }
        }
        probe.state.withLock { $0.presentation = .init(generation: 2, suppressed: false) }
        probe.complete(values(200))
        #expect(queue.sync { sampler.sample().cumulative } == nil)
        probe.complete(values(300))
        #expect(queue.sync { sampler.sample().status } == .baseline)
        #expect(probe.state.withLock { $0.transitions.isEmpty })
        probe.complete(values(400))
        queue.sync {}
        #expect(probe.state.withLock { $0.transitions.map(\.summary) }
            == ["resume->composited frames=100 optimized=0 suppressed=0"])
    }

    @Test func pathTransitionsUseIntervalMajorityAndIgnoreEmptyOrInvalidSamples() {
        var tracker = RendererPathTracker()
        #expect(tracker.observe(values(100, optimized: 51), now: 0) == nil)
        #expect(tracker.observe(values(0), now: 1) == nil)
        #expect(tracker.observe(values(10, optimized: 11), now: 2) == nil)
        #expect(tracker.observe(values(100, optimized: 50), now: .nan) == nil)
        let composited = tracker.observe(values(100, optimized: 50), now: 3)
        #expect(composited == RendererPathTransition(
            fromOptimized: true, toOptimized: false, frames: 100, optimized: 50, suppressed: 0))
        #expect(tracker.observe(values(100, optimized: 0), now: 9) == nil)
        let optimized = tracker.observe(values(3, optimized: 2), now: 10)
        #expect(optimized?.summary == "composited->optimized frames=3 optimized=2 suppressed=0")
    }

    @Test func pathFlappingIsThrottledAndReportsSuppressedFlipsWithActualDirection() {
        var tracker = RendererPathTracker()
        #expect(tracker.observe(values(100, optimized: 100), now: 0) == nil)
        #expect(tracker.observe(values(100), now: 1)?.suppressed == 0)
        #expect(tracker.observe(values(100, optimized: 100), now: 2) == nil)
        #expect(tracker.observe(values(100), now: 3) == nil)
        #expect(tracker.observe(values(100, optimized: 100), now: 5.999) == nil)
        let transition = tracker.observe(values(100), now: 6)
        #expect(transition?.fromOptimized == true)
        #expect(transition?.toOptimized == false)
        #expect(transition?.suppressed == 3)
        #expect(tracker.observe(values(100), now: 20) == nil)
        #expect(tracker.observe(values(100, optimized: 100), now: 21)?.suppressed == 0)
    }

    @Test func rebaselineDoesNotInventTransitionsOrBypassThrottle() {
        var tracker = RendererPathTracker()
        #expect(tracker.observe(values(10, optimized: 10), now: 0) == nil)
        #expect(tracker.observe(values(10), now: 1) != nil)
        tracker.rebaseline()
        #expect(tracker.observe(values(10, optimized: 10), now: 2) == nil)
        #expect(tracker.observe(values(10), now: 3) == nil)
        #expect(tracker.observe(values(10, optimized: 10), now: 6)?.suppressed == 1)
    }

    @Test func completedSamplesReportTransitionsBeforeTheNextExporterTick() {
        let queue = DispatchQueue(label: "renderer-transition-test")
        let probe = Probe()
        let sampler = RendererTelemetry(queue: queue, probe: { probe.source() })
        for counts in [(100, 100), (200, 200), (300, 200)] {
            _ = queue.sync { sampler.sample() }
            probe.complete(values(UInt64(counts.0), optimized: UInt64(counts.1)))
            queue.sync {}
        }
        let transitions = probe.state.withLock { $0.transitions }
        #expect(transitions.count == 1)
        #expect(transitions.first?.summary == "optimized->composited frames=100 optimized=0 suppressed=0")
        _ = queue.sync { sampler.sample() }
        queue.sync { sampler.stop() }
        probe.complete(values(400, optimized: 300))
        queue.sync {}
        #expect(probe.state.withLock { $0.transitions } == transitions)
    }

    @MainActor @Test func rendererSnapshotIncludesVisibleOverlayTreeAndPublicSafeLayerState() {
        let stream = StreamWindow()
        let video = stream.displayLayer
        let overlay = CALayer()
        overlay.name = "Private PC name"
        overlay.opacity = 0.75
        let child = CALayer()
        overlay.addSublayer(child)
        let hidden = CALayer()
        hidden.isHidden = true
        hidden.addSublayer(CALayer())
        video.addSublayer(overlay)
        video.addSublayer(hidden)
        overlay.add(CABasicAnimation(keyPath: "opacity"), forKey: "Private animation name")
        let root = CALayer()
        root.addSublayer(video)
        let above = CALayer()
        above.zPosition = 1
        root.insertSublayer(above, at: 0)
        let below = CALayer()
        below.zPosition = -1
        root.addSublayer(below)
        video.mask = CALayer()
        video.cornerRadius = 4
        video.transform = CATransform3DMakeTranslation(2, 0, 0)
        let overlays = stream.rendererVisibleOverlays()
        #expect(overlays.count == 3)
        #expect(overlays.contains { $0.contains("opacity=0.75,hidden=false,animated=true") })
        #expect(overlays.contains { $0.hasPrefix("ancestor0/0:") })
        let snapshot = stream.rendererDiagnosticSnapshot(hdrInput: false)
        for field in ["level=", "occlusion=", "key=", "fullscreen=borderless", "cursorVisible=true",
                      "cursorSource=owned", "mask=CALayer", "cornerRadius=4.0", "transform=[",
                      "filters=[]", "currentEDR=", "hdrInput=false", "hdrOutput=false", "displayID="] {
            #expect(snapshot.contains(field), "Missing \(field)")
        }
        #expect(!snapshot.contains("Private"))
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
