// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os
import Testing
@testable import GlimmerEngine

final class SoakInputBackend: StreamingBackend {
    enum Edge: Hashable {
        case key(Int16)
        case mouse(Int32)
        case controller(Int16)
    }
    struct State {
        var reject = false
        var loseAcceptedRelease = false
        var held: Set<Edge> = []
        var sends = 0
        var releases = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    private func send(_ edge: Edge, pressed: Bool) -> Int32 {
        state.withLock {
            guard !$0.reject else { return -2 }
            $0.sends += 1
            if pressed {
                $0.held.insert(edge)
            } else {
                $0.releases += 1
                if !$0.loseAcceptedRelease { $0.held.remove(edge) }
            }
            return 0
        }
    }

    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32 {
        send(.key(keyCode), pressed: action == StreamProtocol.KEY_ACTION_DOWN)
    }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 {
        send(.mouse(button), pressed: action == StreamProtocol.BUTTON_ACTION_PRESS)
    }
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        send(.controller(num), pressed: buttons != 0 || analog != InputCore.neutral)
    }
    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8,
                               supportedButtons: UInt32, caps: UInt16) -> Int32 { 0 }
    func startConnection(server: BackendServerInfo, config: BackendStreamConfig) throws {
        Issue.record("The soak must never start a network connection")
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
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 { 0 }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 { 0 }
    func sendScroll(_ amount: Int16) -> Int32 { 0 }
    func sendHScroll(_ amount: Int16) -> Int32 { 0 }
    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                             pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Int32 { 0 }
    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 { 0 }
    func sendUtf8Text(_ text: String) -> Int32 { 0 }
}
