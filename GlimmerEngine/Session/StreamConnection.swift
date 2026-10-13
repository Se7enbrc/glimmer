// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// One transport attempt. The shell supplies media sinks and owns presentation and reconnect policy.
public actor StreamConnection {
    public nonisolated let id: UUID
    private let backend: NativeBackend
    private var started = false
    private var stopped = false

    public enum Event: Sendable, Equatable {
        case stageStarting(String)
        case stageComplete(String)
        case stageFailed(String, code: Int32)
        case connected
        case terminated(code: Int32)
        case connectionPoor(Bool)
        case hdrMode(Bool)
        case audioFailed(String)
    }

    public enum Failure: Error, Sendable {
        case alreadyStarted
        case invalidConfiguration
        case pairingRequired
        case invalidSessionKey
    }

    /// Callbacks run synchronously on engine threads. Enqueue them in order and reject obsolete IDs.
    public init(video: any VideoSink, audio: (any NativeAudioSink)? = nil,
                onEvent: @escaping @Sendable (UUID, Event) -> Void) {
        let id = UUID()
        self.id = id
        backend = NativeBackend()
        backend.attachConnectionEvents(TransportConnectionEvents(id: id, emit: onEvent))
        backend.attachVideoSink(video)
        if let audio { backend.attachAudioSink(audio) }
    }

    /// Uses the paired client's cached PC record, then performs one launch or resume and the live handshake.
    public func connect(network: NetworkClient, appID: Int, configuration: Configuration) async throws {
        guard !started else { throw Failure.alreadyStarted }
        guard !stopped else { throw CancellationError() }
        guard appID > 0 else { throw Failure.invalidConfiguration }
        try configuration.validate()
        let server = await network.server
        guard server.serverCertPEM != nil, server.pairStatus == .paired else { throw Failure.pairingRequired }
        guard !server.isRealGFE else { throw StreamError.gameStreamHost }
        started = true
        do {
            try Task.checkCancellation()
            let request = configuration.request
            let launch = server.currentGameID == appID
                ? try await network.resume(config: request)
                : try await network.launch(appID: appID, config: request)
            guard !stopped else { throw CancellationError() }
            try Task.checkCancellation()
            let config = try configuration.backendConfig(launch: launch)
            let info = BackendServerInfo(address: server.address, appVersion: server.appVersion ?? "unknown",
                rtspSessionUrl: launch.sessionURL,
                serverCodecModeRaw: NetworkClient.backendCodecModeMask(server.serverCodecModeRaw))
            try await backend.startConnectionAsync(server: info, config: config)
        } catch {
            backend.stopConnection()
            throw error
        }
    }

    deinit { backend.stopConnection() }

    /// Stops local transport and joins media workers. It does not quit the game on the PC.
    public func stop() {
        stopped = true
        backend.stopConnection()
    }
}

/// Immutable identity and callback; no mutable state crosses the callback threads.
final class TransportConnectionEvents: ConnectionEvents {
    let id: UUID
    let emit: @Sendable (UUID, StreamConnection.Event) -> Void

    init(id: UUID, emit: @escaping @Sendable (UUID, StreamConnection.Event) -> Void) {
        self.id = id
        self.emit = emit
    }

    func stageStarting(_ name: String) { emit(id, .stageStarting(name)) }
    func stageComplete(_ name: String) { emit(id, .stageComplete(name)) }
    func stageFailed(_ name: String, code: Int32) { emit(id, .stageFailed(name, code: code)) }
    func connectionStarted() { emit(id, .connected) }
    func connectionTerminated(code: Int32) { emit(id, .terminated(code: code)) }
    func connectionStatus(poor: Bool) { emit(id, .connectionPoor(poor)) }
    func setHdrMode(_ enabled: Bool) { emit(id, .hdrMode(enabled)) }
    func audioFailed(_ detail: String) { emit(id, .audioFailed(detail)) }
}
