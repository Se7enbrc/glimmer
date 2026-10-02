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
        channel.reliableBackloggedFlag = backlogged
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
}
