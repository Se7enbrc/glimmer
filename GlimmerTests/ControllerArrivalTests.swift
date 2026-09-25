//
//  ControllerArrivalTests.swift
//
//  What a controller arrival promises the PC, how the slots it announced are kept honest across a
//  reconnect (Sunshine still holds the last session's virtual pads), what focus loss releases,
//  and what a session leaves behind when it ends.
//

import AppKit
import GameController
import Testing
import os
@testable import Glimmer

private struct ControllerSend: Sendable {
    let num: Int16
    let mask: Int16
    let buttons: Int32
    let analog: GamepadAnalog
}

private final class RecordingBackend: StreamingBackend {
    private let sends = OSAllocatedUnfairLock(initialState: [ControllerSend]())

    var calls: [ControllerSend] { sends.withLock { $0 } }

    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {}
    func stopConnection() {}
    func interruptConnection() {}
    func attachVideoSink(_ sink: VideoSink) {}
    func attachAudioSink(_ sink: NativeAudioSink) {}
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func requestIdrFrame() {}
    func hdrMetadata() -> HdrMetadata? { nil }
    func launchUrlQueryParameters() -> String { "" }
    func stageName(for stage: Int32) -> String { "" }
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 { 0 }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        sends.withLock { $0.append(ControllerSend(num: num, mask: mask, buttons: buttons, analog: analog)) }
        return 0
    }
    func sendControllerArrival(
        num: UInt8, mask: UInt16, type: UInt8,
        supportedButtons: UInt32, caps: UInt16
    ) -> Int32 { 0 }
    func sendControllerTouch(
        num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
        pointerId: UInt32, x: Float, y: Float, pressure: Float
    ) -> Int32 { 0 }
    func sendControllerMotion(
        num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float
    ) -> Int32 { 0 }
    func sendUtf8Text(_ text: String) -> Int32 { 0 }
}

@MainActor
struct ControllerArrivalTests {

    private typealias Arrival = InputForwarder.ControllerArrival

    /// Detach removes observers before a new pad can attach during stop.
    @Test func detachRemovesGamepadObservers() {
        let forwarder = InputForwarder()
        forwarder.detach()
        #expect(forwarder.connectObserver == nil)
        #expect(forwarder.disconnectObserver == nil)
    }

    /// Input before the stream is ready must not leave a deliver stamp.
    @Test func unreadyPadDoesNotStampInputDelivery() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        let ex = try #require(pad.extendedGamepad)
        let handler = try #require(ex.valueChangedHandler)
        _ = InputDeliverStamp.shared.take(slot: Int(slot))
        handler(ex, ex.buttonA)
        #expect(InputDeliverStamp.shared.take(slot: Int(slot)) == 0)
    }

    /// Detach clears the stream's handler from a connected pad.
    @Test func detachClearsGamepadHandler() {
        let forwarder = InputForwarder()
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let installed = pad.extendedGamepad?.valueChangedHandler != nil
        forwarder.detach()
        #expect(installed)
        #expect(pad.extendedGamepad?.valueChangedHandler == nil)
    }

    /// A stick or trigger held at Cmd-Tab must release on the PC without removing the pad.
    @Test func focusLossNeutralizesReadyPadWithoutRemovingItsSlot() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        let backend = RecordingBackend()
        forwarder.setBackend(backend)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.installFocusObservers(for: window)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(backend.calls.isEmpty)

        forwarder.isReady = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let sends = backend.calls.filter { $0.num == Int16(slot) }
        #expect(sends.count == 1)
        let sent = try #require(sends.first)
        let analog = sent.analog
        #expect(sent.buttons == 0)
        #expect([analog.leftTrigger, analog.rightTrigger] == [0, 0])
        #expect([analog.leftStickX, analog.leftStickY, analog.rightStickX, analog.rightStickY] == [0, 0, 0, 0])
        #expect(UInt16(bitPattern: sent.mask) & (UInt16(1) << slot) != 0)
    }

    /// Leaving the controller test restores background delivery policy.
    @Test func controllerMonitorRestoresBackgroundMonitoring() {
        let prior = GCController.shouldMonitorBackgroundEvents
        defer { GCController.shouldMonitorBackgroundEvents = prior }
        GCController.shouldMonitorBackgroundEvents = false
        let monitor = ControllerMonitor(isStreaming: { true })
        monitor.start()
        monitor.stop()
        #expect(GCController.shouldMonitorBackgroundEvents == false)
    }

    @Test func suspendedDrainKeepsLightsButDropsMotorUpdates() {
        var lights: [UInt8] = []
        var leds: [UInt8] = []
        var rumble: [UInt8] = []
        var triggers: [UInt8] = []
        var hidDispatches = 0
        ControllerHaptics.processDrain(.init(rumble: [0: (10, 20)], submittedAt: [0: 100],
                                             triggers: [0: (30, 40)], lights: [0: (1, 2, 3)],
                                             playerLEDs: [0: 5], gameControllerSlots: [0],
                                             suspended: true, quiesced: false),
                                       actions: .init(light: { slot, _ in lights.append(slot) },
                                                      playerLEDs: { slot, _ in leds.append(slot) },
                                                      hidRumble: { _, _ in hidDispatches += 1 },
                                                      rumble: { slot, _ in rumble.append(slot) },
                                                      triggers: { slot, _ in triggers.append(slot) }))
        #expect(lights == [0])
        #expect(leds == [0])
        #expect(rumble.isEmpty)
        #expect(triggers.isEmpty)
        #expect(hidDispatches == 0)
    }

    @Test func quiescedDrainDiscardsEveryUpdate() {
        var applied = 0
        ControllerHaptics.processDrain(.init(rumble: [0: (10, 20)], submittedAt: [0: 100],
                                             triggers: [0: (30, 40)], lights: [0: (1, 2, 3)],
                                             playerLEDs: [0: 5], gameControllerSlots: [],
                                             suspended: false, quiesced: true),
                                       actions: .init(light: { _, _ in applied += 1 },
                                                      playerLEDs: { _, _ in applied += 1 },
                                                      hidRumble: { _, _ in applied += 1 },
                                                      rumble: { _, _ in applied += 1 },
                                                      triggers: { _, _ in applied += 1 }))
        #expect(applied == 0)
    }

    @Test func drainDispatchesOnlyHIDRumbleAndItsTimestamp() {
        var dispatched: ([UInt8: ControllerHaptics.Rumble], [UInt8: UInt64])?
        var appliedRumble: [UInt8] = []
        let values: [UInt8: ControllerHaptics.Rumble] = [0: (10, 20), 1: (30, 40)]
        let times: [UInt8: UInt64] = [0: 100, 1: 200]
        ControllerHaptics.processDrain(.init(rumble: values, submittedAt: times, triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [0],
                                             suspended: false, quiesced: false),
                                       actions: .init(light: { _, _ in }, playerLEDs: { _, _ in },
                                                      hidRumble: { dispatched = ($0, $1) },
                                                      rumble: { slot, _ in appliedRumble.append(slot) },
                                                      triggers: { _, _ in }))
        #expect(dispatched?.0.count == 1)
        #expect(dispatched?.0[1]?.low == 30)
        #expect(dispatched?.1 == [1: 200])
        #expect(appliedRumble.sorted() == [0, 1])
    }

    @Test func emptyAndGameControllerOnlyDrainsSkipHIDDispatch() {
        var dispatches = 0
        let actions = ControllerHaptics.DrainActions(light: { _, _ in }, playerLEDs: { _, _ in },
                                                     hidRumble: { _, _ in dispatches += 1 },
                                                     rumble: { _, _ in }, triggers: { _, _ in })
        ControllerHaptics.processDrain(.init(rumble: [:], submittedAt: [:], triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [],
                                             suspended: false, quiesced: false), actions: actions)
        ControllerHaptics.processDrain(.init(rumble: [0: (1, 2)], submittedAt: [0: 3], triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [0],
                                             suspended: false, quiesced: false), actions: actions)
        #expect(dispatches == 0)
    }

    /// A pad GameController has no haptics for is not offered rumble.
    @Test func rumbleNeedsHaptics() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        try #require(pad.haptics == nil)
        forwarder.attach(gamepad: pad)
        let caps = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.arrival.caps)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_TRIGGER_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) != 0)
    }

    /// MISC_FLAG is advertised only when a DualSense Mute actually reaches the PC.
    @Test func muteIsAdvertisedOnlyWhenForwarded() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        let misc = UInt32(bitPattern: StreamProtocol.MISC_FLAG)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: true) & misc == misc)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: false) & misc == 0)
    }

    /// A slot is stale when its pad left or became a different pad; an unchanged pad
    /// keeps its slot, and a slot never announced has nothing to remove.
    @Test func staleSlotsAreTheGoneAndTheChanged() {
        let xbox = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_XBOX), supportedButtons: 0xFFFF, caps: 0x03)
        let dualSense = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_PS), supportedButtons: 0xFFFF, caps: 0x3F)
        let announced: [UInt8: Arrival] = [0: xbox, 1: dualSense, 2: xbox]
        let current: [UInt8: Arrival] = [0: xbox, 1: xbox, 3: dualSense]
        #expect(InputForwarder.staleControllerSlots(announced: announced, current: current) == [1, 2])
        #expect(InputForwarder.staleControllerSlots(announced: [:], current: current).isEmpty)
        #expect(InputForwarder.staleControllerSlots(announced: current, current: current).isEmpty)
    }

    /// A pad unplugged while the link was down is retired when the stream comes back.
    /// One unplugged mid-stream stays on the ledger until the next stream start, in case
    /// its removal went into a link that had already died.
    @Test func aPadThatLeftIsRetired() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.setReady(true)
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        #expect(forwarder.announcedControllers[slot] != nil)

        forwarder.setReady(false)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)

        forwarder.attach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(false)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)
    }
}
