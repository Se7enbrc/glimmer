// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
@testable import GlimmerEngine
import Foundation
import os

final class JourneyReceipts: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [[String: Double]]())
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func record(_ event: [String: Double]) {
        events.withLock { events in
            var timed = event
            timed["receivedAt"] = ProcessInfo.processInfo.systemUptime
            events.append(timed)
            do {
                let data = try JSONSerialization.data(withJSONObject: events)
                try data.write(to: directory.appendingPathComponent("receipts.json"), options: .atomic)
            } catch { preconditionFailure("Could not write isolated journey receipts") }
        }
    }
}

// Receipts are captured after the real input core, at the PC transport boundary. No audio sink is started.
final class JourneyBackend: StreamingBackend {
    let receipts: JourneyReceipts
    private let connected: @Sendable () async -> Void
    init(receipts: JourneyReceipts, connected: @escaping @Sendable () async -> Void = {}) {
        self.receipts = receipts
        self.connected = connected
    }
    func startConnectionAsync(server: BackendServerInfo, config: BackendStreamConfig) async throws {
        await connected()
    }
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
        0
    }
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32 {
        receipts.record(["pcDX": Double(dx), "pcDY": Double(dy)])
        return 0
    }
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 {
        receipts.record(["pcX": Double(x), "pcY": Double(y)])
        return 0
    }
    func sendMouseButton(action: Int8, button: Int32) -> Int32 {
        receipts.record(["pcMouseButton": Double(button), "action": Double(action)])
        return 0
    }
    func sendScroll(_ amount: Int16) -> Int32 {
        receipts.record(["pcScroll": Double(amount)])
        return 0
    }
    func sendHScroll(_ amount: Int16) -> Int32 {
        receipts.record(["pcHScroll": Double(amount)])
        return 0
    }
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32 {
        receipts.record(["pcButtons": Double(buttons), "slot": Double(num), "mask": Double(mask),
            "lt": Double(analog.leftTrigger), "rt": Double(analog.rightTrigger),
            "lx": Double(analog.leftStickX), "ly": Double(analog.leftStickY),
            "rx": Double(analog.rightStickX), "ry": Double(analog.rightStickY)])
        return 0
    }
    func sendControllerArrival(num: UInt8, mask: UInt16, type: UInt8,
                               supportedButtons: UInt32, caps: UInt16) -> Int32 {
        receipts.record(["pcArrival": Double(type), "slot": Double(num), "mask": Double(mask)])
        return 0
    }
    func sendControllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                             pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Int32 { 0 }
    func sendControllerMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 { 0 }
    func sendUtf8Text(_ text: String) -> Int32 { 0 }
}
#endif
