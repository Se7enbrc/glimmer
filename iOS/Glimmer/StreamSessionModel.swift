// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Observation
import UIKit

@MainActor
@Observable
final class StreamSessionModel {
    enum Phase: Equatable {
        case idle, connecting, streaming, reconnecting, stopping, ended(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var audioUnavailable = false
    private(set) var connectionPoor = false
    private(set) var waitingForVideo = false
    private(set) var requestedFormat: StreamFormat?
    private(set) var mouseControllers: Set<ControllerRegistration> = []
    var controllerMouseActive: Bool { !mouseControllers.isEmpty }
    private(set) var controllerConnected = false
    private(set) var controllerModeMessage: String?
    private(set) var dismissWhenStopped = false
    private let backgroundGrace: StreamBackgroundGrace
    private(set) var canStart = true
    private(set) var controlsVisible = true
    var inputCaptureChanged: ((Bool) -> Void)?
    var inputFocused: Bool { canStart && phase == .streaming && !controlsVisible && !captureSuspended }
    var streamInput: StreamInput? { playback?.input }
    nonisolated let launch: StreamLaunch
    private let makePlayback: @MainActor (StreamLaunch, StreamSurface,
        @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback
    private var playback: StreamPlayback?
    private var startTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var endingMessage: String?
    private var terminalFailure = false
    private var stopRequested = false
    private var hasReceivedVideo = false
    private var captureSuspended = false
    private var controlsRequested = false
    private var modeNoticeTask: Task<Void, Never>?
    private var windowResize: StreamWindowResize?
    private let resizeSleep: @Sendable (Duration) async throws -> Void

    init(launch: StreamLaunch, backgroundGrace: StreamBackgroundGrace = StreamBackgroundGrace(),
         resizeSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         makePlayback: @escaping @MainActor (StreamLaunch, StreamSurface,
            @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback = StreamPlayback.make) {
        self.launch = launch
        self.backgroundGrace = backgroundGrace
        self.resizeSleep = resizeSleep
        self.makePlayback = makePlayback
    }

    func start(surface: StreamSurface) {
        guard canStart, phase == .idle, stopTask == nil else { return }
        let playback: StreamPlayback
        do {
            playback = try makePlayback(launch, surface) { [weak self] in
                self?.captureSuspended = true
                self?.synchronizeInputFocus()
            }
        } catch {
            phase = .ended("Couldn't prepare this display. Close the stream and try again.")
            return
        }
        self.playback = playback
        requestedFormat = playback.format
        if let format = playback.format, let request = playback.requestFormatChange {
            windowResize = StreamWindowResize(format: format, request: request, applied: { [weak self] in
                self?.requestedFormat = $0
            }, sleep: resizeSleep)
        }
        phase = .connecting
        playback.observeControllers? { [weak self] connected in self?.controllerConnectionChanged(connected) }
        eventTask = Task { [weak self] in
            for await event in playback.events {
                guard !Task.isCancelled, let self else { return }
                self.receive(event)
            }
        }
        startTask = Task { [weak self] in
            do {
                try await playback.start()
            } catch {
                guard let self, !self.stopRequested else { return }
                if !self.terminalFailure {
                    self.endingMessage = StreamSessionFailureCopy.connection(
                        StreamFailure.connection(error), pcName: self.launch.pcName)
                }
                self.complete()
            }
        }
    }

    func waitForWindowResize() async { await windowResize?.waitForPendingChange() }

    func stop(message: String? = nil) {
        windowResize?.stop()
        stopRequested = true
        guard stopTask == nil, !phase.isEnded else { return }
        endingMessage = message ?? "Disconnected from \(launch.pcName)."
        guard let playback else { complete(); return }
        phase = .stopping
        synchronizeInputFocus()
        stopTask = Task {
            await playback.stop()
            complete()
            stopTask = nil
        }
    }

    func disconnect() {
        dismissWhenStopped = true
        stop()
    }

    private func complete() {
        windowResize?.stop()
        backgroundGrace.finish()
        if phase.isEnded {
            if let endingMessage { phase = .ended(endingMessage) }
            return
        }
        phase = .ended(endingMessage ?? "Disconnected from \(launch.pcName).")
        mouseControllers.removeAll()
        controllerConnected = false
        modeNoticeTask?.cancel()
        controllerModeMessage = nil
        synchronizeInputFocus()
        playback = nil
        startTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private var connectionFailureMessage: String {
        StreamSessionFailureCopy.connection(.invalidConfiguration, pcName: launch.pcName)
    }

    func availabilityChanged(active: Bool, background: Bool, protectedDataAvailable: Bool) {
        let returnedInTime = active ? backgroundGrace.returned() : true
        canStart = active && protectedDataAvailable && returnedInTime
        synchronizeInputFocus()
        guard !phase.isEnded, phase != .stopping else { return }
        var visibility = VideoDecoder.PresentationVisibility(reason: .sceneAvailability)
        visibility.appActive = active
        visibility.background = background
        visibility.protectedDataAvailable = protectedDataAvailable
        visibility.returnedInTime = returnedInTime
        playback?.setVisible?(canStart, visibility)
        if !protectedDataAvailable || !returnedInTime { disconnect(); return }
        if !active {
            guard playback != nil, phase != .reconnecting else { disconnect(); return }
            backgroundGrace.prepare { [weak self] in self?.disconnect() }
            if background { backgroundGrace.leave { [weak self] in self?.disconnect() } }
        }
    }

    func showControls() {
        controlsRequested = true
        controlsVisible = true
        synchronizeInputFocus()
    }

    func resumeInput() {
        guard canStart, phase == .streaming else { return }
        controlsRequested = false
        controlsVisible = false
        synchronizeInputFocus()
    }

    private func controllerConnectionChanged(_ connected: Bool) {
        guard !phase.isEnded, controllerConnected != connected else { return }
        controllerConnected = connected
        if connected, phase == .streaming, !controlsRequested { controlsVisible = false }
        if !connected { controlsVisible = true }
        synchronizeInputFocus()
    }

    private func synchronizeInputFocus() {
        windowResize?.setAvailable(canStart && phase == .streaming)
        playback?.focusInput?(inputFocused)
        inputCaptureChanged?(inputFocused)
    }

    func screenChanged() { playback?.screenChanged() }

    func windowChanged(surface: StreamSurface) {
        guard surface.traitCollection.userInterfaceIdiom == .pad,
              let format = try? launch.profile.resolve(surface: surface) else { return }
        windowResize?.submit(format)
    }

    func waitUntilStartFinishes() async { await startTask?.value }

    func waitUntilStopped() async { await stopTask?.value }

    private func receiveInput(_ event: StreamInput.Event) {
        switch event {
        case .stopRequested: disconnect()
        case .controllersActive: break
        case .mouseMode(let controller, let enabled):
            if enabled { mouseControllers.insert(controller) } else { mouseControllers.remove(controller) }
            if inputFocused, controllerConnected { showControllerMode(enabled) }
        }
    }

    private func showControllerMode(_ enabled: Bool) {
        modeNoticeTask?.cancel()
        controllerModeMessage = enabled ? "Mouse mode · \(launch.mouseStick.label) stick" : "Gamepad mode"
        modeNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.controllerModeMessage = nil
        }
    }

    func receive(_ update: StreamSession.Update) {
        guard playback?.id == update.sessionID, !phase.isEnded else { return }
        if case .stopped = update.event { complete(); return }
        guard phase != .stopping else { return }
        switch update.event {
        case .firstFrame, .reconnected:
            hasReceivedVideo = true
            endingMessage = nil
            terminalFailure = false
            captureSuspended = false
            phase = .streaming
            if controllerConnected, !controlsRequested { controlsVisible = false }
            synchronizeInputFocus()
        case .reconnecting:
            captureSuspended = true
            phase = .reconnecting
            synchronizeInputFocus()
        case .connectionTerminated(let code, let error):
            let reason = StreamFailure.termination(code: code, hasReceivedVideo: hasReceivedVideo)
            terminalFailure = error != nil || reason != .unexpected
            if let error {
                endingMessage = StreamSessionFailureCopy.connection(
                    StreamFailure.connection(error), pcName: launch.pcName)
            } else {
                endingMessage = StreamSessionFailureCopy.termination(reason, pcName: launch.pcName)
            }
            phase = .stopping
            synchronizeInputFocus()
        case .stageFailed:
            endingMessage = connectionFailureMessage
        case .connectionStatus(let quality): connectionPoor = quality == .poor
        case .waitingForVideo(let waiting): waitingForVideo = waiting
        case .audioFailed: audioUnavailable = true
        case .input(let event): receiveInput(event)
        case .connectionEstablished, .stageStarting, .stageComplete, .hdrModeChanged, .hdrActive, .log, .stopped:
            break
        }
    }
}
