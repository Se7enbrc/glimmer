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

    @Test func savedStopOverridesCannotDisableOrReplaceTheFixedPhysicalChord() throws {
        let required: UInt32 = ControllerMappedButton.menu.rawValue | ControllerMappedButton.options.rawValue
            | ControllerMappedButton.leftShoulder.rawValue | ControllerMappedButton.rightShoulder.rawValue
        let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
        for saved: Set<ControllerLayoutSource> in [[], [.button(.a), .button(.b)]] {
            let (core, backend) = rig()
            let config = try ControllerLayoutConfiguration(layout: .init(bindings: []),
                shortcuts: .init(stop: saved), available: available)
            core.configureLayout(config, slot: 0, held: .init(), at: 0)
            core.receive(slot: 0, buttons: Int32(bitPattern: required), analog: InputCore.neutral, capturedAt: 1)
            #expect(core.chordSlots == [0])
            #expect(backend.calls.last?.buttons == 0)
            core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 2)
            core.receive(slot: 0, buttons: StreamProtocol.A_FLAG | StreamProtocol.B_FLAG,
                         analog: InputCore.neutral, capturedAt: 3)
            #expect(core.chordSlots.isEmpty)
        }
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
        core.snapshot.chord = .startSelectL1R1
        let config = try ControllerLayoutConfiguration(layout: .init(bindings: [
            .init(.button(.a), .button(.menu)), .init(.button(.b), .button(.options)),
            .init(.button(.x), .button(.leftShoulder)), .init(.button(.y), .button(.rightShoulder))
        ]), shortcuts: nil, available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(config, slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG | StreamProtocol.Y_FLAG,
                     analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG
            | StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG)
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
