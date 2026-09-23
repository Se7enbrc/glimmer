//
//  GlimmerIntents.swift
//
//  Shortcuts, Siri and Spotlight actions: stream from a PC, wake it, quit its
//  app. Each one runs the launcher's own entry points, not a copy of them.
//

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

    init(host: Host) {
        id = host.id
        name = host.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "desktopcomputer"))
    }
}

struct PCQuery: EnumerableEntityQuery {
    @MainActor func allEntities() async throws -> [PCEntity] {
        try await AppModel.forIntent().hosts.map(PCEntity.init)
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [PCEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }
}

struct StreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Stream from PC"
    static let description = IntentDescription("Opens Glimmer and streams an app from a paired PC.")
    static let supportedModes: IntentModes = .foreground

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
        let model = try await AppModel.forIntent()
        let host = try model.pairedHost(pc)
        let target = app.flatMap(host.app(named:))
        if let app, target == nil { throw PCIntentError.noApp(app, pc: host.displayName) }
        if model.isStreaming {
            // Asking for the stream already running just shows it, as activating Glimmer may have.
            guard AppModel.isLiveStream(target, on: host, live: model.lastLaunchAttempt) else {
                throw PCIntentError.alreadyStreaming
            }
            model.resumeStreamWindow()
            return .result()
        }
        if model.selectedHost?.id != host.id { model.selectHost(host) }
        // The Stream button's app is the PC's running one only while a fresh sample
        // names it; a cold launch or a PC switch has none yet.
        if target == nil, !HostLiveStatus.isFresh(model.hostLiveStatus, for: host.id) {
            _ = await model.pollHostStatusOnce(for: host.id, appListFor: nil)
        }
        await model.awaitRouteSettled(for: host)
        try Task.checkCancellation()
        guard !model.isStreaming else { throw PCIntentError.alreadyStreaming }
        if let target {
            model.requestStream(app: target, on: host)
        } else {
            model.streamHeroApp()
        }
        return .result()
    }
}

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
        if let failure = PCIntentError(outcome, pc: host.displayName) {
            // A wait cut short means Shortcuts stopped the action.
            try Task.checkCancellation()
            throw failure
        }
        return .result()
    }
}

struct QuitAppOnPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit App on PC"
    static let description = IntentDescription("Quits the app a paired PC is streaming and ends its session.")

    @Parameter(title: "PC")
    var pc: PCEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Quit the app on \(\.$pc)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try await AppModel.forIntent()
        let host = try model.pairedHost(pc)
        Diag.notice("Quit App on PC from Shortcuts: \(host.displayName)", "Stream")
        if model.streamingHostID == host.id, await model.stopOwnStream(source: "Shortcuts") {
            return .result()
        }
        do {
            try await model.quitRunningApp(on: host)
        } catch {
            // The launcher's words: a changed certificate says Pair Again…, not "couldn't reach".
            throw PCIntentError.failed(AppModel.quitFailureMessage(for: error, hostName: host.displayName))
        }
        return .result()
    }
}

struct GlimmerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StreamIntent(), phrases: ["Stream \(\.$pc) in \(.applicationName)"],
                    shortTitle: "Stream from PC", systemImageName: "play.fill")
        AppShortcut(intent: WakePCIntent(), phrases: ["Wake \(\.$pc) with \(.applicationName)"],
                    shortTitle: "Wake PC", systemImageName: "power")
    }

    /// Siri learns PC names from the shortcut parameters, so refresh them when
    /// a PC is paired, renamed or removed. Reloading the same PCs is ignored.
    @MainActor static func trackPCs(of model: AppModel) {
        Task {
            await model.startBootstrap().value
            var known: Set<PCEntity>?
            for await pcs in Observations({ Set(model.hosts.map(PCEntity.init)) }) where pcs != known {
                known = pcs
                updateAppShortcutParameters()
            }
        }
    }
}

enum PCIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady, notPaired, alreadyStreaming, notSent
    case noApp(String, pc: String)
    case wakeOff(String), noAddress(String), noAnswer(String), failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Glimmer is still starting. Try again in a moment."
        case .notPaired: "That PC isn't paired with Glimmer anymore."
        case .alreadyStreaming: "\(CommandChannel.alreadyStreaming)"
        case .notSent: "\(AppModel.WakeFailureReason.couldNotSend.line)"
        case let .noApp(app, pc): "\(pc) has no app named \(app)."
        case .wakeOff(let pc): "\(AppModel.wakeOffMessage(pc))"
        case .noAddress(let pc): "\(AppModel.wakeNoMacMessage(pc))"
        case .noAnswer(let pc): "No answer from \(pc). \(AppModel.wakeNoAnswerHint)"
        case .failed(let why): "\(why)"
        }
    }

    /// Why Wake PC failed; nil when the PC answered. `sent` only comes back from
    /// a wait that was stopped.
    init?(_ outcome: WakeOutcome, pc: String) {
        switch outcome {
        case .answered: return nil
        case .noMac: self = .noAddress(pc)
        case .couldNotSend: self = .notSent
        case .sent, .noAnswer: self = .noAnswer(pc)
        }
    }
}

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
