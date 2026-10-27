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

    let shortcuts: StreamShortcuts
    private(set) var statsShown: Bool

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
    /// The engine only reports a held quality change once its anti-flap gate allows it.
    private(set) var adjustingQuality = false
    var recoveryText: String {
        adjustingQuality ? StreamSession.adjustingQualityText : "Reconnecting to \(launch.pcName)…"
    }
    var announce: @MainActor (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }
    private(set) var requestedFormat: StreamFormat?
    /// The adaptive policy's first rate for this stream; nil when adaptive quality is off.
    private(set) var requestedStartKbps: Int?
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
    var inputFocused: Bool {
        canStart && phase == .streaming && !controlsVisible && !captureSuspended
            && (controllerConnected || touchGeometryUsable)
    }
    var streamInput: StreamInput? { playback?.input }
    var touchGamepad: TouchGamepadCapture? { playback?.touchGamepad }
    var editingTouchControls = false
    private(set) var touchGeometryUsable = true
    private(set) var touchControlsRequested = false
    var touchControlsVisible: Bool { inputFocused && (!controllerConnected || touchControlsRequested) }
    var touchMouseActive: Bool {
        guard let registration = touchGamepad?.registration else { return false }
        return mouseControllers.contains(registration)
    }
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

    init(launch: StreamLaunch, defaults: UserDefaults = .standard,
         backgroundGrace: StreamBackgroundGrace = StreamBackgroundGrace(),
         resizeSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         makePlayback: @escaping @MainActor (StreamLaunch, StreamSurface,
            @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback = StreamPlayback.make) {
        shortcuts = StreamShortcuts(defaults: defaults)
        statsShown = defaults.bool(forKey: "showStreamStats")
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
            presentationEnded?()
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
                if let started = try await playback.start(), let self, !self.stopRequested {
                    self.requestedFormat = started.format
                    self.requestedStartKbps = started.startKbps
                    self.windowResize?.adopt(started.format)
                }
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

    func toggleStats() {
        guard phase == .streaming else { return }
        statsShown.toggle()
        synchronizeInputFocus()
    }

    func performShortcut(_ action: StreamShortcuts.Action) {
        guard canStart, !phase.isEnded, phase != .stopping else { return }
        switch action {
        case .quit: disconnect()
        case .stats: toggleStats()
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
        editingTouchControls = false
        touchControlsRequested = false
        playback?.showTouchControls?(false)
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
        windowResize?.stop()
        windowResize = nil
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
        if !canStart { shortcuts.reset() }
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

    func touchGeometryChanged(usable: Bool) {
        guard touchGeometryUsable != usable else { return }
        touchGeometryUsable = usable
        if phase == .streaming, !controllerConnected, !controlsRequested { controlsVisible = !usable }
        synchronizeInputFocus()
    }

    func resumeInput() {
        guard canStart, phase == .streaming, controllerConnected || touchGeometryUsable else { return }
        controlsRequested = false
        controlsVisible = false
        synchronizeInputFocus()
    }

    func toggleTouchControls() {
        guard controllerConnected, phase == .streaming else { return }
        touchControlsRequested.toggle()
        playback?.showTouchControls?(touchControlsRequested)
    }

    private func controllerConnectionChanged(_ connected: Bool) {
        guard !phase.isEnded, controllerConnected != connected else { return }
        controllerConnected = connected
        if phase == .streaming, !controlsRequested { controlsVisible = false }
        if !connected, !touchGeometryUsable { controlsVisible = true }
        synchronizeInputFocus()
    }

    private func synchronizeInputFocus() {
        playback?.showStats?(statsShown && canStart && phase == .streaming)
        playback?.focusInput?(inputFocused)
        inputCaptureChanged?(inputFocused)
        windowResize?.setAvailable(canStart && phase == .streaming)
    }

    /// A resized window, or a continued game at an earlier size, moves to the window's listed mode.
    func windowChanged(surface: StreamSurface) {
        guard let current = requestedFormat,
              let target = try? launch.profile.resolve(surface: surface, preservingFPS: current.fps) else { return }
        // The resume-only seam keeps the running frame rate.
        windowResize?.submit(StreamFormat(width: target.width, height: target.height, fps: current.fps,
                                          changeResolution: current.changeResolution))
    }

    func waitForWindowResize() async { await windowResize?.waitForPendingChange() }

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
        case .statsRequested: toggleStats()
        // Engine activity includes the touch registration; only native discovery reports physical presence.
        case .controllersActive: break
        case .mouseMode(let controller, let enabled):
            if enabled { mouseControllers.insert(controller) } else { mouseControllers.remove(controller) }
            if inputFocused { showControllerMode(enabled) }
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

    private func holdForRecovery(_ event: StreamEvent) {
        var quality = false
        if case .adjustingQuality = event { quality = true }
        if quality, !adjustingQuality { announce(StreamSession.adjustingQualityText) }
        adjustingQuality = quality
        // A bitrate-only change keeps the picture size, so it never judges a size trial.
        if !quality { rejectPictureTrial() }
        if !quality, launch.useScreenSize, let old = launch.previousFormat, old.isValid {
            requestedFormat = StreamFormat(width: old.width, height: old.height, fps: old.fps,
                                           changeResolution: old.changeResolution)
        }
        captureSuspended = true
        phase = .reconnecting
        synchronizeInputFocus()
    }

    private func resumePlayback() {
        recordFirstVideo()
        hasReceivedVideo = true
        endingMessage = nil
        terminalFailure = false
        captureSuspended = false
        adjustingQuality = false
        phase = .streaming
        if !controlsRequested { controlsVisible = !controllerConnected && !touchGeometryUsable }
        synchronizeInputFocus()
    }

    private func adoptSize(width: Int, height: Int) {
        guard let current = requestedFormat else { return }
        let format = StreamFormat(width: width, height: height, fps: current.fps,
                                  changeResolution: current.changeResolution)
        requestedFormat = format
        windowResize?.adopt(format)
    }

    func receive(_ update: StreamSession.Update) {
        guard playback?.id == update.sessionID, !phase.isEnded else { return }
        if case .stopped = update.event { if !quittingGame { complete() }; return }
        guard phase != .stopping else { return }
        switch update.event {
        case .firstFrame, .reconnected: resumePlayback()
        case .sizeChanged(let width, let height): adoptSize(width: width, height: height)
        case .reconnecting, .adjustingQuality: holdForRecovery(update.event)
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
