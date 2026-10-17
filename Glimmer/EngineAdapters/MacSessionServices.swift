// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import Foundation
import os

/// Activity and observer lifetime is serialized by the session actor; the lock covers diagnostic test reads.
final class MacSessionServices: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: (any NSObjectProtocol)?
    private var hidden = false
    var isHidden: Bool { lock.withLock { hidden } }
    private var wakeObservers: [NSObjectProtocol] = []

    func services() -> SessionServices {
        var result = SessionServices()
        result.logConfig = { Self.logStreamConfig($0) }
        result.beginActivity = { self.beginActivity() }
        result.endActivity = { self.endActivity() }
        result.refreshActivity = { self.refreshActivity(hidden: $0) }
        result.startLog = {
            SessionLogFileSink.startIfEnabled(enabled: TelemetryGate.isEnabled, directory: MacTelemetryCapture.logsDirectory)
        }
        result.stopLog = { SessionLogFileSink.stop() }
        result.captureEnd = { SessionReceiptStore.captureStreamEnd(rttMs: $0, collector: $1) }
        result.armWake = { self.armWake($0) }
        result.stopWake = { self.stopWake() }
        result.latchHost = { StreamRouteProbe.latchHost($0) }
        result.route = { MacStreamPath.probe(host: $0.address, rttPort: UInt16($0.httpsPort), rtt: $1) }
        result.feedback = .mac()
        result.defaultDisplayMode = StreamDisplayMode.defaultMode.rawValue
        result.makeCapture = { MacTelemetryCapture.make() }
        result.makeEnvironment = { MacEnvironment.makeObservations() }
        result.makeExporter = {
            TelemetryExporter.makeIfEnabled(source: $0, serverName: $1, outputDirectory: MacTelemetryCapture.logsDirectory)
        }
        result.bookmarkHint = {
            Diag.notice("Telemetry bookmark chord = \(HotkeyChord.defaultBookmark.displayString) "
                + "- press it any time the stream \"feels bad\" to drop a timestamped jank "
                + "marker (client-only; never sent to the host).", TelemetryExporter.logCategory)
        }
        return result
    }

    @MainActor
    private static func logStreamConfig(_ cfgSnapshot: BackendStreamConfig) {
        let screen = NSScreen.main
        let displayMaxFps = screen?.maximumFramesPerSecond ?? -1
        let displayName = screen?.localizedName ?? "n/a"
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Session")
        log.info("""
            Stream config: \
            \(cfgSnapshot.width, privacy: .public)x\(cfgSnapshot.height, privacy: .public)@\(cfgSnapshot.fps, privacy: .public) \
            bitrate=\(cfgSnapshot.bitrate, privacy: .public) packetSize=\(cfgSnapshot.packetSize, privacy: .public) \
            audio=\(cfgSnapshot.audioConfiguration, privacy: .public) \
            videoFormats=0x\(String(cfgSnapshot.supportedVideoFormats, radix: 16), privacy: .public) \
            refreshRateX100=\(cfgSnapshot.clientRefreshRateX100, privacy: .public) \
            colorSpace=\(cfgSnapshot.colorSpace, privacy: .public) colorRange=\(cfgSnapshot.colorRange, privacy: .public) \
            remote=\(cfgSnapshot.streamingRemotely, privacy: .public) display=\(displayName, privacy: .private) \
            displayMaxFps=\(displayMaxFps, privacy: .public)
            """)
        Diag.notice("Stream config: \(cfgSnapshot.width)x\(cfgSnapshot.height)@\(cfgSnapshot.fps), "
            + "\(cfgSnapshot.bitrate / 1000) Mbps, display \(displayName, privacy: .private)", "Stream")
    }

    func beginActivity() {
        lock.withLock {
            hidden = false
            assertion = ProcessInfo.processInfo.beginActivity(
                options: StreamSession.sessionActivityOptions(hidden: false), reason: "Glimmer is streaming")
        }
    }

    func endActivity() {
        lock.withLock {
            if let assertion { ProcessInfo.processInfo.endActivity(assertion) }
            assertion = nil
        }
    }

    func refreshActivity(hidden: Bool) {
        lock.withLock {
            guard let assertion, self.hidden != hidden else { return }
            ProcessInfo.processInfo.endActivity(assertion)
            self.assertion = ProcessInfo.processInfo.beginActivity(
                options: StreamSession.sessionActivityOptions(hidden: hidden), reason: "Glimmer is streaming")
            self.hidden = hidden
        }
    }

    private func armWake(_ wake: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                object: nil, queue: .main) { _ in wake() })
    }

    private func stopWake() {
        let center = NSWorkspace.shared.notificationCenter
        for token in wakeObservers { center.removeObserver(token) }
        wakeObservers.removeAll()
    }
}

extension StreamSession {
    init(hostDisposition: StreamHostDisposition, backend: any StreamingBackend = MacTransport.makeBackend(),
         makeNetwork: @escaping @Sendable (ServerInfo) -> NetworkClient = { NetworkClient(server: $0) },
         makeBackend: @escaping @Sendable () -> any StreamingBackend = { MacTransport.makeBackend() },
         clock: SessionClock = SessionClock()) {
        self.init(hostDisposition: hostDisposition, audioDecoder: AudioDecoder(), services: MacSessionServices().services(),
                  backend: backend, makeNetwork: makeNetwork, makeBackend: makeBackend, clock: clock)
    }
}
