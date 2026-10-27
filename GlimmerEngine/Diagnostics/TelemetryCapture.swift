// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct TelemetryConfiguration: Sendable {

    package init(
        buildCommit: String = "",
        buildDate: String = "",
        clientLabel: String = "",
        fastPingSeconds: Double = 0,
        relaxedPingSeconds: Double = 0,
        keepaliveIdleSeconds: Double = 0,
        audioCushionBaseMs: Double = 0,
        audioCushionStepMs: Double = 0,
        audioOverrunSlackMs: Double = 0
    ) {
        self.buildCommit = buildCommit
        self.buildDate = buildDate
        self.clientLabel = clientLabel
        self.fastPingSeconds = fastPingSeconds
        self.relaxedPingSeconds = relaxedPingSeconds
        self.keepaliveIdleSeconds = keepaliveIdleSeconds
        self.audioCushionBaseMs = audioCushionBaseMs
        self.audioCushionStepMs = audioCushionStepMs
        self.audioOverrunSlackMs = audioOverrunSlackMs
    }

    package var buildCommit = ""
    package var buildDate = ""
    package var engineCommit = ""
    package var buildVersion = ""
    package var appVersion = ""
    package var diagnosticBuild = false
    package var attemptID: UUID?
    package var clientLabel = ""
    package var fastPingSeconds: Double = 0
    package var relaxedPingSeconds: Double = 0
    package var keepaliveIdleSeconds: Double = 0
    package var audioCushionBaseMs: Double = 0
    package var audioCushionStepMs: Double = 0
    package var audioOverrunSlackMs: Double = 0
}

package struct EnvironmentEvidence: Sendable {

    package init(
        stateOrdinal: Int = 0,
        stateLabel: String = "clear",
        stateChangesTotal: UInt64 = 0,
        keepaliveIntervalSeconds: Double = 0,
        videoPingsSentTotal: UInt64 = 0,
        audioPingsSentTotal: UInt64 = 0
    ) {
        self.stateOrdinal = stateOrdinal
        self.stateLabel = stateLabel
        self.stateChangesTotal = stateChangesTotal
        self.keepaliveIntervalSeconds = keepaliveIntervalSeconds
        self.videoPingsSentTotal = videoPingsSentTotal
        self.audioPingsSentTotal = audioPingsSentTotal
    }

    package var stateOrdinal = 0
    package var stateLabel = "clear"
    package var stateChangesTotal: UInt64 = 0
    package var keepaliveIntervalSeconds: Double = 0
    package var videoPingsSentTotal: UInt64 = 0
    package var audioPingsSentTotal: UInt64 = 0
}

#if os(macOS)
package struct TelemetryCapture: Sendable {

    package init(
        configuration: TelemetryConfiguration = TelemetryConfiguration(),
        beginSession: @escaping @Sendable () -> Void = {},
        wifi: @escaping @Sendable () -> WiFiSnapshot? = { nil },
        route: @escaping @Sendable () -> StreamRouteSnapshot? = { nil },
        resource: @escaping @Sendable () -> ResourceSnapshot? = { nil },
        auditQoS: @escaping @Sendable (ResourceSnapshot, String) -> Void = { _, _ in },
        cluster: @escaping @Sendable () -> ClusterResidencySnapshot? = { nil },
        process: @escaping @Sendable () -> (cpuPercent: Double, threadCount: Int)? = { nil },
        udpFullSockTotal: @escaping @Sendable () -> UInt32? = { nil },
        hidReportsPerSecond: @escaping @Sendable () -> Double? = { nil },
        environment: @escaping @Sendable () -> EnvironmentEvidence? = { nil },
        linkGate: @escaping @Sendable () -> LinkGateDecision? = { nil }
    ) {
        self.configuration = configuration
        self.beginSession = beginSession
        self.wifi = wifi
        self.route = route
        self.resource = resource
        self.auditQoS = auditQoS
        self.cluster = cluster
        self.process = process
        self.udpFullSockTotal = udpFullSockTotal
        self.hidReportsPerSecond = hidReportsPerSecond
        self.environment = environment
        self.linkGate = linkGate
    }

    package var configuration = TelemetryConfiguration()
    package var beginSession: @Sendable () -> Void = {}
    package var wifi: @Sendable () -> WiFiSnapshot? = { nil }
    package var route: @Sendable () -> StreamRouteSnapshot? = { nil }
    package var resource: @Sendable () -> ResourceSnapshot? = { nil }
    package var auditQoS: @Sendable (ResourceSnapshot, String) -> Void = { _, _ in }
    package var cluster: @Sendable () -> ClusterResidencySnapshot? = { nil }
    package var process: @Sendable () -> (cpuPercent: Double, threadCount: Int)? = { nil }
    package var udpFullSockTotal: @Sendable () -> UInt32? = { nil }
    package var hidReportsPerSecond: @Sendable () -> Double? = { nil }
    package var environment: @Sendable () -> EnvironmentEvidence? = { nil }
    package var linkGate: @Sendable () -> LinkGateDecision? = { nil }
}

#endif
