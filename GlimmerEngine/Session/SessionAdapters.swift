// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Prepared native ownership operations; input acceptance itself stays synchronous in InputCore.
@MainActor package final class SessionInputHooks {
    package let setBackend: @MainActor @Sendable (any StreamingBackend) -> Void
    package let setReady: @MainActor @Sendable (Bool) -> Void
    package let quiesce: @MainActor @Sendable () -> Void
    package let detach: @MainActor @Sendable () -> Void
    package let configure: @MainActor @Sendable (StreamRequest) -> Void

    package init(setBackend: @escaping @MainActor @Sendable (any StreamingBackend) -> Void, setReady: @escaping @MainActor @Sendable (Bool) -> Void,
                 quiesce: @escaping @MainActor @Sendable () -> Void, detach: @escaping @MainActor @Sendable () -> Void,
                 configure: @escaping @MainActor @Sendable (StreamRequest) -> Void) {
        self.setBackend = setBackend
        self.setReady = setReady
        self.quiesce = quiesce
        self.detach = detach
        self.configure = configure
    }
}

/// Native surfaces are retained by these lifecycle closures, never passed into engine state.
@MainActor package final class SessionPresentation {
    package var showRecovery: @MainActor @Sendable (String?) -> Void = { _ in }
    package var firstFrame: @MainActor () -> Void = {}
    package var hideOverlay: @MainActor @Sendable () -> Void = {}
    package var startStats: @MainActor @Sendable () -> Void = {}
    package var stopStats: @MainActor @Sendable () -> Void = {}
    package var close: @MainActor @Sendable () -> Void = {}
    package var waitForVisualClose: @MainActor @Sendable () async -> Void = {}
    package var setCursorHidden: @MainActor @Sendable (Bool) -> Void = { _ in }
    package var toggleMiniPlayer: @MainActor @Sendable () -> Void = {}
    package var resume: @MainActor @Sendable () -> Void = {}
    package var setStatsCorner: @MainActor @Sendable (String) -> Void = { _ in }
    package var rendererProbe: (@Sendable () -> RendererPerformanceSource?)?
    package var displayMode = ""
    package init() {}
}

extension SessionServices {
    /// Uses existing gated recorders; public consumers supply a local directory, never a LAN listener.
    package static func recording(directory: URL?, enabled: Bool = TelemetryGate.isEnabled) -> SessionServices {
        var services = SessionServices()
        guard enabled, let directory, directory.isFileURL else { return services }
        services.startLog = { SessionLogFileSink.startIfEnabled(enabled: true, directory: directory) }
        services.stopLog = { SessionLogFileSink.stop() }
        services.makeExporter = { source, name in
            TelemetryExporter(source: source, serverName: name, outputDirectory: directory, listenOnLAN: false)
        }
        return services
    }
}

package struct SessionMedia: Sendable {
    package let presentation: SessionPresentation
    package let input: SessionInputHooks
    package let video: VideoDecoder
    package init(presentation: SessionPresentation, input: SessionInputHooks, video: VideoDecoder) {
        self.presentation = presentation
        self.input = input
        self.video = video
    }
}

/// Native session services run only at lifecycle edges or existing diagnostic cadence.
package struct SessionServices: Sendable {
    package var beginActivity: @Sendable () -> Void = {}
    package var endActivity: @Sendable () -> Void = {}
    package var refreshActivity: @Sendable (Bool) -> Void = { _ in }
    package var logConfig: @MainActor @Sendable (BackendStreamConfig) -> Void = { _ in }
    package var startLog: @Sendable () -> Void = {}
    package var stopLog: @Sendable () -> Void = {}
    package var captureEnd: @Sendable (Double?, StatsCollector?) -> Void = { _, _ in }
    package var armWake: @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in }
    package var stopWake: @Sendable () -> Void = {}
    package var latchHost: @Sendable (String) -> Void = { _ in }
    package var route: @Sendable (ServerInfo, RttStats?) -> StreamPathProbe = { _, _ in StreamPathProbe() }
    package var makeEnvironment: @Sendable () -> EnvObservationSource? = { nil }
    package var feedback = SessionFeedback()
    package var defaultDisplayMode = ""
    package var makeCapture: @Sendable () -> TelemetryCapture = { TelemetryCapture() }
    package var makeExporter: @Sendable (TelemetrySource, String) -> TelemetryExporter? = { _, _ in nil }
    package var bookmarkHint: @Sendable () -> Void = {}
    package init() {}
}
