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
    var firstVideo: ((StreamFormat) -> Void)?
    var continuationEnded: (() -> Void)?
    var startupFailed: ((StreamFormat?) -> Void)?
    var pictureNeedsReview = false
    var keepSize: (() -> Void)?
    var restoreSize: (() -> Void)?
    var replacementRequired: ((Int) -> Void)?
    private var quittingGame = false
    var quitFailure: String?
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
    private(set) var externalDisplayActive = false
    var inputCaptureChanged: ((Bool) -> Void)?
    var presentationEnded: (() -> Void)?
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

    init(launch: StreamLaunch, backgroundGrace: StreamBackgroundGrace = StreamBackgroundGrace(),
         makePlayback: @escaping @MainActor (StreamLaunch, StreamSurface,
            @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback = StreamPlayback.make) {
        self.launch = launch
        self.backgroundGrace = backgroundGrace
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
            presentationEnded?()
            return
        }
        self.playback = playback
        requestedFormat = playback.format
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
            } catch RunningAppFailure.ended {
                guard let self, !self.stopRequested else { return }
                self.endingMessage = StreamFailureCopy.gameEnded(self.launch.appName, pc: self.launch.pcName)
                self.continuationEnded?()
                self.complete()
            } catch let takeover as TakeoverRequired {
                guard let self, !self.stopRequested else { return }
                self.replacementRequired?(takeover.appID)
                self.disconnect()
            } catch {
                guard let self, !self.stopRequested else { return }
                self.startupFailed?(self.requestedFormat)
                if !self.terminalFailure {
                    self.endingMessage = StreamSessionFailureCopy.connection(
                        StreamFailure.connection(error), pcName: self.launch.pcName)
                }
                self.complete()
            }
        }
    }

    func stop(message: String? = nil) {
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

    func quitGame() {
        guard stopTask == nil, !phase.isEnded, let quit = playback?.quit else { return }
        quittingGame = true
        stopRequested = true
        phase = .stopping
        synchronizeInputFocus()
        stopTask = Task {
            do {
                try await quit()
                dismissWhenStopped = true
            } catch {
                quitFailure = StreamSessionFailureCopy.quit(error, app: launch.appName, pc: launch.pcName)
                endingMessage = quitFailure
            }
            quittingGame = false
            complete()
            stopTask = nil
        }
    }

    func disconnect() {
        dismissWhenStopped = true
        stop()
    }

    private func complete() {
        backgroundGrace.finish()
        if phase.isEnded {
            if let endingMessage { phase = .ended(endingMessage) }
            return
        }
        phase = .ended(endingMessage ?? "Disconnected from \(launch.pcName).")
        presentationEnded?()
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
        playback?.focusInput?(inputFocused)
        inputCaptureChanged?(inputFocused)
    }

    func screenChanged() { playback?.screenChanged() }

    func prepareForDisplayChange() {
        playback?.focusInput?(false)
        inputCaptureChanged?(false)
    }

    func finishDisplayChange(external: Bool) {
        externalDisplayActive = external
        screenChanged()
        synchronizeInputFocus()
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

    private func recordFirstVideo() {
        guard !hasReceivedVideo, let format = requestedFormat else { return }
        firstVideo?(format)
        pictureNeedsReview = launch.continuing && launch.useScreenSize && launch.previousFormat != nil
        if pictureNeedsReview { controlsRequested = true; controlsVisible = true }
    }

    private func rejectPictureTrial() {
        guard pictureNeedsReview else { return }
        startupFailed?(requestedFormat)
        pictureNeedsReview = false
    }

    private func prepareForRecovery() {
        rejectPictureTrial()
        if launch.useScreenSize, let old = launch.previousFormat, old.isValid {
            requestedFormat = StreamFormat(width: old.width, height: old.height, fps: old.fps,
                                           changeResolution: old.changeResolution)
        }
        captureSuspended = true
        phase = .reconnecting
        synchronizeInputFocus()
    }

    func receive(_ update: StreamSession.Update) {
        guard playback?.id == update.sessionID, !phase.isEnded else { return }
        if case .stopped = update.event { if !quittingGame { complete() }; return }
        guard phase != .stopping else { return }
        switch update.event {
        case .firstFrame, .reconnected:
            recordFirstVideo()
            hasReceivedVideo = true
            endingMessage = nil
            terminalFailure = false
            captureSuspended = false
            phase = .streaming
            if controllerConnected, !controlsRequested { controlsVisible = false }
            synchronizeInputFocus()
        case .reconnecting: prepareForRecovery()
        case .connectionTerminated(let code, let error):
            rejectPictureTrial()
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
