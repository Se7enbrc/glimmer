// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// The native RTSP/ENet/RTP pipeline owns its threads, resources and teardown.
// Injected events retain the originating session and ordered stage delivery.
// NativeConnection diagnostics preserve visibility into each connection stage.

import Foundation
import Network
import os

// Mutable connection resources are guarded by stateLock; receive loops own their packet state.
package final class NativeBackend: StreamingBackend, @unchecked Sendable {
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.NativeBackend")
    static let logCategory = "NativeConnection"

    let stateLock = NSLock()
    /// Concurrent stops join resource disposal; same-thread callback reentry sees the cleared snapshot.
    private let teardownLock = NSRecursiveLock()
    var rtspClient: RtspClient?
    var enetChannel: EnetControlChannel?
    var videoReceiver: VideoRtpReceiver?
    /// Native audio receive: ONE unconnected UDP socket that BOTH pings the audio
    /// port (so the host aims audio RTP at our return port) AND recvfrom's the
    /// audio stream → FEC → opus → AudioDecoder. Replaces the old send-only
    /// audioPinger (which only kept the combined A/V session alive).
    var audioReceiver: RtpAudioReceiver?
    var interrupted = false
    var didConnect = false

    /// Set true at "connected"; gates the input uplink (send* return -2 until
    /// then, mirroring InputStream.c's `initialized` guard). Read on the
    /// @MainActor input forwarders, set under stateLock.
    var inputReady = false

    /// Input queue+merge+1ms-flush (InputStream.c's inputSendThreadProc). Owns
    /// the high-rate mouse/controller coalescing so the reliable input RATE drops
    /// from ~150-250/s to ~1 packet per change per ~1ms tick - the fix for the
    /// host-side ENet peer-timeout that silently killed the stream at ~16-18s.
    /// Constructed when inputReady flips true (with the live enetChannel); torn
    /// down in stopConnection/interruptConnection.
    var inputBatcher: InputBatcher?

    /// Sunshine x-ss-general.featureFlags from the DESCRIBE SDP. Bit 0x02 =
    /// LI_FF_CONTROLLER_TOUCH_EVENTS gates controllerTouch (else -5501).
    var featureFlags: UInt32 = 0

    /// LI_FF_CONTROLLER_TOUCH_EVENTS (Limelight.h:1012).
    static let ffControllerTouchEvents: UInt32 = 0x02

    /// The Swift-native audio sink (the AudioDecoder, wired as a NativeAudioSink).
    /// Injected by StreamSession before startConnection.
    var audioSink: NativeAudioSink?

    /// Inject the audio sink (the AudioDecoder). Set-once before startConnection.
    package func attachAudioSink(_ sink: NativeAudioSink) {
        _ = adoptWhileConnecting { audioSink = sink }
    }

    /// The Swift-native video sink (the VideoDecoder, wired as a VideoSink).
    /// Injected by StreamSession before startConnection. Read on the receive
    /// thread.
    var videoSink: VideoSink?

    /// Inject the video sink (the VideoDecoder). Set-once before startConnection.
    package func attachVideoSink(_ sink: VideoSink) {
        _ = adoptWhileConnecting {
            videoSink = sink
            (sink as? VideoDecoder)?.setBackend(self)
        }
    }

    /// Scoped lock helper - `NSLock.lock()/unlock()` are unavailable from async
    /// contexts under Swift 6 strict concurrency, so all state mutation in the
    /// async pipeline goes through this synchronous critical section.
    func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// Join lifecycle work before reuse; recursive callbacks may stop without holding stateLock.
    func withLifecycle<T>(_ body: () throws -> T) rethrows -> T {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        return try body()
    }

    /// Adoption and the stop snapshot share a lock, so every published resource
    /// belongs to teardown. Rejected resources must never be started.
    func adoptWhileConnecting(_ body: () -> Void) -> Bool {
        withState {
            guard !interrupted else { return false }
            body()
            return true
        }
    }

    let platform: TransportPlatform
    var connectionEvents: (any ConnectionEvents)?

    package init(platform: TransportPlatform = TransportPlatform()) {
        self.platform = platform
    }

    package func attachConnectionEvents(_ events: any ConnectionEvents) {
        _ = adoptWhileConnecting { connectionEvents = events }
    }

    // MARK: - Lifecycle

    package func startConnection(
        server: BackendServerInfo,
        config: BackendStreamConfig
    ) throws {
        // Synchronous protocol entry: block on the bridge completion. Prefer
        // startConnectionAsync (frees the actor instead of parking it here); this
        // is kept for protocol conformance / non-actor callers.
        let bridge = DispatchSemaphore(value: 0)
        let outcomeBox = OutcomeBox()
        runBridgedConnect(server: server, config: config) { outcome in
            outcomeBox.set(outcome)
            bridge.signal()
        }
        bridge.wait()
        if let error = outcomeBox.get() { throw error }
    }

    /// Async actor-safe entry: awaits a continuation instead of blocking, so the
    /// StreamSession actor stays responsive while a hanging host is brought up. On
    /// cancellation we interrupt the in-flight connections; the bridge-thread
    /// completion then resumes the continuation exactly once.
    package func startConnectionAsync(
        server: BackendServerInfo,
        config: BackendStreamConfig
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                runBridgedConnect(server: server, config: config) { outcome in
                    if let error = outcome { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } onCancel: {
            // Unblock the bridge thread's pipeline; its completion resumes the
            // continuation with the resulting (interrupted) error.
            interruptConnection()
        }
    }

    /// The lock guards the bridge thread's single outcome slot (nil = success).
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func set(_ error: Error?) { lock.lock(); value = error; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Run the connect pipeline on a DEDICATED thread, reporting the outcome (nil =
    /// success) via `completion` exactly once. The blocking `done.wait()` runs on
    /// THAT thread, never a Swift cooperative-pool thread. The 30s cap guards an
    /// unforeseen stall; each sub-stage is individually bounded.
    private func runBridgedConnect(
        server: BackendServerInfo,
        config: BackendStreamConfig,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        Diag.notice("native backend: starting connection to \(server.address, privacy: .private)", Self.logCategory)
        log.notice("NativeBackend.startConnection → \(server.address, privacy: .private)")
        let resultBox = ErrorBox()
        let timedOutBox = AtomicCounter()
        let bridgeThread = Thread { [weak self, server, config] in
            let done = DispatchSemaphore(value: 0)
            Task(priority: .userInitiated) { [weak self, server, config] in
                guard let self else { done.signal(); return }
                do {
                    try await self.run(server: server, config: config)
                } catch {
                    resultBox.set(error)
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 30) == .timedOut {
                timedOutBox.increment()
            }
            if timedOutBox.value > 0 {
                Diag.error("native backend: connection timed out after 30s - interrupting", Self.logCategory)
                // Cancel the in-flight RTSP/ENet connections so the still-running
                // async pipeline unwinds on its own (its weak self-captures no-op
                // after teardown). We do not block waiting for that unwind.
                self?.interruptConnection()
                completion(StreamError.sessionFailed(-1))
                return
            }
            completion(resultBox.get().map { Self.mapToStreamError($0) })
        }
        bridgeThread.qualityOfService = .userInitiated
        bridgeThread.name = "Glimmer.nativeConnect"
        bridgeThread.start()
    }

    /// The lock guards the error shared by the synchronous bridge and async pipeline.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func mapToStreamError(_ error: Error) -> StreamError {
        if let streamError = error as? StreamError { return streamError }
        switch error as? RtspError {
        case .connectTimeout(let port): return .streamPortsBlocked(proto: "TCP", port: port)
        // The PC took the connection and went quiet: the shared couldn't-reach copy, not a stream code.
        case .responseTimeout(let seconds): return .hostUnreachable("no RTSP response in \(Int(seconds)) s")
        default: return .sessionFailed(rtspCode(error))
        }
    }

    func checkInterrupted() -> Bool {
        withState { interrupted }
    }

    static func rtspCode(_ error: Error) -> Int32 {
        switch error as? RtspError {
        case .nonOK(_, let code): return Int32(code)
        default: return -1
        }
    }

    package func stopConnection() {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        Diag.info("native backend: stopConnection", Self.logCategory)
        stateLock.lock()
        interrupted = true
        let enet = enetChannel
        let rtsp = rtspClient
        let receiver = videoReceiver
        let audio = audioReceiver
        let sink = videoSink
        let batcher = inputBatcher
        enetChannel = nil
        rtspClient = nil
        videoReceiver = nil
        audioReceiver = nil
        // Release both sinks: the video decoder also holds this backend.
        videoSink = nil
        audioSink = nil
        inputBatcher = nil
        inputReady = false
        stateLock.unlock()
        batcher?.stop()   // cancels the 1ms flush timer + drops the enet ref
        receiver?.stop()
        audio?.stop()   // ends the audio loops + tears down the audio sink; deinit closes the socket
        rtsp?.interrupt()
        enet?.close()
        // Tear down the decoder VT state (idempotent with the C-path cleanup).
        sink?.stop()
        sink?.cleanup()
    }

    package func interruptConnection() {
        Diag.info("native backend: interruptConnection", Self.logCategory)
        stateLock.lock()
        interrupted = true
        inputReady = false
        let enet = enetChannel
        let rtsp = rtspClient
        let receiver = videoReceiver
        let audio = audioReceiver
        let batcher = inputBatcher
        inputBatcher = nil
        stateLock.unlock()
        batcher?.stop()   // cancels the 1ms flush timer + drops the enet ref
        receiver?.stop()
        audio?.stop()
        rtsp?.interrupt()
        enet?.interrupt()
    }
}
