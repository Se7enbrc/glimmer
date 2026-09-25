//
//  RtspClientTests.swift
//
//  The RTSP client's connect/cancel contract and response cap (against real loopback sockets),
//  its sealed RTSP framing and the encryption it negotiates, and the audio decrypt that
//  negotiation turns on, each checked against the PC's side of the cipher.
//

import CommonCrypto
import CryptoKit
import Foundation
import Network
import os
import Testing
@testable import Glimmer

struct RtspClientTests {

    private static let key: [UInt8] = Array(0..<16).map { UInt8($0) }

    private static func makeClient(port: UInt16) -> RtspClient {
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20_000, packetSize: 1392,
            streamingRemotely: 0, audioConfiguration: 0, supportedVideoFormats: 0,
            clientRefreshRateX100: 6000, colorSpace: 0, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: key, remoteInputAesIv: key)
        return RtspClient(
            host: "127.0.0.1", rtspPort: port, rtspTargetUrl: "rtsp://127.0.0.1:\(port)",
            urlAddr: "127.0.0.1", urlSafeAddr: "127.0.0.1", addrFamilyToken: "IPv4",
            config: config, serverCodecModeRaw: 0)
    }

    /// Every request names RTSP client version 14, moonlight's for the app version 7 Sunshine reports.
    @Test func requestsCarryClientVersion14() {
        let request = Self.makeClient(port: 9).makeRequest("OPTIONS", "rtsp://127.0.0.1:48010")
        #expect(request.headerValue("X-GS-ClientVersion") == "14")
    }

    /// Sunshine's 16-char X-SS-Ping-Payload goes out verbatim, followed by a big-endian sequence number.
    @Test func pingCarriesTheSetupPayloadAndSequence() {
        var setup = RtspMessage()
        setup.headers.append(("X-SS-Ping-Payload", "0123456789ABCDEF"))
        let payload = Self.makeClient(port: 9).parsePingPayload(setup)
        #expect(payload == Array("0123456789ABCDEF".utf8))
        #expect(UdpPinger.datagram(payload: payload, sequence: 0x0102_0304) == payload + [1, 2, 3, 4])
    }

    // MARK: - Cancel never strands the connect

    @Test func cancelledConnectEndsTheWaitAsInterrupted() {
        guard case .failure(.interrupted) = RtspClient.connectVerdict(.cancelled) else {
            Issue.record("a cancelled connect must end the wait with .interrupted")
            return
        }
        #expect(RtspClient.connectVerdict(.setup) == nil)
        #expect(RtspClient.connectVerdict(.preparing) == nil)
    }

    @Test func interruptBeforeConnectThrowsInterrupted() async {
        let rtsp = Self.makeClient(port: 9)
        rtsp.interrupt()
        do {
            _ = try await rtsp.oneShot(Data("OPTIONS".utf8))
            Issue.record("oneShot succeeded after interrupt()")
        } catch RtspError.interrupted {
        } catch {
            Issue.record("expected RtspError.interrupted, got \(error)")
        }
    }

    /// Keeps the loopback server's accepted connections alive for the test.
    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var conns: [NWConnection] = []
        func keep(_ conn: NWConnection) { lock.lock(); conns.append(conn); lock.unlock() }
        func cancelAll() { lock.lock(); conns.forEach { $0.cancel() }; lock.unlock() }
    }

    @Test func oversizedResponseIsRefused() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Accepted()
        let queue = DispatchQueue(label: "RtspClientTests.listener")
        let blob = Data(repeating: 0x41, count: RtspClient.maxResponseBytes + 64 * 1024)
        listener.newConnectionHandler = { conn in
            accepted.keep(conn)
            conn.start(queue: queue)
            conn.send(content: blob, isComplete: true, completion: .contentProcessed { _ in })
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
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
        defer { accepted.cancelAll(); listener.cancel() }

        do {
            _ = try await Self.makeClient(port: port).oneShot(Data("OPTIONS".utf8))
            Issue.record("a response past the cap was accepted")
        } catch RtspError.responseTooLarge {
        } catch {
            Issue.record("expected RtspError.responseTooLarge, got \(error)")
        }
    }

    // MARK: - Encrypted RTSP (rtspenc://)

    @Test func launchAsksTheHostForEncryptedRtsp() {
        let config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        let query = NetworkClient.launchQuery(config: config, riKeyHex: "00", riKeyID: 0, appID: 1)
        #expect(query["corever"] == "1")
        #expect(query["sops"] == "1")
    }

    /// Sunshine's RTSP IV: the message seq little-endian, then the originator and 'R'.
    private static func rtspNonce(seq: UInt32, originator: Character) throws -> AES.GCM.Nonce {
        var iv = withUnsafeBytes(of: seq.littleEndian, Array.init) + [UInt8](repeating: 0, count: 8)
        iv[10] = originator.asciiValue ?? 0
        iv[11] = 0x52
        return try AES.GCM.Nonce(data: iv)
    }

    @Test func sealedRequestOpensWithTheHostsFraming() throws {
        let rtsp = Self.makeClient(port: 9)
        let request = Data("OPTIONS rtspenc://10.0.0.5:48010 RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8)
        let first = [UInt8](try rtsp.sealRtsp(request))
        let second = [UInt8](try rtsp.sealRtsp(request))
        #expect(RtspClient.beUInt32(first, 0) == 0x8000_0000 | UInt32(request.count))
        #expect(RtspClient.beUInt32(first, 4) == 1)
        #expect(RtspClient.beUInt32(second, 4) == 2)
        let box = try AES.GCM.SealedBox(
            nonce: Self.rtspNonce(seq: 1, originator: "C"),
            ciphertext: first[24...], tag: first[8..<24])
        #expect(try AES.GCM.open(box, using: SymmetricKey(data: Self.key)) == request)
    }

    @Test func hostSealedResponseUnsealsAndTamperingIsRefused() throws {
        let response = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
        let seq: UInt32 = 0x0102_0304
        let box = try AES.GCM.seal(response, using: SymmetricKey(data: Self.key),
                                   nonce: Self.rtspNonce(seq: seq, originator: "H"))
        var wire = RtspClient.beBytes(0x8000_0000 | UInt32(response.count)) + RtspClient.beBytes(seq)
        wire += [UInt8](box.tag) + [UInt8](box.ciphertext)
        let rtsp = Self.makeClient(port: 9)
        #expect(try rtsp.unsealRtsp(Data(wire)) == response)
        wire[wire.count - 1] ^= 0x01
        #expect(throws: (any Error).self) { try rtsp.unsealRtsp(Data(wire)) }
    }

    /// Sunshine reads a sealed message into 2048 bytes and refuses one whose 24-byte header plus payload
    /// reaches that (rtsp.cpp), so the longest ANNOUNCE we can send, sealed, must stay under it.
    @Test func worstCaseSealedAnnounceFitsSunshinesBuffer() throws {
        let url = "rtspenc://[2001:0db8:ffff:ffff:ffff:ffff:ffff:ffff]:48010"
        let (urlAddr, urlSafeAddr, family) = NativeBackend.addressInfo(rtspSessionUrl: url, fallbackAddress: "")
        let config = BackendStreamConfig(
            width: 7680, height: 4320, fps: 240, bitrate: Int32(AppModel.wiredBitrateCapKbps), packetSize: 1392,
            streamingRemotely: StreamProtocol.STREAM_CFG_REMOTE, audioConfiguration: AudioConfig.surround71.cValue,
            supportedVideoFormats: 0, clientRefreshRateX100: 24_000, colorSpace: 2, colorRange: 1,
            encryptionFlags: 0, remoteInputAesKey: Self.key, remoteInputAesIv: Self.key)
        let rtsp = RtspClient(
            host: "127.0.0.1", rtspPort: 48010, rtspTargetUrl: url, urlAddr: urlAddr,
            urlSafeAddr: urlSafeAddr, addrFamilyToken: family, config: config, serverCodecModeRaw: 0)
        rtsp.sessionIdString = "DEADBEEFCAFE"
        var result = RtspHandshakeResult(
            audioPort: 48000, videoPort: 47998, controlPort: 47999, controlConnectData: 0,
            sessionId: "DEADBEEFCAFE", negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H265_MAIN10,
            encryptionFeaturesSupported: 7, encryptionFeaturesEnabled: 7,
            referenceFrameInvalidationSupported: true)
        result.highQualityAudio = true
        #expect(family == "IPv6" && rtsp.encryptedRtspEnabled)
        let sealed = try rtsp.sealRtsp(rtsp.makeAnnounce(result).serialize())
        #expect(sealed.count < 2048)
    }

    // MARK: - Encryption negotiation

    @Test func controlAndAudioEncryptionFollowTheHostOffer() {
        // Sunshine offers control + audio (5), plus video (7) where it allows but doesn't require it.
        #expect(RtspClient.computeEncryptionEnabled(supported: 5, requested: 1) == 5)
        #expect(RtspClient.computeEncryptionEnabled(supported: 7, requested: 1) == 5)
        #expect(RtspClient.computeEncryptionEnabled(supported: 1, requested: 0) == 1)
    }

    @Test func videoIsEncryptedOnlyWhenThePcRequiresIt() {
        // Mandatory mode requests control, video and audio (7), and refuses an ANNOUNCE without both.
        #expect(RtspClient.computeEncryptionEnabled(supported: 7, requested: 7) == 7)
        #expect(RtspClient.computeEncryptionEnabled(supported: 7, requested: 1) & RtspClient.ssEncVideo == 0)
    }

    // MARK: - Audio decrypt (SS_ENC_AUDIO)

    private final class NullAudioSink: NativeAudioSink {
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: [UInt8]) {}
        func decodeAndPlayPLC() {}
        func cleanup() {}
    }

    private final class RecordingAudioSink: NativeAudioSink, @unchecked Sendable {
        // Every mutable field is read or written while holding this lock.
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        private var cleanups = 0

        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: [UInt8]) { lock.lock(); packets.append(opus); lock.unlock() }
        func decodeAndPlayPLC() {}
        func cleanup() { lock.lock(); cleanups += 1; lock.unlock() }
        func recordedPackets() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return packets }
        func cleanupCount() -> Int { lock.lock(); defer { lock.unlock() }; return cleanups }
    }

    private static func audioDatagram(type: UInt8, sequence: UInt16, timestamp: UInt32,
                                      payload: [UInt8]) -> [UInt8] {
        [0x80, type, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
         UInt8(timestamp >> 24), UInt8(timestamp >> 16), UInt8(timestamp >> 8),
         UInt8(truncatingIfNeeded: timestamp), 0, 0, 0, 1] + payload
    }

    @Test func filledAudioReorderGapDrainsReadyPackets() {
        let sink = RecordingAudioSink()
        let receiver = RtpAudioReceiver(
            host: "127.0.0.1", audioPort: 48000, pingPayload: [], audioPacketDuration: 5,
            opusConfig: RtspHandshakeResult.defaultOpusConfig, audioConfig: 0,
            audioEncryption: false, aesKey: [], aesIvId: [], sink: sink)
        let fec = Self.audioDatagram(type: RtpAudioQueue.payloadTypeFec, sequence: 0, timestamp: 0,
                                     payload: [0, RtpAudioQueue.payloadTypeAudio, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        receiver.handleDatagram(fec, count: fec.count)
        for sequence: UInt16 in [4, 6, 5] {
            let payload = [UInt8](repeating: UInt8(sequence), count: 8)
            let packet = Self.audioDatagram(type: RtpAudioQueue.payloadTypeAudio, sequence: sequence,
                                            timestamp: UInt32(sequence) * 5, payload: payload)
            receiver.handleDatagram(packet, count: packet.count)
        }
        #expect(sink.recordedPackets() == [
            [UInt8](repeating: 4, count: 8), [UInt8](repeating: 5, count: 8),
            [UInt8](repeating: 6, count: 8)
        ])
    }

    private final class BlockingAudioSink: NativeAudioSink, @unchecked Sendable {
        // The semaphores coordinate initialization; cleanup count is lock-guarded.
        private let lock = NSLock()
        let initializationStarted = DispatchSemaphore(value: 0)
        let finishInitialization = DispatchSemaphore(value: 0)
        private var cleanups = 0

        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 {
            initializationStarted.signal()
            finishInitialization.wait()
            return 0
        }
        func decodeAndPlay(_ opus: [UInt8]) {}
        func decodeAndPlayPLC() {}
        func cleanup() { lock.lock(); cleanups += 1; lock.unlock() }
        func cleanupCount() -> Int { lock.lock(); defer { lock.unlock() }; return cleanups }
    }

    @Test func stoppingDuringAudioInitializationCleansUp() async throws {
        try await Task(priority: .high) {
            let sink = BlockingAudioSink()
            let receiver = RtpAudioReceiver(
                host: "127.0.0.1", audioPort: 48000, pingPayload: [], audioPacketDuration: 5,
                opusConfig: RtspHandshakeResult.defaultOpusConfig, audioConfig: 0,
                audioEncryption: false, aesKey: [], aesIvId: [], sink: sink)
            let startupDone = DispatchSemaphore(value: 0)
            let startup = Task {
                try await onTestThread {
                    defer { startupDone.signal() }
                    try receiver.startReceive()
                }
            }
            defer { sink.finishInitialization.signal() }
            #expect(await sink.initializationStarted.waitAsync(for: .seconds(2)) == .success)

            let stopThread = OSAllocatedUnfairLock<thread_act_t>(initialState: 0)
            let stopStarted = DispatchSemaphore(value: 0)
            let stopDone = DispatchSemaphore(value: 0)
            let stop = Task {
                try await onTestThread {
                    stopThread.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
                    stopStarted.signal()
                    receiver.stop()
                    stopDone.signal()
                }
            }
            #expect(await stopStarted.waitAsync(for: .seconds(2)) == .success)
            #expect(await threadParks(stopThread.withLock { $0 }, within: .seconds(2)))
            // Stop must wait for initialization to publish the sink before cleaning it up.
            #expect(await stopDone.waitAsync(for: .milliseconds(50)) == .timedOut)
            sink.finishInitialization.signal()
            try #require(await startupDone.waitAsync(for: .seconds(2)) == .success)
            try #require(await stopDone.waitAsync(for: .seconds(2)) == .success)
            try await startup.value
            try await stop.value
            #expect(receiver.initialized == false)
            #expect(receiver.fd == -1)
            #expect(sink.cleanupCount() == 1)
            receiver.stop()
            #expect(receiver.initialized == false)
            #expect(receiver.fd == -1)
            #expect(sink.cleanupCount() == 1)
        }.value
    }

    /// The host side: AES-128-CBC with PKCS7 padding and IV = BE32(keyId + seq).
    private static func hostEncrypt(_ plaintext: [UInt8], seq: UInt16, keyId: UInt32) -> [UInt8]? {
        let ivSeq = keyId &+ UInt32(seq)
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        iv[0] = UInt8(ivSeq >> 24)
        iv[1] = UInt8((ivSeq >> 16) & 0xFF)
        iv[2] = UInt8((ivSeq >> 8) & 0xFF)
        iv[3] = UInt8(ivSeq & 0xFF)
        let capacity = plaintext.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: capacity)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                             plaintext, plaintext.count, &out, capacity, &moved)
        return status == kCCSuccess ? Array(out[0..<moved]) : nil
    }

    /// 60 bytes pads to 64; 64 gets a whole pad block, which opus must never see.
    @Test(arguments: [60, 64])
    func encryptedAudioDecryptsToTheOpusBytes(length: Int) throws {
        // keyId + seq wraps past UInt32.max, as the host's u32 add does.
        let ivId: [UInt8] = [0xFF, 0xFF, 0xFF, 0xF0] + [UInt8](repeating: 0, count: 12)
        let receiver = RtpAudioReceiver(
            host: "127.0.0.1", audioPort: 48000, pingPayload: [],
            audioPacketDuration: 5, opusConfig: RtspHandshakeResult.defaultOpusConfig,
            audioConfig: 0, audioEncryption: true, aesKey: Self.key, aesIvId: ivId,
            sink: NullAudioSink())
        let opus = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let seq: UInt16 = 0x0123
        let ciphertext = try #require(Self.hostEncrypt(opus, seq: seq, keyId: 0xFFFF_FFF0))
        #expect(receiver.decryptCbc(ciphertext, sequenceNumber: seq) == opus)
    }
}
