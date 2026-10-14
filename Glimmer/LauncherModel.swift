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
    private(set) var apps: [HostApp] = []
    private(set) var selectedName: String?
    private(set) var busy = false
    private(set) var discoveryDenied = false
    private(set) var message: String?
    private(set) var pairing: PairingPrompt?
    var stream: StreamSessionModel?
    private var session: StreamSessionModel?
    private var closingTask: Task<Void, Never>?
    @MainActor
    struct Calls {
        var savedPCs: () throws -> [SavedPC]
        var prepare: (ServerInfo, Bool) async throws -> PreparedPC
        var pair: (PreparedPC, String) async throws -> PreparedPC
        var apps: (PreparedPC) async throws -> [HostApp]
        var remember: (PreparedPC) throws -> [SavedPC]
        var protectedDataChanged: (Bool) -> Void
        var makeSession: @MainActor (StreamLaunch) -> StreamSessionModel = { StreamSessionModel(launch: $0) }
    }

    private let calls: Calls?
    private let discoveryEnabled: Bool
    private let discovery = HostDiscovery()
    private var selected: PreparedPC?
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryRun: UInt64?
    private var active = false
    private var needsRefresh = false

    init(services: LauncherServices?) {
        calls = services.map { services in
            Calls(savedPCs: { try services.savedPCs() },
                  prepare: { try await services.prepare(server: $0, saved: $1) },
                  pair: { try await services.pair($0, pin: $1) },
                  apps: { try await $0.network.appList() },
                  remember: { try services.remember($0) },
                  protectedDataChanged: { services.protectedData.update($0) })
        }
        discoveryEnabled = true
        if services == nil { message = "Glimmer couldn't open its storage. Close the app and try again." }
    }

    init(calls: Calls, discoveryEnabled: Bool = true) {
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
            do { savedPCs = try calls?.savedPCs() ?? [] } catch { showStorageFailure() }
            if session == nil { startDiscovery() }
        } else {
            stopDiscovery()
            if background || !protectedDataAvailable {
                cancelOperation()
                needsRefresh = selected != nil
            }
        }
    }

    func select(_ pc: SavedPC) { select(server: pc.server, saved: true) }

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
        selectedName = server.serverName
        apps = []
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
                    guard isCurrent(attempt) else { return }
                    pairing = nil
                }
                let list = try await calls.apps(pc)
                guard isCurrent(attempt) else { return }
                savedPCs = try calls.remember(pc)
                selected = pc
                selectedName = pc.server.serverName
                apps = list.filter { !$0.hidden }
                needsRefresh = false
                busy = false
            } catch {
                guard isCurrent(attempt) else { return }
                pairing = nil
                busy = false
                message = LauncherFailureCopy.message(error)
            }
        }
    }

    func launch(_ app: HostApp) {
        guard active, !busy, session == nil, let selected, let calls else { return }
        if needsRefresh {
            message = "Choose the PC again to refresh its connection before starting a game."
            return
        }
        stopDiscovery()
        let session = calls.makeSession(StreamLaunch(network: selected.network,
            pcID: selected.server.uniqueId, pcName: selected.server.serverName, appID: app.id, appName: app.name))
        self.session = session
        stream = session
    }

    func streamClosed() {
        guard closingTask == nil, let session else { return }
        stream = nil
        needsRefresh = true
        apps = []
        session.stop()
        closingTask = Task {
            await session.waitUntilStopped()
            self.session = nil
            closingTask = nil
            message = "Disconnected. Choose the PC to reconnect."
            if active { startDiscovery() }
        }
    }

    func waitUntilStreamClosed() async { await closingTask?.value }

    func dismissPairing() {
        if pairing != nil { cancelOperation() }
    }

    func cancelOperation() {
        generation &+= 1
        operation?.cancel()
        pairing = nil
        busy = false
    }

    func waitUntilOperationFinishes() async { await operation?.value }

    private func isCurrent(_ attempt: UInt64) -> Bool { generation == attempt && !Task.isCancelled }

    private func showStorageFailure() {
        savedPCs = []
        message = "Glimmer couldn't read its saved PCs. Unlock the device and try again."
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

    private func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        if let run = discoveryRun {
            discoveryRun = nil
            Task { await discovery.stop(run: run) }
        }
        discovered = []
    }
}
