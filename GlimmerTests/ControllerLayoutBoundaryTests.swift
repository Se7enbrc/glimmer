// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

struct ControllerLayoutBoundaryTests {
    private func rig() -> (InputCore, InputRecordingBackend) {
        let core = InputCore()
        let backend = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.snapshot.acceptEventsAfter = 0
        core.announceController(slot: 0, arrival: .init(type: 1, supportedButtons: ControllerMappedButton.a.rawValue, caps: 1))
        return (core, backend)
    }

    @Test func shortcutOnlyCustomizationKeepsSystemMapping() throws {
        let (core, backend) = rig()
        let config = try ControllerLayoutConfiguration(layout: nil, shortcuts: .init(stop: [.button(.x), .button(.y)]),
            available: [.button(.a), .button(.b), .button(.x), .button(.y), .button(.menu), .button(.options)])
        core.configureLayout(config, slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.B_FLAG, analog: InputCore.neutral, capturedAt: 1,
                     physicalSample: .init(buttons: ControllerMappedButton.a.rawValue))
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        #expect(core.chordSlots.isEmpty)
    }

    @Test func outputButtonsCannotTriggerLocalStop() throws {
        let (core, backend) = rig()
        core.snapshot.chord = .l3r3
        let config = try ControllerLayoutConfiguration(layout: .init(bindings: [
            .init(.button(.a), .button(.leftStick)), .init(.button(.b), .button(.rightStick))
        ]), shortcuts: nil, available: [.button(.a), .button(.b), .button(.menu), .button(.options)])
        core.configureLayout(config, slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG | StreamProtocol.B_FLAG,
                     analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.LS_CLK_FLAG | StreamProtocol.RS_CLK_FLAG)
        #expect(core.chordSlots.isEmpty)
    }

    @Test func newLayoutDoesNotRetainPriorOutputCapabilities() throws {
        let (core, _) = rig()
        let sources: Set<ControllerLayoutSource> = [.button(.a)]
        let first = try ControllerLayoutConfiguration(layout: .init(bindings: [.init(.button(.a), .button(.paddle1))]),
            shortcuts: nil, available: sources)
        let second = try ControllerLayoutConfiguration(layout: .init(bindings: [.init(.button(.a), .button(.b))]),
            shortcuts: nil, available: sources)
        core.configureLayout(first, slot: 0, held: .init(), at: 0)
        core.configureLayout(second, slot: 0, held: .init(), at: 1)
        #expect(core.announcedControllers[0]?.supportedButtons == ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue)
        #expect(core.announcedControllers[0]?.caps == 1)
    }

    @Test func detachBeforeReadinessCannotLeaveALayoutOnAReusedSlot() throws {
        let (core, backend) = rig()
        let controller = NSObject()
        let id = ObjectIdentifier(controller)
        core.registerController(id: id, slot: 0, buttons: 0, analog: InputCore.neutral)
        let layout = try ControllerLayoutConfiguration(layout: .init(bindings: [.init(.button(.a), .button(.b))]),
            shortcuts: nil, available: [.button(.a)])
        core.configureLayout(layout, slot: 0, held: .init(), at: 0)
        core.snapshot.ready = false
        core.removeController(id: id)
        core.snapshot.ready = true
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        #expect(core.layouts == nil)
    }
}
