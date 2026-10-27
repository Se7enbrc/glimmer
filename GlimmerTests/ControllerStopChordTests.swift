// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import os
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@MainActor
struct ControllerStopChordTests {
    #if os(iOS)
    @Test(arguments: ControllerShortcutAction.allCases)
    func heldNativeChordReachesTheStreamingSession(action: ControllerShortcutAction) async throws {
        let rig = try ChordCaptureRig()
        defer { rig.stop() }
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        let pad = try #require(rig.controller.extendedGamepad)
        let buttons = [pad.leftShoulder, pad.rightShoulder] + (action == .stop
            ? [try #require(pad.buttonOptions), pad.buttonMenu]
            : [try #require(pad.leftThumbstickButton), try #require(pad.rightThumbstickButton)])
        for button in buttons { button.setValue(1); rig.deliver() }
        let state = try #require(rig.core.layouts?.states[0])
        rig.advance(state, at: try #require(state.gesture.deadline))
        for event in rig.events.withLock({ $0 }) { model.receive(fixture.update(.input(event))) }
        if action == .stop {
            await model.waitUntilStopped()
            #expect(model.phase.isEnded && fixture.completedStops == 1)
        } else {
            #expect(model.statsShown && fixture.statsHistory.last == true)
            model.stop()
            await model.waitUntilStopped()
        }
    }
    #endif

    @Test(arguments: ControllerShortcutAction.allCases, [false, true])
    func nativeExtendedGamepadFiresAtHoldDeadline(action: ControllerShortcutAction, remapped: Bool) throws {
        let rig = try ChordCaptureRig()
        defer { rig.stop() }
        let pad = try #require(rig.controller.extendedGamepad)
        let options = try #require(pad.buttonOptions)
        let leftStick = try #require(pad.leftThumbstickButton)
        let rightStick = try #require(pad.rightThumbstickButton)
        let buttons = remapped ? [pad.buttonA, pad.buttonB, pad.buttonX]
            : [pad.leftShoulder, pad.rightShoulder] + (action == .stop
                ? [options, pad.buttonMenu] : [leftStick, rightStick])
        if remapped {
            var shortcuts = ControllerLayoutShortcuts()
            shortcuts[action] = [.button(.a), .button(.b), .button(.x)]
            let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: shortcuts,
                available: Set(ControllerMappedButton.allCases.map { .button($0) }))
            rig.core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        }
        for button in buttons { button.setValue(1); rig.deliver() }
        let state = try #require(rig.core.layouts?.states[0])
        let deadline = try #require(state.gesture.deadline)
        rig.advance(state, at: deadline - 0.001)
        #expect(rig.actions.withLock { $0.isEmpty })
        rig.advance(state, at: deadline)
        #expect(rig.actions.withLock { $0 } == [action])
        rig.advance(state, at: deadline + 1)
        #expect(rig.actions.withLock { $0 } == [action])
        #expect(rig.core.controllerMouseStates[0]?.isMouse != true)
    }

    @Test func menuAloneKeepsItsPlatformActionAndChordsCancelIt() throws {
        let rig = try ChordCaptureRig()
        defer { rig.stop() }
        let pad = try #require(rig.controller.extendedGamepad)
        let menus = OSAllocatedUnfairLock(initialState: 0)
        rig.core.onControllerMenu = { _ in menus.withLock { $0 += 1 } }
        pad.buttonMenu.setValue(1)
        rig.deliver()
        let now = ProcessInfo.processInfo.systemUptime
        rig.core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, chordButtons: 0, capturedAt: now + 1)
        #if os(iOS)
        #expect(menus.withLock { $0 } == 1)
        #expect(rig.core.controllerMouseStates[0]?.isMouse != true)
        #else
        #expect(menus.withLock { $0 } == 0)
        #expect(rig.core.controllerMouseStates[0]?.isMouse == true)
        #endif
        #expect(rig.actions.withLock { $0.isEmpty })
        let full = Int32(bitPattern: ControllerLayoutShortcuts.fixedStop.reduce(UInt32(0)) { result, source in
            if case .button(let button) = source { return result | button.rawValue }
            return result
        })
        rig.core.receive(slot: 0, buttons: full, analog: InputCore.neutral, chordButtons: full, capturedAt: now + 2)
        let state = try #require(rig.core.layouts?.states[0])
        rig.advance(state, at: try #require(state.gesture.deadline))
        rig.core.receive(slot: 0, buttons: StreamProtocol.PLAY_FLAG, analog: InputCore.neutral,
                         chordButtons: StreamProtocol.PLAY_FLAG, capturedAt: now + 3)
        rig.core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, chordButtons: 0, capturedAt: now + 4)
        #expect(rig.actions.withLock { $0 } == [.stop])
        #if os(iOS)
        #expect(menus.withLock { $0 } == 1)
        #expect(rig.core.controllerMouseStates[0]?.isMouse != true)
        #else
        #expect(rig.core.controllerMouseStates[0]?.isMouse == true)
        #endif
    }

    @Test(arguments: ControllerShortcutAction.allCases, 0..<4)
    func everyPartialDefaultChordNeverFires(action: ControllerShortcutAction, missing: Int) throws {
        let rig = try ChordCaptureRig()
        defer { rig.stop() }
        let pad = try #require(rig.controller.extendedGamepad)
        let buttons = [pad.leftShoulder, pad.rightShoulder] + (action == .stop
            ? [try #require(pad.buttonOptions), pad.buttonMenu]
            : [try #require(pad.leftThumbstickButton), try #require(pad.rightThumbstickButton)])
        for (index, button) in buttons.enumerated() where index != missing { button.setValue(1); rig.deliver() }
        let state = try #require(rig.core.layouts?.states[0])
        rig.advance(state, at: ProcessInfo.processInfo.systemUptime + 1)
        #expect(rig.actions.withLock { $0.isEmpty })
        #expect(state.gesture.deadline == nil)
        #expect(rig.core.controllerMouseStates[0]?.isMouse != true)
    }
}

@MainActor
private final class ChordCaptureRig {
    let controller = GCController.withExtendedGamepad()
    let backend = InputRecordingBackend()
    let actions = OSAllocatedUnfairLock(initialState: [ControllerShortcutAction]())
    let events = OSAllocatedUnfairLock(initialState: [StreamInput.Event]())
    let core: InputCore
    private let submit: () -> Void
    let stop: () -> Void

    init() throws {
        let pad = try #require(controller.extendedGamepad)
        #if os(iOS)
        let input = StreamInput(backend: backend, emit: { [actions, events] event in
            events.withLock { $0.append(event) }
            if event == .stopRequested { actions.withLock { $0.append(.stop) } }
            if event == .statsRequested { actions.withLock { $0.append(.stats) } }
        })
        StreamPlayback.configureInput(input)
        input.activate(true)
        let capture = IOSControllerCapture(calls: .init(register: input.registerController,
            unregister: input.unregisterController, submit: { registration, sample, _ in
                input.submitController(registration, sample: sample, capturedAt: ProcessInfo.processInfo.systemUptime)
            }, focus: { input.setFocused($0) }), center: NotificationCenter(),
            readControllers: { [controller] in [controller] })
        capture.start()
        capture.setFocused(true)
        let handler = try #require(pad.valueChangedHandler)
        submit = { handler(pad, pad.buttonMenu) }
        core = input.core
        stop = { capture.stop(); input.stop() }
        #else
        let forwarder = InputForwarder()
        forwarder.controllerQuitChordProvider = { .startSelectL1R1 }
        forwarder.attach(gamepad: controller)
        forwarder.setBackend(backend)
        forwarder.isReady = true
        core = forwarder.inputCore
        submit = { forwarder.sendGamepadUpdate(pad: pad, slot: 0) }
        stop = { forwarder.detach() }
        core.onControllerShortcut = { [actions] action in actions.withLock { $0.append(action) } }
        #endif
        // Snapshot setters are scripted; invoke the installed capture route exactly once per edge.
        pad.valueChangedHandler = nil
    }

    func advance(_ state: ControllerLayoutRouting.State, at time: TimeInterval) {
        core.withLock {
            core.advanceLayoutHold(state, slot: 0, at: time)
            state.timer?.cancel()
            state.timer = nil
        }
    }

    func deliver() {
        core.withLock {
            submit()
            core.layouts?.states[0]?.timer?.cancel()
            core.layouts?.states[0]?.timer = nil
        }
    }
}
