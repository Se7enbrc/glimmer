// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization
import Testing
@testable import Glimmer

struct ControllerShortcutRoutingTests {
    private func rig(layout: ControllerLayout? = nil) throws -> (InputCore, InputRecordingBackend, ControllerLayoutConfiguration) {
        let core = InputCore()
        let backend = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.snapshot.acceptEventsAfter = 0
        let config = try ControllerLayoutConfiguration(layout: layout, shortcuts: nil,
            available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(config, slot: 0, held: .init(), at: 0)
        return (core, backend, config)
    }

    @Test func partialInputForwardsButFullShortcutIsCapturedBeforeItsHold() throws {
        let (core, backend, config) = try rig()
        let actions = Mutex<[ControllerShortcutAction]>([])
        core.onControllerShortcut = { action in actions.withLock { $0.append(action) } }
        let full = Int32(bitPattern: config.stats.buttons)
        let partial = Int32(bitPattern: ControllerMappedButton.leftShoulder.rawValue)
        core.receive(slot: 0, buttons: partial, analog: InputCore.neutral, capturedAt: 10)
        #expect(backend.calls.last?.buttons == partial)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10.1)
        #expect(backend.calls.last?.buttons == 0)
        #expect(actions.withLock { $0.isEmpty })
        let state = try #require(core.layouts?.states[0])
        core.advanceLayoutHold(state, slot: 0, at: 10.51)
        #expect(backend.calls.last?.buttons == 0)
        #expect(actions.withLock { $0 } == [.stats])
        core.receive(slot: 0, buttons: partial, analog: InputCore.neutral, capturedAt: 10.6)
        #expect(backend.calls.last?.buttons == 0)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10.7)
        #expect(backend.calls.last?.buttons == 0)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 10.8)
        #expect(actions.withLock { $0 } == [.stats])
        core.receive(slot: 0, buttons: partial, analog: InputCore.neutral, capturedAt: 11)
        #expect(backend.calls.last?.buttons == partial)
    }

    @Test func mappedChordOutputsReleaseBeforeTheActionAndFocusLossCancels() throws {
        let layout = ControllerLayout(bindings: [
            .init(.button(.leftShoulder), .button(.a)), .init(.button(.leftStick), .button(.b)),
            .init(.button(.rightStick), .button(.x))
        ])
        let (core, backend, config) = try rig(layout: layout)
        let actions = Mutex(0)
        core.onControllerShortcut = { _ in actions.withLock { $0 += 1 } }
        let full = Int32(bitPattern: config.stats.buttons)
        let partial = full & ~Int32(bitPattern: ControllerMappedButton.rightShoulder.rawValue)
        core.receive(slot: 0, buttons: partial, analog: InputCore.neutral, capturedAt: 9.9)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10)
        #expect(backend.calls.last?.buttons == 0)
        #expect(actions.withLock { $0 } == 0)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10.5)
        #expect(backend.calls.last?.buttons == 0)
        #expect(actions.withLock { $0 } == 1)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 11)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 12)
        core.clearChords()
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 13)
        #expect(actions.withLock { $0 } == 1)
    }

    @Test func aShortcutLeavesUnrelatedButtonsAndAnalogInputRunning() throws {
        let (core, backend, config) = try rig()
        let actions = Mutex(0)
        core.onControllerShortcut = { _ in actions.withLock { $0 += 1 } }
        let other = ControllerMappedButton.a.rawValue
        let full = Int32(bitPattern: config.stats.buttons | other)
        let analog = GamepadAnalog(leftTrigger: 200, rightTrigger: 0,
                                   leftStickX: 1000, leftStickY: 0, rightStickX: 0, rightStickY: 0)
        core.receive(slot: 0, buttons: full, analog: analog, capturedAt: 10)
        let state = try #require(core.layouts?.states[0])
        core.advanceLayoutHold(state, slot: 0, at: 10.5)
        #expect(backend.calls.last?.buttons == Int32(bitPattern: other))
        #expect(backend.calls.last?.analog == analog)
        core.receive(slot: 0, buttons: Int32(bitPattern: other), analog: analog, capturedAt: 11)
        #expect(actions.withLock { $0 } == 1)
        #expect(backend.calls.last?.buttons == Int32(bitPattern: other))
    }

    @Test func rejectedReleaseCannotFireAnAction() throws {
        let (core, backend, config) = try rig()
        let actions = Mutex(0)
        core.onControllerShortcut = { _ in actions.withLock { $0 += 1 } }
        let full = Int32(bitPattern: config.stop.buttons)
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10)
        backend.inputResult = -2
        core.receive(slot: 0, buttons: full, analog: InputCore.neutral, capturedAt: 10.5)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 11)
        #expect(actions.withLock { $0 } == 0)
    }
}
