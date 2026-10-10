import Foundation
import os
@testable import Glimmer

struct ControllerSend: Sendable {
    let num: Int16
    let mask: Int16
    let buttons: Int32
    let analog: GamepadAnalog
}

struct ControllerTouchSend: Sendable {
    let num: UInt8
    let eventType: UInt8
    let pointerId: UInt32
    let x: Float
    let y: Float
    let pressure: Float
}

struct ControllerMotionSend: Equatable, Sendable {
    let num: UInt8
    let motionType: UInt8
    let x: Float
    let y: Float
    let z: Float
}

struct KeyboardSend: Equatable, Sendable {
    let keyCode: Int16
    let action: Int8
    let modifiers: Int8
    let flags: Int8
}

struct MouseMoveSend: Equatable, Sendable {
    let dx: Int16
    let dy: Int16
}

/// Every pointer send other than relative motion, in the order they went out.
enum PointerSend: Equatable, Sendable {
    case position(x: Int16, y: Int16, refW: Int16, refH: Int16)
    case button(action: Int8, button: Int32)
    case scroll(Int16)
    case hScroll(Int16)
}

final class InputRecordingBackend: StreamingBackend {
    private let sends = OSAllocatedUnfairLock(initialState: [ControllerSend]())

    private let textSends = OSAllocatedUnfairLock(initialState: [String]())
    private let touchSends = OSAllocatedUnfairLock(initialState: [ControllerTouchSend]())
    private let motionSends = OSAllocatedUnfairLock(initialState: [ControllerMotionSend]())
    private let keyboardSends = OSAllocatedUnfairLock(initialState: [KeyboardSend]())
    private let mouseMoveSends = OSAllocatedUnfairLock(initialState: [MouseMoveSend]())
    private let pointerSends = OSAllocatedUnfairLock(initialState: [PointerSend]())

    var calls: [ControllerSend] { sends.withLock { $0 } }
    var texts: [String] { textSends.withLock { $0 } }
    var touches: [ControllerTouchSend] { touchSends.withLock { $0 } }
    var motions: [ControllerMotionSend] { motionSends.withLock { $0 } }
    var keyboard: [KeyboardSend] { keyboardSends.withLock { $0 } }
    var mouseMoves: [MouseMoveSend] { mouseMoveSends.withLock { $0 } }
    var pointer: [PointerSend] { pointerSends.withLock { $0 } }

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
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        keyboardSends.withLock { $0.append(.init(keyCode: keyCode, action: action, modifiers: modifiers, flags: flags)) }
        return 0
    }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 {
        mouseMoveSends.withLock { $0.append(.init(dx: dx, dy: dy)) }
        return 0
    }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 {
        recordPointer(.position(x: x, y: y, refW: refW, refH: refH))
    }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 { recordPointer(.button(action: action, button: button)) }
    func sendScroll(_ amount: Int16) -> Int32 { recordPointer(.scroll(amount)) }
    func sendHScroll(_ amount: Int16) -> Int32 { recordPointer(.hScroll(amount)) }
    private func recordPointer(_ send: PointerSend) -> Int32 {
        pointerSends.withLock { $0.append(send) }
        return 0
    }
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
    ) -> Int32 {
        touchSends.withLock { $0.append(.init(num: num, eventType: eventType, pointerId: pointerId,
                                            x: x, y: y, pressure: pressure)) }
        return 0
    }
    func sendControllerMotion(
        num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float
    ) -> Int32 {
        motionSends.withLock { $0.append(.init(num: num, motionType: motionType, x: x, y: y, z: z)) }
        return 0
    }
    func sendUtf8Text(_ text: String) -> Int32 {
        textSends.withLock { $0.append(text) }
        return 0
    }
}
