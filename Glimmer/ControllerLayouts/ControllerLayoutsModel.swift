// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController
import GlimmerEngine
import Observation

typealias ControllerLayoutGame = ControllerLayoutGameRecord

extension ControllerLayoutGameRecord {
    var title: String { "\(name) · \(pcName)" }
}

struct ControllerLayoutDevice: Identifiable {
    let id: String
    let name: String
    let identity: ControllerLayoutIdentity?
    let owner: ControllerLayoutOwner
    let reader: ControllerLayoutReader?
    let controller: GCController?
    let controls: [ControllerLayoutControl]
    let nintendoLabels: Bool
    var hidID: UInt64?
    var captureSource: ControllerLayoutCaptureSource?

    var connected: Bool { controller != nil || hidID != nil }
    var isSharedType: Bool {
        if case .type = owner { return true }
        return false
    }
}

@MainActor @Observable
final class ControllerLayoutsModel {
    static let shared = ControllerLayoutsModel()
    static let didChange = Notification.Name("ControllerLayoutsDidChange")
    private(set) var library = ControllerLayoutLibrary()
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var devices: [ControllerLayoutDevice] = []
    var games: [ControllerLayoutGame] = []
    private let store: ControllerLayoutStore
    private var loadTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var observers = 0
    private var saving = false

    init(url: URL = ControllerLayoutsModel.storeURL) {
        store = ControllerLayoutStore(url: url)
    }

    private static var storeURL: URL {
        #if os(macOS)
        URL.applicationSupportDirectory.appendingPathComponent("Glimmer/ControllerLayouts.json")
        #else
        URL.applicationSupportDirectory.appendingPathComponent("ControllerLayouts.json")
        #endif
    }

    func load() async {
        if let loadTask { await loadTask.value; return }
        guard !loaded else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                library = try await store.load()
                let current = games
                games = library.games.filter { cached in !current.contains { $0.id == cached.id } } + current
                loaded = true
            } catch {
                loadError = "Couldn't read controller layouts. Your saved file has been kept."
            }
        }
        await loadTask?.value
        loadTask = nil
    }

    func save(_ record: ControllerLayoutRecord) async throws {
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        saving = true
        defer { saving = false }
        var next = library
        try next.save(record)
        try await commit(next)
    }

    func remove(_ key: ControllerLayoutKey) async throws {
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        saving = true
        defer { saving = false }
        var next = library
        next.remove(key)
        try await commit(next)
    }

    func saveShortcuts(_ record: ControllerShortcutRecord) async throws {
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        saving = true
        defer { saving = false }
        var next = library
        try next.saveShortcuts(record)
        try await commit(next)
    }

    func resetShortcuts(for owner: ControllerLayoutOwner) async throws {
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        saving = true
        defer { saving = false }
        var next = library
        next.removeShortcuts(for: owner)
        try await commit(next)
    }

    private func commit(_ next: ControllerLayoutLibrary) async throws {
        var next = next
        next.games = Array(games.prefix(1024))
        try await store.save(next)
        library = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if observers > 0 { refreshDevices() }
    }

    func beginObserving() {
        observers += 1
        guard observations.isEmpty else { return }
        #if os(macOS)
        HIDGamepadManager.shared.retain()
        #endif
        refreshDevices()
        var names: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect]
        #if os(macOS)
        names.append(HIDGamepadManager.devicesDidChange)
        #endif
        for name in names {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    func endObserving() {
        observers = max(0, observers - 1)
        Task { @MainActor [weak self] in
            guard let self, observers == 0, !observations.isEmpty else { return }
            stopObserving()
        }
    }

    private func stopObserving() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        devices.removeAll()
        #if os(macOS)
        HIDGamepadManager.shared.release()
        #endif
    }

    func refreshDevices() {
        var devices: [ControllerLayoutDevice] = []
        for controller in GCController.controllers() {
            let reader = ControllerLayoutReader(controller)
            let identity = reader?.identity ?? ControllerLayoutIdentity(category: controller.productCategory,
                profile: "unavailable", controls: [])
            let owner = identity.hardware.map { ControllerLayoutOwner.hardware($0) } ?? .type(identity.type)
            let nintendo = controller.productCategory.localizedCaseInsensitiveContains("Nintendo")
            devices.append(ControllerLayoutDevice(id: "connected:\(ObjectIdentifier(controller))",
                name: controller.vendorName ?? "Controller",
                identity: identity, owner: owner, reader: reader, controller: controller, controls: reader?.controls ?? [],
                nintendoLabels: nintendo && UserDefaults.standard.bool(forKey: "nintendoButtonLayout"),
                captureSource: reader.map { .init(controller: controller, reader: $0) }))
        }
        #if os(macOS)
        devices += HIDGamepadManager.shared.devices.values.map(HIDControllerLayouts.device)
        #endif
        var owners = Set(devices.map(\.owner))
        for record in library.records where owners.insert(record.key.owner).inserted {
            devices.append(ControllerLayoutDevice(id: "saved:\(String(describing: record.key.owner))", name: record.name,
                identity: nil, owner: record.key.owner, reader: nil, controller: nil,
                controls: record.controls.isEmpty ? record.layout.bindings.map {
                    .init(id: $0.source, name: $0.source.layoutName, symbol: $0.source.layoutSymbol)
                } : record.controls, nintendoLabels: false))
        }
        self.devices = devices
    }

    func current(_ device: ControllerLayoutDevice) -> ControllerLayoutDevice {
        if let current = devices.first(where: { $0.id == device.id }) { return current }
        guard device.connected else { return device }
        return ControllerLayoutDevice(id: device.id, name: device.name, identity: device.identity,
            owner: device.owner, reader: nil, controller: nil, controls: device.controls, nintendoLabels: device.nintendoLabels)
    }

    func resolved(_ device: ControllerLayoutDevice, scope: ControllerLayoutScope) -> ControllerLayoutRecord? {
        if let identity = device.identity { return library.resolve(identity, scope: scope) }
        return library.records.first { $0.key == .init(owner: device.owner, scope: scope) }
            ?? library.records.first { $0.key == .init(owner: device.owner, scope: .allGames) }
    }

    func baseline(_ device: ControllerLayoutDevice, scope: ControllerLayoutScope) -> ControllerLayout {
        if let record = resolved(device, scope: scope) { return record.layout }
        let sources = Set(device.controls.map(\.id))
        let standard = ControllerLayout.standard(buttons: ControllerMappedButton.allCases.filter { sources.contains(.button($0)) },
                                                 extras: device.captureSource?.extras ?? [], nintendoLabels: device.nintendoLabels)
        return ControllerLayout(bindings: standard.bindings.filter { sources.contains($0.source) })
    }
}
