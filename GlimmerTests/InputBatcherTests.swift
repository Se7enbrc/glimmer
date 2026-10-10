// Input ordering under a stalled reliable channel, and the one-shot flush timer.

import CryptoKit
import Foundation
import Testing
@testable import Glimmer

struct InputBatcherTests {
    private static let key = Array(0..<16).map { UInt8($0) }

    private static func makeChannel(backlogged: Bool = true) throws -> EnetControlChannel {
        let channel = EnetControlChannel(host: "127.0.0.1", port: 9, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: key))
        channel.reliableBackloggedFlag.store(backlogged, ordering: .relaxed)
        return channel
    }

    /// The InputEncoder bytes inside each sealed SEND_RELIABLE command, in wire order.
    private static func sentPayloads(_ channel: EnetControlChannel) throws -> [[UInt8]] {
        try channel.withState { channel.sentReliable.map(\.commandBytes) }.map { command in
            let envelope = Array(command.dropFirst(6))  // 0x86, channel, relSeq, dataLength
            var iv = [UInt8](repeating: 0, count: 12)
            iv[0..<4] = envelope[4..<8]
            iv[10] = 0x43; iv[11] = 0x43  // client-originated, control stream
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: envelope[24...], tag: envelope[8..<24])
            return try Array(AES.GCM.open(box, using: SymmetricKey(data: key)).dropFirst(4))
        }
    }

    private static func motion(in payloads: some Collection<[UInt8]>) -> (dx: Int, dy: Int) {
        payloads.filter { $0.count == 12 }.reduce(into: (dx: 0, dy: 0)) { sum, move in
            sum.dx += Int(Int16(bitPattern: UInt16(move[8]) << 8 | UInt16(move[9])))
            sum.dy += Int(Int16(bitPattern: UInt16(move[10]) << 8 | UInt16(move[11])))
        }
    }

    private static func waitForMotion(_ channel: EnetControlChannel, dx: Int, dy: Int) async throws -> Bool {
        for _ in 0..<500 {
            let moved = try motion(in: sentPayloads(channel))
            if moved.dx == dx, moved.dy == dy { return true }
            try await Task.sleep(for: .milliseconds(4))
        }
        return false
    }

    @Test func clickFollowsPendingPositionDuringBackpressure() throws {
        let channel = try Self.makeChannel()
        let batcher = InputBatcher(enet: channel)
        _ = batcher.setAbsMouse(x: 100, y: 100, refW: 1920, refH: 1080)
        _ = batcher.passThrough(
            InputEncoder.mouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1),
            channel: Enet.ctrlChannelMouse)
        batcher.stop()

        let lengths = channel.withState { channel.sentReliable.map(\.commandBytes.count) }
        try #require(lengths.count == 2)
        // The position (18 bytes) seals longer than the button (9), so this is wire order.
        #expect(lengths[0] > lengths[1])
    }

    @Test func relativeMotionFollowsPendingPositionDuringBackpressure() throws {
        let channel = try Self.makeChannel()
        let batcher = InputBatcher(enet: channel)
        _ = batcher.setAbsMouse(x: 100, y: 100, refW: 1920, refH: 1080)
        _ = batcher.accumulateMouseMove(dx: 5, dy: 0)
        batcher.stop()

        #expect(channel.withState { channel.sentReliable.count } == 1)
    }

    @Test func absolutePositionFollowsPendingMotionDuringBackpressure() throws {
        let channel = try Self.makeChannel()
        let batcher = InputBatcher(enet: channel)
        _ = batcher.accumulateMouseMove(dx: 5, dy: 0)
        _ = batcher.setAbsMouse(x: 100, y: 100, refW: 1920, refH: 1080)
        batcher.stop()

        #expect(channel.withState { channel.sentReliable.count } == 1)
    }

    @Test func timerSendsEveryMoveAndRearmsAfterIdle() async throws {
        let channel = try Self.makeChannel(backlogged: false)
        let batcher = InputBatcher(enet: channel)
        defer { batcher.stop() }
        for _ in 0..<50 { _ = batcher.accumulateMouseMove(dx: 3, dy: -1) }
        #expect(try await Self.waitForMotion(channel, dx: 150, dy: -50))

        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<10 { _ = batcher.accumulateMouseMove(dx: 3, dy: -1) }
        #expect(try await Self.waitForMotion(channel, dx: 180, dy: -60))
    }

    private static func waitForPayload(_ channel: EnetControlChannel, _ expected: [UInt8]) async throws -> Bool {
        for _ in 0..<500 {
            if try sentPayloads(channel).contains(expected) { return true }
            try await Task.sleep(for: .milliseconds(4))
        }
        return false
    }

    /// A pad's held stick reaches the wire on the timer, and a press after it carries the same axes.
    @Test func controllerStateReachesTheWire() async throws {
        let channel = try Self.makeChannel(backlogged: false)
        let batcher = InputBatcher(enet: channel)
        defer { batcher.stop() }
        let held = GamepadAnalog(leftTrigger: 0, rightTrigger: 40, leftStickX: 12_000, leftStickY: -3_000,
                                 rightStickX: 0, rightStickY: 0)
        _ = batcher.updateController(num: 0, mask: 1, buttons: 0, analog: held)
        #expect(try await Self.waitForPayload(
            channel, InputEncoder.multiController(num: 0, mask: 1, buttons: 0, analog: held)))
        try await Task.sleep(for: .milliseconds(20))
        _ = batcher.updateController(num: 0, mask: 1, buttons: 0x1000, analog: held)
        #expect(try await Self.waitForPayload(
            channel, InputEncoder.multiController(num: 0, mask: 1, buttons: 0x1000, analog: held)))
    }

    @Test func clickFollowsEveryEarlierMove() throws {
        let channel = try Self.makeChannel(backlogged: false)
        let batcher = InputBatcher(enet: channel)
        for _ in 0..<40 { _ = batcher.accumulateMouseMove(dx: 2, dy: 1) }
        _ = batcher.passThrough(
            InputEncoder.mouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1),
            channel: Enet.ctrlChannelMouse)
        batcher.stop()

        let payloads = try Self.sentPayloads(channel)
        try #require(payloads.last?.count == 9)
        let moved = Self.motion(in: payloads.dropLast())
        #expect(moved.dx == 80 && moved.dy == 40)
    }

    // MARK: Merge decisions, drained by an edge under backpressure

    private static let click = InputEncoder.mouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1)

    /// Merged state left behind by `fill`, then the edge that drained it.
    private static func drained(_ fill: (InputBatcher) -> Void) throws -> [[UInt8]] {
        let channel = try makeChannel()
        let batcher = InputBatcher(enet: channel)
        fill(batcher)
        _ = batcher.passThrough(click, channel: Enet.ctrlChannelMouse)
        batcher.stop()
        return try sentPayloads(channel)
    }

    @Test func mergedMotionSplitsIntoWireSizedChunks() throws {
        let right = try Self.drained { batcher in
            for _ in 0..<3 { _ = batcher.accumulateMouseMove(dx: 20_000, dy: -20_000) }
        }
        #expect(right == [InputEncoder.mouseMove(dx: 32_767, dy: -32_768),
                          InputEncoder.mouseMove(dx: 27_233, dy: -27_232), Self.click])
        let left = try Self.drained { batcher in
            for _ in 0..<3 { _ = batcher.accumulateMouseMove(dx: -20_000, dy: 20_000) }
        }
        #expect(left == [InputEncoder.mouseMove(dx: -32_768, dy: 32_767),
                         InputEncoder.mouseMove(dx: -27_232, dy: 27_233), Self.click])
    }

    @Test func absolutePositionIsLatestOnly() throws {
        let payloads = try Self.drained { batcher in
            _ = batcher.setAbsMouse(x: 1, y: 1, refW: 1920, refH: 1080)
            _ = batcher.setAbsMouse(x: 900, y: 500, refW: 1920, refH: 1080)
        }
        #expect(payloads == [InputEncoder.mousePosition(x: 900, y: 500, refW: 1920, refH: 1080), Self.click])
    }

    /// A button change ends the batch so the press carries the axes it was made with.
    @Test func buttonChangeSendsThePendingAxesFirst() throws {
        func pad(_ x: Int16) -> GamepadAnalog {
            GamepadAnalog(leftTrigger: 0, rightTrigger: 0, leftStickX: x, leftStickY: 0,
                          rightStickX: 0, rightStickY: 0)
        }
        let payloads = try Self.drained { batcher in
            _ = batcher.updateController(num: 1, mask: 3, buttons: 0, analog: pad(100))
            _ = batcher.updateController(num: 1, mask: 3, buttons: 0, analog: pad(200))
            _ = batcher.updateController(num: 1, mask: 3, buttons: 0x1000, analog: pad(300))
        }
        #expect(payloads == [
            InputEncoder.multiController(num: 1, mask: 3, buttons: 0, analog: pad(200)),
            InputEncoder.multiController(num: 1, mask: 3, buttons: 0x1000, analog: pad(300)),
            Self.click
        ])
    }

    /// Sensor samples ride unreliable, except the gyro null that stops sensors.
    @Test func onlyTheGyroNullRidesReliable() throws {
        let channel = try Self.makeChannel()
        let batcher = InputBatcher(enet: channel)
        let gyro = UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO)
        let accel = UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL)
        #expect(batcher.updateMotion(num: 0, motionType: 3, x: 1, y: 1, z: 1) == InputBatcherResult.sendFailed)
        _ = batcher.updateMotion(num: 0, motionType: accel, x: 1, y: 2, z: 3)
        _ = batcher.updateMotion(num: 0, motionType: gyro, x: 4, y: 4, z: 4)
        _ = batcher.updateMotion(num: 0, motionType: gyro, x: 0, y: 0, z: 0)
        _ = batcher.passThrough(Self.click, channel: Enet.ctrlChannelMouse)
        batcher.stop()

        #expect(try Self.sentPayloads(channel) == [
            InputEncoder.controllerMotion(num: 0, motionType: gyro, x: 0, y: 0, z: 0), Self.click
        ])
        // Every seal takes a nonce; the one not in sentReliable went unreliable.
        #expect(channel.withState { channel.enetSeq } == 3)
    }

    @Test func pairsAndReportsKeepTheirOrderBehindMergedMotion() throws {
        let channel = try Self.makeChannel()
        let batcher = InputBatcher(enet: channel)
        let report = InputEncoder.scroll(120)
        _ = batcher.accumulateMouseMove(dx: 5, dy: 0)
        _ = batcher.passThroughReport(report, channel: Enet.ctrlChannelMouse)
        _ = batcher.passThroughPair(Self.click, report, channel: Enet.ctrlChannelMouse)
        batcher.stop()

        #expect(try Self.sentPayloads(channel) == [InputEncoder.mouseMove(dx: 5, dy: 0), report, Self.click, report])
    }

    @Test func aStoppedBatcherRefusesEverything() throws {
        let channel = try Self.makeChannel(backlogged: false)
        let batcher = InputBatcher(enet: channel)
        batcher.stop()
        let analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
                                   rightStickX: 0, rightStickY: 0)
        let results = [
            batcher.accumulateMouseMove(dx: 1, dy: 1),
            batcher.setAbsMouse(x: 1, y: 1, refW: 2, refH: 2),
            batcher.updateController(num: 0, mask: 1, buttons: 0, analog: analog),
            batcher.updateMotion(num: 0, motionType: 1, x: 0, y: 0, z: 0),
            batcher.passThrough(Self.click, channel: 0),
            batcher.passThroughReport(Self.click, channel: 0),
            batcher.passThroughPair(Self.click, Self.click, channel: 0)
        ]
        #expect(results.allSatisfy { $0 == InputBatcherResult.notReady })
        #expect(channel.withState { channel.sentReliable.isEmpty })
    }

    @Test func motionTraceIsCappedButNeverDropsTheGyroNull() {
        let interval = InputBatcher.motionTraceIntervalNanos
        #expect(InputBatcher.motionTraceDue(lastNanos: 0, nowNanos: interval, isGyroNull: false))
        #expect(!InputBatcher.motionTraceDue(lastNanos: 1, nowNanos: interval, isGyroNull: false))
        #expect(InputBatcher.motionTraceDue(lastNanos: 1, nowNanos: interval, isGyroNull: true))
    }
}
