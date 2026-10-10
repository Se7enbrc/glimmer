//
//  StatsSupportTypesTests.swift
//  Overlay presets and corners, stream history, trace metrics, resource labels, display samples.
//

import Darwin
import Foundation
import Testing
@testable import Glimmer

@MainActor @Suite(.serialized)
struct StatsSupportTypesTests {

    // MARK: - Presets

    @Test func presetRowSetsNestAndExtendedLeavesOutTheMacRows() {
        #expect(StatsOverlayDefaults.minimalRows.isSubset(of: StatsOverlayDefaults.microRows))
        #expect(StatsOverlayDefaults.microRows.isSubset(of: StatsOverlayDefaults.extendedRows))
        #expect(StatsOverlayDefaults.initialCustomRows == StatsOverlayDefaults.microRows)
        #expect(StatsOverlayDefaults.minimalRows == [.renderFps, .latency, .bitrate, .codec])
        let excluded: Set<StatsRow.Kind> = [.audio, .macBattery, .macCpu, .macRam]
        #expect(StatsOverlayDefaults.extendedRows == Set(StatsRow.Kind.allCases).subtracting(excluded))
    }

    @Test func presetAndCornerNamesAreWhatThePickersShow() {
        let presets = StatsOverlayPreset.allCases.map(\.displayName)
        #expect(presets == ["Minimal", "Standard", "Extended", "Custom"])
        let corners = StatsOverlayCorner.allCases.map(\.displayName)
        #expect(corners == ["Top left", "Top center", "Top right",
                            "Bottom left", "Bottom center", "Bottom right"])
    }

    @Test func thresholdsDefaultToTheDocumentedBands() {
        let defaults = StatsThresholds.default
        #expect(defaults.fpsWarningBelow == 0)
        #expect(defaults.fpsCriticalBelow == 0)
        #expect(defaults.latencyWarningAbove == 50)
        #expect(defaults.latencyCriticalAbove == 100)
        #expect(defaults.jitterWarningAbove == 10)
        #expect(defaults.jitterCriticalAbove == 25)
        #expect(defaults.dropsWarningAbove == 0.5)
        #expect(defaults.dropsCriticalAbove == 2.0)
        #expect(defaults == StatsThresholds())
    }

    // MARK: - Stream history

    @Test func historyKeepsTheNewest60SamplesAndTurnsMissingReadingsIntoZero() {
        let history = StreamHistory()
        history.append(mbps: nil, fps: nil, rttMs: nil)
        #expect(history.mbps == [0])
        #expect(history.fps == [0])
        #expect(history.rttMs == [0])
        for index in 1...70 { history.append(mbps: Double(index), fps: Double(index * 2), rttMs: 1) }
        #expect(history.mbps.count == StreamHistory.capacity)
        #expect(history.mbps.first == 11)
        #expect(history.mbps.last == 70)
        #expect(history.fps.first == 22)
        #expect(history.rttMs.count == 60)
        history.reset()
        #expect(history.mbps.isEmpty && history.fps.isEmpty && history.rttMs.isEmpty)
    }

    @Test func historyFeedRecordsEveryFourthTick() {
        let shared = StreamHistory.shared
        shared.reset()
        defer { shared.reset() }
        let feed = StreamHistoryFeed()
        for tick in 1...9 { feed.tick(mbps: Double(tick), fps: 60, rttMs: 3) }
        #expect(shared.mbps == [4, 8])
        #expect(shared.fps == [60, 60])
    }

    // MARK: - Trace metrics

    @Test func eachRowKindMapsToItsTraceMetricAndTextRowsHaveNone() {
        #expect(StatsTrace.Metric(kind: .renderFps) == .render)
        #expect(StatsTrace.Metric(kind: .hostFps) == .host)
        #expect(StatsTrace.Metric(kind: .networkFps) == .network)
        #expect(StatsTrace.Metric(kind: .latency) == .latency)
        #expect(StatsTrace.Metric(kind: .bitrate) == .bitrate)
        #expect(StatsTrace.Metric(kind: .jitter) == .jitter)
        #expect(StatsTrace.Metric(kind: .networkDrops) == .drops)
        for kind in [StatsRow.Kind.decodeFps, .decoderDrops, .codec, .audio, .macCpu, .smoothness] {
            #expect(StatsTrace.Metric(kind: kind) == nil)
        }
        #expect(StatsTrace.Metric.render.judgesDrops)
        #expect(!StatsTrace.Metric.latency.judgesDrops)
        #expect(!StatsTrace.Metric.drops.judgesDrops)
    }

    @Test func metricsReadTheirOwnSnapshotField() {
        var snap = StreamStatsSnapshot()
        snap.hostFps = 120
        snap.receivedFps = 59
        snap.rttMs = 4
        snap.measuredBitrateMbps = 50
        snap.jitterMs = 1
        snap.networkDroppedPercent = 0.2
        #expect(StatsTrace.Metric.render.value(in: snap) == 120)
        snap.renderedFps = 58
        #expect(StatsTrace.Metric.render.value(in: snap) == 58)
        #expect(StatsTrace.Metric.host.value(in: snap) == 120)
        #expect(StatsTrace.Metric.network.value(in: snap) == 59)
        #expect(StatsTrace.Metric.latency.value(in: snap) == 4)
        #expect(StatsTrace.Metric.bitrate.value(in: snap) == 50)
        #expect(StatsTrace.Metric.jitter.value(in: snap) == 1)
        #expect(StatsTrace.Metric.drops.value(in: snap) == 0.2)
    }

    @Test func rateMetricsFlagAHalfAndThreeTenthsDipFromTheirReference() {
        let thresholds = StatsThresholds.default
        let metric = StatsTrace.Metric.render
        #expect(metric.severity(value: 60, reference: 60, thresholds: thresholds) == .none)
        #expect(metric.severity(value: 29, reference: 60, thresholds: thresholds) == .caution)
        #expect(metric.severity(value: 30, reference: 60, thresholds: thresholds) == .none)
        #expect(metric.severity(value: 17, reference: 60, thresholds: thresholds) == .critical)
        #expect(metric.severity(value: 5, reference: nil, thresholds: thresholds) == .none)
        #expect(metric.severity(value: 5, reference: 0, thresholds: thresholds) == .none)
        #expect(metric.severity(value: -1, reference: 60, thresholds: thresholds) == .none)
        #expect(metric.severity(value: nil, reference: 60, thresholds: thresholds) == .none)
        #expect(metric.severity(value: .nan, reference: 60, thresholds: thresholds) == .none)
    }

    @Test func latencyUsesTheThresholdsThenAJumpOverItsOwnAverage() {
        let thresholds = StatsThresholds.default
        let metric = StatsTrace.Metric.latency
        #expect(metric.severity(value: 120, reference: nil, thresholds: thresholds) == .critical)
        #expect(metric.severity(value: 60, reference: nil, thresholds: thresholds) == .caution)
        #expect(metric.severity(value: 20, reference: nil, thresholds: thresholds) == .none)
        // Under the warning line, a jump past max(ref + 3, ref * 1.8) still shows.
        #expect(metric.severity(value: 12, reference: 5, thresholds: thresholds) == .caution)
        #expect(metric.severity(value: 8, reference: 5, thresholds: thresholds) == .none)
        #expect(metric.severity(value: 20, reference: 10, thresholds: thresholds) == .caution)
        #expect(metric.severity(value: 18, reference: 10, thresholds: thresholds) == .none)
    }

    @Test func jitterAndDropMetricsFollowTheirThresholdBands() {
        let thresholds = StatsThresholds.default
        #expect(StatsTrace.Metric.jitter.severity(value: 10, reference: nil, thresholds: thresholds) == .none)
        #expect(StatsTrace.Metric.jitter.severity(value: 11, reference: nil, thresholds: thresholds) == .caution)
        #expect(StatsTrace.Metric.jitter.severity(value: 26, reference: nil, thresholds: thresholds) == .critical)
        #expect(StatsTrace.Metric.drops.severity(value: 0.5, reference: nil, thresholds: thresholds) == .none)
        #expect(StatsTrace.Metric.drops.severity(value: 1, reference: nil, thresholds: thresholds) == .caution)
        #expect(StatsTrace.Metric.drops.severity(value: 3, reference: nil, thresholds: thresholds) == .critical)
    }

    @Test func rowBandsGiveCoreRowsTheBigValueAndTextRowsNoTrace() {
        #expect(StatsOverlayLayer.rowBands(for: .renderFps) == (54, 24, 17))
        #expect(StatsOverlayLayer.rowBands(for: .networkFps) == (46, 19, 14))
        #expect(StatsOverlayLayer.rowBands(for: .codec) == (32, 19, 0))
    }

    // MARK: - Resource labels

    @Test func qosClassesGetStableLabelsAndOnlyTheTopTwoCountAsHigh() {
        let cases: [(qos_class_t, String, Bool)] = [
            (QOS_CLASS_USER_INTERACTIVE, "userInteractive", true),
            (QOS_CLASS_USER_INITIATED, "userInitiated", true),
            (QOS_CLASS_DEFAULT, "default", false),
            (QOS_CLASS_UTILITY, "utility", false),
            (QOS_CLASS_BACKGROUND, "background", false),
            (QOS_CLASS_UNSPECIFIED, "unspecified", false)
        ]
        for (qos, label, high) in cases {
            #expect(ResourceTelemetry.qosLabel(Int(qos.rawValue)) == label)
            #expect(ResourceTelemetry.isHighQoS(Int(qos.rawValue)) == high)
        }
        #expect(ResourceTelemetry.qosLabel(0x7F) == "unspecified")
    }

    @Test func unnamedThreadsAreLabelledUnnamed() {
        let snapshot = ResourceSnapshot()
        let blank = ThreadResourceSample(name: "", tid: 1, cpuPercent: 1, qos: 0, qosLabel: "unspecified")
        let named = ThreadResourceSample(name: "decode", tid: 2, cpuPercent: 1, qos: 0, qosLabel: "unspecified")
        #expect(snapshot.threadLabel(blank) == "unnamed")
        #expect(snapshot.threadLabel(named) == "decode")
    }

    // MARK: - Display samples

    @Test func displayTelemetryReportsNoEdrFiguresBeforeAnySample() {
        let probe = DisplayProbe(edrHeadroom: 2, hdrEngaged: true, screenName: "Built-in",
                                 proMotionCapable: true, maxRefreshHz: 120)
        let display = DisplayTelemetry(probe: { probe })
        let snap = display.snapshotAndReset()
        #expect(snap.edrHeadroomMin == nil)
        #expect(snap.edrHeadroomAvg == nil)
        #expect(snap.edrHeadroomMax == nil)
        #expect(snap.state == nil)
    }
}
