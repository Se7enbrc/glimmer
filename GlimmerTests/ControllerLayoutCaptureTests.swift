// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import GameController
import Synchronization
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerLayoutCaptureTests {
    private final class Harness: Sendable {
        struct State: Sendable {
            var sample = ControllerMappingSample()
            var receive: (@Sendable (ControllerMappingSample, TimeInterval) -> Void)?
            var releases = 0
        }
        let state = Mutex(State())

        @MainActor func source() -> ControllerLayoutCaptureSource {
            let sources: [ControllerLayoutSource] = [.button(.a), .button(.b), .button(.menu), .button(.options),
                                                     .button(.leftShoulder), .trigger(.left), .axis(.leftX), .extra("back")]
            return .init(controls: sources.map { .init(id: $0, name: $0.layoutName, symbol: $0.layoutSymbol) },
                extras: ["back"], read: { self.state.withLock { $0.sample } }, acquire: { receive in
                    self.state.withLock { $0.receive = receive }
                    return { self.state.withLock { $0.receive = nil; $0.releases += 1 } }
                })
        }

        func send(_ sample: ControllerMappingSample, at time: TimeInterval) {
            let receive = state.withLock { state in state.sample = sample; return state.receive }
            receive?(sample, time)
        }
    }

    @Test(arguments: [false, true])
    func installedLeaseHandlerRunsOffMainAndRejectsLateInput(stopped: Bool) async throws {
        let controller = GCController.withExtendedGamepad()
        let input = controller.input
        let queue = DispatchQueue(label: "controller-lease-test")
        let deliveries = Mutex(0)
        let lease = ControllerLayoutInputLease(controller: controller, input: input, queue: queue,
            read: { .init(buttons: ControllerMappedButton.a.rawValue) }, receive: { sample, timestamp in
                #expect(!Thread.isMainThread)
                #expect(sample.buttons == ControllerMappedButton.a.rawValue)
                #expect(timestamp.isFinite)
                deliveries.withLock { $0 += 1 }
            })
        defer { lease.stop() }
        let handler = try #require(input.elementValueDidChangeHandler)
        if stopped { lease.stop() }
        await withCheckedContinuation { continuation in
            queue.async(execute: ControllerCallbackTestDelivery.physical(input, handler: handler) {
                continuation.resume()
            })
        }
        #expect(deliveries.withLock { $0 } == (stopped ? 0 : 1))
        lease.stop()
        #expect(input.elementValueDidChangeHandler == nil)
    }

    @Test func heldOnEntryMustReleaseAndCaptureCompletesOnlyAfterFreshPressAndRelease() {
        let harness = Harness()
        harness.state.withLock { $0.sample.buttons = ControllerMappedButton.a.rawValue }
        let capture = ControllerLayoutCapture(input: harness.source())
        capture.start(cancel: {})
        #expect(capture.message == "Release the controls to begin.")
        harness.send(.init(), at: 1)
        harness.send(.init(buttons: ControllerMappedButton.b.rawValue), at: 2)
        #expect(capture.source == nil)
        harness.send(.init(), at: 3)
        #expect(capture.source == .button(.b))
        #expect(capture.finished)
        capture.stop()
        #expect(harness.state.withLock { $0.releases } == 1)
    }

    @Test func ambiguousPressDoesNotSelectAControlAndCanBeRetried() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source())
        capture.start(cancel: {})
        harness.send(.init(buttons: ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue), at: 1)
        #expect(capture.message == "Press one control at a time.")
        harness.send(.init(), at: 2)
        var extra = ControllerMappingSample()
        extra.setExtra(0, pressed: true)
        harness.send(extra, at: 3)
        harness.send(.init(), at: 4)
        #expect(capture.source == .extra("back"))
        capture.stop()
    }

    @Test func analogCaptureIgnoresDriftAndWaitsForNeutral() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source())
        capture.start(cancel: {})
        var sample = ControllerMappingSample()
        sample.analog[2] = 4000
        harness.send(sample, at: 1)
        #expect(capture.source == nil)
        sample.analog[2] = 22000
        harness.send(sample, at: 2)
        #expect(capture.source == nil)
        sample.analog[2] = 5000
        harness.send(sample, at: 3)
        #expect(capture.source == .axis(.leftX))
        capture.stop()
    }

    @Test func callbacksQueuedBeforeCancellationCannotChangeTheDraft() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source())
        capture.start(cancel: {})
        let late = harness.state.withLock { $0.receive }
        harness.send(.init(buttons: ControllerMappedButton.a.rawValue), at: 1)
        capture.stop()
        late?(.init(), 2)
        #expect(capture.source == nil)
        #expect(!capture.finished)
        #expect(harness.state.withLock { $0.releases } == 1)
    }

    @Test func chordRecordingRequiresASimultaneousHoldAndRelease() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), recordingChord: true)
        capture.start(cancel: {})
        let buttons = ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue | ControllerMappedButton.menu.rawValue
        harness.send(.init(buttons: buttons), at: 10)
        #expect(!capture.finished)
        harness.send(.init(buttons: ControllerMappedButton.menu.rawValue), at: 10.5)
        #expect(!capture.finished)
        harness.send(.init(), at: 10.6)
        #expect(capture.finished)
        #expect(capture.chord == [.button(.a), .button(.b), .button(.menu)])
        capture.restart(cancel: {})
        #expect(!capture.finished && capture.chord.isEmpty)
        harness.send(.init(buttons: buttons), at: 12)
        harness.send(.init(), at: 12.5)
        #expect(capture.finished)
        capture.stop()
    }

    @Test func chordRecordingRejectsRollingPressesAndCancellationDropsLateEvents() {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source(), recordingChord: true)
        capture.start(cancel: {})
        harness.send(.init(buttons: ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue), at: 10)
        harness.send(.init(buttons: ControllerMappedButton.b.rawValue | ControllerMappedButton.menu.rawValue), at: 10.5)
        harness.send(.init(), at: 11)
        #expect(!capture.finished)
        #expect(capture.chord.isEmpty)
        let late = harness.state.withLock { $0.receive }
        capture.stop()
        late?(.init(buttons: ControllerMappedButton.a.rawValue), 12)
        #expect(capture.chord.isEmpty)
        #expect(harness.state.withLock { $0.releases } == 1)
    }

    @Test func savingShortcutsRoundTripsBothChoicesAndRejectsConflictsWithoutChangingTheFile() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let name = "shortcut-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ControllerLayoutsModel(url: url, defaults: defaults)
        await model.load()
        let source = Harness().source()
        let identity = ControllerLayoutIdentity(category: "Fixture", profile: "test", controls: [])
        let device = ControllerLayoutDevice(id: "fixture", name: "Saved controller", identity: identity,
            owner: .type(identity.type), reader: nil, controller: nil, controls: source.controls, nintendoLabels: false)
        let stop: Set<ControllerLayoutSource> = [.button(.a), .button(.b), .button(.menu)]
        let stats: Set<ControllerLayoutSource> = [.button(.options), .trigger(.left), .extra("back")]
        try await model.saveShortcut(stop, action: .stop, device: device)
        try await model.saveShortcut(stats, action: .stats, device: device)
        let bytes = try Data(contentsOf: url)
        await #expect(throws: ControllerLayoutError.invalidBindings) {
            try await model.saveShortcut(stop.union([.button(.options)]), action: .stats, device: device)
        }
        #expect(try Data(contentsOf: url) == bytes)
        let reloaded = ControllerLayoutsModel(url: url, defaults: defaults)
        await reloaded.load()
        #expect(reloaded.shortcuts(device) == ControllerLayoutShortcuts(stop: stop, stats: stats))
        reloaded.refreshDevices()
        #expect(reloaded.devices.contains { $0.name == device.name && !$0.connected })
        try await reloaded.reset(includeGames: false)
        #expect(reloaded.shortcuts(device) == ControllerLayoutShortcuts())
        #expect(try await ControllerLayoutStore(url: url).load().shortcuts.isEmpty)
    }

    @Test func previousStatsDefaultSurvivesReloadUntilAnExplicitReset() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let name = "shortcut-defaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ControllerLayoutsModel(url: url, defaults: defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let previous: Set<ControllerLayoutSource> = [.button(.options), .button(.leftStick), .button(.rightStick)]
        #expect(model.shortcuts(device).stats == ControllerLayoutShortcuts.defaultStats)
        try await model.saveShortcut(previous, action: .stats, device: device)
        let bytes = try Data(contentsOf: url)
        let reloaded = ControllerLayoutsModel(url: url, defaults: defaults)
        await reloaded.load()
        #expect(reloaded.shortcuts(device).stats == previous)
        #expect(try Data(contentsOf: url) == bytes)
        try await reloaded.reset(includeGames: false)
        #expect(reloaded.shortcuts(device).stats == ControllerLayoutShortcuts.defaultStats)
    }

    @Test func protectedEscapeCancelsControlCapture() throws {
        let harness = Harness()
        let capture = ControllerLayoutCapture(input: harness.source())
        var cancelled = false
        capture.start { cancelled = true }
        let pair = ControllerMappedButton.menu.rawValue | ControllerMappedButton.options.rawValue
        harness.send(.init(buttons: pair), at: 10)
        harness.send(.init(), at: 11.1)
        #expect(cancelled)
        #expect(capture.source == nil)
        capture.stop()
    }
}

// Construct framework invocations outside actor isolation, as GameController does on its input queue.
enum ControllerCallbackTestDelivery {
    private final class Element: NSObject, GCPhysicalInputElement {
        let aliases: Set<String> = ["test"]
        let localizedName: String? = "Test"
        let sfSymbolsName: String? = nil
    }

    static func physical(_ input: GCControllerLiveInput,
                         handler: @escaping (any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void,
                         completion: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        DispatchWorkItem {
            #expect(!Thread.isMainThread)
            handler(input, Element())
            completion()
        }
    }

    static func gamepad(_ pad: GCExtendedGamepad, handler: @escaping GCExtendedGamepadValueChangedHandler,
                        completion: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        DispatchWorkItem {
            #expect(!Thread.isMainThread)
            handler(pad, pad.buttonA)
            completion()
        }
    }
}
