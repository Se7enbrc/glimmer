// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryRenderFixtures.swift
//
//  Shared builders for the telemetry renderer tests: a fully populated snapshot and
//  extras with a distinct value in every field, plus parsers for both wire forms.
//

import Foundation
import Testing
@testable import Glimmer

enum TelemetryRenderFixtures {

    /// `count` observations of `value` recorded through the real histogram stage.
    static func stage(
        _ value: Double, count: Int = 10, bounds: [Double] = LatencyHistograms.Stage.boundsMs
    ) -> LatencyHistogramSnapshot.Stage {
        let stage = LatencyHistograms.Stage(bounds: bounds)
        for _ in 0..<count { stage.observe(value) }
        return stage.snapshotValue()
    }

    static func histograms(_ make: (LatencyHistograms) -> Void = { _ in }) -> LatencyHistogramSnapshot {
        let source = LatencyHistograms()
        make(source)
        return source.snapshot()
    }

    static func snapshot() -> TelemetrySnapshot {
        var snap = TelemetrySnapshot()
        snap.sessionId = "abcd1234"
        snap.sinceConnectSeconds = 42.5
        snap.wallClockISO8601 = "2026-10-10T12:00:00Z"
        snap.serverName = "deadbeef"
        snap.buildCommit = "abc123"
        snap.buildDate = "2026-10-10"
        fillFrames(&snap)
        fillNetwork(&snap)
        fillPacing(&snap)
        fillSystem(&snap)
        fillLifecycle(&snap)
        snap.audio = audio()
        snap.wifi = WiFiSnapshot(linkState: .associated, rssiDbm: -61, txRateMbps: 866.5,
                                 noiseDbm: -92, ssid: "Den \"5G\"", channel: 149, band: "5GHz")
        snap.latencyHistograms = histograms {
            for _ in 0..<10 {
                $0.receiveToAssemble.observe(1)
                $0.glassToGlass.observe(8)
            }
        }
        return snap
    }

    private static func fillFrames(_ snap: inout TelemetrySnapshot) {
        snap.receivedFps = 119.5
        snap.decodedFps = 118.5
        snap.renderedFps = 117.5
        snap.decodeEmaMs = 3.25
        snap.decodeServiceMs = 2.75
        snap.decodeWaitMs = 0.5
        snap.presentCadenceErrorMs = 1.5
        snap.presentOnTimeCount = 900
        snap.presentLateCount = 12
        snap.presentOnTimePercent = 98.5
        snap.presentLateHostCadenceCount = 4
        snap.hostFrameIntervalP50Ms = 8.25
        snap.hostFrameIntervalP95Ms = 9.5
        snap.hostUnevenPairs = 7
        snap.hostEncodeLatencyMinMs = 2.5
        snap.hostEncodeLatencyAvgMs = 4.5
        snap.hostEncodeLatencyMaxMs = 9.75
        snap.avgFrameBytes = 41_000.5
        snap.maxFrameBytes = 190_000
        snap.idrFramePercent = 1.25
    }

    private static func fillNetwork(_ snap: inout TelemetrySnapshot) {
        snap.recvJitterMs = 0.75
        snap.fecRecoveryRate = 0.125
        snap.fecPercentage = 20
        snap.fecParityMargin = 3
        snap.reorderDispMaxMs = 6.5
        snap.reorderDispMaxPackets = 14
        snap.reorderDispHoldMs = 10
        snap.reorderHoldExceededTotal = 2
        snap.reorderHoldTakenTotal = 21
        snap.reorderHoldRescuedTotal = 19
        snap.packetsPerSecond = 9_500.5
        snap.rttMs = 4.5
        snap.rttVarianceMs = 0.25
        snap.preFecLossRate = 0.005
        snap.outOfOrderRate = 0.01
        snap.duplicateRate = 0.002
        snap.goodputMbps = 180.5
        snap.negotiatedBitrateMbps = 200
        snap.goodputUtilization = 0.9
        snap.packetGapP50Us = 101
        snap.packetGapP95Us = 450
        snap.packetGapMaxUs = 2_500
        snap.enetSentReliable = 3
        snap.enetOldestUnackedMs = 40
        snap.enetSinceLastAckMs = 12
        snap.enetRetransmitTotal = 5
        snap.ackSilenceNearMissTotal = 1
        snap.awdlSuppressing = true
        snap.awdlReSuppressTotal = 8
        snap.udpFullSockDelta = 6
    }

    private static func fillPacing(_ snap: inout TelemetrySnapshot) {
        snap.pacingQueueDepth = 2
        snap.pacingAdaptiveTargetDepth = 3
        snap.inFlightDecodeBacklog = 1
        snap.dropsDecoder = 11
        snap.dropsBackpressure = 12
        snap.dropsPresentationLate = 13
        snap.presentationGaps = 14
        snap.dropsRecoveryWaitTotal = 15
        snap.refreshMinHz = 80
        snap.refreshAvgHz = 110.5
        snap.refreshMaxHz = 120
        snap.refreshChanged = true
        snap.inputEventsPerSecond = 250.5
        snap.inputFlushPerSecond = 125
        snap.inputMotionPerSecond = 240
        snap.inputIdleToActiveTotal = 9
        snap.timeSinceLastInputMs = 33.5
        snap.inputFlushSendBackloggedSkipTotal = 16
        snap.inputFlushReliableBackloggedSkipTotal = 17
        snap.staleFrameRepeatTotal = 31
        snap.staleRepeatsPerSecond = 1.5
        snap.staleEmptyQueueTotal = 22
        snap.presentGapDroughtTotal = 23
        snap.audioNearMissTotal = 24
        snap.audioStallRecoveryTotal = 25
        snap.tickMissDescheduledTotal = 41
        snap.tickMissCoalescedTotal = 42
        snap.tickMissPreemptedTotal = 43
        snap.tickMissLinkskipTotal = 44
    }

    private static func fillSystem(_ snap: inout TelemetrySnapshot) {
        snap.thermalState = 2
        snap.lowPowerModeEnabled = true
        snap.lowPowerMode = true
        snap.onBattery = false
        snap.processCpuPercent = 55.5
        snap.threadCount = 61
        snap.edrHeadroomMin = 1
        snap.edrHeadroomAvg = 2.5
        snap.edrHeadroomMax = 4
        snap.displayState = DisplayProbe(edrHeadroom: 2.5, hdrEngaged: true, screenName: "Studio \"Display\"",
                                         proMotionCapable: true, maxRefreshHz: 120)
        snap.decodeState = TelemetryCounters.DecodeState(hwDecode: true, codec: "hevc", pixelFormat: "x420",
                                                         bitDepth: 10, colorSpaceKey: "itur_2100_PQ")
        snap.vtSessionCreateMs = 18.5
        snap.cruiseMaxGain = 2.5
        snap.decoderRecreateTotal = 4
        snap.decoderRecreateFirstTotal = 1
        snap.decoderRecreateResolutionTotal = 2
        snap.decoderRecreateColorspaceTotal = 1
        snap.discontinuityFlushTotal = 3
        snap.resource = ResourceSnapshot(
            threads: [ThreadResourceSample(name: "Glimmer.decode", tid: 7, cpuPercent: 71.5, qos: 33,
                                           qosLabel: "userInteractive"),
                      ThreadResourceSample(name: "", tid: 8, cpuPercent: 3.5, qos: 17, qosLabel: "utility")],
            physFootprintBytes: 512_000_000, onBattery: true, batteryCharging: false)
        snap.clusterResidency = ClusterResidencySnapshot(
            eClusterActive: 0.25, pClusterActive: 0.75, eClusterCount: 2, pClusterCount: 4,
            packagePowerW: 9.5, gpuResidencyPercent: 38.5)
        snap.rfiTotal = 51
        snap.idrRequestedTotal = 52
        snap.backlogOverflowTotal = 53
        snap.presentStallTotal = 54
        snap.frameLossTotal = 55
        snap.unrecoverableFrameTotal = 56
        snap.pacerDisabledTotal = 57
        snap.bookmarkTotal = 58
        snap.cruiseBoostedBatchesTotal = 59
        snap.cruiseIdentityBatchesTotal = 60
        snap.rendererPerformance = RendererPerformanceSnapshot(
            status: .ready,
            cumulative: RendererPerformanceValues(frames: 1_000, dropped: 7, optimized: 990, delaySeconds: 1.5),
            delta: RendererPerformanceValues(frames: 120, dropped: 1, optimized: 119, delaySeconds: 0.25),
            intervalSeconds: 1.0, ageSeconds: 0.5, resets: 2)
    }

    private static func fillLifecycle(_ snap: inout TelemetrySnapshot) {
        var handshake = HandshakeBreakdown()
        handshake.rtspMs = 120.5
        handshake.controlSetupMs = 15
        handshake.enetConnectMs = 80.25
        handshake.firstFrameMs = 210
        handshake.totalMs = 425.75
        handshake.clickToFirstFrameMs = 900
        handshake.launchPathMs = 470
        handshake.launchServerinfoMs = 30
        handshake.launchCancelMs = 40
        handshake.launchBusyWaitMs = 50
        handshake.launchBusyPollCount = 3
        handshake.launchMs = 60
        handshake.buildMs = 70
        snap.handshake = handshake
        snap.reconnectTotal = 2
        snap.wakeTotal = 1
        snap.routeChangeTotal = 4
        snap.disconnectReason = .hostError
        snap.disconnectByReason = [(label: "user_stopped", total: 5), (label: "host_error", total: 1)]
        snap.idrRoundTrip = IdrRoundTripSnapshot(requestsTotal: 6, matchedTotal: 5, lastRoundTripMs: 22.5)
        snap.corruptionTotal = 3
        snap.corruptionPerSecond = 0.5
    }

    static func audio() -> AudioSnapshot {
        var audio = AudioSnapshot()
        audio.packetsTotal = 5_000
        audio.packetsLostTotal = 7
        audio.fecRecoveredTotal = 9
        audio.packetsPerSecond = 200.5
        audio.gapMaxMs = 25.5
        audio.lossRate = 0.001
        audio.fecRecoveryRate = 0.002
        audio.bufferFillMs = 48.5
        audio.resamplerPpm = -12.5
        audio.engineRunning = true
        audio.bufferFillMinMs = 31.5
        audio.rePrimeTotal = 2
        audio.underrunTotal = 4
        audio.overrunTotal = 1
        audio.underrunsPerSecond = 0.25
        audio.overrunsPerSecond = 0.125
        audio.audioClockDriftMs = -3.5
        audio.firstPacketMs = 310.5
        return audio
    }

    static func extras() -> TelemetrySnapshot.Extras {
        var extras = TelemetrySnapshot.Extras()
        fillPacer(&extras)
        fillAudio(&extras)
        fillGaps(&extras)
        extras.streamRoute = StreamRouteSnapshot(linkLabel: "wired", interfaceName: "en12")
        extras.envStateOrdinal = 1
        extras.envStateLabel = "caution"
        extras.envStateChangesTotal = 3
        extras.keepaliveIntervalMs = 75
        extras.videoPingsSentTotal = 600
        extras.audioPingsSentTotal = 590
        extras.videoPingsPerSecond = 13.5
        extras.audioPingsPerSecond = 13
        return extras
    }

    private static func fillPacer(_ extras: inout TelemetrySnapshot.Extras) {
        extras.pacerOverTargetReleaseTotal = 71
        extras.pacerOverTargetReleasesPerSecond = 0.5
        extras.pacerOverTargetReleaseRatio = 0.0625
        extras.suppressedDropTotal = 72
        extras.pacerSubmitReleaseTotal = 73
        extras.presentSuppressed = true
        extras.ctrlIgnoredTotal = 74
        extras.pacerTicksPerSecond = 119.75
        extras.pacerReleasesPerSecond = 118.5
        extras.pacerTickRealtime = true
        extras.decodeGated = true
        extras.decodeGatedDropTotal = 79
        extras.rumbleEventTotal = 80
        extras.rumbleEventsPerSecond = 135
        extras.rumbleDroppedInvalidTotal = 81
        extras.dualSenseHidReportsPerSecond = 250
    }

    private static func fillAudio(_ extras: inout TelemetrySnapshot.Extras) {
        extras.audioTrimTotal = 75
        extras.audioTrimsPerSecond = 0.75
        extras.audioFecMismatchTotal = 76
        extras.audioReceiveFailedTotal = 77
        extras.audioDecodeFailedTotal = 78
        extras.audioPlayoutTargetMs = 45
        extras.audioCushionMaxMs = 150
        extras.audioCushionFloorMs = 35
        extras.audioCushionSeedMs = 30
        extras.audioUnderrunDeadairTotal = 82
        extras.avSkewMs = -42.5
        extras.avClockSkewMs = 1.75
        extras.avSkewRebaseTotal = 83
    }

    private static func fillGaps(_ extras: inout TelemetrySnapshot.Extras) {
        extras.videoGapOver20msTotal = 91
        extras.videoGapOver50msTotal = 92
        extras.videoGapOver100msTotal = 93
        extras.audioGapOver20msTotal = 94
        extras.audioGapOver50msTotal = 95
        extras.audioGapOver100msTotal = 96
        extras.enetGapOver20msTotal = 97
        extras.enetGapOver50msTotal = 98
        extras.enetGapOver100msTotal = 99
    }

    // MARK: Parsers

    static func row(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    struct Sample {
        let labels: String
        let value: Double
    }

    /// A Prometheus text body as metric name to its samples.
    static func parseProm(_ body: String) -> [String: [Sample]] {
        var out: [String: [Sample]] = [:]
        for line in body.split(separator: "\n") where !line.hasPrefix("#") {
            let text = String(line)
            guard let space = text.lastIndex(of: " ") else { continue }
            let head = text[..<space]
            let value = Double(text[text.index(after: space)...]) ?? .nan
            var name = String(head)
            var labels = ""
            if let brace = head.firstIndex(of: "{") {
                name = String(head[..<brace])
                labels = String(head[brace...])
            }
            out[name, default: []].append(Sample(labels: labels, value: value))
        }
        return out
    }
}
