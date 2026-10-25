// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import UIKit

extension LauncherModel {
    struct GameAction: Identifiable {
        let id = UUID()
        let running: HostApp
        let target: HostApp?
        var resize = false
        var restart = false
    }

    struct PictureTrial {
        let app: HostApp
        let previous: ContinuationFormat
        let requested: ContinuationFormat
        let pc: String
    }

    enum StreamReturn {
        case replace(GameAction)
        case restore(HostApp, ContinuationFormat)
        case ended(HostApp, ContinuationFormat?)
    }

    func applyStreamReturn(pcID: String) {
        let action = streamReturn
        streamReturn = nil
        guard selected?.server.uniqueId == pcID else { return }
        switch action {
        case .replace(let action):
            if let runningApp, runningApp.id != action.target?.id {
                pendingGameAction = GameAction(running: runningApp, target: action.target)
            }
        case .restore(let app, let format):
            if runningApp?.id == app.id { continueGame() } else if runningApp == nil { offerStart(app, format: format) }
        case .ended(let app, let format):
            if runningApp == nil { offerStart(app, format: format) }
        case nil: break
        }
    }

    private func offerStart(_ app: HostApp, format: ContinuationFormat?) {
        endedGame = app
        endedFormat = format
        message = StreamFailureCopy.gameEnded(app.name, pc: selectedName ?? "the PC")
    }

    func startEndedGame() {
        guard active, !busy, session == nil, let app = endedGame else { return }
        openStream(app, continuing: false, startFormat: endedFormat)
        endedGame = nil
        endedFormat = nil
    }

    var continuationTitle: String {
        guard let selected, let runningApp else { return "Continue here" }
        return history.previous(pc: selected.server.uniqueId, app: runningApp.id) == nil ? "Continue here" : "Resume"
    }

    func updateRunningApp(_ info: ServerInfo, list: [HostApp]? = nil) {
        guard info.currentGameID > 0 else {
            if !info.isBusy { history.invalidate(pc: info.uniqueId) }
            runningApp = nil
            return
        }
        runningApp = (list ?? allApps).first { $0.id == info.currentGameID }
            ?? HostApp(id: info.currentGameID, name: "the running app", hdrCapable: false, hidden: true)
    }

    func launch(_ app: HostApp) {
        guard active, !busy, session == nil, let selected, let calls else { return }
        guard !needsRefresh else { refreshPC(); return }
        let attempt = generation
        busy = true
        operation = Task {
            defer { if isCurrent(attempt) { busy = false } }
            do {
                let info = try await calls.status(selected)
                guard isCurrent(attempt) else { return }
                updateRunningApp(info)
                if let runningApp, runningApp.id != app.id {
                    pendingGameAction = GameAction(running: runningApp, target: app)
                } else {
                    openStream(app, continuing: runningApp?.id == app.id)
                }
            } catch {
                guard isCurrent(attempt) else { return }
                runningApp = nil
                message = LauncherFailureCopy.message(error, pcName: selected.server.serverName)
            }
        }
    }

    func continueGame() {
        guard let runningApp else { return }
        // The engine must not turn an ended continuation into a fresh launch.
        guard active, !busy, session == nil else { return }
        openStream(runningApp, continuing: true)
    }

    func requestQuit() {
        guard !busy, let runningApp else { return }
        pendingGameAction = GameAction(running: runningApp, target: nil)
    }

    func requestScreenSize() {
        guard leaveGamesRunning, !busy, let runningApp else { return }
        pendingGameAction = GameAction(running: runningApp, target: runningApp, resize: true,
                                       restart: screenSizeNeedsRestart)
    }

    var screenSizeNeedsRestart: Bool {
        guard let selected, let runningApp else { return true }
        guard history.previous(pc: selected.server.uniqueId, app: runningApp.id) != nil else { return true }
        let target = Self.streamWindow.flatMap { try? streamProfile.screenSize(windowPixels: $0.pixels,
            maximumFramesPerSecond: $0.fps) }
        return target.map { history.rejected($0.continuationFormat, pc: selected.server.uniqueId, app: runningApp.id) }
            ?? true
    }

    func confirmGameAction(_ action: GameAction) {
        guard active, !busy, session == nil, let selected, let calls else { return }
        pendingGameAction = nil
        if let target = action.target {
            openStream(target, continuing: action.resize && !action.restart,
                       useScreenSize: action.resize,
                       approvedOccupant: action.resize && !action.restart ? nil : action.running.id)
            return
        }
        let attempt = generation
        busy = true
        operation = Task {
            defer { if isCurrent(attempt) { busy = false } }
            do {
                try await calls.quit(selected, action.running.id)
                guard isCurrent(attempt) else { return }
                runningApp = nil
                refreshPC()
            } catch let changed as TakeoverRequired {
                guard isCurrent(attempt) else { return }
                var info = selected.server
                info.currentGameID = changed.appID
                updateRunningApp(info)
                message = StreamFailureCopy.runningAppChanged(selected.server.serverName)
            } catch {
                guard isCurrent(attempt) else { return }
                message = StreamSessionFailureCopy.quit(error, app: action.running.name, pc: selected.server.serverName)
            }
        }
    }

    func refreshPC() {
        guard let pc = savedPCs.first(where: { $0.id == selected?.server.uniqueId }) else { return }
        select(pc)
    }

    func keepPictureSize() {
        guard let trial = pictureTrial else { return }
        history.prefer(trial.requested, previous: trial.previous, pc: trial.pc, app: trial.app.id)
        pictureTrial = nil
    }

    func restorePictureSize() {
        guard let trial = pictureTrial else { return }
        history.reject(trial.requested, previous: trial.previous, pc: trial.pc, app: trial.app.id)
        pictureTrial = nil
        if let session {
            streamReturn = .restore(trial.app, trial.previous)
            session.disconnect()
        } else if runningApp?.id == trial.app.id {
            continueGame()
        } else { offerStart(trial.app, format: trial.previous) }
    }

    /// The active window's physical pixels as a stream will see them; iPhone streams turn landscape.
    private static var streamWindow: (pixels: CGSize, fps: Int)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.keyWindow ?? scene.windows.first else { return nil }
        let scale = scene.screen.nativeScale
        var pixels = CGSize(width: window.bounds.width * scale, height: window.bounds.height * scale)
        if scene.traitCollection.userInterfaceIdiom != .pad, pixels.height > pixels.width {
            pixels = CGSize(width: pixels.height, height: pixels.width)
        }
        return (pixels, scene.screen.maximumFramesPerSecond)
    }

    private func preferredStart(for app: HostApp) -> ContinuationFormat? {
        guard let selected, let window = Self.streamWindow,
            let source = try? streamProfile.resolve(windowPixels: window.pixels, maximumFramesPerSecond: window.fps),
            let native = try? streamProfile.screenSize(windowPixels: window.pixels,
                                                       maximumFramesPerSecond: window.fps) else {
            return nil
        }
        return history.preferredStart(pc: selected.server.uniqueId, app: app.id,
                                      source: source.continuationFormat, screen: native.continuationFormat)
    }

    private func openStream(_ app: HostApp, continuing: Bool, useScreenSize: Bool = false,
                            approvedOccupant: Int? = nil, startFormat: ContinuationFormat? = nil) {
        guard let selected, let calls else { return }
        stopDiscovery()
        let previous = history.previous(pc: selected.server.uniqueId, app: app.id)
        let preferred = startFormat ?? (continuing || useScreenSize ? nil : preferredStart(for: app))
        let session = calls.makeSession(StreamLaunch(network: selected.network,
            pcID: selected.server.uniqueId, pcName: selected.server.serverName, appID: app.id, appName: app.name,
            profile: streamProfile, mouseStick: mouseStick, touchMouseEnabled: touchMouseEnabled,
            leaveGamesRunning: leaveGamesRunning, continuing: continuing, previousFormat: previous,
            useScreenSize: useScreenSize, approvedOccupant: approvedOccupant, startFormat: preferred))
        session.continuationEnded = { [weak self] in
            self?.streamReturn = .ended(app, previous)
        }
        session.startupFailed = { [weak self] requested in
            guard useScreenSize, let self, let previous, let requested else { return }
            self.pictureTrial = nil
            self.history.reject(requested.continuationFormat, previous: previous,
                                pc: selected.server.uniqueId, app: app.id)
        }
        session.keepSize = { [weak self, weak session] in
            self?.keepPictureSize()
            session?.pictureNeedsReview = false
        }
        session.restoreSize = { [weak self, weak session] in
            session?.pictureNeedsReview = false
            self?.restorePictureSize()
        }
        session.firstVideo = { [weak self] format in
            guard let self else { return }
            if continuing, useScreenSize, let previous {
                self.pictureTrial = PictureTrial(app: app, previous: previous,
                    requested: format.continuationFormat, pc: selected.server.uniqueId)
            } else {
                self.history.remember(format.continuationFormat, pc: selected.server.uniqueId, app: app.id)
            }
        }
        session.replacementRequired = { [weak self] appID in
            guard let self else { return }
            var info = selected.server
            info.currentGameID = appID
            self.updateRunningApp(info)
            if let running = self.runningApp { self.streamReturn = .replace(GameAction(running: running, target: app)) }
        }
        self.session = session
        stream = session
    }
}
