// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import AppKit

extension AppModel {
    struct PictureTrial {
        let host: Host
        let app: LibraryApp
        let previous: ContinuationFormat
        let requested: ContinuationFormat
    }

    struct EndedContinuation {
        let host: Host
        let app: LibraryApp
        let format: ContinuationFormat?
    }

    func startEndedGame() {
        guard let ended = endedContinuation else { return }
        stream(app: ended.app, on: ended.host, startFormat: ended.format)
    }

    private func screenSizeConfig(host: Host, app: LibraryApp) -> StreamConfig {
        var config = nativeStreamConfig(for: host, app: app)
        let size = effectiveValuesForPreset(.matchDisplay)
        config.width = size.width
        config.height = size.height
        return config
    }

    var continuationHistory: ContinuationHistory { ContinuationHistory(defaults: settingsDefaults) }

    func requestQuitGame(on host: Host, app: LibraryApp) {
        guard !menuStopInProgress else { return }
        let alert = NSAlert()
        alert.messageText = "Quit \(app.name) on \(host.displayName)?"
        alert.informativeText = "Unsaved progress may be lost. Other streams from \(host.displayName) will stop."
        alert.addButton(withTitle: "Quit \(app.name)").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do { try await self.quitRunningApp(on: host, expectedAppID: app.id) } catch {
                    self.nativeStreamError = Self.quitFailureMessage(for: error, hostName: host.displayName)
                }
            }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else { confirm(alert.runModal()) }
    }

    func makeNativeSession(server: ServerInfo, disposition: StreamHostDisposition, takeoverAuthorized: Bool,
                           approvedOccupant: Int?, continuing: Bool) async -> (StreamSession, BandwidthSignals?) {
        let (session, bandwidth) = StreamSession.mac(server: server, disposition: disposition, makeNetwork: makeNetwork)
        nativeSession = session
        await session.authorizeTakeover(takeoverAuthorized)
        if let approvedOccupant { await session.approveReplacement(of: approvedOccupant) }
        if continuing { await session.requireContinuation(previous: pictureTrial?.previous) }
        return (session, bandwidth)
    }

    func runningApp(on host: Host) -> LibraryApp? {
        if isStreaming, let active = lastLaunchAttempt, active.host.id == host.id { return active.app }
        guard let live = hostLiveStatus, HostLiveStatus.isFresh(live, for: host.id),
              let id = live.runningAppID, id > 0 else { return nil }
        if let app = host.apps.first(where: { $0.id == id }) { return app }
        let name: String
        if case .streamingApp(let reported) = live.state { name = reported } else { name = "the running app" }
        return LibraryApp(id: id, name: name, hdr: false, hidden: true)
    }

    func continuationTitle(on host: Host, app: LibraryApp) -> String {
        if isStreaming, lastLaunchAttempt?.host.id == host.id { return "Back to stream" }
        return continuationHistory.previous(pc: host.id, app: app.id) == nil ? "Continue here" : "Resume"
    }

    func continuationConfig(for host: Host, app: LibraryApp, continuing: Bool,
                            useScreenSize: Bool, startFormat: ContinuationFormat? = nil) -> StreamConfig {
        var config = useScreenSize ? screenSizeConfig(host: host, app: app) : nativeStreamConfig(for: host, app: app)
        guard continuing || startFormat != nil || runningApp(on: host)?.id == app.id else {
            if !useScreenSize, let preferred = continuationHistory.preferredStart(pc: host.id, app: app.id,
                source: config.continuationFormat, screen: screenSizeConfig(host: host, app: app).continuationFormat) {
                config.request = preferred.applying(to: config.request)
            }
            return config
        }
        let previous = startFormat ?? continuationHistory.previous(pc: host.id, app: app.id)
        if useScreenSize {
            config.request.resumeResolutionChange = true
            if continuing, let previous {
                pictureTrial = PictureTrial(host: host, app: app, previous: previous, requested: config.continuationFormat)
            }
            return config
        }
        config.request.changeResolution = false
        if let format = previous?.supported(maximumWidth: 7680, maximumHeight: 4320,
                                              maximumFPS: 240, supportsHDR: config.hdrRequested) {
            config.width = format.width
            config.height = format.height
            config.fps = format.fps
            if !format.hdr {
                config.videoFormats = config.videoFormats.subtracting([.hevcMain10, .hevcRext10_444, .av1Main10, .av1High10_444])
            }
            config.request.changeResolution = format.changeResolution
            config.request.resumeResolutionChange = true
        }
        return config
    }

    func rememberContinuation(on host: Host) {
        guard let format = activeContinuationFormat, let app = lastLaunchAttempt?.app, pictureTrial == nil else { return }
        continuationHistory.remember(format, pc: host.id, app: app.id)
        activeContinuationFormat = nil
    }

    func screenSizeNeedsRestart(app: LibraryApp, host: Host) -> Bool {
        let native = screenSizeConfig(host: host, app: app).continuationFormat
        return continuationHistory.rejected(native, pc: host.id, app: app.id)
            || continuationHistory.previous(pc: host.id, app: app.id) == nil
    }

    func confirmScreenSize(app: LibraryApp, host: Host, restart: Bool) {
        stream(app: app, on: host, approvedOccupant: restart ? app.id : nil,
               continuing: !restart, useScreenSize: true)
    }

    func rejectPictureTrial() {
        guard let trial = pictureTrial else { return }
        continuationHistory.reject(trial.requested, previous: trial.previous, pc: trial.host.id, app: trial.app.id)
        pictureTrial = nil
    }

    func keepPictureSize() {
        guard let trial = pictureTrial else { return }
        // A good picture does not prove Sunshine changed the physical display mode.
        continuationHistory.prefer(trial.requested, previous: trial.previous, pc: trial.host.id, app: trial.app.id)
        activeContinuationFormat = nil
        pictureTrial = nil
    }

    func restorePictureSize() {
        guard let trial = pictureTrial else { return }
        continuationHistory.reject(trial.requested, previous: trial.previous, pc: trial.host.id, app: trial.app.id)
        pictureTrial = nil
        let ending = nativeStreamTask
        Task {
            await nativeSession?.disconnectLeavingGameRunning()
            await ending?.value
            stream(app: trial.app, on: trial.host, continuing: true)
        }
    }
}

extension StreamConfig {
    var hdrRequested: Bool {
        !videoFormats.isDisjoint(with: [.hevcMain10, .hevcRext10_444, .av1Main10, .av1High10_444])
    }

    var continuationFormat: ContinuationFormat {
        ContinuationFormat(width: width, height: height, fps: fps,
                           hdr: hdrRequested, changeResolution: request.changeResolution)
    }
}
