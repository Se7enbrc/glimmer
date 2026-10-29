// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@MainActor
struct ControllerMouseParityTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "mouse-parity-" + UUID().uuidString))
    }

    @Test func macUpgradeUsesRightAndExplicitMobileLeftSurvives() throws {
        let defaults = try defaults()
        defer { SettingsReset.reset(defaults: defaults) }
        #expect(ControllerMouseBindings.load(from: defaults).preset == .rightStick)
        defaults.set("left", forKey: "controllerMouseStick")
        let left = ControllerMouseBindings.load(from: defaults)
        #expect(left.preset == .leftStick && !left.isCustom)
        try left.save(to: defaults)
        #expect(ControllerMouseBindings.load(from: defaults) == left)
        SettingsReset.reset(defaults: defaults)
        #expect(ControllerMouseBindings.load(from: defaults) == .init(preset: .rightStick))
    }

    @Test func presetsNeverOverwriteCustomBindingsAndExplicitResetRestoresRight() async throws {
        let defaults = try defaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SettingsReset.reset(defaults: defaults); try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: defaults)
        await model.load()
        let device = ControllerMouseSettingsView.generic
        try model.saveMouse([.button(.up)], action: .primary, device: device)
        try model.selectMousePreset(.leftStick)
        #expect(model.mouse.title == "Custom")
        #expect(model.mouse[.primary] == [.button(.up)])
        #expect(ControllerMouseBindings.load(from: defaults) == model.mouse)
        try model.resetMouseToPreset()
        #expect(model.mouse == .init(preset: .leftStick))
        try model.saveMouse([.button(.down)], action: .middle, device: device)
        try await model.reset(includeGames: false)
        SettingsReset.reset(defaults: defaults)
        #expect(model.mouse == .init(preset: .rightStick))
        #expect(ControllerMouseBindings.load(from: defaults) == model.mouse)
    }

    @Test func conflictsNeverStealAndCustomBindingsWinOverPresetChanges() {
        var bindings = ControllerMouseBindings()
        let available = Set(ControllerMouseSettingsView.generic.controls.map(\.id))
        #expect(bindings.recordingProblem([.button(.rightShoulder)], for: .primary,
            available: available, shortcuts: [])?.contains("Secondary click") == true)
        bindings.assign([], to: .secondary)
        #expect(bindings.recordingProblem([.button(.rightShoulder)], for: .primary,
            available: available, shortcuts: []) == nil)
        bindings.assign([.button(.rightShoulder)], to: .primary)
        bindings.preset = .leftStick
        #expect(bindings[.primary] == [.button(.rightShoulder)])
        #expect(bindings[.forward].isEmpty)
        #expect(bindings.title == "Custom")
        let stop = ControllerLayoutShortcuts(stop: [.button(.up), .button(.down), .button(.menu)])
        #expect(bindings.recordingProblem([.button(.up)], for: .middle,
            available: available, shortcuts: [stop]) != nil)
        #expect(bindings.recordingProblem([.button(.a)], for: .primary,
            available: available, shortcuts: []) != nil)
    }

    @Test(arguments: ControllerMouseMapping.allCases)
    func identicalSamplesProduceTheSamePointerClicksAndScrollOnEveryPlatform(preset: ControllerMouseMapping) throws {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setControllerMouseBindings(.init(preset: preset))
        input.activate(true)
        input.setFocused(true)
        let pad = try #require(input.registerController(.init(kind: .unknown, supportedButtons: .init(rawValue: 0xFFFF),
                                                              capabilities: [.analogTriggers])))
        input.setControllerMouseMode(true, for: pad)
        let right = preset == .rightStick
        let sample = ControllerInputSample(buttons: right ? .rightShoulder : .leftShoulder,
            leftTrigger: right ? 0 : 1, rightTrigger: right ? 1 : 0,
            leftStickX: right ? 0 : 1, leftStickY: right ? 1 : 0,
            rightStickX: right ? 1 : 0, rightStickY: right ? 0 : 1)
        input.core.withLock {
            input.submitController(pad, sample: sample, capturedAt: ProcessInfo.processInfo.systemUptime)
            input.core.controllerMouseTimer?.cancel()
            input.core.controllerMouseTimer = nil
            input.core.pollControllerMouse()
        }
        #expect(backend.mouseMoves == [.init(dx: 10, dy: 0)])
        #expect(backend.pointer == [.button(action: 7, button: 1), .button(action: 7, button: 3)])
        input.submitController(pad, sample: .init(), capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.pointer.suffix(2) == [.button(action: 8, button: 1), .button(action: 8, button: 3)])
    }

    @Test func everyMouseFunctionCompilesFromItsCustomBindingIncludingToggleAndExtras() throws {
        var bindings = ControllerMouseBindings()
        bindings.assign([], to: .scroll)
        bindings.assign(ControllerMouseMapping.stick(right: false), to: .pointer)
        bindings.assign(ControllerMouseMapping.stick(right: true), to: .scroll)
        let functions: [ControllerMouseAction] = [.primary, .secondary, .middle, .back, .forward, .toggle]
        let buttons: [ControllerMappedButton] = [.up, .down, .left, .right, .options, .share]
        for (action, button) in zip(functions, buttons) { bindings.assign([.button(button)], to: action) }
        bindings.assign([.extra("rear")], to: .middle)
        let plan = ControllerMousePlan(bindings, extras: ["rear"])
        for (index, button) in buttons.prefix(5).enumerated() where index != 2 {
            #expect(plan.clickMask(.init(buttons: button.rawValue)) == 1 << index)
        }
        var extra = ControllerMappingSample()
        extra.setExtra(0, pressed: true)
        #expect(plan.clickMask(extra) == 4)
        var state = ControllerMouseState()
        _ = state.update(buttons: Int32(bitPattern: ControllerMappedButton.share.rawValue), analog: InputCore.neutral,
                         chordHeld: false, now: 10, toggleChord: plan.toggle)
        let toggled = state.update(buttons: 0, analog: InputCore.neutral, chordHeld: false, now: 11, toggleChord: plan.toggle)
        #expect(toggled)
        #expect(state.isMouse)
        var analog = InputCore.neutral
        analog.leftStickX = 32767
        analog.rightStickY = 32767
        #expect(plan.sticks(analog).pointer == SIMD2(32767, 0))
        #expect(plan.sticks(analog).scroll == SIMD2(0, 32767))
    }
    @Test func customMouseAndShortcutConflictsCannotChangeEitherSavedChoice() async throws {
        let defaults = try defaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SettingsReset.reset(defaults: defaults); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let model = ControllerLayoutsModel(url: url, defaults: defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let chord: Set<ControllerLayoutSource> = [.button(.up), .button(.menu), .button(.options)]
        try model.saveMouse([.button(.up)], action: .primary, device: device)
        await #expect(throws: ControllerLayoutError.invalidBindings) {
            try await model.saveShortcut(chord, action: .stats, device: device)
        }
        #expect(model.shortcuts(device).stats == ControllerLayoutShortcuts.defaultStats)
        try model.resetMouseToPreset()
        try model.saveMouse([], action: .toggle, device: device)
        try await model.saveShortcut(chord, action: .stats, device: device)
        let bytes = try Data(contentsOf: url)
        #expect(throws: ControllerLayoutError.invalidBindings) {
            try model.saveMouse([.button(.up)], action: .primary, device: device)
        }
        try model.selectMousePreset(.leftStick)
        #expect(try Data(contentsOf: url) == bytes)
        let reloaded = ControllerLayoutsModel(url: url, defaults: defaults)
        await reloaded.load()
        #expect(reloaded.shortcuts(device).stats == chord)
        #expect(reloaded.mouse.preset == .leftStick)
    }

    @Test(arguments: ["global", "device", "default"], [-1, 0, 1])
    func mouseRecordingsRespectEveryControllersShortcuts(origin: String, relation: Int) async throws {
        let defaults = try defaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SettingsReset.reset(defaults: defaults); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let other = ControllerLayoutRenderTests().fixture(.xbox)
        let available = Set(device.controls.map(\.id))
        let chord: Set<ControllerLayoutSource> = origin == "default" ? ControllerLayoutShortcuts.fixedStop
            : [.button(.up), .button(.options), .button(.menu)]
        if origin == "global" {
            defaults.set("custom", forKey: "controllerQuitChord")
            defaults.set(try JSONEncoder().encode(Set<ControllerButton>([.dpadUp, .create, .options])),
                         forKey: "customControllerChord")
        }
        var library = ControllerLayoutLibrary()
        try library.saveShortcuts(.init(owner: device.owner,
            shortcuts: .init(stop: [.button(.down), .button(.left), .button(.right)]), available: available))
        if origin == "device" {
            try library.saveShortcuts(.init(owner: other.owner, shortcuts: .init(stop: chord), available: available))
        }
        try await ControllerLayoutStore(url: url).save(library)
        let bytes = try Data(contentsOf: url)
        var candidate = chord
        if relation < 0 { candidate.remove(.button(.options)) }
        if relation > 0 { candidate.insert(.button(.down)) }
        for action in ControllerMouseAction.allCases where !action.isStick {
            let original = ControllerMouseBindings(overrides: Dictionary(uniqueKeysWithValues:
                ControllerMouseAction.allCases.map { ($0, Set<ControllerLayoutSource>()) }))
            try original.save(to: defaults)
            let mouseBytes = defaults.data(forKey: "controllerMouseBindings")
            let model = ControllerLayoutsModel(url: url, defaults: defaults)
            await model.load()
            #expect(model.shortcuts(other).stop == chord)
            #expect(throws: ControllerLayoutError.invalidBindings) {
                try model.saveMouse(candidate, action: action, device: device)
            }
            #expect(model.mouse == original)
            #expect(defaults.data(forKey: "controllerMouseBindings") == mouseBytes)
            #expect(try Data(contentsOf: url) == bytes)
            #expect(model.library.shortcuts == library.shortcuts)
        }
    }

    @Test(arguments: [-1, 0, 1])
    func shortcutRecordingsRespectEveryCustomMouseFunction(relation: Int) async throws {
        let defaults = try defaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SettingsReset.reset(defaults: defaults); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let chord: Set<ControllerLayoutSource> = [.button(.up), .button(.options), .button(.menu), .button(.down)]
        var candidate = chord
        if relation < 0 { candidate.remove(.button(.down)) }
        if relation > 0 { candidate.insert(.button(.left)) }
        for action in ControllerMouseAction.allCases where !action.isStick {
            let original = ControllerMouseBindings(overrides: [action: chord])
            try original.save(to: defaults)
            let model = ControllerLayoutsModel(url: url, defaults: defaults)
            await model.load()
            for shortcut in ControllerShortcutAction.allCases {
                await #expect(throws: ControllerLayoutError.invalidBindings) {
                    try await model.saveShortcut(candidate, action: shortcut, device: device)
                }
            }
            #expect(model.library.shortcuts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(ControllerMouseBindings.load(from: defaults) == original)
        }
    }

    @Test(arguments: ControllerMouseMapping.allCases)
    func shortcutRecordingsCannotTakePresetMouseControls(preset: ControllerMouseMapping) async throws {
        let defaults = try defaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SettingsReset.reset(defaults: defaults); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let original = ControllerMouseBindings(preset: preset)
        try original.save(to: defaults)
        let model = ControllerLayoutsModel(url: url, defaults: defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        for action in ControllerMouseAction.allCases where !action.isStick {
            let candidate = original[action].union([.button(.up), .button(.down)])
            for shortcut in ControllerShortcutAction.allCases {
                await #expect(throws: ControllerLayoutError.invalidBindings) {
                    try await model.saveShortcut(candidate, action: shortcut, device: device)
                }
            }
        }
        #expect(model.library.shortcuts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ControllerMouseBindings.load(from: defaults) == original)
    }

    @Test func remappedExtraClicksReachTheStreamAndChangingLayoutRearmsWithoutLeavingMouseMode() throws {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.activate(true)
        input.setFocused(true)
        let pad = try #require(input.registerController(.init(kind: .unknown, supportedButtons: [.menu], capabilities: [])))
        var bindings = ControllerMouseBindings()
        bindings.assign([.extra("rear")], to: .primary)
        let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil,
            available: Set(ControllerMouseSettingsView.generic.controls.map(\.id)).union([.extra("rear")]),
            extras: ["rear"], mouse: bindings)
        input.setControllerLayout(configuration, for: pad)
        input.setControllerMouseMode(true, for: pad)
        let held = ControllerInputSample(extraButtons: SIMD2(1, 0))
        input.submitController(pad, sample: held, capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.pointer == [.button(action: 7, button: 1)])
        var sample = ControllerMappingSample()
        sample.setExtra(0, pressed: true)
        input.setControllerLayout(configuration, for: pad, held: sample)
        #expect(input.core.controllerMouseStates[pad.slot]?.isMouse == true)
        #expect(backend.pointer.last == .button(action: 8, button: 1))
        input.submitController(pad, sample: held, capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.pointer.count == 2)
        input.submitController(pad, sample: .init(), capturedAt: ProcessInfo.processInfo.systemUptime)
        input.submitController(pad, sample: held, capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.pointer.last == .button(action: 7, button: 1))
    }

    @Test func aPartialToggleReleaseCannotTurnAShortChordIntoALongHold() throws {
        let chord = try ControllerPhysicalChord(sources: [.button(.options), .button(.up)], extras: [])
        var state = ControllerMouseState()
        _ = state.update(buttons: 0x21, analog: InputCore.neutral, chordHeld: false, now: 1, toggleChord: chord)
        _ = state.update(buttons: 0x20, analog: InputCore.neutral, chordHeld: false, now: 1.1, toggleChord: chord)
        let toggled = state.update(buttons: 0, analog: InputCore.neutral, chordHeld: false, now: 3, toggleChord: chord)
        #expect(!toggled && !state.isMouse)
    }
}
