// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
@testable import Glimmer

struct ControllerLayoutRoutingTests {
    private func rig() -> (InputCore, InputRecordingBackend) {
        let core = InputCore()
        let backend = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.withLock { core.snapshot.acceptEventsAfter = 0 }
        core.announceController(slot: 0, arrival: .init(type: 1, supportedButtons: UInt32(StreamProtocol.A_FLAG), caps: 1))
        return (core, backend)
    }

    private func configuration(_ target: ControllerMappedButton) throws -> ControllerLayoutConfiguration {
        try .init(layout: .init(bindings: [.init(.button(.a), .button(target))]), shortcuts: nil,
                  available: [.button(.a), .button(.menu), .button(.options)])
    }

    @Test func unusedLayoutsAllocateNoRouterAndStartNoTimer() {
        let (core, backend) = rig()
        for _ in 0..<500 { core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral) }
        #expect(core.layouts == nil)
        #expect(core.controllerMouseTimer == nil)
        #expect(backend.calls.count == 500)
        #expect(backend.calls.allSatisfy { $0.buttons == StreamProtocol.A_FLAG })
    }

    @Test func rejectedReleasePrecedesNewArrivalAndHeldSourceMustRearm() throws {
        let (core, backend) = rig()
        core.configureLayout(try configuration(.b), slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        let before = backend.calls.count
        backend.inputResult = -2
        core.configureLayout(try configuration(.x), slot: 0,
                             held: .init(buttons: ControllerMappedButton.a.rawValue), at: 2)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 3)
        #expect(backend.calls.count == before)
        backend.inputResult = 0
        let eventCount = backend.controllerEvents.count
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 4)
        #expect(backend.calls.last?.buttons == 0)
        #expect(Array(backend.controllerEvents.dropFirst(eventCount).prefix(2)) == ["state", "arrival"])
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 5)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 6)
        #expect(backend.calls.last?.buttons == StreamProtocol.X_FLAG)
    }

    @Test func customLayoutBypassesNintendoSwapAndPreservesHardwareCapabilities() throws {
        let (core, backend) = rig()
        core.snapshot.nintendoSlots = [0]
        core.configureLayout(try configuration(.b), slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        #expect(core.announcedControllers[0]?.supportedButtons == UInt32(StreamProtocol.A_FLAG | StreamProtocol.B_FLAG))
        #expect(core.announcedControllers[0]?.caps == 1)
    }

    @Test func disablingEveryOutputDoesNotTurnTheOldEscapePairIntoAnAction() throws {
        let (core, backend) = rig()
        let configuration = try ControllerLayoutConfiguration(layout: .init(bindings: []), shortcuts: nil,
            available: [.button(.menu), .button(.options)])
        core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        core.receive(slot: 0, buttons: StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG,
                     analog: InputCore.neutral, capturedAt: 1)
        #expect(core.layouts?.states[0]?.gesture.deadline == nil)
        #expect(core.chordSlots.isEmpty)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 2.1)
        #expect(core.layouts?.states[0]?.gesture.latched == nil)
        #expect(backend.calls.last?.buttons == 0)
    }

    @Test func removingLayoutRearmsHeldInputsAndRetiresRouter() throws {
        let (core, backend) = rig()
        core.configureLayout(try configuration(.b), slot: 0, held: .init(), at: 0)
        core.configureLayout(nil, slot: 0, held: .init(buttons: ControllerMappedButton.a.rawValue), at: 1)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 2)
        #expect(backend.calls.last?.buttons == 0)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: 3)
        #expect(core.layouts == nil)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral, capturedAt: 4)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
    }
}
