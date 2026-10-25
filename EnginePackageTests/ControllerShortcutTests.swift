// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing

struct ControllerShortcutTests {
    private let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })

    @Test func recordingsRequireThreePhysicalButtonsAndRejectBothConflictDirections() {
        var value = ControllerLayoutShortcuts()
        #expect(value.recordingProblem(for: .stop, available: available) == nil)
        #expect(value.recordingProblem(for: .stats, available: available) == nil)
        value.stats = [.button(.leftStick), .button(.rightStick)]
        #expect(value.recordingProblem(for: .stats, available: available) != nil)
        value.stats = value.stop.subtracting([.button(.menu)])
        #expect(value.recordingProblem(for: .stats, available: available) != nil)
        value.stats = value.stop.union([.button(.a)])
        #expect(value.recordingProblem(for: .stats, available: available) != nil)
        value.stats = [.button(.a), .button(.b), .axis(.leftX)]
        #expect(value.recordingProblem(for: .stats, available: available) != nil)
        value.stats = [.button(.a), .button(.b), .button(.home)]
        #expect(value.recordingProblem(for: .stats, available: available) != nil)
    }

    @Test func commonGamePairsWarnWithoutRejectingAnIntentionalChord() {
        #expect(ControllerLayoutShortcuts.warning(for: ControllerLayoutShortcuts.defaultStats) != nil)
        #expect(ControllerLayoutShortcuts.warning(for: ControllerLayoutShortcuts.fixedStop) != nil)
        #expect(ControllerLayoutShortcuts.warning(for: [.button(.a), .button(.x), .button(.menu)]) == nil)
    }

    @Test func oldStopChoiceSurvivesAndNewStatsDefaultIsOnlyUsedWhenMissing() throws {
        let old = ControllerLayoutShortcuts(stop: [.button(.a), .button(.b)])
        let data = try JSONEncoder().encode(old)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stats")
        let decoded = try JSONDecoder().decode(ControllerLayoutShortcuts.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.stop == old.stop)
        #expect(decoded.stats == ControllerLayoutShortcuts.defaultStats)
        let chosen = ControllerLayoutShortcuts(stats: [.button(.a), .button(.x), .button(.menu)])
        #expect(try JSONDecoder().decode(ControllerLayoutShortcuts.self,
            from: JSONEncoder().encode(chosen)) == chosen)
    }

    @Test func globalLegacyChoicesRemainExplicitUntilReset() throws {
        let name = "legacy-chord.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ControllerLayoutShortcuts.savedGlobal(in: defaults) == nil)
        defaults.set("none", forKey: "controllerQuitChord")
        #expect(ControllerLayoutShortcuts.savedGlobal(in: defaults)?.stop.isEmpty == true)
        defaults.set("l3r3", forKey: "controllerQuitChord")
        let saved = try #require(ControllerLayoutShortcuts.savedGlobal(in: defaults))
        #expect(saved.stop == [.button(.leftStick), .button(.rightStick)])
        #expect(saved.hasConflict)
        let config = try ControllerLayoutConfiguration(layout: nil, shortcuts: saved, available: available)
        #expect(config.stats.buttons == 0 && config.stop.buttons != 0)
        defaults.set("custom", forKey: "controllerQuitChord")
        defaults.set(Data("[\"faceDown\",\"l1\",\"r2\"]".utf8), forKey: "customControllerChord")
        #expect(ControllerLayoutShortcuts.savedGlobal(in: defaults)?.stop
                == [.button(.a), .button(.leftShoulder), .trigger(.right)])
        SettingsReset.reset(defaults: defaults)
        #expect(ControllerLayoutShortcuts.savedGlobal(in: defaults) == nil)
    }

    @Test func holdSuppressesOnlyAfterThresholdAndFiresOnceAfterEveryButtonReleases() throws {
        let config = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil, available: available)
        var gesture = ControllerShortcutGesture(stop: config.stop, stats: config.stats)
        let full = ControllerMappingSample(buttons: config.stats.buttons)
        #expect(gesture.update(full, at: 10) == nil)
        #expect(gesture.suppressing == nil)
        #expect(gesture.update(full, at: 10.39) == nil)
        #expect(gesture.suppressing == nil)
        #expect(gesture.update(full, at: 10.4) == nil)
        #expect(gesture.suppressing?.removing(from: full).buttons == 0)
        #expect(gesture.update(.init(buttons: ControllerMappedButton.leftStick.rawValue), at: 10.5) == nil)
        #expect(gesture.suppressing != nil)
        #expect(gesture.update(.init(), at: 10.6) == .stats)
        #expect(gesture.update(.init(), at: 10.7) == nil)
        #expect(gesture.suppressing == nil)
    }

    @Test func shortHoldsAndCancellationNeverFire() throws {
        let config = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil, available: available)
        var gesture = ControllerShortcutGesture(stop: config.stop, stats: config.stats)
        #expect(gesture.update(.init(buttons: config.stop.buttons), at: 10) == nil)
        #expect(gesture.update(.init(), at: 10.3) == nil)
        #expect(gesture.update(.init(buttons: config.stop.buttons), at: 12) == nil)
        gesture.reset()
        #expect(gesture.update(.init(), at: 13) == nil)
        #expect(gesture.update(.init(buttons: config.stop.buttons), at: 14) == nil)
        #expect(gesture.update(.init(), at: .nan) == nil)
        #expect(gesture.deadline == nil)
    }
}
