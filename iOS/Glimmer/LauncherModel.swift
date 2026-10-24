// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Observation
import UIKit

@MainActor
@Observable
final class LauncherModel {
    struct PairingPrompt: Identifiable {
        let id = UUID()
        let name: String
        let pin: String
    }

    private(set) var savedPCs: [SavedPC] = []
    private(set) var discovered: [HostDiscovery.Discovered] = []
    var apps: [HostApp] = []
    private(set) var selectedName: String?
    var controllerLayoutPC: SavedPC? { selection }
    var busy = false
    private(set) var discoveryDenied = false
    var message: String?
    private(set) var pairing: PairingPrompt?
    private(set) var pendingForget: SavedPC?
    private(set) var forgetFailure: String?
    var canForgetPC: Bool { active && session == nil && !busy }
    var stream: StreamSessionModel?
    var allApps: [HostApp] = []
    var runningApp: HostApp?
    var endedGame: HostApp?
    var endedFormat: ContinuationFormat?
    var pendingGameAction: GameAction?
    var leaveGamesRunning = false
    var history: ContinuationHistory
    var pictureTrial: PictureTrial?
    var streamReturn: StreamReturn?
    private var returningPCID: String?
    var streamProfile: StreamProfile = .native120
    var touchMouseEnabled = true
    var mouseStick: ControllerMouseStick = .right
    var session: StreamSessionModel?
    var hasActiveStream: Bool { session.map { !$0.phase.isEnded } ?? false }
    private var closingTask: Task<Void, Never>?
    @MainActor
    struct Calls {
        var savedPCs: () throws -> [SavedPC]
        var prepare: (ServerInfo, Bool) async throws -> PreparedPC
        var pair: (PreparedPC, String) async throws -> PreparedPC
        var apps: (PreparedPC) async throws -> [HostApp]
        var remember: (PreparedPC) throws -> [SavedPC]
        var protectedDataChanged: (Bool) -> Void
        var lastConnectedPCID: () -> String? = { nil }
        var forget: (String) throws -> [SavedPC] = { _ in throw LauncherServices.Failure.unavailable }
        var artwork: @Sendable (PreparedPC, Int) async throws -> Data = { try await $0.network.appAsset(appID: $1) }
        var status: (PreparedPC) async throws -> ServerInfo = { $0.server }
        var quit: (PreparedPC, Int) async throws -> Void = {
            try await StreamSession.quitRunningApp(network: $0.network, expectedAppID: $1)
        }
        var makeSession: @MainActor (StreamLaunch) -> StreamSessionModel = { StreamSessionModel(launch: $0) }
    }

    let calls: Calls?
    private let discoveryEnabled: Bool
    private let discovery = HostDiscovery()
    var selected: PreparedPC?
    private var selection: SavedPC?
    var generation: UInt64 = 0
    var operation: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryRun: UInt64?
    private let artCache = LauncherArtCache(base: URL.cachesDirectory)
    var active = false
    var needsRefresh = false

    init(services: LauncherServices?) {
        history = ContinuationHistory(defaults: .standard)
        calls = services.map { services in
            Calls(savedPCs: { try services.savedPCs() },
                  prepare: { try await services.prepare(server: $0, saved: $1) },
                  pair: { try await services.pair($0, pin: $1) },
                  apps: { try await $0.network.appList() },
                  remember: { try services.remember($0) },
                  protectedDataChanged: { services.protectedData.update($0) },
                  lastConnectedPCID: { services.lastConnectedPCID() },
                  forget: { try services.forget($0) }, status: { try await $0.network.fetchServerInfo() })
        }
        discoveryEnabled = true
        if services == nil { message = "Glimmer couldn't open its storage. Close the app and try again." }
    }

    init(calls: Calls, discoveryEnabled: Bool = true) {
        let defaults = UserDefaults(suiteName: "launcher-test-\(UUID().uuidString)") ?? UserDefaults()
        history = ContinuationHistory(defaults: defaults)
        self.calls = calls
        self.discoveryEnabled = discoveryEnabled
    }

    static func make() -> LauncherModel {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            return LauncherModel(services: LauncherServices(base: base,
                protectedData: ProtectedDataState(UIApplication.shared.isProtectedDataAvailable)))
        } catch { return LauncherModel(services: nil) }
    }

    func availabilityChanged(active: Bool, background: Bool, protectedDataAvailable: Bool) {
        self.active = active && protectedDataAvailable
        calls?.protectedDataChanged(protectedDataAvailable)
        session?.availabilityChanged(active: active, background: background,
                                    protectedDataAvailable: protectedDataAvailable)
        if self.active {
            refreshSavedPCs()
            if session == nil { startDiscovery() }
        } else {
            pendingForget = nil
            stopDiscovery()
            if background || !protectedDataAvailable {
                cancelOperation()
                needsRefresh = selection != nil
            }
        }
    }

    func selectInitialPCIfNeeded() {
        guard active, session == nil, !busy else { return }
        if needsRefresh, let selection {
            select(selection)
        } else if selectedName == nil {
            let remembered = savedPCs.first { $0.id == calls?.lastConnectedPCID() }
            if let pc = remembered ?? (savedPCs.count == 1 ? savedPCs.first : nil) { select(pc) }
        }
    }

    func select(_ pc: SavedPC) { select(server: pc.server, saved: true) }

    func requestForget(_ pc: SavedPC) {
        guard canForgetPC, savedPCs.contains(where: { $0.id == pc.id }) else { return }
        forgetFailure = nil
        pendingForget = pc
    }

    func cancelForget() { pendingForget = nil }

    func confirmForget(_ pc: SavedPC) {
        pendingForget = nil
        guard canForgetPC, savedPCs.contains(where: { $0.id == pc.id }), let calls else { return }
        do {
            let remaining = try calls.forget(pc.id)
            if selection?.id == pc.id || selected?.server.uniqueId == pc.id {
                cancelOperation()
                selected = nil
                selection = nil
                selectedName = nil
                apps = []
                needsRefresh = false
                message = nil
            }
            savedPCs = remaining
            forgetFailure = nil
        } catch {
            forgetFailure = LauncherFailureCopy.storageMessage(error, action: "forget \(pc.name)")
        }
    }

    func select(address: String) {
        guard let address = PCAddress.parse(address) else { return }
        if let saved = savedPCs.first(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame }) {
            select(saved)
        } else {
            select(server: ServerInfo(address: address, uniqueId: "", serverName: address), saved: false)
        }
    }

    func select(_ pc: HostDiscovery.Discovered) {
        if let saved = savedPCs.first(where: { $0.address == pc.host && $0.httpPort == pc.port }) {
            select(saved)
            return
        }
        var server = ServerInfo(address: pc.host, uniqueId: "", serverName: pc.displayName)
        server.httpPort = pc.port
        select(server: server, saved: false)
    }

    private func select(server: ServerInfo, saved: Bool) {
        guard active, session == nil, let calls else { return }
        cancelOperation()
        let attempt = generation
        selected = nil
        selection = saved ? SavedPC(server: server) : nil
        needsRefresh = false
        selectedName = server.serverName
        apps = []
        runningApp = nil
        endedGame = nil
        pendingGameAction = nil
        busy = true
        message = nil
        operation = Task {
            do {
                var pc = try await calls.prepare(server, saved)
                guard isCurrent(attempt) else { return }
                if pc.server.isRealGFE {
                    message = StreamFailureCopy.needsSunshineMessage(pc.server.serverName)
                    busy = false
                    return
                }
                if pc.server.pairStatus != .paired || pc.server.serverCertPEM == nil {
                    let pin = String(format: "%04d", Int.random(in: 0...9999))
                    pairing = PairingPrompt(name: pc.server.serverName, pin: pin)
                    pc = try await calls.pair(pc, pin)
                    refreshSavedPCs()
                    guard isCurrent(attempt) else { return }
                    pairing = nil
                }
                let list = try await calls.apps(pc)
                guard isCurrent(attempt) else { return }
                savedPCs = try calls.remember(pc)
                selected = pc
                selection = SavedPC(server: pc.server)
                selectedName = pc.server.serverName
                allApps = list
                apps = list.filter { !$0.hidden }
                updateRunningApp(pc.server, list: list)
                needsRefresh = false
                busy = false
                if let returningPCID {
                    self.returningPCID = nil
                    applyStreamReturn(pcID: returningPCID)
                }
            } catch {
                guard isCurrent(attempt) else { return }
                pairing = nil
                busy = false
                refreshSavedPCs()
                message = LauncherFailureCopy.message(error, pcName: server.serverName)
            }
        }
    }

    var artworkRevision: String? {
        guard active, session == nil, !busy, !needsRefresh, let selected else { return nil }
        return "\(selected.server.uniqueId):\(generation):\(LauncherArtCache.revision(for: apps))"
    }

    func artwork(for app: HostApp) async -> CGImage? {
        guard let revision = artworkRevision, let selected, let calls, apps.contains(where: { $0.id == app.id })
        else { return nil }
        let fetch = calls.artwork
        let listRevision = LauncherArtCache.revision(for: apps)
        let data = await artCache.image(pcID: selected.server.uniqueId, appID: app.id, revision: listRevision) {
            try await fetch(selected, app.id)
        }
        guard !Task.isCancelled, artworkRevision == revision, let data else { return nil }
        return LauncherArtCache.decode(data)
    }

    func streamClosed() {
        guard closingTask == nil, let session else { return }
        stream = nil
        returningPCID = session.launch.pcID
        needsRefresh = true
        apps = []
        runningApp = nil
        session.stop()
        closingTask = Task {
            await session.waitUntilStopped()
            self.session = nil
            closingTask = nil
            message = nil
            if active {
                startDiscovery()
                selectInitialPCIfNeeded()
                await waitUntilOperationFinishes()
            }
        }
    }

    func waitUntilStreamClosed() async { await closingTask?.value }

    func dismissPairing() {
        if pairing != nil { cancelOperation() }
    }

    func cancelOperation() {
        pendingGameAction = nil
        generation &+= 1
        operation?.cancel()
        refreshSavedPCs()
        pairing = nil
        busy = false
    }

    func waitUntilOperationFinishes() async { await operation?.value }

    func isCurrent(_ attempt: UInt64) -> Bool { generation == attempt && !Task.isCancelled }

    private func refreshSavedPCs() {
        guard active else { return }
        do { savedPCs = try calls?.savedPCs() ?? [] } catch {
            message = LauncherFailureCopy.storageMessage(error, action: "read its saved PCs")
        }
    }

    private func startDiscovery() {
        guard discoveryEnabled, discoveryTask == nil, calls != nil else { return }
        discoveryTask = Task { [weak self, discovery] in
            let (updates, run) = await discovery.start()
            guard let self, !Task.isCancelled else { await discovery.stop(run: run); return }
            discoveryRun = run
            for await update in updates {
                guard !Task.isCancelled else { break }
                discovered = update.hosts
                discoveryDenied = update.denied
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        if let run = discoveryRun {
            discoveryRun = nil
            Task { await discovery.stop(run: run) }
        }
        discovered = []
    }
}
