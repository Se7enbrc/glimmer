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
    var savedCategory: String?

    var category: String { controller?.productCategory ?? savedCategory ?? name }

    var diagramFamily: ControllerDiagramFamily {
        .identify(category: category, name: name, controls: controls)
    }

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
    private(set) var mouse: ControllerMouseBindings
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var devices: [ControllerLayoutDevice] = []
    var games: [ControllerLayoutGame] = []
    private let store: ControllerLayoutStore
    private let defaults: UserDefaults
    private let readLibrary: () async throws -> ControllerLayoutLibrary
    private var loadTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var observers = 0
    private var saving = false

    init(url: URL = ControllerLayoutsModel.storeURL, defaults: UserDefaults = PersistentStorage.defaults,
         read: (() async throws -> ControllerLayoutLibrary)? = nil) {
        self.defaults = defaults
        mouse = ControllerMouseBindings.load(from: defaults)
        let store = ControllerLayoutStore(url: url)
        self.store = store
        readLibrary = read ?? { try await store.load() }
    }

    private static var storeURL: URL {
        #if os(macOS)
        PersistentStorage.applicationSupport.appendingPathComponent("Glimmer/ControllerLayouts.json")
        #else
        PersistentStorage.applicationSupport.appendingPathComponent("ControllerLayouts.json")
        #endif
    }

    func load() async {
        if let loadTask { await loadTask.value; return }
        guard !loaded else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                library = try await readLibrary()
                let current = games
                games = library.games.filter { cached in !current.contains { $0.id == cached.id } } + current
                loaded = true
                if observers > 0 { refreshDevices() }
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

    func shortcuts(for identity: ControllerLayoutIdentity) -> ControllerLayoutShortcuts {
        library.shortcuts(for: identity) ?? ControllerLayoutShortcuts.savedGlobal(in: defaults) ?? .init()
    }

    func shortcuts(_ device: ControllerLayoutDevice) -> ControllerLayoutShortcuts {
        if let identity = device.identity { return shortcuts(for: identity) }
        return library.shortcuts.first { $0.owner == device.owner }?.shortcuts
            ?? ControllerLayoutShortcuts.savedGlobal(in: defaults) ?? .init()
    }

    func saveShortcut(_ buttons: Set<ControllerLayoutSource>, action: ControllerShortcutAction,
                      device: ControllerLayoutDevice) async throws {
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        var value = shortcuts(device)
        value[action] = buttons
        let available = Set(device.controls.map(\.id))
        guard value.recordingProblem(for: action, available: available) == nil else {
            throw ControllerLayoutError.invalidBindings
        }
        guard !mouse.overrides.values.contains(where: { ControllerMouseBindings.overlaps($0, buttons) }) else {
            throw ControllerLayoutError.invalidBindings
        }
        saving = true
        defer { saving = false }
        var next = library
        try next.saveShortcuts(.init(owner: device.owner, shortcuts: value, available: available,
                                    name: device.name, controls: device.controls, category: device.category))
        try await commit(next)
    }

    func reset(includeGames: Bool) async throws {
        await load()
        guard loaded, !saving else { throw ControllerLayoutError.invalidDocument }
        saving = true
        defer { saving = false }
        let kept = includeGames ? [] : library.records.filter { $0.key.scope != .allGames }
        try await commit(ControllerLayoutLibrary(records: kept))
        try setMouse(.init())
    }

    func selectMousePreset(_ preset: ControllerMouseMapping) throws {
        var next = mouse
        next.preset = preset
        try setMouse(next)
    }

    func resetMouseToPreset() throws { try setMouse(.init(preset: mouse.preset)) }

    func mouseProblem(_ sources: Set<ControllerLayoutSource>, action: ControllerMouseAction,
                      device: ControllerLayoutDevice) -> String? {
        let explicit = library.shortcuts.map(\.shortcuts) + [ControllerLayoutShortcuts.savedGlobal(in: defaults)].compactMap { $0 }
        if sources == mouse[action], !explicit.contains(where: {
            ControllerMouseBindings.overlaps(sources, $0.stop) || ControllerMouseBindings.overlaps(sources, $0.stats)
        }) { return nil }
        return mouse.recordingProblem(sources, for: action, available: Set(device.controls.map(\.id)),
            shortcuts: library.shortcuts.map(\.shortcuts) + [shortcuts(device)])
    }

    func saveMouse(_ sources: Set<ControllerLayoutSource>, action: ControllerMouseAction,
                   device: ControllerLayoutDevice) throws {
        guard mouseProblem(sources, action: action, device: device) == nil else {
            throw ControllerLayoutError.invalidBindings
        }
        var next = mouse
        next.assign(sources, to: action)
        try setMouse(next)
    }

    private func setMouse(_ next: ControllerMouseBindings) throws {
        guard loaded else { throw ControllerLayoutError.invalidDocument }
        try next.save(to: defaults)
        mouse = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
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
                nintendoLabels: nintendo && PersistentStorage.defaults.bool(forKey: "nintendoButtonLayout"),
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
                } : record.controls, nintendoLabels: false, savedCategory: record.category))
        }
        for record in library.shortcuts where owners.insert(record.owner).inserted {
            devices.append(ControllerLayoutDevice(id: "saved:\(String(describing: record.owner))",
                name: record.name ?? "Controller", identity: nil, owner: record.owner, reader: nil, controller: nil,
                controls: record.controls ?? record.available.sorted { $0.layoutName < $1.layoutName }.map {
                    .init(id: $0, name: $0.layoutName, symbol: $0.layoutSymbol)
                }, nintendoLabels: false, savedCategory: record.category))
        }
        self.devices = devices
    }

    func current(_ device: ControllerLayoutDevice) -> ControllerLayoutDevice {
        if let current = devices.first(where: { $0.id == device.id }) { return current }
        guard device.connected else { return device }
        return ControllerLayoutDevice(id: device.id, name: device.name, identity: device.identity,
            owner: device.owner, reader: nil, controller: nil, controls: device.controls,
            nintendoLabels: device.nintendoLabels, savedCategory: device.category)
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
