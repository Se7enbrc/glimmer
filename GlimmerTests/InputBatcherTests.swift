// Input ordering under a stalled reliable channel.

import Foundation
import Testing
@testable import Glimmer

struct InputBatcherTests {
    private static func makeChannel() throws -> EnetControlChannel {
        let key = Array(0..<16).map { UInt8($0) }
        let channel = EnetControlChannel(host: "127.0.0.1", port: 9, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: key))
        channel.reliableBackloggedFlag = true
        return channel
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
}
