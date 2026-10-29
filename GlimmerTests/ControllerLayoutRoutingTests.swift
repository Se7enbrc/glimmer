// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import os
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

    @Test func legacyResyncDoesNotOverrideLaterPhysicalCenterButtons() throws {
        let (core, backend) = rig()
        let actions = OSAllocatedUnfairLock(initialState: [ControllerShortcutAction]())
        core.onControllerShortcut = { action in actions.withLock { $0.append(action) } }
        core.mouseQueue.suspend()
        defer { core.mouseQueue.resume() }
        let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil,
            available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        let time = ProcessInfo.processInfo.systemUptime
        // Focus resync can use the legacy profile before the physical-input callback arrives.
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, chordButtons: 0, capturedAt: time)
        let held = StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG | StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG
        core.receive(slot: 0, buttons: held, analog: InputCore.neutral, capturedAt: time + 0.1,
                     physicalSample: .init(buttons: held, analog: InputCore.neutral))
        let state = try #require(core.layouts?.states[0])
        #expect(state.last.buttons == UInt32(bitPattern: held))
        core.advanceLayoutHold(state, slot: 0, at: time + 0.6)
        #expect(state.gesture.latched == .stop)
        #expect(actions.withLock { $0 } == [.stop])
        #expect(backend.calls.last?.buttons == 0)
    }

    @Test(arguments: [false, true])
    func rawShoulderReleaseKeepsOnlyThePhysicalSourcesContribution(physicalHeld: Bool) throws {
        let (core, backend) = rig()
        core.mouseQueue.suspend()
        defer { core.mouseQueue.resume() }
        let id = ObjectIdentifier(backend)
        let token = core.registerController(id: id, slot: 0, buttons: 0, analog: InputCore.neutral)
        let configuration = try ControllerLayoutConfiguration(
            layout: .init(bindings: [.init(.button(.leftShoulder), .button(.a))]), shortcuts: nil,
            available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        let time = ProcessInfo.processInfo.systemUptime
        let buttons = physicalHeld ? StreamProtocol.LB_FLAG : 0
        core.receive(slot: 0, buttons: buttons, analog: InputCore.neutral, capturedAt: time,
                     physicalSample: .init(buttons: buttons, analog: InputCore.neutral))
        core.receiveCenterButtons(id: id, token: token, buttons: 0,
                                  shoulders: StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG, capturedAt: time + 0.1)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        core.receive(slot: 0, buttons: buttons, analog: InputCore.neutral, capturedAt: time + 0.15,
                     physicalSample: .init(buttons: buttons, analog: InputCore.neutral),
                     rawSupplement: (0, StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG))
        core.receiveCenterButtons(id: id, token: token, buttons: 0, shoulders: 0, capturedAt: time + 0.2)
        #expect(core.layouts?.states[0]?.last.buttons == UInt32(bitPattern: buttons))
        #expect(backend.calls.last?.buttons == (physicalHeld ? StreamProtocol.A_FLAG : 0))
        let state = try #require(core.layouts?.states[0])
        core.advanceLayoutHold(state, slot: 0, at: time + 0.6)
        #expect(state.gesture.latched == nil)
        core.receive(slot: 0, buttons: 0, analog: InputCore.neutral, capturedAt: time + 0.7,
                     physicalSample: .init())
        #expect(backend.calls.last?.buttons == 0)
    }

    @Test func rawShoulderReleaseCancelsTheShortcutHold() throws {
        let (core, backend) = rig()
        core.mouseQueue.suspend()
        defer { core.mouseQueue.resume() }
        let id = ObjectIdentifier(backend)
        let token = core.registerController(id: id, slot: 0, buttons: 0, analog: InputCore.neutral)
        let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil,
            available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        let time = ProcessInfo.processInfo.systemUptime
        let sticks = StreamProtocol.LS_CLK_FLAG | StreamProtocol.RS_CLK_FLAG
        core.receive(slot: 0, buttons: sticks, analog: InputCore.neutral, capturedAt: time)
        core.receiveCenterButtons(id: id, token: token, buttons: 0,
                                  shoulders: StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG, capturedAt: time + 0.1)
        let state = try #require(core.layouts?.states[0])
        #expect(state.gesture.deadline != nil)
        core.receiveCenterButtons(id: id, token: token, buttons: 0, shoulders: 0, capturedAt: time + 0.2)
        core.advanceLayoutHold(state, slot: 0, at: time + 0.6)
        #expect(state.gesture.deadline == nil && state.gesture.latched == nil)
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
