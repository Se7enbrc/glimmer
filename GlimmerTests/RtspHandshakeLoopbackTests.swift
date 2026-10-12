// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  RtspHandshakeLoopbackTests.swift
//
//  RtspClient's seven-message handshake against a scripted Sunshine RTSP peer on loopback: one
//  connection per message, replies delimited by close, and the ports, session and codec it settles.
//

import GlimmerEngine
import Foundation
import Network
import os
import Testing
@testable import Glimmer

/// A loopback RTSP peer that answers each request from `reply` and closes, as Sunshine does.
private final class RtspPeer: Sendable {
    typealias Reply = @Sendable (_ command: String, _ target: String, _ cseq: String) -> String

    let listener: NWListener
    private let queue = DispatchQueue(label: "RtspHandshakeLoopbackTests.peer")
    private let received = OSAllocatedUnfairLock<[RtspMessage]>(initialState: [])
    private let reply: Reply

    init(reply: @escaping Reply) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.reply = reply
    }

    var requests: [RtspMessage] { received.withLock { $0 } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: queue)
            read(conn, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let request = Self.complete(buffer) {
                received.withLock { $0.append(request) }
                let answer = reply(request.command ?? "", request.target ?? "", request.headerValue("CSeq") ?? "")
                conn.send(content: Data(answer.utf8), isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                read(conn, buffer: buffer)
            }
        }
    }

    /// The request once its headers and any Content-length payload have arrived.
    private static func complete(_ buffer: Data) -> RtspMessage? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(bytes: buffer[..<end.lowerBound], encoding: .utf8),
              var message = RtspMessage.parseResponse(buffer) else { return nil }
        let length = message.headerValue("Content-length").flatMap(Int.init) ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        // parseResponse reads a status line; a request's first line is "<command> <target> RTSP/1.0".
        let parts = head.prefix { $0 != "\r" }.split(separator: " ").map(String.init)
        message.command = parts.first
        message.target = parts.count > 1 ? parts[1] : nil
        if length == 0 { message.payload = nil }
        return message
    }
}

struct RtspHandshakeLoopbackTests {

    private static let sdp = """
        v=0\r\na=sprop-parameter-sets=AAAAAU\r\na=x-nv-video[0].refPicInvalidation:1\r\n\
        a=x-ss-general.encryptionSupported:5\r\na=x-ss-general.featureFlags:3\r\n
        """

    /// Sunshine's replies for a full handshake; `failing` answers that command with 454 instead.
    private static func sunshine(failing: String? = nil, session: String? = "DEADBEEF;timeout = 90") -> RtspPeer.Reply {
        { command, target, cseq in
            var headers = ["CSeq: \(cseq)"]
            var body = ""
            switch (command, target) {
            case ("DESCRIBE", _):
                body = sdp
                headers.append("Content-Length: \(body.utf8.count)")
            case ("SETUP", "streamid=audio/0/0"):
                headers += ["Transport: server_port=48100", "X-SS-Ping-Payload: AUDIOPING0123456"]
                if let session { headers.append("Session: \(session)") }
            case ("SETUP", "streamid=video/0/0"):
                headers += ["Transport: server_port=48098", "X-SS-Ping-Payload: VIDEOPING0123456"]
            case ("SETUP", _):
                headers += ["Transport: server_port=48099", "X-SS-Connect-Data: 0x1234abcd"]
            default:
                break
            }
            let status = "\(command) \(target)".hasPrefix(failing ?? "\u{0}") ? "454 Session Not Found" : "200 OK"
            return "RTSP/1.0 \(status)\r\n" + headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        }
    }

    private static func client(port: UInt16) -> RtspClient {
        let key = [UInt8](repeating: 7, count: 16)
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20_000, packetSize: 1392, streamingRemotely: 0,
            audioConfiguration: 0, supportedVideoFormats: StreamProtocol.VIDEO_FORMAT_H264 | StreamProtocol.VIDEO_FORMAT_H265,
            clientRefreshRateX100: 6000, colorSpace: 0, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: key, remoteInputAesIv: key)
        return RtspClient(host: "127.0.0.1", rtspPort: port, rtspTargetUrl: "rtsp://127.0.0.1:\(port)",
                          urlAddr: "127.0.0.1", urlSafeAddr: "127.0.0.1", addrFamilyToken: "IPv4",
                          config: config, serverCodecModeRaw: 0)
    }

    @Test func theHandshakeSettlesPortsSessionCodecAndEncryption() async throws {
        let peer = try RtspPeer(reply: Self.sunshine())
        let port = try await peer.start()
        defer { peer.listener.cancel() }
        let rtsp = Self.client(port: port)
        let audioNegotiatedAfter = OSAllocatedUnfairLock<Int?>(initialState: nil)
        rtsp.onAudioPortNegotiated = { audioPort, ping, encrypted, _ in
            #expect(audioPort == 48100 && ping == Array("AUDIOPING0123456".utf8) && encrypted)
            audioNegotiatedAfter.withLock { $0 = peer.requests.count }
        }

        let result = try await rtsp.performHandshake()

        #expect((result.audioPort, result.videoPort, result.controlPort) == (48100, 48098, 48099))
        #expect(result.controlConnectData == 0x1234_ABCD && result.sessionId == "DEADBEEF")
        #expect(result.negotiatedVideoFormat == StreamProtocol.VIDEO_FORMAT_H265)
        #expect(result.encryptionFeaturesSupported == 5 && result.encryptionFeaturesEnabled == 5 && result.audioEncryption)
        #expect(result.referenceFrameInvalidationSupported && result.featureFlags == 3)
        #expect(result.videoPingPayload == Array("VIDEOPING0123456".utf8))
        let requests = peer.requests
        #expect(requests.map { "\($0.command ?? "") \($0.target ?? "")" } == [
            "OPTIONS rtsp://127.0.0.1:\(port)", "DESCRIBE rtsp://127.0.0.1:\(port)", "SETUP streamid=audio/0/0",
            "SETUP streamid=video/0/0", "SETUP \(RtspClient.controlStreamId)",
            "ANNOUNCE \(RtspClient.controlStreamId)", "PLAY /"
        ])
        #expect(requests.map { $0.headerValue("CSeq") } == (1...7).map { "\($0)" })
        #expect(requests.map { $0.headerValue("Session") } == [nil, nil, nil] + Array(repeating: "DEADBEEF", count: 4))
        #expect(audioNegotiatedAfter.withLock { $0 } == 3)
        let announce = try #require(requests.first { $0.command == "ANNOUNCE" }?.payload)
        #expect(String(bytes: announce, encoding: .utf8)?.contains("x-nv-video[0].clientViewportWd:1920") == true)
    }

    @Test func aRefusedStepNamesItselfAndStopsTheHandshake() async throws {
        let peer = try RtspPeer(reply: Self.sunshine(failing: "SETUP streamid=control"))
        let port = try await peer.start()
        defer { peer.listener.cancel() }
        do {
            _ = try await Self.client(port: port).performHandshake()
            Issue.record("a refused SETUP control was accepted")
        } catch RtspError.nonOK(let step, let code) {
            #expect(step == "SETUP control" && code == 454)
        }
        #expect(peer.requests.count == 5)
    }

    @Test func aSetupWithoutASessionIsABadResponse() async throws {
        let peer = try RtspPeer(reply: Self.sunshine(session: nil))
        let port = try await peer.start()
        defer { peer.listener.cancel() }
        do {
            _ = try await Self.client(port: port).performHandshake()
            Issue.record("a SETUP audio without Session was accepted")
        } catch RtspError.badResponse(let reason) {
            #expect(reason.contains("missing Session"))
        }
        #expect(peer.requests.count == 3)
    }
}
