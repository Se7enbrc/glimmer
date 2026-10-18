// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import SystemConfiguration
import Darwin

enum DiagnosticBuild {
    static var isEnabled: Bool { enabled(info: Bundle.main.infoDictionary ?? [:]) }

    static func enabled(info: [String: Any]) -> Bool {
        if let value = info["GlimmerDiagnosticBuild"] as? String { return value == "YES" }
        return info["GlimmerDiagnosticBuild"] as? Bool == true
    }
}

// Constructed only after the existing opt-in gate; probes retain their original cadence and ownership.
enum MacTelemetryCapture {
    static let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Glimmer", isDirectory: true)

    static func make() -> TelemetryCapture {
        let wifi = WiFiTelemetry()
        let ioReport = IOReportSampler.shared
        var capture = TelemetryCapture()
        var config = TelemetryConfiguration()
        config.buildCommit = BuildInfo.commit
        config.buildDate = BuildInfo.date
        config.engineCommit = BuildInfo.commit
        config.buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        config.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        config.diagnosticBuild = DiagnosticBuild.isEnabled
        config.clientLabel = clientLabel
        config.fastPingSeconds = UdpPinger.steadyPingIntervalSeconds
        config.relaxedPingSeconds = UdpPinger.relaxedPingIntervalSeconds
        config.keepaliveIdleSeconds = EnvSignalController.keepaliveIdleSeconds
        config.audioCushionBaseMs = AudioDecoder.playoutCushionBaseMs
        config.audioCushionStepMs = AudioDecoder.playoutCushionStepMs
        config.audioOverrunSlackMs = AudioDecoder.bufferOverrunCeilingSlackMs
        capture.configuration = config
        capture.beginSession = { ioReport?.beginSession() }
        capture.wifi = { wifi.sample() }
        capture.route = { EnvSignalController.shared.routeSnapshot }
        capture.resource = { ResourceTelemetry.sample() }
        capture.auditQoS = { QoSAudit.runAndLog($0, category: $1) }
        capture.cluster = { ioReport?.sample() }
        capture.process = { ProcessMetrics.sample() }
        capture.udpFullSockTotal = { udpFullSockTotal() }
        capture.hidReportsPerSecond = {
            DualSenseHID.isEnabled ? DualSenseHID.shared.reportsPerSecond : nil
        }
        capture.environment = { environment() }
        capture.linkGate = { StreamPathMTU.currentGateDecision }
        return capture
    }

    static func environment() -> EnvironmentEvidence {
        let controller = EnvSignalController.shared
        var evidence = EnvironmentEvidence()
        evidence.stateOrdinal = controller.state.rawValue
        evidence.stateLabel = controller.state.label
        evidence.stateChangesTotal = controller.stateChangesTotal.value
        evidence.keepaliveIntervalSeconds = controller.steadyPingInterval()
        evidence.videoPingsSentTotal = controller.videoPingsSentTotal.value
        evidence.audioPingsSentTotal = controller.audioPingsSentTotal.value
        return evidence
    }

    static func udpFullSockTotal() -> UInt32? {
        var stats = udpstat()
        var size = MemoryLayout<udpstat>.size
        guard sysctlbyname("net.inet.udp.stats", &stats, &size, nil, 0) == 0 else { return nil }
        return stats.udps_fullsock
    }

    static let clientLabel: String = {
        var name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return TelemetryRenderer.pseudonym(name)
    }()
}
