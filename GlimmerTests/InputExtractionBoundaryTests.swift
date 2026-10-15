// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing
@testable import Glimmer

struct InputExtractionBoundaryTests {
    private func rig() -> (InputCore, InputRecordingBackend) {
        let core = InputCore()
        let backend = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        return (core, backend)
    }

    @Test func staleGCAndCenterSnapshotsCannotEnterReusedRegistration() {
        let (core, backend) = rig()
        let object = NSObject()
        let id = ObjectIdentifier(object)
        let token = core.registerController(id: id, slot: 0, buttons: 0, analog: InputCore.neutral)
        core.receiveCenterButtons(device: 17, capturedAt: .infinity, controller: { _ in (id, token) }, buttons: { _ in
            core.removeController(id: id)
            core.registerController(id: id, slot: 0, buttons: 0, analog: InputCore.neutral)
            return DualSenseExtraButtons(options: true)
        })
        core.receiveController(id: id, token: token, buttons: StreamProtocol.A_FLAG,
            analog: InputCore.neutral, chordButtons: 0, capturedAt: .infinity)
        #expect(backend.calls.isEmpty)
        #expect(core.state(slot: 0) == nil)
    }

    @Test func failedContactUpBlocksAnotherFingerInTheSameSnapshot() {
        let (core, backend) = rig()
        core.forwardTouchpad(slot: 0, primary: (0.3, 0.4), secondary: (0, 0))
        let first = backend.touches.first?.pointerId
        backend.touchUpResult = -2
        core.forwardTouchpad(slot: 0, primary: (0, 0), secondary: (0.5, 0.6))
        #expect(backend.touches.count == 1)
        #expect(core.pendingTouchReleases.count == 1)
        backend.touchUpResult = 0
        core.forwardTouchpad(slot: 0, primary: (0, 0), secondary: (0.5, 0.6))
        #expect(backend.touches.map(\.eventType) == [
            UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN), UInt8(StreamProtocol.LI_TOUCH_EVENT_UP),
            UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN)
        ])
        #expect(backend.touches[1].pointerId == first)
        #expect(backend.touches[2].pointerId != first)
    }

    @Test func offlineFocusReleaseSurvivesUntilReadyAndPrecedesReusedSlotTouch() throws {
        let (core, backend) = rig()
        core.forwardTouchpad(slot: 0, primary: (0.3, 0.4), secondary: (0, 0))
        core.publish(.init(ready: false, focused: false, mask: 1), backend: backend)
        core.releaseControllerTouches()
        #expect(core.pendingTouchReleases.count == 1)
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.forwardTouchpad(slot: 0, primary: (-0.4, 0.2), secondary: (0, 0))
        try #require(backend.touches.count == 3)
        #expect(backend.touches[1].eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP))
        #expect(backend.touches[0].pointerId != backend.touches[2].pointerId)
        #expect(core.pendingTouchReleases.isEmpty)
    }

    @Test(arguments: [false, true])
    func controllerActivationEscapesBackendLatchAndCannotReviveStoppedInput(stopBeforeDrain: Bool) throws {
        let backend = NativeBackend()
        let latchWasHeld = OSAllocatedUnfairLock(initialState: false)
        let recorder = InputRecordingBackend(onInput: {
            if backend.stateLock.try() { backend.stateLock.unlock() } else { latchWasHeld.withLock { $0 = true } }
        })
        let input = StreamInput(backend: recorder, emit: { _ in })
        defer { input.stop(); backend.stopConnection() }
        _ = input.registerController(.init(kind: .unknown, supportedButtons: .a, capabilities: []))
        let enet = EnetControlChannel(host: .ipv4(.loopback), port: 0, controlConnectData: 0,
            crypto: try ControlCrypto(rikey: [UInt8](repeating: 0, count: 16)))
        input.lifecycleQueue.suspend()
        #expect(backend.wireControllerFeedback(enet: enet,
            events: TransportConnectionEvents(id: UUID(), input: input, emit: { _, _ in })))
        #expect(recorder.controllerEvents.isEmpty)
        if stopBeforeDrain { input.stop() }
        input.lifecycleQueue.resume()
        input.lifecycleQueue.sync {}
        #expect(!latchWasHeld.withLock { $0 })
        #expect(input.core.snapshot.ready == !stopBeforeDrain)
        #expect(recorder.controllerEvents == (stopBeforeDrain ? [] : ["arrival"]))
    }

    @MainActor @Test func secondHeldPadGetsItsOwnDwellAfterFirstPadReleases() {
        let dwell = ControllerChordDwell()
        var fired: [UInt8] = []
        dwell.arm(slot: 0, held: { true }, expired: { if $0 { fired.append(0) } })
        dwell.arm(slot: 1, held: { true }, expired: { if $0 { fired.append(1) } })
        dwell.cancel(slot: 0)
        #expect(dwell.slot == 1)
        dwell.expire()
        #expect(fired == [1])
        #expect(dwell.task == nil)
        dwell.cancel()
    }

    @Test func invalidPointerGeometryIsRejectedWithoutIntegerConversionTrap() {
        for size in [CGSize(width: 40000, height: 1080), CGSize(width: CGFloat.infinity, height: 1080), CGSize(width: 1e30, height: 1080),
                     CGSize(width: 1920, height: CGFloat.nan)] {
            #expect(PointerMapping.streamPoint(viewPoint: .zero, viewSize: CGSize(width: 100, height: 100),
                                              streamPixelSize: size) == nil)
        }
    }
    @Test func staleMouseTimerCannotPollAResumedOwner() {
        let (core, backend) = rig()
        core.controllerMouseStates[0] = ControllerMouseState(isMouse: true)
        core.controllerMouseStates[0]?.analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
            leftStickX: 32767, leftStickY: 0, rightStickX: 0, rightStickY: 0)
        core.updateControllerMousePolling()
        let old = core.mousePollingGeneration
        core.suspendControllerMouse()
        core.controllerMouseStates[0]?.analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
            leftStickX: 32767, leftStickY: 0, rightStickX: 0, rightStickY: 0)
        core.updateControllerMousePolling()
        core.pollControllerMouse(generation: old)
        #expect(backend.mouseMoves.isEmpty)
        core.pollControllerMouse(generation: core.mousePollingGeneration)
        #expect(backend.mouseMoves.count == 1)
        core.suspendControllerMouse()
    }

    @Test func publicTouchGeometryIsFiniteAndBoundedAtAcceptance() throws {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.activate(true)
        input.setFocused(true)
        let registration = try #require(input.registerController(
            .init(kind: .unknown, supportedButtons: [], capabilities: .touchpad)))
        input.submitController(registration, sample: .init(touchpad: .init(
            primaryX: .nan, primaryY: 1, secondaryX: 4, secondaryY: -4, clicked: false)),
            capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.touches.count == 1)
        #expect(backend.touches[0].x == 1 && backend.touches[0].y == 1)
    }
    private func waitForCapturedEdge(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 2)
    }

    @MainActor @Test func capturedMacReleaseAndRepressCannotCompleteOldDwell() async throws {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.gamepadMask = 1
        forwarder.controllerQuitChordProvider = { .l1r1 }
        let held = StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        forwarder.pushHID(slot: 0, state: (held, InputCore.neutral)) { (held, InputCore.neutral) }
        defer { forwarder.detach() }
        try #require(forwarder.quitChordDwellTask != nil)
        var stops = 0
        forwarder.onQuitHotkey = { stops += 1 }
        let captured = DispatchSemaphore(value: 0)
        let core = forwarder.inputCore
        DispatchQueue.global().async {
            core.receive(slot: 0, buttons: 0, analog: InputCore.neutral)
            core.receive(slot: 0, buttons: held, analog: InputCore.neutral)
            captured.signal()
        }
        #expect(waitForCapturedEdge(captured) == .success)
        forwarder.controllerChordDwell.expire()
        #expect(stops == 0)
        for _ in 0..<100 where forwarder.quitChordDwellTask == nil { await Task.yield() }
        try #require(forwarder.quitChordDwellTask != nil)
        forwarder.controllerChordDwell.expire()
        #expect(stops == 1)
    }
}
