// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import GameController
import Network
import Synchronization
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@MainActor
struct ControllerLayoutDeliveryTests {
    @Test func controllerMouseStartsRightHandedWithoutFaceButtonClicks() {
        let core = InputCore()
        #expect(core.controllerMouseMapping == .rightStick)
        #expect(core.controllerMousePlan.clickMask(.init(buttons: StreamProtocol.A_FLAG | StreamProtocol.B_FLAG
            | StreamProtocol.X_FLAG, analog: InputCore.neutral)) == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func systemProfileChangesReachEncoderWhileMainIsOccupied(physicalFirst: Bool, observesChord: Bool) throws {
        let fixture = try ControllerLayoutDeliveryFixture()
        let controller = fixture.controller
        let queue = DispatchQueue(label: "controller-layout-delivery-test")
        ControllerStreamHandlers.install(controller: controller, input: controller.input, queue: queue,
            mapsGameInput: false, shortcutElements: observesChord ? [ObjectIdentifier(fixture.element)] : [],
            read: { fixture.physical.withLock { $0 } }, receive: { sample, time in fixture.submit(sample, at: time) })
        defer { fixture.stop() }
        let physicalHandler = controller.input.elementValueDidChangeHandler
        #expect((physicalHandler != nil) == observesChord)
        let gamepadHandler = try #require(controller.extendedGamepad?.valueChangedHandler)
        #expect(fixture.deliver(queue: queue, physicalHandler: physicalHandler,
                                gamepadHandler: gamepadHandler, physicalFirst: physicalFirst) == .success)
        let expected = fixture.states.map { state in
            InputEncoder.multiController(num: 0, mask: 1, buttons: state.buttons, analog: state.analog)
        }
        let packets = try fixture.packets()
        // Duplicate profile notifications are allowed; every changed game state must remain ordered.
        let changes = packets.reduce(into: [[UInt8]]()) { if $0.last != $1 { $0.append($1) } }
        #expect(changes == expected)
        #expect(packets.last == expected.last)
        let timestamps = fixture.timestamps.withLock { $0 }
        #expect(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(controller.handlerQueue === queue)
        #expect(controller.input.queue === queue)
        #expect(controller.extendedGamepad?.buttonMenu.pressedChangedHandler == nil)
    }

    @Test(arguments: [false, true])
    func streamOwnsOnlyItsAuthoritativeProfileWithoutChordObservers(mapsGameInput: Bool) throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let queue = DispatchQueue(label: "stream-handler-ownership-test")
        ControllerStreamHandlers.install(controller: controller, input: controller.input, queue: queue,
            mapsGameInput: mapsGameInput, shortcutElements: [], read: { .init() }, receive: { _, _ in })
        #expect((pad.valueChangedHandler != nil) == !mapsGameInput)
        #expect((controller.input.elementValueDidChangeHandler != nil) == mapsGameInput)
        #expect(pad.buttonMenu.pressedChangedHandler == nil)
        #expect(controller.handlerQueue === queue)
        #expect(controller.input.queue === queue)
    }

    @Test func physicalOnlyCaptureRestoresPriorHandlersAndQueues() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let input = controller.input
        let priorQueue = DispatchQueue(label: "controller-prior-profile")
        let captureQueue = DispatchQueue(label: "controller-physical-only")
        let calls = Mutex(0)
        controller.handlerQueue = priorQueue
        input.queue = priorQueue
        pad.valueChangedHandler = { @Sendable _, _ in calls.withLock { $0 += 1 } }
        input.elementValueDidChangeHandler = { @Sendable _, _ in calls.withLock { $0 += 1 } }
        let lease = ControllerLayoutInputLease(controller: controller, input: input, queue: captureQueue,
            read: { .init() }, receive: { _, _ in })
        #expect(pad.valueChangedHandler == nil)
        #expect(controller.handlerQueue === priorQueue)
        #expect(input.queue === captureQueue)
        lease.stop()
        #expect(input.queue === priorQueue)
        #expect(controller.handlerQueue === priorQueue)
        let handler = try #require(input.elementValueDidChangeHandler)
        let restored = DispatchSemaphore(value: 0)
        priorQueue.async(execute: ControllerCallbackTestDelivery.physical(input, handler: handler) { restored.signal() })
        #expect(restored.wait(timeout: .now() + 2) == .success)
        pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(calls.withLock { $0 } == 2)
    }
}

// The fixture mutates the snapshot pad only on the serial delivery queue; physical state is locked.
private final class ControllerLayoutDeliveryFixture: @unchecked Sendable {
    struct State {
        let buttons: Int32
        let analog: GamepadAnalog
    }
    let controller = GCController.withExtendedGamepad()
    let element = Element()
    let physical = Mutex(ControllerMappingSample())
    let timestamps = Mutex<[TimeInterval]>([])
    let core = InputCore()
    let backend = NativeBackend()
    let channel: EnetControlChannel
    let batcher: InputBatcher
    private let key = Array(0..<16).map { UInt8($0) }
    let states: [State] = [
        State(buttons: 0, analog: InputCore.neutral),
        State(buttons: StreamProtocol.B_FLAG, analog: InputCore.neutral),
        State(buttons: StreamProtocol.B_FLAG, analog: .init(leftTrigger: 0, rightTrigger: 0,
            leftStickX: 16384, leftStickY: 0, rightStickX: 0, rightStickY: 0)),
        State(buttons: 0, analog: .init(leftTrigger: 0, rightTrigger: 0,
            leftStickX: 16384, leftStickY: 0, rightStickX: 0, rightStickY: 0)),
        State(buttons: 0, analog: InputCore.neutral)
    ]

    init() throws {
        channel = EnetControlChannel(host: .ipv4(.loopback), port: 9, controlConnectData: 0,
                                     crypto: try ControlCrypto(rikey: key))
        // An unstarted socket supplies local acceptance without making a network connection.
        channel.setConnection(NWConnection(host: .ipv4(.loopback), port: 9, using: .udp))
        batcher = InputBatcher(enet: channel, tracker: { nil }, backpressure: { _ in false },
                               scheduleFlush: { _, _, _ in })
        backend.withState { backend.inputBatcher = batcher; backend.inputReady = true }
        core.publish(.init(ready: true, focused: true, mask: 1), backend: backend)
        core.withLock { core.snapshot.acceptEventsAfter = 0 }
        core.announceController(slot: 0, arrival: .init(type: 1, supportedButtons: 0xFFFF, caps: 1))
        let configuration = try ControllerLayoutConfiguration(layout: nil, shortcuts: nil,
            available: Set(ControllerMappedButton.allCases.map { .button($0) }))
        core.configureLayout(configuration, slot: 0, held: .init(), at: 0)
        channel.withState { channel.sentReliable.removeAll() }
    }

    func submit(_ sample: ControllerMappingSample, at timestamp: TimeInterval) {
        #expect(Thread.isMainThread == false)
        timestamps.withLock { $0.append(timestamp) }
        guard let pad = controller.extendedGamepad else { Issue.record("Missing gamepad"); return }
        let analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
            leftStickX: Int16((pad.leftThumbstick.xAxis.value * 32767).rounded()), leftStickY: 0,
            rightStickX: 0, rightStickY: 0)
        _ = core.receive(slot: 0, buttons: pad.buttonB.isPressed ? StreamProtocol.B_FLAG : 0,
            analog: analog, capturedAt: ProcessInfo.processInfo.systemUptime, physicalSample: sample)
        // Drain each scripted report so coalescing cannot hide a missing source callback.
        _ = batcher.passThroughReport([], channel: Enet.ctrlChannelGeneric)
    }

    func deliver(queue: DispatchQueue,
                 physicalHandler: ((any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void)?,
                 gamepadHandler: GCExtendedGamepadValueChangedHandler?, physicalFirst: Bool) -> DispatchTimeoutResult {
        let done = DispatchSemaphore(value: 0)
        queue.async(execute: DispatchWorkItem { [self] in
            guard let pad = controller.extendedGamepad else { done.signal(); return }
            for state in states {
                let updatePhysical = {
                    // The system remaps physical A to B, independently of the legacy profile's publication.
                    self.physical.withLock {
                        $0 = .init(buttons: state.buttons == 0 ? 0 : ControllerMappedButton.a.rawValue,
                                   analog: SIMD8(0, 0, Int32(state.analog.leftStickX), 0, 0, 0, 0, 0))
                    }
                    physicalHandler?(self.controller.input, self.element)
                }
                if physicalFirst { updatePhysical() }
                // Invoke the saved handler once, independent of snapshot setter callback behavior.
                pad.valueChangedHandler = nil
                pad.buttonB.setValue(state.buttons == 0 ? 0 : 1)
                pad.leftThumbstick.xAxis.setValue(Float(state.analog.leftStickX) / 32767)
                gamepadHandler?(pad, pad.buttonB)
                if !physicalFirst { updatePhysical() }
            }
            done.signal()
        })
        // Main cannot service queued input until the complete sequence has reached the encoder.
        return done.wait(timeout: .now() + 2)
    }

    func packets() throws -> [[UInt8]] {
        try channel.withState { channel.sentReliable.map(\.commandBytes) }.map { command in
            let envelope = Array(command.dropFirst(6))
            var iv = [UInt8](repeating: 0, count: 12)
            iv[0..<4] = envelope[4..<8]
            iv[10] = 0x43; iv[11] = 0x43
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                ciphertext: envelope[24...], tag: envelope[8..<24])
            return try Array(AES.GCM.open(box, using: SymmetricKey(data: key)).dropFirst(4))
        }.filter { $0.count == 34 }
    }

    func stop() { batcher.stop(); backend.stopConnection(); channel.close() }

    final class Element: NSObject, GCPhysicalInputElement {
        let aliases: Set<String> = ["test"]
        let localizedName: String? = "Test"
        let sfSymbolsName: String? = nil
    }
}
