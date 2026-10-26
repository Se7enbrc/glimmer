// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import GameController
import os
import Observation
import Testing
@testable import Glimmer

struct InputCoreTests {
    private func rig() -> (InputCore, InputRecordingBackend) {
        let core = InputCore()
        let backend = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 3), backend: backend)
        return (core, backend)
    }

    @Test func capturedControllerUpdatesRegisteredSlotAndRetiresItsChordOnRemoval() {
        let (core, backend) = rig()
        let identity = NSObject()
        let id = ObjectIdentifier(identity)
        let analog = GamepadAnalog(leftTrigger: 127, rightTrigger: 255, leftStickX: -32767,
                                   leftStickY: 32767, rightStickX: 123, rightStickY: -456)
        let token = core.registerController(id: id, slot: 1, buttons: 0, analog: InputCore.neutral)
        core.receiveController(id: id, token: token, buttons: StreamProtocol.A_FLAG, analog: analog,
                               chordButtons: StreamProtocol.A_FLAG, capturedAt: .infinity)
        #expect(backend.calls.last?.num == 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        #expect(core.withLock { core.controllers[id]?.analog } == analog)
        #expect(core.state(slot: 1)?.analog == analog)
        #expect(core.withLock { core.chordSlots.insert(1).inserted })
        core.removeController(id: id)
        core.removeController(id: id)
        core.receiveController(id: id, token: token, buttons: StreamProtocol.B_FLAG, analog: analog,
                               chordButtons: 0, capturedAt: .infinity)
        #expect(backend.calls.count == 1)
        #expect(core.state(slot: 1) == nil)
        #expect(core.withLock { !core.chordSlots.contains(1) })
    }

    @Test func rawCenterButtonsReplaceStaleCenterStateAndKeepCapturedAxes() {
        let (core, backend) = rig()
        let identity = NSObject()
        let id = ObjectIdentifier(identity)
        let partials = OSAllocatedUnfairLock(initialState: [UInt8]())
        core.onCenterPartial = { slot in partials.withLock { $0.append(slot) } }
        let analog = GamepadAnalog(leftTrigger: 12, rightTrigger: 34, leftStickX: 56,
                                   leftStickY: 78, rightStickX: 90, rightStickY: 123)
        let token = core.registerController(id: id, slot: 0, buttons: StreamProtocol.A_FLAG | StreamProtocol.PLAY_FLAG,
                                analog: analog)
        core.receiveCenterButtons(device: 17, capturedAt: .infinity, controller: { _ in (id, token) }, buttons: { _ in
            DualSenseExtraButtons(create: true, ps: true, mute: true)
        })
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG | StreamProtocol.BACK_FLAG
            | StreamProtocol.SPECIAL_FLAG | StreamProtocol.MISC_FLAG)
        #expect(core.state(slot: 0)?.analog == analog)
        #expect(partials.withLock { $0 } == [0])
        core.receiveCenterButtons(device: 17, capturedAt: 0, controller: { _ in
            (id, token)
        })
        core.receiveCenterButtons(device: 17, controller: { _ in nil })
        #expect(backend.calls.count == 1)
        core.receiveCenterButtons(device: 17, capturedAt: .infinity, controller: { _ in (id, token) }, buttons: { _ in
            DualSenseExtraButtons()
        })
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        #expect(partials.withLock { $0 } == [0])
        core.withLock { core.snapshot.chord = .l1r1 }
        core.receiveCenterButtons(device: 17, capturedAt: .infinity, controller: { _ in (id, token) }, buttons: { _ in
            DualSenseExtraButtons(options: true, l1: true, r1: true)
        })
        #expect(core.withLock { core.chordSlots.contains(0) })
        #expect(partials.withLock { $0 } == [0])
    }

    @Test func neutralControllerSamplesDoNotWakeMainForReconciliation() {
        let (core, _) = rig()
        let updates = OSAllocatedUnfairLock(initialState: 0)
        core.onActivity = { updates.withLock { $0 += 1 } }
        for _ in 0..<10 { core.receive(slot: 0, buttons: 0, analog: InputCore.neutral) }
        #expect(updates.withLock { $0 } == 0)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        #expect(updates.withLock { $0 } == 1)
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        #expect(updates.withLock { $0 } == 1)
    }

    @MainActor @Test func firstResponderPublishesControllerFocusWithoutAKeyNotification() async {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        let window = PointerFocusTestWindow(contentRect: .zero, styleMask: .borderless,
                                            backing: .buffered, defer: true)
        window.focused = false
        forwarder.attach(to: window)
        forwarder.backend = backend
        forwarder.isReady = true
        forwarder.gamepadMask = 1
        forwarder.controllerQuitChordProvider = { .l1r1 }
        forwarder.neutralizeControllers()
        defer { forwarder.detach() }
        window.focused = true
        forwarder.fullscreenRelativePointer = false
        forwarder.installFirstResponder()
        #expect(forwarder.inputCore.withLock { forwarder.inputCore.snapshot.focused })
        let core = forwarder.inputCore
        _ = await Task.detached {
            core.receive(slot: 0, buttons: StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG,
                         analog: InputCore.neutral)
        }.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(forwarder.quitChordDwellSlot == 0)
        var stopped = false
        forwarder.onQuitHotkey = { stopped = true }
        forwarder.controllerChordDwell.expire()
        #expect(stopped)
    }

    @MainActor @Test func controllerHandlerHealingReassertsSystemGestureOwnership() throws {
        let forwarder = InputForwarder()
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.buttonMenu.preferredSystemGestureState = .enabled
        forwarder.attach(gamepad: controller)
        defer { forwarder.detach() }
        let state = try #require(forwarder.attachedControllers[ObjectIdentifier(controller)])
        #expect(pad.buttonMenu.preferredSystemGestureState == .disabled)
        pad.buttonMenu.preferredSystemGestureState = .enabled
        forwarder.installInputHandlers(for: state)
        #expect(pad.buttonMenu.preferredSystemGestureState == .disabled)
        forwarder.detach(gamepad: controller)
        #expect(pad.buttonMenu.preferredSystemGestureState == .enabled)
    }

    @Test func rawCaptureKeepsNintendoMappingAndMouseClicksPositional() {
        let (core, backend) = rig()
        let token = UUID()
        let start = ProcessInfo.processInfo.systemUptime
        core.withLock {
            core.snapshot.nintendoSlots = [0]
            core.hidRegistrations[0] = token
        }
        defer { core.resetControllerMouse() }
        let queue = DispatchQueue(label: "test.controller.capture")
        queue.sync {
            core.receiveHID(slot: 0, token: token, buttons: StreamProtocol.A_FLAG,
                            analog: InputCore.neutral, capturedAt: start)
            core.receiveHID(slot: 0, token: token, buttons: StreamProtocol.PLAY_FLAG,
                            analog: InputCore.neutral, capturedAt: start + 1)
            core.receiveHID(slot: 0, token: token, buttons: 0,
                            analog: InputCore.neutral, capturedAt: start + 2)
            core.receiveHID(slot: 0, token: token, buttons: StreamProtocol.A_FLAG,
                            analog: InputCore.neutral, capturedAt: start + 3)
        }
        #expect(backend.calls.first?.buttons == StreamProtocol.B_FLAG)
        #expect(core.withLock { core.controllerMouseStates[0]?.isMouse } == true)
        #expect(backend.calls.last?.buttons == 0)
        #expect(backend.pointer == [.button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1)])
    }

    @Test func captureTouchpadUsesTrackpadAndRetainsFailedClickRelease() {
        let (core, backend) = rig()
        core.withLock { core.controllerMouseStates[0] = ControllerMouseState(isMouse: true) }
        defer { core.resetControllerMouse() }
        core.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: (0, 0), clicked: true, now: 1)
        core.forwardTouchpad(slot: 0, primary: (0.4, 0.2), secondary: (0, 0), clicked: true, now: 1.02)
        #expect(backend.touches.isEmpty)
        #expect(backend.mouseMoves.count == 1)
        backend.inputResult = -2
        core.forwardTouchpad(slot: 0, primary: (0, 0), secondary: (0, 0), now: 1.03)
        #expect(core.withLock { core.releases.pending } == [.mouse(StreamProtocol.BUTTON_LEFT)])
        core.receive(slot: 1, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        #expect(backend.calls.isEmpty)
        backend.inputResult = 0
        core.receive(slot: 1, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        #expect(backend.pointer.last == .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: 1))
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        #expect(core.withLock { core.releases.pending.isEmpty })
    }

    @Test func nintendoChordReleasesUseMappedAcceptedButtons() {
        let (core, backend) = rig()
        core.withLock { core.snapshot.nintendoSlots = [0]; core.snapshot.chord = .l1r1 }
        defer { core.resetControllerMouse() }
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        let chord = StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        core.receive(slot: 0, buttons: chord | StreamProtocol.A_FLAG, analog: InputCore.neutral)
        #expect(backend.calls.count == 1)
        core.receive(slot: 0, buttons: chord, analog: InputCore.neutral)
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.B_FLAG, 0])
    }

    @MainActor @Test func miniPlayerFocusLossKeepsControllerMouseClickUntilItsOwnRelease() {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.backend = backend
        forwarder.isReady = true
        forwarder.gamepadMask = 1
        forwarder.setMiniPlayer(true)
        defer { forwarder.detach() }
        forwarder.controllerMouseStates[0] = ControllerMouseState(isMouse: true)
        forwarder.inputCore.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        forwarder.inputOwnershipLost(reason: "test focus loss", includingControllers: false)
        #expect(backend.pointer.count == 1)
        forwarder.inputCore.receive(slot: 0, buttons: 0, analog: InputCore.neutral)
        #expect(backend.pointer.count == 2)
        #expect(backend.pointer.last == .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: 1))
    }

    @Test func failureLoggingResetsOnlyForANewConnection() {
        let (core, backend) = rig()
        core.withLock { core.record("test", -2) }
        core.publish(.init(ready: true, focused: false, mask: 3), backend: backend)
        #expect(core.withLock { core.failureCodes } == [-2])
        core.publish(.init(ready: false, focused: false, mask: 3), backend: backend)
        core.publish(.init(ready: true, focused: true, mask: 3), backend: backend)
        #expect(core.withLock { core.failureCodes.isEmpty })
        core.withLock { core.record("test", -2) }
        core.publish(.init(ready: true, focused: true, mask: 3), backend: InputRecordingBackend())
        #expect(core.withLock { core.failureCodes.isEmpty })
    }

    @Test func senderSerializesConcurrentProducersWithoutRunningOnTheirThreads() {
        let sender = InputSendThread(realtime: false)
        defer { sender.stop() }
        let observed = OSAllocatedUnfairLock(initialState: [(Int, Int)]())
        DispatchQueue.concurrentPerform(iterations: 4) { producer in
            for sequence in 0..<100 {
                let result = sender.sync {
                    #expect(Thread.current.name == "Glimmer.inputSend")
                    observed.withLock { $0.append((producer, sequence)) }
                    return Int32(sequence)
                }
                #expect(result == Int32(sequence))
            }
        }
        let values = observed.withLock { $0 }
        #expect(values.count == 400)
        for producer in 0..<4 {
            #expect(values.filter { $0.0 == producer }.map(\.1) == Array(0..<100))
        }
    }

    @Test func timerAndReentrantAcceptanceUseTheSameOwnedThread() {
        let sender = InputSendThread(realtime: false)
        defer { sender.stop() }
        let fired = DispatchSemaphore(value: 0)
        sender.schedule(deadline: .now()) {
            sender.sync {
                #expect(Thread.current.name == "Glimmer.inputSend")
                return 0
            }
            fired.signal()
        }
        #expect(fired.wait(timeout: .now() + 2) == .success)
    }

    @Test func senderCanStopFromItsOwnTimerWithoutWaitingForItself() {
        let sender = InputSendThread(realtime: false)
        let fired = DispatchSemaphore(value: 0)
        sender.schedule(deadline: .now()) { sender.stop(); fired.signal() }
        #expect(fired.wait(timeout: .now() + 2) == .success)
        sender.stop()
    }

    @Test func focusReadinessAndSlotSnapshotsRejectLateCapture() {
        let (core, backend) = rig()
        core.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
        #expect(backend.calls.count == 1)
        core.publish(.init(ready: true, focused: false, mask: 3), backend: backend)
        core.receive(slot: 0, buttons: 2, analog: InputCore.neutral)
        core.publish(.init(ready: false, focused: true, mask: 3), backend: backend)
        core.receive(slot: 0, buttons: 3, analog: InputCore.neutral)
        core.publish(.init(ready: true, focused: true, mask: 2), backend: backend)
        core.receive(slot: 0, buttons: 4, analog: InputCore.neutral)
        core.receive(slot: 1, buttons: 5, analog: InputCore.neutral, capturedAt: 1)
        #expect(backend.calls.count == 1)
        core.receive(slot: 1, buttons: 6, analog: InputCore.neutral)
        #expect(backend.calls.last?.buttons == 6)
    }

    @Test func failedKeyboardReleaseBlocksControllerEdgesAndSurvivesReplacement() {
        let (core, first) = rig()
        let key = VKScanCode(vk: 0x41)
        core.withLock {
            core.releases.hold(.key(key))
            core.releases.release(.key(key))
        }
        first.inputResult = -1
        core.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
        #expect(first.calls.isEmpty)
        #expect(core.withLock { core.releases.pending.contains(.key(key)) })
        let replacement = InputRecordingBackend()
        core.publish(.init(ready: true, focused: true, mask: 3), backend: replacement)
        core.receive(slot: 0, buttons: 2, analog: InputCore.neutral)
        #expect(replacement.keyboard.map(\.action) == [Int8(StreamProtocol.KEY_ACTION_UP)])
        #expect(replacement.calls.last?.buttons == 2)
        #expect(core.withLock { core.releases.pending.isEmpty })
    }

    @Test func reannouncementRemainsABarrierAfterAReleaseRecoversOnTheCaptureThread() {
        let (core, backend) = rig()
        let key = VKScanCode(vk: 0x41)
        core.withLock { core.releases.hold(.key(key)); core.releases.release(.key(key)) }
        core.publish(.init(ready: true, focused: true, mask: 1, controllersAnnounced: false), backend: backend)
        core.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
        core.forwardTouchpad(slot: 0, primary: (1, 1), secondary: (0, 0))
        #expect(backend.keyboard.count == 1)
        #expect(backend.calls.isEmpty)
        #expect(backend.touches.isEmpty)
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.receive(slot: 0, buttons: 2, analog: InputCore.neutral)
        #expect(backend.calls.map(\.buttons) == [2])
    }

    @Test func configSnapshotSuppressesOnlyNewChordPresses() {
        let (core, backend) = rig()
        core.receive(slot: 0, buttons: StreamProtocol.A_FLAG, analog: InputCore.neutral)
        core.publish(.init(ready: true, focused: true, mask: 3, chord: .l1r1), backend: backend)
        core.receive(slot: 0, buttons: StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG, analog: InputCore.neutral)
        #expect(backend.calls.last?.buttons == 0)
        #expect(core.withLock { core.chordSlots.contains(0) })
        core.receive(slot: 0, buttons: StreamProtocol.LB_FLAG, analog: InputCore.neutral)
        #expect(backend.calls.last?.buttons == StreamProtocol.LB_FLAG)
        #expect(core.withLock { !core.chordSlots.contains(0) })
    }

    @Test func concurrentControllerEdgesKeepEachDevicesOrder() {
        let (core, backend) = rig()
        DispatchQueue.concurrentPerform(iterations: 2) { slot in
            for edge in 1...100 { core.receive(slot: UInt8(slot), buttons: Int32(edge), analog: InputCore.neutral) }
        }
        for slot in 0...1 {
            #expect(backend.calls.filter { $0.num == Int16(slot) }.map(\.buttons) == (1...100).map(Int32.init))
        }
    }

    @MainActor @Test func gameControllerOwnsItsCaptureQueueAndRestoresItOnDetach() {
        let forwarder = InputForwarder()
        let pad = GCController.withExtendedGamepad()
        let prior = pad.handlerQueue
        forwarder.attach(gamepad: pad)
        #expect(pad.handlerQueue === forwarder.controllerCaptureQueue)
        forwarder.detach(gamepad: pad)
        #expect(pad.handlerQueue === prior)
        forwarder.detach()
    }
    @Test func rawReportAssemblyPreservesPressAndReleaseWithoutAMainQueueDrain() {
        let elements = [HIDGamepadElement(cookie: 1, page: 9, usage: 1, kind: .button),
                        HIDGamepadElement(cookie: 2, page: 9, usage: 2, kind: .button)]
        let readings = HIDGamepadReadings(descriptors: elements, logical: [
            1: .init(minimum: 0, maximum: 1), 2: .init(minimum: 0, maximum: 1)])
        let drains = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
        let capture = HIDGamepadCapture(readings: readings,
            mapping: HIDGamepadMapping(name: "Test", bindings: ["a": .button(0), "b": .button(1)]),
            scheduleDrain: { drain in drains.withLock { $0.append(drain) } })
        let edges = OSAllocatedUnfairLock(initialState: [Int32]())
        capture.setReading(true)
        capture.setHandler { buttons, _, _ in edges.withLock { $0.append(buttons) } }
        capture.receive(cookie: 1, raw: 1, timestamp: 10, report: 1)
        capture.receive(cookie: 2, raw: 1, timestamp: 10, report: 1)
        #expect(edges.withLock { $0.isEmpty })
        capture.receive(cookie: 1, raw: 0, timestamp: 20, report: 1)
        capture.receive(cookie: 2, raw: 0, timestamp: 20, report: 1)
        let scheduled = drains.withLock { $0 }
        #expect(scheduled.count == 1)
        scheduled.forEach { $0() }
        #expect(edges.withLock { $0 } == [StreamProtocol.A_FLAG | StreamProtocol.B_FLAG, 0])
        #expect(capture.count == 2)
    }

    @Test func streamHIDHandlerReceivesExtraButtonsWithoutALayoutLease() {
        let elements = [HIDGamepadElement(cookie: 1, page: 9, usage: 1, kind: .button),
                        HIDGamepadElement(cookie: 2, page: 9, usage: 2, kind: .button)]
        let readings = HIDGamepadReadings(descriptors: elements, logical: [
            1: .init(minimum: 0, maximum: 1), 2: .init(minimum: 0, maximum: 1)])
        let drains = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
        let capture = HIDGamepadCapture(readings: readings,
            mapping: HIDGamepadMapping(name: "Test", bindings: ["a": .button(0)]),
            scheduleDrain: { drain in drains.withLock { $0.append(drain) } })
        let samples = OSAllocatedUnfairLock(initialState: [ControllerMappingSample]())
        capture.setStreamHandler(indexes: [1]) { sample, _ in samples.withLock { $0.append(sample) } }
        capture.setReading(true)
        capture.receive(cookie: 2, raw: 1, timestamp: 10, report: 1)
        capture.receive(cookie: 2, raw: 0, timestamp: 20, report: 1)
        drains.withLock { $0 }.forEach { $0() }
        #expect(samples.withLock { $0.map(\.buttons) } == [0, 0])
        #expect(samples.withLock { $0.map(\.extras) } == [SIMD2(1, 0), .zero])
        capture.setHandler(nil)
    }

    @Test func lateRawCallbackCannotPressIntoAReusedSlot() {
        let (core, backend) = rig()
        let retired = UUID()
        let replacement = UUID()
        core.withLock { core.hidRegistrations[0] = replacement }
        core.receiveHID(slot: 0, token: retired, buttons: 1, analog: InputCore.neutral,
                        capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.calls.isEmpty)
        core.receiveHID(slot: 0, token: replacement, buttons: 2, analog: InputCore.neutral,
                        capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.calls.last?.buttons == 2)
    }

    @MainActor @Test func miniPlayerKeepsControllerOwnershipWhenOnlyKeyboardFocusLeaves() {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.gamepadMask = 1
        forwarder.setMiniPlayer(true)
        defer { forwarder.detach() }
        forwarder.inputOwnershipLost(reason: "test focus loss", includingControllers: false)
        forwarder.inputCore.receive(slot: 0, buttons: 1, analog: InputCore.neutral)
        #expect(backend.calls.last?.buttons == 1)
        forwarder.inputOwnershipLost(reason: "test sleep")
        #expect(backend.calls.last?.buttons == 0)
        let count = backend.calls.count
        forwarder.inputCore.receive(slot: 0, buttons: 2, analog: InputCore.neutral)
        #expect(backend.calls.count == count)
    }

    @Test func hidThreadExecutesOffMain() {
        HIDInputThread.shared.sync {
            #expect(!Thread.isMainThread)
            #expect(Thread.current.name == "Glimmer.hidCapture")
        }
    }

    @MainActor @Test func observableConfigurationPublishesWithoutAnInputEvent() async {
        let config = InputChordConfig()
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        forwarder.controllerQuitChordProvider = { config.chord }
        #expect(forwarder.inputCore.withLock { forwarder.inputCore.snapshot.chord } == .none)
        config.chord = .l1r1
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(forwarder.inputCore.withLock { forwarder.inputCore.snapshot.chord } == .l1r1)
    }
}

@MainActor @Observable private final class InputChordConfig {
    var chord: ControllerQuitChord = .none
}
