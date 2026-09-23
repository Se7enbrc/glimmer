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
        description: "An app on the PC, such as Desktop. Leave it empty to resume the running app or start the default one.")
    var app: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Stream from \(\.$pc)") { \.$app }
    }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try await AppModel.forIntent()
        let host = try model.pairedHost(pc)
        guard !model.isStreaming else { throw PCIntentError.alreadyStreaming }
        let target = app.flatMap(host.app(named:))
        if let app, target == nil { throw PCIntentError.noApp(app, pc: host.displayName) }
        if model.selectedHost?.id != host.id { model.selectHost(host) }
        if let target { model.requestStream(app: target, on: host) } else { model.streamHeroApp() }
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
        switch await model.sendWakeAndWait(host, waitSeconds: AppModel.wakeBudgetSeconds) {
        case .answered: return .result()
        case .noMac: throw PCIntentError.noAddress(host.displayName)
        case .couldNotSend: throw PCIntentError.notSent
        case .sent, .noAnswer:
            // Either one before the budget ran out means Shortcuts stopped the action.
            try Task.checkCancellation()
            throw PCIntentError.noAnswer(host.displayName)
        }
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
        if model.isStreaming, model.lastLaunchAttempt?.host.id == host.id,
           await model.stopOwnStream(source: "Shortcuts") {
            return .result()
        }
        do {
            try await model.quitRunningApp(on: host)
        } catch StreamError.launchFailed(let why), StreamError.pairingFailed(let why) {
            throw PCIntentError.failed(why)
        } catch {
            throw PCIntentError.unreachable(host.displayName)
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

enum PCIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, notPaired, alreadyStreaming, notSent
    case noApp(String, pc: String)
    case wakeOff(String), noAddress(String), noAnswer(String), unreachable(String), failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Glimmer is still starting. Try again in a moment."
        case .notPaired: "That PC isn't paired with Glimmer anymore."
        case .alreadyStreaming: "Glimmer is already streaming. Stop Streaming, then try again."
        case .notSent: "Glimmer couldn't send the wake packets. Check that this Mac is on the network."
        case let .noApp(app, pc): "\(pc) has no app named \(app)."
        case .wakeOff(let pc): "Wake on LAN is off for \(pc)."
        case .noAddress(let pc): "Glimmer doesn't know the network address of \(pc) yet. Connect to it once while it's on."
        case .noAnswer(let pc):
            "\(pc) didn't answer. Wake on LAN works on your home network; over Tailscale it can't reach the PC."
        case .unreachable(let pc): "Couldn't reach \(pc)."
        case .failed(let why): "\(why)"
        }
    }
}

extension Host {
    /// The app a spoken or typed name means: an exact match first, then one
    /// that differs only in case, accents or surrounding spaces.
    func app(named name: String) -> LibraryApp? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.first { $0.name == wanted }
            ?? apps.first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

extension AppModel {
    /// The model once launch has loaded the paired PCs.
    static func forIntent() async throws -> AppModel {
        guard let model = AppDelegate.boundManager else { throw PCIntentError.notReady }
        await model.startBootstrap().value
        return model
    }

    func pairedHost(_ pc: PCEntity) throws -> Host {
        guard let host = hosts.first(where: { $0.id == pc.id }) else { throw PCIntentError.notPaired }
        return host
    }
}
