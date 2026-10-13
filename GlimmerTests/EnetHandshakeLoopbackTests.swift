// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  EnetHandshakeLoopbackTests.swift
//
//  The ENet control channel against a loopback peer: CONNECT to START_B over a real socket,
//  a forged VERIFY_CONNECT refused, and NativeBackend's input landing on its per-class channels.
//

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

struct EnetHandshakeLoopbackTests {

    private static func channel(to peer: EnetLoopbackPeer, connectData: UInt32 = 0) throws -> EnetControlChannel {
        EnetControlChannel(host: "127.0.0.1", port: peer.udp.port, controlConnectData: connectData,
                           crypto: try ControlCrypto(rikey: EnetFixture.key))
    }

    /// Runs the handshake, returning the stages that completed and the one that failed.
    private static func handshake(_ channel: EnetControlChannel) async -> (done: [String], failed: [String: Int32],
                                                                          error: Error?) {
        var done: [String] = []
        var failed: [String: Int32] = [:]
        do {
            try await channel.establishAndStart(stage: { _ in }, stageDone: { done.append($0) },
                                                stageFailed: { failed[$0] = $1 })
            return (done, failed, nil)
        } catch {
            return (done, failed, error)
        }
    }

    /// Waits for `count` reliables, then opens each to its control type and payload.
    private static func controlMessages(from peer: EnetLoopbackPeer, count: Int) async throws
        -> [(channel: UInt8, type: UInt16, payload: [UInt8])] {
        for _ in 0..<count {
            try #require(await peer.reliableArrived.waitAsync(for: .seconds(5)) == .success)
        }
        return try peer.reliables.map { reliable in
            let inner = try EnetFixture.openClient(reliable.data)
            return (reliable.channel, UInt16(inner[0]) | UInt16(inner[1]) << 8, Array(inner.dropFirst(4)))
        }
    }

    @Test func handshakeReachesStartBAndAdoptsThePeersIdentity() async throws {
        let peer = try #require(EnetLoopbackPeer())
        defer { peer.stop() }
        let channel = try Self.channel(to: peer, connectData: 0xC0FF_EE01)
        defer { channel.close() }

        let result = await Self.handshake(channel)
        #expect(result.error == nil)
        #expect(result.done == ["ENET_CONNECT", "START_A", "START_B"])
        #expect(result.failed.isEmpty)
        #expect(peer.connectData == 0xC0FF_EE01)
        #expect(channel.withState { channel.outgoingPeerID } == EnetLoopbackPeer.assignedPeerID)
        #expect(channel.withState { channel.sentReliable.isEmpty })
        #expect(channel.estimatedRtt() != nil)

        let starts = try await Self.controlMessages(from: peer, count: 2)
        #expect(starts.map(\.channel) == [Enet.ctrlChannelGeneric, Enet.ctrlChannelGeneric])
        #expect(starts.map(\.type) == [0x0302, 0x0307])
        #expect(starts.map(\.payload) == [[0, 0], [0]])
    }

    @Test func forgedVerifyConnectFailsTheConnectStage() async throws {
        let peer = try #require(EnetLoopbackPeer(forgesConnectID: true))
        defer { peer.stop() }
        let channel = try Self.channel(to: peer)
        defer { channel.close() }

        let result = await Self.handshake(channel)
        guard case .disconnected = result.error as? EnetError else {
            Issue.record("expected a disconnected handshake, got \(String(describing: result.error))")
            return
        }
        #expect(result.done.isEmpty)
        #expect(result.failed == ["ENET_CONNECT": -103])
        #expect(peer.reliables.isEmpty)
    }

    @Test func backendInputRidesItsChannelsOnceControlIsUp() async throws {
        let peer = try #require(EnetLoopbackPeer())
        defer { peer.stop() }
        let channel = try Self.channel(to: peer)
        #expect(await Self.handshake(channel).error == nil)
        _ = try await Self.controlMessages(from: peer, count: 2)

        let backend = NativeBackend()
        let keyDown = Int8(StreamProtocol.KEY_ACTION_DOWN), press = Int8(StreamProtocol.BUTTON_ACTION_PRESS)
        #expect(backend.sendKeyboard(keyCode: 0x41, action: keyDown, modifiers: 0, flags: 0)
            == NativeBackend.inputNotReady)
        backend.withState {
            backend.enetChannel = channel
            backend.inputBatcher = InputBatcher(enet: channel)
            backend.inputReady = true
        }
        defer { backend.stopConnection() }

        #expect(backend.sendKeyboard(keyCode: 0x41, action: keyDown, modifiers: 0, flags: 0) == 0)
        #expect(backend.sendMouseButton(action: press, button: StreamProtocol.BUTTON_LEFT) == 0)
        #expect(backend.sendUtf8Text("hi") == 0)
        #expect(backend.sendControllerTouch(num: 0, eventType: 1, touchpadIndex: 0, pointerId: 0,
                                            x: 0, y: 0, pressure: 1) == StreamProtocol.LI_ERR_UNSUPPORTED)

        let input = try await Self.controlMessages(from: peer, count: 3).dropFirst(2)
        #expect(input.map(\.channel) == [Enet.ctrlChannelKeyboard, Enet.ctrlChannelMouse, Enet.ctrlChannelUtf8])
        #expect(input.allSatisfy { $0.type == CtrlV2.inputData })
        let sent = [InputEncoder.keyboard(keyCode: 0x41, action: keyDown, modifiers: 0, flags: 0),
                    InputEncoder.mouseButton(action: press, button: UInt8(StreamProtocol.BUTTON_LEFT))]
        #expect(input.map(\.payload) == sent + InputEncoder.utf8TextPackets("hi"))
        #expect(backend.estimatedRtt() != nil)
    }
}
