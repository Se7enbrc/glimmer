// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StatsSnapshotRowsTests.swift
//  The stats rows a snapshot builds: order, text, symbols, sections and health.
//

import Foundation
import Testing
@testable import Glimmer

struct StatsSnapshotRowsTests {
    private let dash = "\u{2014}"

    private struct ExpectedRow {
        let kind: StatsRow.Kind
        let label: String
        let symbol: String?
        let section: StatsRow.Section
    }

    private func row(_ kind: StatsRow.Kind, _ snap: StreamStatsSnapshot, target: Double = 60,
                     thresholds: StatsThresholds = .default) throws -> StatsRow {
        try #require(snap.rows(enabled: [kind], targetFps: target, thresholds: thresholds).first)
    }

    @Test func rowsFollowTheFixedPlanAndSkipDisabledKinds() {
        let snap = StreamStatsSnapshot()
        let all = snap.rows(enabled: Set(StatsRow.Kind.allCases), targetFps: 60).map(\.kind)
        #expect(all == [.hostFps, .networkFps, .decodeFps, .renderFps, .latency, .jitter, .networkDrops,
                        .decoderDrops, .smoothness, .decodeTime, .bitrate, .hostProcessing,
                        .macCpu, .macRam, .macBattery, .controllerBattery, .codec, .audio])
        #expect(snap.rows(enabled: [.audio, .codec], targetFps: 60).map(\.kind) == [.codec, .audio])
        #expect(snap.rows(enabled: [], targetFps: 60).isEmpty)
    }

    @Test func everyKindLandsInItsSectionWithItsLabelAndSymbol() throws {
        let expected: [ExpectedRow] = [
            ExpectedRow(kind: .hostFps, label: "PC",
                        symbol: "display", section: .frameRates),
            ExpectedRow(kind: .networkFps, label: "Network",
                        symbol: "network", section: .frameRates),
            ExpectedRow(kind: .decodeFps, label: "Decode",
                        symbol: "cpu", section: .frameRates),
            ExpectedRow(kind: .renderFps, label: "Render",
                        symbol: "display", section: .frameRates),
            ExpectedRow(kind: .latency, label: "Latency",
                        symbol: "bolt.horizontal", section: .network),
            ExpectedRow(kind: .jitter, label: "Jitter",
                        symbol: "waveform.path.ecg", section: .network),
            ExpectedRow(kind: .networkDrops, label: "Drop rate",
                        symbol: "arrow.down.right", section: .network),
            ExpectedRow(kind: .decoderDrops, label: "Drops",
                        symbol: "exclamationmark.triangle", section: .pipeline),
            ExpectedRow(kind: .smoothness, label: "Smoothness",
                        symbol: "metronome", section: .pipeline),
            ExpectedRow(kind: .decodeTime, label: "Decode time",
                        symbol: "clock", section: .pipeline),
            ExpectedRow(kind: .bitrate, label: "Bitrate",
                        symbol: "gauge.with.dots.needle.bottom.50percent", section: .pipeline),
            ExpectedRow(kind: .hostProcessing, label: "PC encode",
                        symbol: "cpu.fill", section: .pipeline),
            ExpectedRow(kind: .macCpu, label: "Mac CPU",
                        symbol: "cpu", section: .mac),
            ExpectedRow(kind: .macRam, label: "Mac RAM",
                        symbol: "memorychip", section: .mac),
            ExpectedRow(kind: .macBattery, label: "Mac battery",
                        symbol: nil, section: .mac),
            ExpectedRow(kind: .controllerBattery, label: "Controller",
                        symbol: "gamecontroller", section: .mac),
            ExpectedRow(kind: .codec, label: "Codec",
                        symbol: "film", section: .config),
            ExpectedRow(kind: .audio, label: "Audio",
                        symbol: "speaker.wave.2", section: .config)
        ]
        for item in expected {
            let built = try row(item.kind, StreamStatsSnapshot())
            #expect(built.label == item.label)
            #expect(built.symbolName == item.symbol)
            #expect(built.section == item.section)
        }
        #expect(StatsRow.Section.frameRates < .config)
    }

    @Test func missingReadingsShowADashAndStayNeutral() throws {
        let snap = StreamStatsSnapshot()
        for kind in StatsRow.Kind.allCases where kind != .codec {
            let built = try row(kind, snap)
            #expect(built.value == dash, "\(kind)")
            #expect(built.health == .neutral, "\(kind)")
        }
        #expect(try row(.codec, snap).value == "-")
    }

    @Test func frameRateRowsFormatOneDecimalAndRenderPrefersTheHostRate() throws {
        var snap = StreamStatsSnapshot()
        snap.hostFps = 119.95
        snap.receivedFps = 59.94
        snap.decodedFps = 60
        snap.renderedFps = 58.04
        #expect(try row(.networkFps, snap).value == "59.9 FPS")
        #expect(try row(.decodeFps, snap).value == "60.0 FPS")
        #expect(try row(.hostFps, snap).value == "120.0 FPS")
        #expect(try row(.renderFps, snap).value == "120.0 FPS")
        snap.hostFps = nil
        #expect(try row(.renderFps, snap).value == "58.0 FPS")
    }

    @Test func frameRateHealthIsNeutralUntilAFloorIsConfigured() throws {
        var snap = StreamStatsSnapshot()
        snap.receivedFps = 25
        #expect(try row(.networkFps, snap).health == .neutral)
        let floors = StatsThresholds(fpsWarningBelow: 50, fpsCriticalBelow: 30)
        #expect(try row(.networkFps, snap, thresholds: floors).health == .critical)
        snap.receivedFps = 45
        #expect(try row(.networkFps, snap, thresholds: floors).health == .warning)
        snap.receivedFps = 50
        #expect(try row(.networkFps, snap, thresholds: floors).health == .healthy)
        #expect(try row(.hostFps, snap, thresholds: floors).health == .neutral)
    }

    @Test func latencyShowsRttWithJitterFallingBackToRttVariance() throws {
        var snap = StreamStatsSnapshot()
        snap.rttMs = 12.5
        #expect(try row(.latency, snap).value == "12.50 ms")
        snap.rttVarianceMs = 1.25
        #expect(try row(.latency, snap).value == "12.50 ms \u{00B1}1.25")
        snap.jitterMs = 0.5
        #expect(try row(.latency, snap).value == "12.50 ms \u{00B1}0.50")
        #expect(try row(.jitter, snap).value == "0.50 ms")
        snap.jitterMs = nil
        #expect(try row(.jitter, snap).value == "1.25 ms")
    }

    @Test(arguments: [(50.0, StatsRow.Health.healthy), (50.5, .warning), (100.0, .warning), (100.5, .critical)])
    func latencyHealthCrossesAtTheConfiguredThresholds(rtt: Double, expected: StatsRow.Health) throws {
        var snap = StreamStatsSnapshot()
        snap.rttMs = rtt
        #expect(try row(.latency, snap).health == expected)
    }

    @Test(arguments: [(10.0, StatsRow.Health.healthy), (10.5, .warning), (25.0, .warning), (26.0, .critical)])
    func jitterHealthCrossesAtTheConfiguredThresholds(jitter: Double, expected: StatsRow.Health) throws {
        var snap = StreamStatsSnapshot()
        snap.jitterMs = jitter
        #expect(try row(.jitter, snap).health == expected)
    }

    @Test(arguments: [(0.5, StatsRow.Health.healthy), (0.75, .warning), (2.0, .warning), (2.5, .critical)])
    func dropRateHealthCrossesAtTheConfiguredThresholds(percent: Double, expected: StatsRow.Health) throws {
        var snap = StreamStatsSnapshot()
        snap.networkDroppedPercent = percent
        snap.decoderDroppedPercent = percent
        #expect(try row(.networkDrops, snap).health == expected)
        #expect(try row(.decoderDrops, snap).health == expected)
        #expect(try row(.networkDrops, snap).value == String(format: "%.2f %%", percent))
    }

    @Test func decoderDropsBreakDownByCauseOnlyWhenAnyOccurred() throws {
        var snap = StreamStatsSnapshot()
        snap.decoderDroppedPercent = 0.25
        #expect(try row(.decoderDrops, snap).value == "0.25 %")
        snap.decoderDropCount = 3
        snap.rendererBackpressureDrops = 2
        snap.presentationLateDrops = 1
        #expect(try row(.decoderDrops, snap).value == "0.25 % \u{00B7} 3D/2B/1L")
        snap.decoderDropCount = 0
        snap.rendererBackpressureDrops = 0
        snap.presentationLateDrops = 4
        #expect(try row(.decoderDrops, snap).value == "0.25 % \u{00B7} 0D/0B/4L")
    }

    @Test func decodeTimeShowsTheServiceAndWaitSplitOnlyForARealWait() throws {
        var snap = StreamStatsSnapshot()
        snap.avgDecodeTimeMs = 4
        #expect(try row(.decodeTime, snap).value == "4.00 ms")
        snap.avgDecodeServiceMs = 3
        snap.avgDecodeWaitMs = 0.04
        #expect(try row(.decodeTime, snap).value == "4.00 ms")
        snap.avgDecodeWaitMs = 1
        #expect(try row(.decodeTime, snap).value == "4.00 ms \u{00B7} 3.00 + 1.00 wait")
    }

    @Test func decodeTimeIsCriticalOnlyPastOneFrameBudget() {
        #expect(StreamStatsSnapshot.decodeTimeHealth(16.66, targetFps: 60) == .healthy)
        #expect(StreamStatsSnapshot.decodeTimeHealth(16.67, targetFps: 60) == .critical)
        #expect(StreamStatsSnapshot.decodeTimeHealth(nil, targetFps: 60) == .neutral)
        #expect(StreamStatsSnapshot.decodeTimeHealth(5, targetFps: 0) == .neutral)
    }

    @Test func hostProcessingShowsMinMaxAndAverageTogether() throws {
        var snap = StreamStatsSnapshot()
        snap.minHostProcessingLatencyMs = 2.5
        snap.maxHostProcessingLatencyMs = 12
        #expect(try row(.hostProcessing, snap).value == dash)
        snap.avgHostProcessingLatencyMs = 7.25
        #expect(try row(.hostProcessing, snap).value == "2.5 / 12.0 / 7.2 ms")
    }

    @Test func smoothnessAppendsQueueDepthAndLateDropsAndJudgesAgainstTheFrameBudget() throws {
        var snap = StreamStatsSnapshot()
        snap.avgPresentCadenceErrorMs = 1.5
        #expect(try row(.smoothness, snap).value == dash)
        snap.onTimePresentPercent = 98.4
        #expect(try row(.smoothness, snap).value == "1.5 ms \u{00B7} 98%")
        snap.pacingQueueDepth = 2
        snap.presentationLateDrops = 0
        #expect(try row(.smoothness, snap).value == "1.5 ms \u{00B7} 98% (d2)")
        snap.presentationLateDrops = 3
        #expect(try row(.smoothness, snap).value == "1.5 ms \u{00B7} 98% (d2) +3 late")
        // Frame budget at 60 fps is 16.67 ms: warning past a quarter, critical past a half.
        #expect(try row(.smoothness, snap).health == .healthy)
        snap.avgPresentCadenceErrorMs = 4.2
        #expect(try row(.smoothness, snap).health == .warning)
        snap.avgPresentCadenceErrorMs = 8.4
        #expect(try row(.smoothness, snap).health == .critical)
        #expect(try row(.smoothness, snap, target: 0).health == .neutral)
    }

    @Test func bitrateShowsMeasuredAndNegotiatedInEveryCombination() throws {
        var snap = StreamStatsSnapshot()
        snap.negotiatedBitrateMbps = 80
        #expect(try row(.bitrate, snap).value == "\u{2014} / 80 Mbps")
        snap.measuredBitrateMbps = 42.31
        #expect(try row(.bitrate, snap).value == "42.3 / 80 Mbps")
        snap.negotiatedBitrateMbps = nil
        #expect(try row(.bitrate, snap).value == "42.3 Mbps")
    }

    @Test func macRowsFormatPercentagesAndBatteryState() throws {
        var snap = StreamStatsSnapshot()
        snap.macCpuPercent = 12.5
        snap.macRamPercent = 61.234
        #expect(try row(.macCpu, snap).value == "12.50 %")
        #expect(try row(.macRam, snap).value == "61.23 %")
        snap.macBatteryPercent = 80
        #expect(try row(.macBattery, snap).value == "80 %")
        snap.macBatteryCharging = true
        #expect(try row(.macBattery, snap).value == "80 % \u{00B7} Charging")
        snap.macBatteryCharging = false
        #expect(try row(.macBattery, snap).value == "80 % \u{00B7} On battery")
        snap.controllerBatteryPercent = 15
        snap.controllerBatteryCharging = true
        #expect(try row(.controllerBattery, snap).value == "15 % \u{00B7} Charging")
    }

    @Test(arguments: [(0, "battery.0"), (9, "battery.0"), (10, "battery.25"), (34, "battery.25"),
                      (35, "battery.50"), (59, "battery.50"), (60, "battery.75"), (84, "battery.75"),
                      (85, "battery.100"), (100, "battery.100")])
    func batterySymbolStepsWithTheCharge(percent: Int, symbol: String) throws {
        var snap = StreamStatsSnapshot()
        snap.macBatteryPercent = percent
        snap.macBatteryCharging = false
        #expect(try row(.macBattery, snap).symbolName == symbol)
        snap.macBatteryCharging = true
        #expect(try row(.macBattery, snap).symbolName == "battery.100.bolt")
    }

    @Test func codecAndAudioShowTheirDescriptions() throws {
        var snap = StreamStatsSnapshot()
        snap.videoCodec = "HEVC"
        snap.audioConfigDescription = "5.1 Opus"
        #expect(try row(.codec, snap).value == "HEVC")
        #expect(try row(.audio, snap).value == "5.1 Opus")
    }
}
