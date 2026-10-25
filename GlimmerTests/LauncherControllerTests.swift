// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GameController
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
struct LauncherControllerTests {
    private let settings = IsolatedDefaults()

    @Test func runningGameActionsFormTheirOwnControllerRow() {
        let cells: [LauncherFocus] = [.runningResume, .runningQuit, .runningSize, .app(1), .app(2), .app(3)]
        func move(_ from: LauncherFocus, _ command: LauncherCommand) -> LauncherFocus? {
            LauncherNavigation.destination(from: from, command: command, cells: cells, columns: 2, hasSwitcher: true)
        }
        #expect(move(.runningResume, .right) == .runningQuit)
        #expect(move(.runningQuit, .down) == .app(2))
        #expect(move(.app(2), .up) == .runningQuit)
        #expect(move(.app(1), .down) == .app(3))
        #expect(move(.runningResume, .up) == .pc)
    }

    @Test func pairingSheetReceivesDirectionsAndActivationAfterNeutralInput() {
        let sheet = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let window = PairingParentWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.testSheet = sheet
        let controller = LauncherController(navigationEnabled: { true }, availableControllers: { [] },
                                            now: { 1 }, keyWindow: { sheet }, postEvent: { _ in })
        defer { controller.detach() }
        controller.attach(window: window)
        var commands: [LauncherCommand] = []
        controller.handleSheet = { commands.append($0) }
        let id = ObjectIdentifier(controller)
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(commands.isEmpty)
        controller.poll(inputs: [id: .init()])
        controller.poll(inputs: [id: .init(direction: .down)])
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(commands == [.down, .activate])
    }

    @Test func emptyLauncherRegistersItsPairButton() {
        var cells: [LauncherFocus] = []
        let view = NSHostingView(rootView: EmptyPairingFocusFixture { cells = $0 }.environment(AppModel(defaults: settings.defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        #expect(cells == [.state])
        #expect(LauncherNavigation.destination(from: nil, command: .down, cells: cells,
                                               columns: 1, hasSwitcher: false) == .state)
    }

    @Test func pairingControlsTraverseAndHeldActivationCannotCrossScreens() {
        let controller = LauncherController(navigationEnabled: { true }, availableControllers: { [] }, now: { 1 })
        defer { controller.detachSheet() }
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        controller.attachSheet(window: window)
        let id = ObjectIdentifier(controller)
        var cells: [LauncherFocus] = [.pairing(.pc("tower")), .pairing(.manual), .pairing(.cancel)]
        var focus: LauncherFocus?
        var activated: [LauncherFocus] = []
        controller.handleSheet = { command in
            if command == .activate, let focus { activated.append(focus) }
            focus = PairingNavigation.destination(from: focus, command: command, cells: cells)
        }
        controller.poll(inputs: [id: .init()])
        controller.poll(inputs: [id: .init(direction: .down)])
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(activated == [.pairing(.pc("tower"))])
        cells = [.pairing(.style(.buttons)), .pairing(.style(.covers)), .pairing(.done), .pairing(.stream)]
        focus = cells.first
        controller.resetInput()
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(activated.count == 1)
        for input in [LauncherControllerInput(direction: .right), .init(activate: true),
                      .init(direction: .down), .init(direction: .right), .init(activate: true)] {
            controller.poll(inputs: [id: .init()])
            controller.poll(inputs: [id: input])
        }
        #expect(activated == [.pairing(.pc("tower")), .pairing(.style(.covers)), .pairing(.stream)])
    }

    @Test func discoveredControllersSleepAtNeutralRepeatAndReleaseOwnership() throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try #require(pad.extendedGamepad)
        var live = [pad]
        var time = 1.0
        var enabled = true
        let controller = LauncherController(navigationEnabled: { enabled }, availableControllers: { live },
                                            now: { time })
        defer { controller.detach() }
        var commands: [LauncherCommand] = []
        controller.handle = { commands.append($0) }
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        controller.attach(window: window)
        #expect(profile.valueChangedHandler != nil)
        #expect(!controller.isPolling)
        profile.leftThumbstick.setValueForXAxis(1, yAxis: 0)
        controller.inputChanged()
        #expect(commands == [.right])
        #expect(controller.isPolling)
        time = 1.39
        controller.poll()
        #expect(commands == [.right])
        time = 1.4
        controller.poll()
        #expect(commands == [.right, .right])
        profile.dpad.setValueForXAxis(0, yAxis: 1)
        controller.poll()
        #expect(commands.last == .up)
        enabled = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!controller.isPolling)
        #expect(profile.valueChangedHandler == nil)
        enabled = true
        controller.refresh()
        #expect(commands.count == 3)
        profile.dpad.setValueForXAxis(0, yAxis: 0)
        profile.leftThumbstick.setValueForXAxis(0, yAxis: 0)
        controller.poll()
        #expect(!controller.isPolling)
        profile.buttonA.setValue(1)
        controller.poll()
        #expect(commands.last == .activate)
        live = []
        controller.refresh()
        #expect(profile.valueChangedHandler == nil)
        #expect(!controller.isPolling)
    }

    @Test func valueChangedWakesPollingAndNeutralTimerTickGoesBackToSleep() async throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try #require(pad.extendedGamepad)
        let controller = LauncherController(navigationEnabled: { true }, availableControllers: { [pad] })
        defer { controller.detach() }
        let activated = DispatchSemaphore(value: 0)
        controller.handle = { command in
            #expect(command == .activate)
            activated.signal()
        }
        controller.refresh()
        profile.buttonA.setValue(1)
        profile.valueChangedHandler?(profile, profile.buttonA)
        #expect(await activated.waitAsync(for: .seconds(2)) == .success)
        #expect(controller.isPolling)
        profile.buttonA.setValue(0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.isPolling)
        controller.testingChanged(true)
        #expect(!controller.isPolling)
        controller.streamingChanged(true)
        #expect(!controller.isPolling)
    }

    @Test func dismissalWinsOverActivationAndDirectionChangesRestartRepeatDelay() {
        var state = LauncherControllerRepeat()
        #expect(state.commands(.init(), at: 0).isEmpty)
        #expect(state.commands(.init(direction: .left, activate: true, dismiss: true), at: 1) == [.dismiss, .left])
        #expect(state.commands(.init(direction: .right), at: 1.1) == [.right])
        #expect(state.commands(.init(direction: .right), at: 1.4).isEmpty)
        #expect(state.commands(.init(direction: .right), at: 1.5) == [.right])
        #expect(state.commands(.init(), at: 2).isEmpty)
        #expect(state.commands(.init(direction: .right), at: 2.01) == [.right])
    }

    @Test func anotherConsumersHandlerIsNeverReplacedOrRemoved() throws {
        let pad = GCController.withExtendedGamepad()
        let profile = try #require(pad.extendedGamepad)
        profile.valueChangedHandler = { _, _ in }
        let controller = LauncherController(navigationEnabled: { true }, availableControllers: { [pad] })
        controller.refresh()
        #expect(!controller.isPolling)
        controller.detach()
        #expect(profile.valueChangedHandler != nil)
        profile.valueChangedHandler = nil
    }

    @Test func menuCommandsBecomePairedLocalKeysAndObserversRetireOnDetach() throws {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var events: [NSEvent] = []
        let controller = LauncherController(navigationEnabled: { true }, availableControllers: { [] },
                                            keyWindow: { window }, postEvent: { events.append($0) })
        defer { controller.detach() }
        controller.attach(window: window)
        controller.attach(window: window)
        let id = ObjectIdentifier(controller)
        var commands: [LauncherCommand] = []
        controller.handle = { commands.append($0) }
        controller.poll(inputs: [id: .init()])
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(events.map(\.keyCode) == [36, 36])
        #expect(events.map(\.type) == [.keyDown, .keyUp])
        #expect(events.map(\.characters) == ["\r", "\r"])
        #expect(commands.isEmpty)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        controller.poll(inputs: [id: .init()])
        controller.poll(inputs: [id: .init(dismiss: true)])
        #expect(commands == [.dismiss])
        controller.detach()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.poll(inputs: [id: .init()])
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(commands == [.dismiss, .activate])
        #expect(events.count == 2)
    }

    @Test func everyCommandUsesItsNativeKeyPairAndMissingFocusPostsNothing() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var target: NSWindow? = window
        var events: [NSEvent] = []
        let controller = LauncherController(navigationEnabled: { true }, keyWindow: { target },
                                            postEvent: { events.append($0) })
        for command in [LauncherCommand.up, .down, .left, .right, .activate, .dismiss] {
            controller.postKey(command)
        }
        #expect(events.map(\.keyCode) == [126, 126, 125, 125, 123, 123, 124, 124, 49, 49, 53, 53])
        #expect(events.allSatisfy { $0.windowNumber == window.windowNumber && !$0.isARepeat })
        #expect(events.map(\.characters) == ["\u{F700}", "\u{F700}", "\u{F701}", "\u{F701}",
            "\u{F702}", "\u{F702}", "\u{F703}", "\u{F703}", " ", " ", "\u{1B}", "\u{1B}"])
        target = nil
        controller.postKey(.activate)
        #expect(events.count == 12)
    }

    @Test func absentOrHiddenLauncherNeverDiscoversControllers() {
        let controller = LauncherController(availableControllers: {
            Issue.record("A hidden launcher must not acquire controllers")
            return []
        })
        defer { controller.detach() }
        controller.refresh()
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        controller.attach(window: window)
        controller.poll(inputs: [ObjectIdentifier(controller): .init(activate: true)])
        #expect(!controller.isPolling)
        controller.attach(window: nil)
        #expect(controller.window == nil)
        var cells: [LauncherFocus] = [.pc]
        LauncherFocusCells.reduce(value: &cells) { [.app(7), .app(8)] }
        LauncherFocusCells.reduce(value: &cells) { [.state] }
        #expect(cells == [.pc, .app(7), .app(8), .state])
    }

    @Test func controllerCommandsDriveFocusAndActivationWithoutWrapping() {
        let controller = LauncherController(navigationEnabled: { true })
        defer { controller.detach() }
        let id = ObjectIdentifier(controller)
        let cells: [LauncherFocus] = [.app(1), .app(2), .state]
        var focus: LauncherFocus?
        var activated: [LauncherFocus] = []
        controller.handle = { command in
            if command == .activate, let focus { activated.append(focus) }
            focus = LauncherNavigation.destination(from: focus, command: command, cells: cells,
                                                   columns: 2, hasSwitcher: true)
        }
        for input in [LauncherControllerInput(direction: .down), .init(direction: .right),
                      .init(activate: true), .init(direction: .down), .init(direction: .up)] {
            controller.poll(inputs: [id: .init()])
            controller.poll(inputs: [id: input])
        }
        #expect(activated == [.app(2)])
        #expect(focus == .app(2))
        #expect(LauncherNavigation.destination(from: nil, command: .up, cells: [],
                                               columns: 0, hasSwitcher: false) == nil)
        #expect(LauncherNavigation.destination(from: nil, command: .up, cells: [],
                                               columns: 0, hasSwitcher: true) == .pc)
        #expect(LauncherNavigation.destination(from: .state, command: .up, cells: [.state],
                                               columns: 0, hasSwitcher: false) == .state)
        #expect(LauncherNavigation.destination(from: .pc, command: .left, cells: cells,
                                               columns: 2, hasSwitcher: true) == .pc)
    }
}

@MainActor
private final class PairingParentWindow: NSWindow {
    var testSheet: NSWindow?
    override var attachedSheet: NSWindow? { testSheet }
}

@MainActor
private struct EmptyPairingFocusFixture: View {
    let report: ([LauncherFocus]) -> Void
    @FocusState private var focus: LauncherFocus?

    var body: some View {
        EmptyPairingState(focus: $focus).onPreferenceChange(LauncherFocusCells.self, perform: report)
    }
}
