// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Observation
import GlimmerEngine

extension LauncherModel {
    static weak var intentModel: LauncherModel?

    static func forIntent() async throws -> LauncherModel {
        guard let model = intentModel else { throw PCIntentError.notReady }
        return model
    }

    func commandPCs() throws -> [SavedPC] { try calls?.savedPCs() ?? savedPCs }

    private func commandPC(_ query: String) throws -> SavedPC {
        guard let pc = try commandPCs().first(where: {
            StreamCommandMatch.pc(query, names: [$0.id, $0.name, $0.address])
        }) else {
            throw PCIntentError.notPaired
        }
        return pc
    }

    func streamFromCommand(pc query: String, app name: String?) async throws {
        let pc = try commandPC(query)
        commandEpoch &+= 1
        let epoch = commandEpoch
        pendingCommandPCID = pc.id
        defer { if commandEpoch == epoch { pendingCommandPCID = nil } }
        if let session, !session.phase.isEnded {
            guard session.launch.pcID == pc.id else { throw PCIntentError.alreadyStreaming }
            guard let name else { stream = session; return }
            guard let target = StreamCommandMatch.app(name, in: allApps, name: \.name) else {
                throw PCIntentError.noApp(name, pc: pc.name)
            }
            if target.id == session.launch.appID { stream = session; return }
            session.showControls()
            let running = HostApp(id: session.launch.appID, name: session.launch.appName,
                                  hdrCapable: false, hidden: false)
            pendingGameAction = GameAction(running: running, target: target)
            return
        }
        if session != nil {
            streamClosed()
            await waitUntilStreamClosed()
            guard commandEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        }
        try await prepareCommand(pc, epoch: epoch)
        let target = name.flatMap { StreamCommandMatch.app($0, in: allApps, name: \.name) }
        if let name, target == nil { throw PCIntentError.noApp(name, pc: pc.name) }
        let defaultApp = StreamCommandMatch.app("Desktop", in: apps, name: \.name) ?? apps.first
        guard let app = target ?? runningApp ?? defaultApp else {
            throw PCIntentError.failed("Glimmer doesn't know any apps on \(pc.name).")
        }
        launch(app)
        await waitUntilOperationFinishes()
        try Task.checkCancellation()
        guard commandEpoch == epoch else { throw CancellationError() }
        if let message { throw PCIntentError.failed(message) }
    }

    private func prepareCommand(_ pc: SavedPC, epoch: UInt64) async throws {
        for await ready in Observations({ self.active || self.commandEpoch != epoch }) where ready { break }
        try Task.checkCancellation()
        guard commandEpoch == epoch else { throw CancellationError() }
        select(pc)
        await waitUntilOperationFinishes()
        try Task.checkCancellation()
        guard commandEpoch == epoch else { throw CancellationError() }
        guard selected?.server.uniqueId == pc.id else {
            throw PCIntentError.failed(message ?? "Couldn't connect to \(pc.name). Check Sunshine and try again.")
        }
    }

    func stopFromCommand(matching query: String? = nil) async -> CommandStopResult {
        if let query {
            let id = pendingCommandPCID ?? session?.launch.pcID ?? selected?.server.uniqueId
            guard let pc = try? commandPC(query), pc.id == id else { return .pcMismatch }
        }
        let pending = pendingCommand || busy || pendingGameAction != nil || commandTask != nil
        pendingCommandPCID = nil
        commandEpoch &+= 1
        commandTask?.cancel()
        commandTask = nil
        cancelOperation()
        guard let session else { return pending ? .stopped : .noActiveStream }
        session.disconnect()
        await session.waitUntilStopped()
        streamClosed()
        await waitUntilStreamClosed()
        return .stopped
    }

    func quitFromCommand(pc query: String, confirmation: Bool) async throws {
        let pc = try commandPC(query)
        if let session, !session.phase.isEnded {
            guard session.launch.pcID == pc.id else { throw PCIntentError.alreadyStreaming }
            if confirmation {
                let app = HostApp(id: session.launch.appID, name: session.launch.appName,
                                  hdrCapable: false, hidden: false)
                session.showControls()
                pendingGameAction = GameAction(running: app, target: nil)
            } else {
                session.quitGame()
                await session.waitUntilStopped()
                if let failure = session.quitFailure { throw PCIntentError.failed(failure) }
            }
            return
        }
        if !active, !confirmation {
            guard let calls else { throw PCIntentError.notReady }
            let prepared = try await calls.prepare(pc.server, true)
            try Task.checkCancellation()
            guard prepared.server.currentGameID > 0 else { return }
            try await calls.quit(prepared, prepared.server.currentGameID)
            needsRefresh = true
            return
        }
        commandEpoch &+= 1
        let epoch = commandEpoch
        try await prepareCommand(pc, epoch: epoch)
        guard let runningApp else { return }
        if confirmation { requestQuit(); return }
        confirmGameAction(GameAction(running: runningApp, target: nil))
        await waitUntilOperationFinishes()
        try Task.checkCancellation()
        guard commandEpoch == epoch else { throw CancellationError() }
        if let message { throw PCIntentError.failed(message) }
    }

    func confirmStreamingAction(_ action: GameAction) {
        guard let session, active, !busy else { return }
        pendingGameAction = nil
        if action.target == nil { session.quitGame(); return }
        commandEpoch &+= 1
        let epoch = commandEpoch
        pendingCommandPCID = session.launch.pcID
        commandTask = Task {
            defer { if commandEpoch == epoch { pendingCommandPCID = nil } }
            streamClosed()
            await waitUntilStreamClosed()
            guard commandEpoch == epoch, !Task.isCancelled,
                  selected?.server.uniqueId == session.launch.pcID else { return }
            commandTask = nil
            confirmGameAction(action)
        }
    }

    struct URLCommandRequest: Identifiable {
        let id = UUID()
        let command: GlimmerCommandURL
        let prompt: CommandURLPrompt
        let session: StreamSessionModel?
        let epoch: UInt64
        let generation: UInt64
    }

    @discardableResult
    func handleCommandURL(_ url: URL) -> Task<Void, Never>? {
        guard let command = GlimmerCommandURL.parse(url), command.action != .wake else { return nil }
        // Quit already presents the running game's explicit confirmation after authenticated preparation.
        guard CommandURLPrompt.requiresConfirmation(command.action), command.action != .quit else {
            return dispatchURLCommand(command)
        }
        do {
            let pc = try command.pc.map(commandPC)
            if command.action == .stop {
                if let pc, pc.id != session?.launch.pcID,
                   pc.id != selected?.server.uniqueId, pc.id != pendingCommandPCID {
                    message = CommandStopResult.pcMismatch.message
                    return nil
                }
                guard session != nil || pendingCommand || busy || commandTask != nil else {
                    message = CommandStopResult.noActiveStream.message
                    return nil
                }
            }
            let prompt = CommandURLPrompt(action: command.action,
                pc: pc?.name ?? session?.launch.pcName ?? selectedName ?? "the PC",
                app: command.app ?? session?.launch.appName ?? "the app")
            pendingGameAction = nil
            pendingURLCommand = URLCommandRequest(command: command, prompt: prompt, session: session,
                                                   epoch: commandEpoch, generation: generation)
            session?.showControls()
        } catch { message = LauncherFailureCopy.message(error, pcName: selectedName ?? "the PC") }
        return nil
    }

    @discardableResult
    func confirmURLCommand(_ request: URLCommandRequest) -> Task<Void, Never>? {
        guard pendingURLCommand?.id == request.id else { return nil }
        pendingURLCommand = nil
        guard active, session === request.session, commandEpoch == request.epoch,
              generation == request.generation else { return nil }
        return dispatchURLCommand(request.command, expected: request)
    }

    private func dispatchURLCommand(_ command: GlimmerCommandURL,
                                    expected: URLCommandRequest? = nil) -> Task<Void, Never> {
        Task {
            if let expected {
                guard session === expected.session, commandEpoch == expected.epoch,
                      generation == expected.generation else { return }
            }
            do {
                switch command.action {
                case .stream:
                    if let pc = command.pc { try await streamFromCommand(pc: pc, app: command.app) }
                case .stop:
                    let result = await stopFromCommand(matching: command.pc)
                    if result != .stopped { message = result.message }
                case .quit:
                    if let pc = command.pc { try await quitFromCommand(pc: pc, confirmation: true) }
                case .wake: break
                }
            } catch is CancellationError {} catch let error as PCIntentError {
                message = String(localized: error.localizedStringResource)
            } catch { message = LauncherFailureCopy.message(error, pcName: selectedName ?? "the PC") }
        }
    }
}
