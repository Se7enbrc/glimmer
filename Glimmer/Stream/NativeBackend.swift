//
//  NativeBackend.swift
//
//  The Swift-native streaming engine. P2: `startConnection` drives a real native
//  connection AND native video receive:
//
//    name resolution  →  RTSP/SDP handshake over plain TCP (OPTIONS, DESCRIBE,
//    SETUP audio/video/control, ANNOUNCE, PLAY)  →  ENet-subset reliable-UDP
//    CONTROL channel CONNECT/VERIFY_CONNECT/ACK  →  START_A  →  START_B  →
//    connected  →  video ping + RTP receive → FEC → depacketize → VideoSink.
//
//  This is the only streaming engine. The whole native stack lives under
//  Glimmer/Stream/Native/.
//
//  IMPORTANT: this file does NOT import Limelight.h. Protocol constants come
//  through the Swift StreamProtocol mirror (StreamProtocolConstants.swift).
//
//  STAGE/EVENT WIRING: the native stack emits StreamEvents
//  (stageStarting/stageComplete/stageFailed/connectionEstablished) by yielding
//  to StreamBridgeContext.current.eventContinuation, so the Troubleshooting →
//  Logs + connection UI light up from the connection lifecycle. Diag lines
//  under category "NativeConnection" trace each sub-stage so progress is
//  watchable live.

import Foundation
import Network
import os

public final class NativeBackend: StreamingBackend, @unchecked Sendable {
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.NativeBackend")
    static let logCategory = "NativeConnection"

    let stateLock = NSLock()
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
    public func attachAudioSink(_ sink: NativeAudioSink) {
        withState { audioSink = sink }
    }

    /// The Swift-native video sink (the VideoDecoder, wired as a VideoSink).
    /// Injected by StreamSession before startConnection. Read on the receive
    /// thread.
    var videoSink: VideoSink?

    /// Inject the video sink (the VideoDecoder). Set-once before startConnection.
    public func attachVideoSink(_ sink: VideoSink) {
        withState { videoSink = sink }
    }

    /// Scoped lock helper - `NSLock.lock()/unlock()` are unavailable from async
    /// contexts under Swift 6 strict concurrency, so all state mutation in the
    /// async pipeline goes through this synchronous critical section.
    func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    public init() {}

    // MARK: - Lifecycle

    public func startConnection(
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
    public func startConnectionAsync(
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

    /// Thread-safe single-slot outcome carrier (nil = success).
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
        Diag.notice("native backend: starting connection to \(server.address)", Self.logCategory)
        log.notice("NativeBackend.startConnection → \(server.address, privacy: .public)")
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
            completion(resultBox.get().map { self?.mapToStreamError($0) ?? .sessionFailed(-1) })
        }
        bridgeThread.qualityOfService = .userInitiated
        bridgeThread.name = "Glimmer.nativeConnect"
        bridgeThread.start()
    }

    /// Thread-safe single-slot error carrier for the synchronous→async bridge.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func mapToStreamError(_ error: Error) -> StreamError {
        if let streamError = error as? StreamError { return streamError }
        if let rtsp = error as? RtspError, case .nonOK(_, let code) = rtsp {
            return StreamError.sessionFailed(Int32(code))
        }
        return StreamError.sessionFailed(-1)
    }

    func checkInterrupted() -> Bool {
        withState { interrupted }
    }

    func rtspCode(_ error: Error) -> Int32 {
        if let rtsp = error as? RtspError, case .nonOK(_, let code) = rtsp {
            return Int32(code)
        }
        return -1
    }

    public func stopConnection() {
        Diag.info("native backend: stopConnection", Self.logCategory)
        stateLock.lock()
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
        inputBatcher = nil
        inputReady = false
        stateLock.unlock()
        batcher?.stop()   // cancels the 1ms flush timer + drops the enet ref
        receiver?.stop()
        audio?.stop()   // closes the audio socket + tears down the audio sink
        rtsp?.interrupt()
        enet?.close()
        // Tear down the decoder VT state (idempotent with the C-path cleanup).
        sink?.stop()
        sink?.cleanup()
    }

    public func interruptConnection() {
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

// MARK: - ConnectionEvents adapter for the native stack

/// Bridges the native stack's stage callbacks onto the event channel: it yields
/// StreamEvents to StreamBridgeContext.current's continuation (FIFO,
/// thread-safe) and emits matching Diag lines, driving the Troubleshooting →
/// Logs view + connection UI. Conforms to the ConnectionEvents protocol from
/// StreamingBackend.swift; the native backend owns its own sinks.
final class NativeConnectionEvents: ConnectionEvents, @unchecked Sendable {
    private static let logCategory = "NativeConnection"

    func stageStarting(_ name: String) {
        Diag.info("stage starting: \(name)", Self.logCategory)
        // P2 CONNECT-HANDSHAKE breakdown (always-live; off any hot path - a stage
        // edge is the rarest event). Stamp the connect-relative instant of the
        // stages that bound the breakdown legs. Name-matched against the engine's
        // own stage labels (performRtspStage / performControlStage).
        let now = TelemetryCounters.monotonicNowNanos()
        let p2 = TelemetryCounters.shared.p2
        if name == "name resolution" { p2.markRtspStart(now) }
        if name == "ENET_CONNECT" { p2.markEnetStart(now) }
        StreamBridgeContext.current?.eventContinuation?.yield(.stageStarting(name: name))
    }

    func stageComplete(_ name: String) {
        Diag.info("stage complete: \(name)", Self.logCategory)
        // P2 CONNECT-HANDSHAKE: the RTSP-done edge bounds the RTSP leg + the start
        // of the pairing/auth leg (RTSP-done → ENet-connect start, where the
        // control crypto + control-V2 negotiation set up the per-session material).
        if name == "RTSP handshake" {
            TelemetryCounters.shared.p2.markRtspDone(TelemetryCounters.monotonicNowNanos())
        }
        StreamBridgeContext.current?.eventContinuation?.yield(.stageComplete(name: name))
    }

    func stageFailed(_ name: String, code: Int32) {
        Diag.error("stage FAILED: \(name) (code \(code))", Self.logCategory)
        StreamBridgeContext.current?.eventContinuation?.yield(.stageFailed(name: name, errorCode: code))
    }

    func connectionStarted() {
        Diag.notice("connection established (native)", Self.logCategory)
        // P2 established edge: bounds the ENet-connect leg, starts the first-frame
        // leg. Reconnect is NOT inferred here (silent-reconnect resets the timeline
        // per attempt) - it's counted at the recovery site (runReconnectEpisode).
        TelemetryCounters.shared.p2.markEstablished()
        let bridge = StreamBridgeContext.current
        // If the continuation is gone at yield time, this established edge fires
        // into the void and the UI's connecting→streaming promotion falls back to
        // .firstFrame; log it so a torn yield is diagnosable (not load-bearing).
        if bridge?.eventContinuation == nil {
            Diag.error("connection established but event continuation is nil "
                + "(bridge=\(bridge == nil ? "nil" : "live")) - relying on first-frame fallback "
                + "to promote streaming", Self.logCategory)
        }
        bridge?.eventContinuation?.yield(.connectionEstablished)
        // Drive the actor side effect (flip InputForwarder ready,
        // close the ConnectFlow signpost). Best-effort; lossy if torn down.
        if let session = bridge?.session {
            Task { await session.nativeConnectionEstablished() }
        }
    }

    func connectionTerminated(code: Int32) {
        if code == 0 {
            Diag.notice("connection terminated cleanly (native)", Self.logCategory)
        } else {
            Diag.error("connection terminated unexpectedly (native, code \(code))", Self.logCategory)
        }
        // Latch the per-session reason ordinal only (code 0 → clean, else error).
        // The process-global tally is bumped at genuine teardown, NOT here - a
        // recoverable terminate may be silently reconnected (would over-count).
        TelemetryCounters.shared.p2.setDisconnectReason(
            code == 0 ? .hostClosedClean : .hostError)
        let bridge = StreamBridgeContext.current
        // Don't yield `.connectionTerminated` directly: handleHostTerminate
        // classifies it (a recoverable live-session close drives a silent reconnect
        // under the frozen frame). No session → fall back so it's never swallowed.
        if let session = bridge?.session {
            Task { await session.handleHostTerminate(code: code) }
        } else {
            bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
        }
    }

    func connectionStatus(poor: Bool) {
        let quality: ConnectionQuality = poor ? .poor : .good
        StreamBridgeContext.current?.eventContinuation?.yield(.connectionStatus(quality))
    }

    func setHdrMode(_ enabled: Bool) {
        // Intent signal only - the native video path engages HDR through
        // EnetControlChannel.onHdrMode (see startVideoStage). This yields the
        // matching UI event for ConnectionEvents parity with the C bridge.
        StreamBridgeContext.current?.eventContinuation?.yield(.hdrModeChanged(enabled))
    }
}
