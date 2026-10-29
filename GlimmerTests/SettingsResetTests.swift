// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct SettingsResetTests {
    @Test func resetRemovesOnlyNamedPreferencesAndRevealsCurrentDefaults() throws {
        let name = "reset-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let protected = ["hosts.1.uuid", "hosts.1.apps.1.hidden", "glimmer.selectedHostID", "continuationHistory",
                         "pairingIdentity", "controllerLayoutIdentitySalt", "GlimmerUpdateChannel",
                         "awdlHelperEnabled", "rawHIDPromptAnswered", "diagnosticsCapture", "futureUnknownSetting"]
        for key in SettingsReset.keys { defaults.set("chosen", forKey: key) }
        for prefix in SettingsReset.prefixes { defaults.set("chosen", forKey: prefix + "fixture") }
        for key in protected { defaults.set("kept", forKey: key) }
        defaults.register(defaults: ["streamHDR": true, "touchMouseEnabled": true])
        SettingsReset.reset(defaults: defaults)
        let saved = defaults.persistentDomain(forName: name) ?? [:]
        #expect(Set(saved.keys) == Set(protected))
        #expect(protected.allSatisfy { saved[$0] as? String == "kept" })
        #expect(defaults.bool(forKey: "streamHDR"))
        #expect(defaults.bool(forKey: "touchMouseEnabled"))
    }

    @Test(arguments: [false, true])
    func resetControllerLayoutsKeepsGameCatalogAndHonorsPerGameChoice(includeGames: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let owner = ControllerLayoutOwner.type(String(repeating: "a", count: 64))
        let game = ControllerLayoutGame(pcID: "pc", appID: 7, pcName: "Den PC", name: "Adventure")
        let layout = ControllerLayout(bindings: [.init(.button(.a), .button(.b))])
        var library = ControllerLayoutLibrary(records: [
            .init(key: .init(owner: owner, scope: .allGames), name: "Controller", layout: layout),
            .init(key: .init(owner: owner, scope: game.id), name: "Controller", layout: layout)
        ], shortcuts: [.init(owner: owner, shortcuts: .init(stop: ControllerLayoutShortcuts.fixedStop),
                              available: ControllerLayoutShortcuts.fixedStop)])
        library.games = [game]
        let store = ControllerLayoutStore(url: url)
        try await store.save(library)
        let model = ControllerLayoutsModel(url: url)
        try await model.reset(includeGames: includeGames)
        let saved = try await store.load()
        #expect(saved.games == [game])
        #expect(saved.shortcuts.isEmpty)
        #expect(saved.records.count == (includeGames ? 0 : 1))
        #expect(saved.records.allSatisfy { $0.key.scope == game.id })
        #expect(model.library == saved)
    }
    #if os(macOS)
    @Test func resetUpdatesTheLiveModelWithoutSavingDefaultsOrLosingPCData() async throws {
        let defaults = IsolatedDefaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        defaults.defaults.set("preserved", forKey: "hosts.1.uuid")
        defaults.defaults.set(true, forKey: "rawHIDPromptAnswered")
        let model = AppModel(defaults: defaults.defaults)
        model.qualityPreset = .custom
        model.streamHDR = false
        model.streamCoversNotch = false
        model.rawHIDControllerEnabled = true
        let layouts = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"))
        try await model.resetSettings(includeGames: false, layouts: layouts)
        #expect(model.qualityPreset == .defaultPreset)
        #expect(model.streamHDR && model.streamCoversNotch)
        #expect(model.rawHIDControllerEnabled == false)
        #expect(defaults.defaults.string(forKey: "hosts.1.uuid") == "preserved")
        #expect(defaults.defaults.bool(forKey: "rawHIDPromptAnswered"))
        let stored = defaults.defaults.persistentDomain(forName: defaults.name) ?? [:]
        #expect(SettingsReset.keys.isDisjoint(with: stored.keys))
    }

    @Test func failedLayoutResetLeavesPreferencesAndLiveModelUnchanged() async throws {
        let defaults = IsolatedDefaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(defaults: defaults.defaults)
        model.streamHDR = false
        let layouts = ControllerLayoutsModel(url: directory, read: { .init() })
        await #expect(throws: (any Error).self) {
            try await model.resetSettings(includeGames: true, layouts: layouts)
        }
        #expect(model.streamHDR == false)
        #expect(defaults.defaults.object(forKey: "streamHDR") as? Bool == false)
    }
    #endif
}
