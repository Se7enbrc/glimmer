// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Low-level, single transport attempt retained for existing consumers.
/// Use StreamSession for shared recovery, watchdogs and complete media lifetime.
public actor StreamConnection {
    public nonisolated let id: UUID
    public nonisolated let input: StreamInput
    private let backend: NativeBackend
    private var started = false
    private var stopped = false
    private var launchTask: Task<LaunchResponse, Error>?

    public enum Event: Sendable, Equatable {
        case stageStarting(String)
        case stageComplete(String)
        case stageFailed(String, code: Int32)
        case connected
        case terminated(code: Int32)
        case connectionPoor(Bool)
        case hdrMode(Bool)
        case audioFailed(String)
        case input(StreamInput.Event)
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
        let backend = NativeBackend()
        self.backend = backend
        input = StreamInput(backend: backend) { onEvent(id, .input($0)) }
        backend.attachConnectionEvents(TransportConnectionEvents(id: id, input: input, emit: onEvent))
        backend.attachVideoSink(video)
        if let audio { backend.attachAudioSink(audio) }
    }

    /// Uses the paired client's cached PC record, then performs one launch or resume and the live handshake.
    public func connect(network: NetworkClient, appID: Int, configuration: Configuration) async throws {
        try await connect(network: network, appID: appID, configuration: configuration,
                          readServer: { await $0.server })
    }

    func connect(network: NetworkClient, appID: Int, configuration: Configuration,
                 readServer: @Sendable (NetworkClient) async -> ServerInfo) async throws {
        guard !stopped else { throw CancellationError() }
        guard !started else { throw Failure.alreadyStarted }
        guard appID > 0 else { throw Failure.invalidConfiguration }
        try configuration.validate()
        // Reserve this attempt before crossing actors; stop and another connect can run at every await.
        started = true
        do {
            let server = await readServer(network)
            guard !stopped else { throw CancellationError() }
            guard server.serverCertPEM != nil, server.pairStatus == .paired else { throw Failure.pairingRequired }
            guard !server.isRealGFE else { throw StreamError.gameStreamHost }
            try Task.checkCancellation()
            let request = configuration.request
            let pending = Task {
                try Task.checkCancellation()
                return server.currentGameID == appID
                    ? try await network.resume(config: request)
                    : try await network.launch(appID: appID, config: request)
            }
            launchTask = pending
            defer { launchTask = nil }
            let launch = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
            guard !stopped else { throw CancellationError() }
            try Task.checkCancellation()
            let config = try configuration.backendConfig(launch: launch)
            let info = BackendServerInfo(address: server.address, appVersion: server.appVersion ?? "unknown",
                rtspSessionUrl: launch.sessionURL,
                serverCodecModeRaw: NetworkClient.backendCodecModeMask(server.serverCodecModeRaw))
            try await backend.startConnectionAsync(server: info, config: config)
        } catch {
            input.stop()
            backend.stopConnection()
            throw error
        }
    }

    deinit { input.stop(); backend.stopConnection() }

    /// Stops local transport and joins media workers. It does not quit the game on the PC.
    public func stop() {
        stopped = true
        launchTask?.cancel()
        input.stop()
        backend.stopConnection()
    }
}

/// Immutable identity and callback; no mutable state crosses the callback threads.
final class TransportConnectionEvents: ConnectionEvents {
    let id: UUID
    let emit: @Sendable (UUID, StreamConnection.Event) -> Void
    let input: StreamInput?

    init(id: UUID, input: StreamInput? = nil, emit: @escaping @Sendable (UUID, StreamConnection.Event) -> Void) {
        self.id = id
        self.input = input
        self.emit = emit
    }

    func controllersActivated() { input?.enqueueActivation(true) }
    func controllersDeactivated() { input?.enqueueActivation(false) }
    func rumble(controller: UInt16, lowFreq: UInt16, highFreq: UInt16) {
        input?.feedback(slot: controller, .rumble(lowFrequency: lowFreq, highFrequency: highFreq))
    }
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        input?.feedback(slot: controller, .triggerRumble(left: left, right: right))
    }
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        input?.feedback(slot: controller, .rgbLED(red: r, green: g, blue: b))
    }
    func setPlayerLEDs(controller: UInt16, solid: UInt8, flashing: UInt8) {
        input?.feedback(slot: controller, .playerLEDs(solid: solid, flashing: flashing))
    }
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        input?.feedback(slot: controller, .motion(type: motionType, reportRateHz: reportRateHz))
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
