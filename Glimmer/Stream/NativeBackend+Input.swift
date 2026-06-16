//
//  NativeBackend+Input.swift
//
//  Telemetry/control accessors (RTT, IDR, HDR metadata, stage names) and the
//  client→host input uplink: each send* builds the plaintext NV_INPUT_HEADER+body
//  with InputEncoder and routes it through the InputBatcher onto the encrypted
//  control stream. Split out of NativeBackend.swift to keep each unit focused;
//  see that file for the backend's stored state.
//

import Foundation

extension NativeBackend {
    // MARK: - Telemetry / control (no native A/V receive yet)

    public func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? {
        withState { enetChannel }?.estimatedRtt()
    }

    public func enetHealth() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)? {
        withState { enetChannel }?.health()
    }

    public func requestIdrFrame() {
        withState { enetChannel }?.requestIdrFrame()
    }

    public func hdrMetadata() -> HdrMetadata? { withState { enetChannel }?.hdrMetadata() }

    public func launchUrlQueryParameters() -> String { "" }

    public func stageName(for stage: Int32) -> String {
        StreamStageNames.name(for: stage)
    }

    // MARK: - Input uplink (InputEncoder → EnetControlChannel.sendInputPacket)
    //
    // Each method builds the plaintext NV_INPUT_HEADER+body with InputEncoder
    // (pure bytes) and seals/sends it over the encrypted control stream on the
    // input class's channel (keyboard 0x02, mouse/scroll/hscroll 0x03, gamepad
    // 0x10 + num%16). Return contract matches LiSend*: -2 when the input stream
    // isn't ready (mirrors InputStream.c's `initialized` guard), 0 on a queued
    // send, -1 on a seal/send failure. InputForwarder.record() tolerates -2.

    static let inputNotReady: Int32 = -2

    /// Resolve the input batcher iff input is ready. Returns nil → caller -2.
    /// All high-rate and pass-through input flows through the batcher so the
    /// reliable input RATE stays bounded (one merged packet per ~1ms tick).
    func readyBatcher() -> InputBatcher? {
        withState { inputReady ? inputBatcher : nil }
    }

    /// Build → seal → send one input packet on `channel`; map to the Li* return.
    /// Routes through the batcher's pass-through (flush-pending-then-send) so
    /// low-rate edge events stay ordered relative to the merged mouse/controller
    /// stream. Falls back to -2 when input isn't ready.
    func dispatchInput(_ plaintext: [UInt8], channel: UInt8) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.passThrough(plaintext, channel: channel)
    }

    public func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        dispatchInput(
            InputEncoder.keyboard(keyCode: keyCode, action: action,
                                  modifiers: modifiers, flags: flags),
            channel: Enet.ctrlChannelKeyboard)
    }

    public func sendMouseMove(dx: Int16, dy: Int16) -> Int32 {
        // Merged: ACCUMULATE into the running delta; the batcher's 1ms tick sends
        // the total (splitting into Int16 chunks). NOT one packet per move event.
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.accumulateMouseMove(dx: dx, dy: dy)
    }

    public func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 {
        // Merged: latest-only per tick.
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.setAbsMouse(x: x, y: y, refW: refW, refH: refH)
    }

    public func sendMouseButton(action: Int8, button: Int32) -> Int32 {
        dispatchInput(
            InputEncoder.mouseButton(action: action, button: UInt8(truncatingIfNeeded: button)),
            channel: Enet.ctrlChannelMouse)
    }

    public func sendScroll(_ amount: Int16) -> Int32 {
        dispatchInput(InputEncoder.scroll(amount), channel: Enet.ctrlChannelMouse)
    }

    public func sendHScroll(_ amount: Int16) -> Int32 {
        // hscroll rides the mouse channel (CTRL_CHANNEL_MOUSE, InputStream.c).
        // Sunshine-only on the wire, but the !IS_SUNSHINE → LI_ERR_UNSUPPORTED
        // guard is moot here (we only ever target Sunshine).
        dispatchInput(InputEncoder.hscroll(amount), channel: Enet.ctrlChannelMouse)
    }

    public func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        // Merged: latest state per gamepad slot; a buttonFlags change flushes the
        // slot first so the host gets exact axes at the press edge.
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.updateController(num: num, mask: mask, buttons: buttons, analog: analog)
    }

    public func sendControllerArrival(
        num: UInt8, mask: UInt16, type: UInt8,
        supportedButtons: UInt32, caps: UInt16
    ) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        let channel = gamepadChannel(Int(num))
        // Pass-through pair (flush pending merged state, then send both in order):
        // the Sunshine-only arrival packet + the mandatory fallback
        // multiController(num, mask, 0, …) for hosts that don't support arrival
        // events (InputStream.c:1471).
        return batcher.passThroughPair(
            InputEncoder.controllerArrival(num: num, mask: mask, type: type,
                                           supportedButtons: supportedButtons, caps: caps),
            InputEncoder.multiController(
                num: Int16(num), mask: Int16(bitPattern: mask), buttons: 0,
                analog: GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                      leftStickX: 0, leftStickY: 0,
                                      rightStickX: 0, rightStickY: 0)),
            channel: channel)
    }

    public func sendControllerTouch(
        num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
        pointerId: UInt32, x: Float, y: Float, pressure: Float
    ) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        // Protocol extension only supported by Sunshine when the feature flag is
        // set (InputStream.c:1481) — else LI_ERR_UNSUPPORTED.
        guard withState({ featureFlags }) & Self.ffControllerTouchEvents != 0 else {
            return StreamProtocol.LI_ERR_UNSUPPORTED
        }
        return batcher.passThrough(
            InputEncoder.controllerTouch(num: num, eventType: eventType,
                                         touchpadIndex: touchpadIndex, pointerId: pointerId,
                                         x: x, y: y, pressure: pressure),
            channel: gamepadChannel(Int(num)))
    }

    /// CTRL_CHANNEL_GAMEPAD_BASE + (controllerNumber % MAX_GAMEPADS).
    func gamepadChannel(_ num: Int) -> UInt8 {
        Enet.ctrlChannelGamepadBase &+ UInt8(num % Enet.maxGamepads)
    }
}
