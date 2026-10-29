// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppIntents
import Foundation
import Observation

/// A paired PC, as Shortcuts and Siri see it. Hashable over the name too, so
/// a rename counts as a change to what Siri knows.
struct PCEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "PC"
    static let defaultQuery = PCQuery()

    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    #if os(macOS)
    init(host: Host) {
        id = host.id
        name = host.displayName
    }
    #endif

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "display"))
    }
}

struct PCQuery: EnumerableEntityQuery {
    @MainActor func allEntities() async throws -> [PCEntity] {
        #if os(macOS)
        try await AppModel.forIntent().hosts.map(PCEntity.init)
        #else
        try await LauncherModel.forIntent().commandPCs().map { PCEntity(id: $0.id, name: $0.name) }
        #endif
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [PCEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }
}

struct StreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Stream from PC"
    static let description = IntentDescription("Opens Glimmer and streams an app from a paired PC.")
    @available(macOS 26, *)
    static var supportedModes: IntentModes { .foreground }
    // The macOS 15 spelling of the same foreground launch.
    static let openAppWhenRun = true

    @Parameter(title: "PC")
    var pc: PCEntity

    @Parameter(
        title: "App",
        description: "An app on the PC, such as Desktop. Leave it empty for the app Glimmer's Stream button shows.")
    var app: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Stream from \(\.$pc)") { \.$app }
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if os(macOS)
        try await Self.stream(pc, app: app, model: AppModel.forIntent())
        #else
        try await LauncherModel.forIntent().streamFromCommand(pc: pc.id, app: app)
        #endif
        return .result()
    }

    #if os(macOS)
    /// Tests stand in for the status probe, the route wait and the launch.
    @MainActor static func stream(
        _ pc: PCEntity, app: String?, model: AppModel,
        probe: @MainActor (AppModel, Host) async -> Void = { _ = await $0.pollHostStatusOnce(for: $1.id, appListFor: nil) },
        settle: @MainActor (AppModel, Host) async -> Void = { await $0.awaitRouteSettled(for: $1) },
        launch: @MainActor (AppModel, LibraryApp, Host) -> Void = { $0.requestStream(app: $1, on: $2) }
    ) async throws {
        let host = try model.pairedHost(pc)
        let target = app.flatMap(host.app(named:))
        if let app, target == nil { throw PCIntentError.noApp(app, pc: host.displayName) }
        if model.isStreaming {
            if AppModel.isLiveStream(target, on: host, live: model.lastLaunchAttempt) {
                model.resumeStreamWindow()
                return
            }
            if let target, model.lastLaunchAttempt?.host.id == host.id {
                launch(model, target, host)
                return
            }
            throw PCIntentError.alreadyStreaming
        }
        if model.selectedHost?.id != host.id { model.selectHost(host) }
        // The Stream button's app is the PC's running one only while a fresh sample
        // names it; a cold launch or a PC switch has none yet.
        if target == nil, !HostLiveStatus.isFresh(model.hostLiveStatus, for: host.id) {
            await probe(model, host)
        }
        guard let launchApp = target ?? model.heroTargetApp(on: host) else {
            throw PCIntentError.failed("Glimmer doesn't know any apps on \(host.displayName).")
        }
        await settle(model, host)
        try Task.checkCancellation()
        guard !model.isStreaming else { throw PCIntentError.alreadyStreaming }
        let currentHost = try model.pairedHost(pc)
        if model.selectedHost?.id != currentHost.id { model.selectHost(currentHost) }
        launch(model, launchApp, currentHost)
    }
    #endif
}

#if os(macOS)
struct WakePCIntent: AppIntent {
    static let title: LocalizedStringResource = "Wake PC"
    static let description = IntentDescription("Sends Wake on LAN to a paired PC and waits until it's ready to stream.")

    @Parameter(title: "PC")
    var pc: PCEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Wake \(\.$pc)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try await AppModel.forIntent()
        let host = try model.pairedHost(pc)
        guard host.wakeOnLAN else { throw PCIntentError.wakeOff(host.displayName) }
        let outcome = await model.sendWakeAndWait(host, waitSeconds: AppModel.wakeBudgetSeconds)
        try Self.checkOutcome(outcome, pc: host.displayName)
        return .result()
    }

    static func checkOutcome(_ outcome: WakeOutcome, pc: String) throws {
        try Task.checkCancellation()
        if outcome == .cancelled { throw CancellationError() }
        if let failure = PCIntentError(outcome, pc: pc) { throw failure }
    }
}

#endif

struct QuitAppOnPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit App on PC"
    static let description = IntentDescription("Quits the app a paired PC is streaming and ends its session.")

    @Parameter(title: "PC")
    var pc: PCEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Quit the app on \(\.$pc)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if os(macOS)
        let model = try await AppModel.forIntent()
        let host = try model.pairedHost(pc)
        Diag.notice("Quit App on PC from Shortcuts: \(host.displayName, privacy: .private)", "Stream")
        do {
            try await model.quitRunningApp(on: host)
        } catch {
            // The launcher's words: a changed certificate says Pair Again…, not "couldn't reach".
            throw PCIntentError.failed(AppModel.quitFailureMessage(for: error, hostName: host.displayName))
        }
        #else
        try await LauncherModel.forIntent().quitFromCommand(pc: pc.id, confirmation: false)
        #endif
        return .result()
    }
}

struct StopStreamingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Streaming"
    static let description = IntentDescription("Stops this device's stream using your disconnect setting.")

    @MainActor func perform() async throws -> some IntentResult {
        #if os(macOS)
        try await Self.stop(model: AppModel.forIntent())
        #else
        let model = try await LauncherModel.forIntent()
        let result = await model.stopFromCommand()
        guard result == .stopped else { throw PCIntentError.failed(result.message) }
        #endif
        return .result()
    }

    #if os(macOS)
    @MainActor static func stop(model: AppModel) async throws {
        let result = await model.stopActiveStream(source: "Shortcuts")
        guard result == .stopped else { throw PCIntentError.failed(result.message) }
    }
    #endif
}

struct GlimmerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StreamIntent(), phrases: ["Stream \(\.$pc) in \(.applicationName)"],
                    shortTitle: "Stream from PC", systemImageName: "play.fill")
        AppShortcut(intent: StopStreamingIntent(), phrases: ["Stop streaming in \(.applicationName)"],
                    shortTitle: "Stop Streaming", systemImageName: "stop.fill")
        #if os(macOS)
        AppShortcut(intent: WakePCIntent(), phrases: ["Wake \(\.$pc) with \(.applicationName)"],
                    shortTitle: "Wake PC", systemImageName: "power")
        #endif
    }

    #if os(macOS)
    /// Siri learns PC names from the shortcut parameters, so refresh them when
    /// a PC is paired, renamed or removed. Reloading the same PCs is ignored.
    @MainActor @discardableResult
    static func trackPCs(of model: AppModel,
                         bootstrap: @escaping @MainActor (AppModel) -> Task<Void, Never> = { $0.startBootstrap() },
                         update: @escaping @MainActor () -> Void = { updateAppShortcutParameters() }) -> Task<Void, Never> {
        Task {
            await bootstrap(model).value
            var known: Set<PCEntity>?
            if #available(macOS 26, *) {
                for await pcs in Observations({ Set(model.hosts.map(PCEntity.init)) }) where pcs != known {
                    known = pcs
                    update()
                }
            } else {
                await forEachTrackedValue({ Set(model.hosts.map(PCEntity.init)) }, perform: { pcs in
                    guard pcs != known else { return }
                    known = pcs
                    update()
                })
            }
        }
    }
    #endif
}

enum PCIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady, notPaired, alreadyStreaming
    #if os(macOS)
    case notSent
    case wakeOff(String), noAddress(String), noAnswer(String)
    #endif
    case noApp(String, pc: String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Glimmer is still starting. Try again in a moment."
        case .notPaired: "That PC isn't paired with Glimmer anymore."
        case .alreadyStreaming: "\(StreamCommandMatch.alreadyStreaming)"
        #if os(macOS)
        case .notSent: "\(AppModel.WakeFailureReason.couldNotSend.line)"
        case .wakeOff(let pc): "\(AppModel.wakeOffMessage(pc))"
        case .noAddress(let pc): "\(AppModel.wakeNoMacMessage(pc))"
        case .noAnswer(let pc): "No answer from \(pc). \(AppModel.wakeNoAnswerHint)"
        #endif
        case let .noApp(app, pc): "\(pc) has no app named \(app)."
        case .failed(let why): "\(why)"
        }
    }

    #if os(macOS)
    /// Cancellation is handled separately from failures to wake the PC.
    init?(_ outcome: WakeOutcome, pc: String) {
        switch outcome {
        case .answered, .cancelled: return nil
        case .noMac: self = .noAddress(pc)
        case .couldNotSend: self = .notSent
        case .sent, .noAnswer: self = .noAnswer(pc)
        }
    }
    #endif
}

#if os(macOS)
extension AppModel {
    /// The model once launch has loaded the paired PCs.
    static func forIntent() async throws -> AppModel {
        guard let model = AppDelegate.boundManager else { throw PCIntentError.notReady }
        await model.startBootstrap().value
        return model
    }

    /// A shortcut naming the PC being streamed, and its app or none, means
    /// the stream already running.
    nonisolated static func isLiveStream(_ app: LibraryApp?, on host: Host, live: (app: LibraryApp, host: Host)?) -> Bool {
        guard let live, live.host.id == host.id else { return false }
        return app.map { $0.id == live.app.id } ?? true
    }

    func pairedHost(_ pc: PCEntity) throws -> Host {
        guard let host = hosts.first(where: { $0.id == pc.id }) else { throw PCIntentError.notPaired }
        return host
    }
}

#endif
