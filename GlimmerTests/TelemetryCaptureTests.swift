// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryCaptureTests.swift
//  The 1 Hz capture driven by a scripted source and private counters, into a temp directory.
//

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

// Serialized: the capture's cross-tick baselines are one static slot. A class, so each
// test's scratch directory is removed in deinit whether the test passed or not.
@Suite(.serialized)
final class TelemetryCaptureTests {

    private static let pcName = "Den PC"
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func stats() -> StreamStatsSnapshot {
        var stats = StreamStatsSnapshot()
        stats.receivedFps = 120
        stats.decodedFps = 119
        stats.renderedFps = 100
        stats.avgDecodeTimeMs = 3.5
        stats.avgDecodeServiceMs = 3
        stats.avgDecodeWaitMs = 0.5
        stats.avgPresentCadenceErrorMs = 1.25
        stats.onTimePresentPercent = 90
        stats.hostCadence = StatsCollector.HostCadence(
            intervalP50Ms: 8.25, intervalP95Ms: 9.5, unevenPairs: 3, lateByHostPercent: 4)
        stats.measuredBitrateMbps = 80
        stats.negotiatedBitrateMbps = 100
        stats.minHostProcessingLatencyMs = 2
        stats.avgHostProcessingLatencyMs = 4
        stats.maxHostProcessingLatencyMs = 9
        stats.avgFrameBytes = 41_000
        stats.maxFrameBytes = 190_000
        stats.idrFramePercent = 1.5
        return stats
    }

    private func pacing() -> FramePacer.LivenessSnapshot {
        FramePacer.LivenessSnapshot(
            secondsSinceLastTick: 0.004, secondsSinceLastRelease: 0.004, depth: 2,
            secondsQueueNonEmpty: 0, running: true, totalTicks: 5000,
            totalReleases: 4000, streamFrameIntervalSeconds: 1.0 / 120, adaptiveTargetDepth: 1,
            recentTicksPerSecond: 120, recentReleasesPerSecond: 120, tickDeficitSeconds: 0,
            expectedTickHz: 120, tickDeficitModeActive: false, presentRejectStreak: 0,
            rendererRefusalSeconds: 0, secondsSinceLastReject: .infinity)
    }

    private func source() -> TelemetrySource {
        let stats = stats()
        let pacing = pacing()
        return TelemetrySource(
            videoStats: { stats }, decoderDrops: { 7 }, backpressureDrops: { 8 },
            presentationLateDrops: { 9 }, presentationGaps: { 10 },
            estimatedRtt: { (rttMs: 5.5, varianceMs: 0.75) },
            enetHealth: { (sentReliable: 3, oldestUnackedMs: 12, sinceLastAckMs: 4) },
            pacingLiveness: { pacing }, inFlightDecodeBacklog: { 4 },
            refreshWindow: { FramePacer.RefreshWindowSnapshot(minHz: 59.5, avgHz: 60, maxHz: 120, changed: true) },
            displayProbe: { nil }, displayMode: "window",
            stream: StreamTelemetryConfig(width: 2560, height: 1440, fps: 120, codec: "HEVC", bitrate: nil),
            capture: MacTelemetryCapture.make())
    }

    private func exporter(in dir: URL, counters: TelemetryCounters = TelemetryCounters()) -> TelemetryExporter {
        TelemetryExporter.captureBaselines = TelemetryExporter.CaptureBaselines()
        return TelemetryExporter(source: source(), serverName: Self.pcName, outputDirectory: dir, counters: counters)
    }

    private func capture(
        _ exporter: TelemetryExporter, now: DispatchTime = .now()
    ) throws -> (TelemetrySnapshot, TelemetrySnapshot.Extras) {
        exporter.workQueue.sync { exporter.capture(now: now) }
    }

    // MARK: - Seam

    @Test func publicSessionRecordingRequiresOptInAndLocalDirectory() throws {
        let source = source()
        let remote = try #require(URL(string: "https://example.invalid/diagnostics"))
        for services in [SessionServices.recording(directory: dir, enabled: false),
                         SessionServices.recording(directory: nil, enabled: true),
                         SessionServices.recording(directory: remote, enabled: true)] {
            #expect(services.makeExporter(source, Self.pcName) == nil)
        }
        let services = SessionServices.recording(directory: dir, enabled: true)
        let exporter = try #require(services.makeExporter(source, Self.pcName))
        #expect(exporter.outputDirectory == dir)
        #expect(exporter.ndjsonURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func gatedConstructionKeepsProductionDirectoryAndCounters() throws {
        let made = TelemetryExporter.makeIfEnabled(source: source(), serverName: Self.pcName,
                                                   outputDirectory: MacTelemetryCapture.logsDirectory, enabled: true)
        let exporter = try #require(made)
        #expect(exporter.outputDirectory == MacTelemetryCapture.logsDirectory)
        #expect(exporter.counters === TelemetryCounters.shared)
        #expect(exporter.ndjsonURL == nil)
    }

    // MARK: - Source-driven sections

    @Test func captureCopiesTheScriptedSourceIntoTheSnapshot() throws {
        let exporter = exporter(in: dir)
        let (snap, _) = try capture(exporter)
        #expect(snap.sessionId == exporter.sessionId)
        #expect(snap.receivedFps == 120 && snap.decodedFps == 119 && snap.renderedFps == 100)
        #expect(snap.decodeEmaMs == 3.5 && snap.decodeServiceMs == 3 && snap.decodeWaitMs == 0.5)
        #expect(snap.presentCadenceErrorMs == 1.25 && snap.presentOnTimePercent == 90)
        #expect(snap.presentOnTimeCount == 90 && snap.presentLateCount == 10)
        #expect(snap.presentLateHostCadenceCount == 4)
        #expect(snap.hostFrameIntervalP50Ms == 8.25 && snap.hostFrameIntervalP95Ms == 9.5)
        #expect(snap.hostUnevenPairs == 3)
        #expect(snap.rttMs == 5.5 && snap.rttVarianceMs == 0.75)
        #expect(snap.goodputMbps == 80 && snap.negotiatedBitrateMbps == 100 && snap.goodputUtilization == 0.8)
        #expect(snap.enetSentReliable == 3 && snap.enetOldestUnackedMs == 12 && snap.enetSinceLastAckMs == 4)
        #expect(snap.pacingQueueDepth == 2 && snap.pacingAdaptiveTargetDepth == 1)
        #expect(snap.inFlightDecodeBacklog == 4)
        #expect(snap.dropsDecoder == 7 && snap.dropsBackpressure == 8)
        #expect(snap.dropsPresentationLate == 9 && snap.presentationGaps == 10)
        #expect(snap.refreshMinHz == 59.5 && snap.refreshAvgHz == 60 && snap.refreshMaxHz == 120)
        #expect(snap.refreshChanged)
        #expect(snap.hostEncodeLatencyMinMs == 2 && snap.hostEncodeLatencyAvgMs == 4)
        #expect(snap.hostEncodeLatencyMaxMs == 9)
        #expect(snap.avgFrameBytes == 41_000 && snap.maxFrameBytes == 190_000 && snap.idrFramePercent == 1.5)
        #expect(snap.buildCommit == BuildInfo.commit && snap.buildDate == BuildInfo.date)
    }

    @Test func aGonePacerReportsZeroDepthNotAStaleValue() throws {
        TelemetryExporter.captureBaselines = TelemetryExporter.CaptureBaselines()
        var scripted = source()
        scripted.pacingLiveness = { nil }
        let exporter = TelemetryExporter(
            source: scripted, serverName: Self.pcName, outputDirectory: dir, counters: TelemetryCounters())
        let (snap, extras) = try capture(exporter)
        #expect(snap.pacingQueueDepth == 0 && snap.pacingAdaptiveTargetDepth == 0)
        #expect(extras.pacerTicksPerSecond == nil)
    }

    // MARK: - Counter-driven sections

    @Test func firstTickCarriesTotalsAndNoRates() throws {
        let counters = TelemetryCounters()
        counters.videoPacketsTotal.increment(by: 1000)
        counters.rfiTotal.increment(by: 2)
        counters.reconnectTotal.increment(by: 3)
        counters.corruptionHeuristicTotal.increment(by: 5)
        counters.audioPacketsTotal.increment(by: 50)
        let (snap, _) = try capture(exporter(in: dir, counters: counters))
        #expect(snap.rfiTotal == 2 && snap.reconnectTotal == 3 && snap.corruptionTotal == 5)
        #expect(snap.preFecLossRate == nil && snap.outOfOrderRate == nil && snap.fecRecoveryRate == nil)
        #expect(snap.corruptionPerSecond == nil)
        let audio = try #require(snap.audio)
        #expect(audio.packetsTotal == 50 && audio.lossRate == nil)
    }

    @Test func secondTickDerivesRatesFromTheDeltas() throws {
        let counters = TelemetryCounters()
        counters.videoPacketsTotal.increment(by: 1000)
        counters.audioPacketsTotal.increment(by: 50)
        let exporter = exporter(in: dir, counters: counters)
        let start = exporter.connectInstant
        _ = try capture(exporter, now: start)
        counters.videoPacketsTotal.increment(by: 900)
        counters.videoPacketsLostPreFecTotal.increment(by: 100)
        counters.videoPacketsOutOfOrderTotal.increment(by: 45)
        counters.videoPacketsDuplicateTotal.increment(by: 9)
        counters.videoFramesTotal.increment(by: 50)
        counters.fecRecoveredFramesTotal.increment(by: 5)
        counters.audioPacketsTotal.increment(by: 95)
        counters.audioPacketsLostTotal.increment(by: 5)
        counters.audioFecRecoveredTotal.increment(by: 3)
        counters.corruptionHeuristicTotal.increment(by: 4)
        let (snap, _) = try capture(exporter, now: start + .milliseconds(80))
        #expect(snap.preFecLossRate == 100.0 / 1000.0)
        #expect(snap.outOfOrderRate == 45.0 / 900.0)
        #expect(snap.duplicateRate == 9.0 / 900.0)
        #expect(snap.fecRecoveryRate == 5.0 / 50.0)
        #expect(snap.corruptionPerSecond == 50)
        let audio = try #require(snap.audio)
        #expect(audio.packetsTotal == 145)
        #expect(audio.lossRate == 5.0 / 100.0)
        #expect(audio.fecRecoveryRate == 3.0 / 98.0)
    }

    @Test func videoOnlyTickLeavesTheAudioBlockOut() throws {
        let (snap, _) = try capture(exporter(in: dir))
        #expect(snap.audio == nil)
        #expect(snap.handshake == nil)
        #expect(snap.idrRoundTrip == nil)
    }

    @Test func idrRoundTripAttachesOnceARequestIsArmed() throws {
        let counters = TelemetryCounters()
        counters.idrRoundTripRequestTotal.increment(by: 4)
        counters.idrRoundTripMatchedTotal.increment(by: 3)
        let (snap, _) = try capture(exporter(in: dir, counters: counters))
        let idr = try #require(snap.idrRoundTrip)
        #expect(idr.requestsTotal == 4 && idr.matchedTotal == 3)
    }

    @Test func completeHandshakeIsCarriedAndItsEventWrittenOnce() throws {
        let counters = TelemetryCounters()
        let base = TelemetryCounters.monotonicNowNanos() &- 100_000_000
        counters.p2.anchorConnectStart(base)
        counters.p2.markRtspStart(base)
        counters.p2.markRtspDone(base &+ 2_000_000)
        counters.p2.markEnetStart(base &+ 3_000_000)
        counters.p2.markEstablished()
        counters.p2.markFirstFrame(TelemetryCounters.monotonicNowNanos() &+ 5_000_000)
        let exporter = exporter(in: dir, counters: counters)
        exporter.workQueue.sync { exporter.openNDJSONFile() }
        let (snap, _) = try capture(exporter)
        _ = try capture(exporter)
        let handshake = try #require(snap.handshake)
        #expect(handshake.complete && handshake.rtspMs == 2 && handshake.controlSetupMs == 1)
        let rows = try ndjsonRows(exporter)
        let events = rows.filter { $0["event"] as? String == "handshake" }
        #expect(events.count == 1)
        #expect(events.first?["rtsp_ms"] as? Double == 2)
        #expect(events.first?["session"] as? String == exporter.sessionId)
    }

    // MARK: - Output directory and privacy

    private func ndjsonRows(_ exporter: TelemetryExporter) throws -> [[String: Any]] {
        let url = try #require(exporter.ndjsonURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try TelemetryRenderFixtures.row(String($0)) }
    }

    @Test func sessionWritesItsFilesIntoTheGivenDirectoryOnly() throws {
        let exporter = exporter(in: dir)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.writeConfigEvent()
            exporter.capture()
            exporter.writeSessionReport()
            try? exporter.fileHandle?.close()
            exporter.fileHandle = nil
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names.count == 2)
        #expect(names.contains { $0.hasPrefix("telemetry-session-") && $0.hasSuffix(".json") })
        let rowsName = try #require(names.first { !$0.hasPrefix("telemetry-session-") })
        #expect(rowsName.hasPrefix("telemetry-") && rowsName.hasSuffix(".ndjson"))
        #expect(exporter.ndjsonURL?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

        let rows = try ndjsonRows(exporter)
        #expect(rows.count == 2)
        let config = try #require(rows.first)
        #expect(config["event"] as? String == "config")
        #expect(config["display_mode"] as? String == "window")
        #expect(config["stream_width"] as? Int == 2560 && config["codec"] as? String == "HEVC")
        let sample = try #require(rows.last)
        #expect(sample["session"] as? String == exporter.sessionId)
        #expect(sample["rtt_ms"] as? Double == 5.5)
        #expect(sample["enet_sent_reliable"] as? Int == 3)
    }

    @Test func everyFileNamesThePCAndMacByPseudonymOnly() throws {
        let exporter = exporter(in: dir)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.writeConfigEvent()
            exporter.capture()
            exporter.writeSessionReport()
            try? exporter.fileHandle?.close()
        }
        let pseudonym = TelemetryRenderer.pseudonym(Self.pcName)
        #expect(exporter.serverLabel == pseudonym)
        #expect(exporter.sessionId.count == 16 && exporter.sessionId.allSatisfy(\.isHexDigit))
        let sample = try #require(try ndjsonRows(exporter).last)
        #expect(sample["host"] as? String == pseudonym)
        #expect(sample["client"] as? String == MacTelemetryCapture.clientLabel)

        let reportName = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .first { $0.hasPrefix("telemetry-session-") })
        let report = try TelemetryRenderFixtures.row(
            String(contentsOf: dir.appendingPathComponent(reportName), encoding: .utf8))
        #expect(report["host"] as? String == pseudonym)
        #expect(report["client"] as? String == MacTelemetryCapture.clientLabel)

        var macName = ProcessInfo.processInfo.hostName
        if macName.hasSuffix(".local") { macName.removeLast(".local".count) }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains(Self.pcName))
            #expect(macName.count < 4 || !text.contains(macName))
        }
    }
}
