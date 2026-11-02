// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os
import Testing
@testable import GlimmerEngine

struct ControllerStartupTests {
    private let arrival = ControllerArrival(type: UInt8(StreamProtocol.LI_CTYPE_PS),
                                            supportedButtons: 0x30f7ff, caps: 0xeb)

    private func configuration() throws -> ControllerLayoutConfiguration {
        let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
        return try ControllerLayoutConfiguration(layout: nil, shortcuts: nil, available: available)
    }

    @Test(.bug("https://github.com/Se7enbrc/glimmer/issues/217"), arguments: [false, true])
    func initialLayoutMustNotCreateALegacyControllerBeforeArrival(ready: Bool) throws {
        let core = InputCore()
        let backend = ControllerStartupBackend()
        core.backend = backend
        core.snapshot = .init(ready: ready, focused: true, mask: 1, controllersAnnounced: false)
        core.configureLayout(try configuration(), slot: 0, held: .init(), at: 1)
        core.snapshot.ready = true
        try #require(core.flushReleases())
        try #require(core.announceController(slot: 0, arrival: arrival) == 0)
        let events = backend.events.withLock { $0 }
        #expect(events.first == .arrival(0, arrival.type))
    }

    @Test func layoutChangeStillReleasesHeldButtonsBeforeReannouncing() throws {
        let core = InputCore()
        let backend = ControllerStartupBackend()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        try #require(core.announceController(slot: 0, arrival: arrival) == 0)
        core.sendController(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        backend.events.withLock { $0.removeAll() }
        backend.controllerResult.withLock { $0 = -2 }
        core.configureLayout(try configuration(), slot: 0, held: .init(), at: 1)
        #expect(core.releases.pending == [.controller(0)])
        #expect(backend.events.withLock { $0.isEmpty })
        backend.controllerResult.withLock { $0 = 0 }
        try #require(core.flushReleases())
        try #require(core.flushControllerArrivals())
        #expect(backend.events.withLock { $0 } == [.controller(0, 1, 0), .arrival(0, arrival.type)])
    }

    @Test func removalStillPrecedesArrivalWhenSlotIsReused() throws {
        let core = InputCore()
        let backend = ControllerStartupBackend()
        core.publish(.init(ready: false, focused: true, mask: 1), backend: backend)
        core.retireController(slot: 0)
        core.configureLayout(try configuration(), slot: 0, held: .init(), at: 1)
        core.snapshot.ready = true
        try #require(core.announceController(slot: 0, arrival: arrival) == 0)
        #expect(backend.events.withLock { $0 } == [.controller(0, 0, 0), .arrival(0, arrival.type)])
    }
}

final class ControllerStartupBackend: StreamingBackend {
    enum Event: Equatable {
        case arrival(UInt8, UInt8)
        case controller(Int16, Int16, Int32)
        case key(Int16)
    }
    let events = OSAllocatedUnfairLock(initialState: [Event]())
    let controllerResult = OSAllocatedUnfairLock(initialState: Int32(0))
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        let result = controllerResult.withLock { $0 }
        guard result == 0 else { return result }
        events.withLock { $0.append(.controller(num, mask, buttons)) }
        return 0
    }
    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8,
                               supportedButtons: UInt32, caps: UInt16) -> Int32 {
        events.withLock { $0.append(.arrival(num, type)) }
        return 0
    }
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        events.withLock { $0.append(.key(keyCode)) }
        return 0
    }
    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {
        Issue.record("Controller ordering tests must never open a network connection")
    }
    func stopConnection() {}
    func interruptConnection() {}
    func attachVideoSink(_ sink: VideoSink) {}
    func attachAudioSink(_ sink: NativeAudioSink) {}
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func requestIdrFrame() {}
    func hdrMetadata() -> HdrMetadata? { nil }
    func launchUrlQueryParameters() -> String { "" }
    func stageName(for stage: Int32) -> String { "" }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                             pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Int32 { 0 }
    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 { 0 }
    func sendUtf8Text(_ text: String) -> Int32 { 0 }
}
