// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin
import Foundation
import Testing
@testable import GlimmerEngine

struct TransportBoundaryTests {
    // Every callback access shares this lock, including observations after the receive thread returns.
    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        var values: [(UUID, StreamConnection.Event)] = []
        func append(_ id: UUID, _ event: StreamConnection.Event) { lock.withLock { values.append((id, event)) } }
        var snapshot: [(UUID, StreamConnection.Event)] { lock.withLock { values } }
    }

    @Test func callbacksPreserveIdentityAndOrder() {
        let id = UUID()
        let received = Events()
        let events = TransportConnectionEvents(id: id, emit: { received.append($0, $1) })
        events.stageStarting("RTSP handshake")
        events.stageComplete("RTSP handshake")
        events.setHdrMode(true)
        events.audioFailed("unavailable")
        events.connectionStarted()
        events.connectionTerminated(code: 7)
        #expect(received.snapshot.allSatisfy { $0.0 == id })
        #expect(received.snapshot.map(\.1) == [.stageStarting("RTSP handshake"), .stageComplete("RTSP handshake"),
            .hdrMode(true), .audioFailed("unavailable"), .connected, .terminated(code: 7)])
    }

    @Test func controlChannelForwardsHdrWithoutAConcreteDecoder() throws {
        let received = Events()
        let backend = NativeBackend()
        let events = TransportConnectionEvents(id: UUID(), emit: { received.append($0, $1) })
        let channel = EnetControlChannel(host: .ipv4(.loopback), port: 47999, controlConnectData: 0,
            crypto: try ControlCrypto(rikey: [UInt8](repeating: 0, count: 16)))
        backend.wireVideoControl(enet: channel, events: events)
        channel.onHdrMode?(true)
        channel.onHdrMode?(false)
        #expect(received.snapshot.map(\.1) == [.hdrMode(true), .hdrMode(false)])
        backend.stopConnection()
        channel.onHdrMode?(true)
        #expect(received.snapshot.count == 2)
    }

    @Test func absentBatchAdapterSelectsPublicFallback() {
        let batch = DatagramBatch(capacity: 2, stride: 1500)
        #expect(batch.receive(from: -1) == -1)
        #expect(errno == ENOSYS)
    }

    @Test func configurationRejectsInvalidInputsAndSessionKeys() throws {
        let valid = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                   bitrateKbps: 20_000, videoFormats: [.h264])
        try valid.validate()
        let invalid = StreamConnection.Configuration(width: 0, height: 1080, fps: 60,
                                                     bitrateKbps: 20_000, videoFormats: [.h264])
        #expect(throws: StreamConnection.Failure.self) { try invalid.validate() }
        let launch = LaunchResponse(sessionURL: "rtsp://127.0.0.1:48010", gcmKey: Data(), gcmKeyId: Data())
        #expect(throws: StreamConnection.Failure.self) { try valid.backendConfig(launch: launch) }
    }

    @Test func remoteConfigurationPreservesPacketClamp() throws {
        let config = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
            bitrateKbps: 20_000, videoFormats: [.hevc], remote: true, routeMTU: 1100)
        let key = Data(repeating: 0, count: 16)
        let launch = LaunchResponse(sessionURL: "rtsp://127.0.0.1:48010", gcmKey: key, gcmKeyId: key)
        let backend = try config.backendConfig(launch: launch)
        #expect(backend.packetSize == 972)
        #expect(backend.isRemoteSession)
        #expect(backend.audioConfiguration == AudioConfig.stereo.cValue)
    }
    private final class Sink: VideoSink {
        let capabilities: Int32 = 0
        func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 { 0 }
        func start() {}
        func stop() {}
        func cleanup() {}
        func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { 0 }
    }

    @Test func stoppedAndUnpairedConnectionsNeverLoadCredentials() async {
        let server = ServerInfo(address: "127.0.0.1", uniqueId: "test", serverName: "Test PC")
        let network = NetworkClient(server: server, deviceName: { "Test" }, identity: {
            Issue.record("Rejected connections must not load credentials or contact the PC")
            throw IdentityStorageError.unavailable
        })
        let config = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                    bitrateKbps: 20_000, videoFormats: [.h264])
        let connection = StreamConnection(video: Sink()) { _, _ in }
        await #expect(throws: StreamConnection.Failure.pairingRequired) {
            try await connection.connect(network: network, appID: 1, configuration: config)
        }
        await connection.stop()
        await #expect(throws: CancellationError.self) {
            try await connection.connect(network: network, appID: 1, configuration: config)
        }
    }

    @Test func connectReservesAttemptBeforeReadingNetworkActor() async {
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let network = rejectingNetwork()
        let connection = StreamConnection(video: Sink()) { _, _ in }
        let config = connectionConfiguration()
        let first = Task<Void, Never> {
            _ = await #expect(throws: StreamConnection.Failure.pairingRequired) {
                try await connection.connect(network: network, appID: 1, configuration: config) { network in
                    entry.yield(())
                    for await _ in release { break }
                    return await network.server
                }
            }
        }
        for await _ in entered { break }
        await #expect(throws: StreamConnection.Failure.alreadyStarted) {
            try await connection.connect(network: network, appID: 1, configuration: config)
        }
        continuation.yield(())
        await first.value
        await connection.stop()
    }

    @Test func stopDuringNetworkSnapshotPreventsLaunch() async {
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let network = rejectingNetwork(paired: true)
        let connection = StreamConnection(video: Sink()) { _, _ in }
        let config = connectionConfiguration()
        let first = Task<Void, Never> {
            _ = await #expect(throws: CancellationError.self) {
                try await connection.connect(network: network, appID: 1, configuration: config) { network in
                    entry.yield(())
                    for await _ in release { break }
                    return await network.server
                }
            }
        }
        for await _ in entered { break }
        await connection.stop()
        continuation.yield(())
        await first.value
    }

    @Test func stopCancelsLaunchWaitingForIdentity() async {
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        var server = ServerInfo(address: "127.0.0.1", uniqueId: "test", serverName: "Test PC")
        server.serverCertPEM = "test pin, never used by a transport"
        server.pairStatus = .paired
        let network = NetworkClient(server: server, deviceName: { "Test" }, transport: { _, _, _, _, _, _, _ in
            Issue.record("A stopped connection must not send its pending launch")
            throw IdentityStorageError.unavailable
        }, identity: {
            entry.yield(())
            for await _ in release { break }
            return ("test certificate", "test key", "test identity")
        })
        let connection = StreamConnection(video: Sink()) { _, _ in }
        let config = connectionConfiguration()
        let first = Task<Void, Never> {
            _ = await #expect(throws: CancellationError.self) {
                try await connection.connect(network: network, appID: 1, configuration: config)
            }
        }
        for await _ in entered { break }
        await connection.stop()
        continuation.yield(())
        await first.value
    }

    private func rejectingNetwork(paired: Bool = false) -> NetworkClient {
        var server = ServerInfo(address: "127.0.0.1", uniqueId: "test", serverName: "Test PC")
        if paired {
            server.serverCertPEM = "test pin, never used by a transport"
            server.pairStatus = .paired
        }
        return NetworkClient(server: server,
                      deviceName: { "Test" }, identity: {
            Issue.record("Rejected connections must not load credentials or contact the PC")
            throw IdentityStorageError.unavailable
        })
    }

    private func connectionConfiguration() -> StreamConnection.Configuration {
        StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                       bitrateKbps: 20_000, videoFormats: [.h264])
    }

    @Test func workerConfiguresItsOwnedThreadOnce() {
        let configured = DispatchSemaphore(value: 0)
        let worker = AudioPacketWorker(configureThread: {
            #expect(Thread.current.name == "Glimmer.audioDecode")
            configured.signal()
        }, consume: { _, _ in })
        worker.start()
        #expect(configured.wait(timeout: .now() + 2) == .success)
        worker.stop()
        #expect(configured.wait(timeout: .now()) == .timedOut)
    }
}
