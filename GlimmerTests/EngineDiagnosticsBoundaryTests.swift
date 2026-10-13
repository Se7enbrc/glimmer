// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization
import Testing

@Suite(.serialized)
struct EngineDiagnosticsBoundaryTests {
    private func source(capture: TelemetryCapture = .init()) -> TelemetrySource {
        TelemetrySource(
            videoStats: { StreamStatsSnapshot() }, decoderDrops: { 0 }, backpressureDrops: { 0 },
            presentationLateDrops: { 0 }, presentationGaps: { 0 }, estimatedRtt: { nil },
            enetHealth: { nil }, pacingLiveness: { nil }, inFlightDecodeBacklog: { 0 },
            refreshWindow: { nil }, displayProbe: { nil }, capture: capture)
    }

    @Test func absentPlatformProbesStayAbsent() throws {
        let exporter = TelemetryExporter(source: source(), serverName: "Test PC", counters: TelemetryCounters())
        exporter.workQueue.sync { exporter.capture() }
        let (snapshot, extras) = try #require(exporter.latestSample)
        #expect(snapshot.wifi == nil && snapshot.resource == nil && snapshot.clusterResidency == nil)
        #expect(snapshot.processCpuPercent == nil && snapshot.threadCount == nil)
        #expect(snapshot.onBattery == nil)
        #expect(snapshot.udpFullSockDelta == nil && extras.streamRoute == nil)
        #expect(extras.dualSenseHidReportsPerSecond == nil && extras.envStateOrdinal == nil)
        let line = TelemetryRenderer.ndjson(snapshot, extras: extras)
        #expect(!line.contains("wifi_rssi_dbm") && !line.contains("phys_footprint_bytes"))
        #expect(!line.contains("Test PC"))
    }

    @Test func suppliedEvidenceIsCapturedOnceForBothRenderers() throws {
        let calls = Mutex(0)
        var capture = TelemetryCapture()
        capture.configuration.clientLabel = "1234abcd"
        capture.configuration.buildCommit = "test-commit"
        capture.environment = {
            calls.withLock { $0 += 1 }
            return EnvironmentEvidence(stateOrdinal: 2, stateLabel: "distress", stateChangesTotal: 7,
                                       keepaliveIntervalSeconds: 0.5, videoPingsSentTotal: 11, audioPingsSentTotal: 13)
        }
        capture.hidReportsPerSecond = { 250 }
        let exporter = TelemetryExporter(
            source: source(capture: capture), serverName: "Test PC", counters: TelemetryCounters())
        exporter.workQueue.sync { exporter.capture() }
        let (snapshot, extras) = try #require(exporter.latestSample)
        #expect(calls.withLock { $0 } == 1)
        #expect(snapshot.clientLabel == "1234abcd" && snapshot.buildCommit == "test-commit")
        #expect(extras.envStateOrdinal == 2 && extras.keepaliveIntervalMs == 500)
        #expect(extras.videoPingsSentTotal == 11 && extras.audioPingsSentTotal == 13)
        #expect(extras.dualSenseHidReportsPerSecond == 250)
        let ndjson = TelemetryRenderer.ndjson(snapshot, extras: extras)
        let prometheus = TelemetryRenderer.prometheus(snapshot, extras: extras)
        #expect(ndjson.contains("1234abcd") && prometheus.contains("1234abcd"))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func disabledExporterNeverInvokesCaptureFunctions() {
        let calls = Mutex(0)
        var capture = TelemetryCapture()
        capture.beginSession = { calls.withLock { $0 += 1 } }
        capture.environment = { calls.withLock { $0 += 1 }; return nil }
        let exporter = TelemetryExporter.makeIfEnabled(
            source: source(capture: capture), serverName: "Test PC", enabled: false)
        #expect(exporter == nil && calls.withLock { $0 } == 0)
    }

    @Test func suppliedDirectoryAndConfigurationReachTheConfigRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var capture = TelemetryCapture()
        capture.outputDirectory = directory
        capture.configuration = TelemetryConfiguration(
            buildCommit: "boundary-build", fastPingSeconds: 0.125, relaxedPingSeconds: 0.75,
            keepaliveIdleSeconds: 9, audioCushionBaseMs: 31, audioCushionStepMs: 6, audioOverrunSlackMs: 41)
        capture.linkGate = {
            LinkGateDecision(interfaceName: "test0", mtu: 1280, isTunnel: true,
                             configuredBitrateKbps: 20_000, askedBitrateKbps: 15_000, packetSize: 1024)
        }
        let exporter = try #require(TelemetryExporter.makeIfEnabled(
            source: source(capture: capture), serverName: "Test PC", enabled: true))
        #expect(exporter.outputDirectory == directory)
        exporter.workQueue.sync {
            exporter.openNDJSONFile()
            exporter.writeConfigEvent()
        }
        let url = try #require(exporter.ndjsonURL)
        let data = try Data(contentsOf: url)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(row["build_commit"] as? String == "boundary-build")
        #expect(row["keepalive_fast_ping_ms"] as? Int == 125)
        #expect(row["keepalive_relaxed_ping_ms"] as? Int == 750)
        #expect(row["audio_cushion_base_ms"] as? Int == 31)
        #expect(row["audio_cushion_step_ms"] as? Int == 6)
        #expect(row["audio_overrun_slack_ms"] as? Int == 41)
        #expect(row["gate_stream_if"] as? String == "test0")
        #expect(row["gate_packet_size"] as? Int == 1024)
        try exporter.fileHandle?.close()
    }

    @Test func privateInterpolationSurvivesTheModuleBoundary() throws {
        let store = LogStore(captureDebug: true)
        let detail: DiagMessage = "PC \("private-pc", privacy: .private)"
        let message: DiagMessage = "Connecting: \(detail)" + "; stage=1"
        store.log(.notice, message, category: "BoundaryTest")
        let entry = try #require(store.snapshot().first)
        #expect(entry.message == "Connecting: PC private-pc; stage=1")
        #expect(entry.redactedMessage == "Connecting: PC <private>; stage=1")
        #expect(!entry.shareable.contains("private-pc"))
        #expect(message.systemLogText == entry.redactedMessage)
    }
}
