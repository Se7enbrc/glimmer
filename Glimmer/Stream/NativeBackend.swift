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
        Diag.notice("native backend: starting connection to \(server.address)", Self.logCategory)
        log.notice("NativeBackend.startConnection → \(server.address, privacy: .public)")

        // startConnection is documented to BLOCK like LiStartConnection (it fires
        // stage callbacks while running and returns 0/throws). We run the async
        // pipeline to completion on a private semaphore so the contract holds for
        // the synchronous caller (StreamSession). The result is carried across
        // the Task boundary in a Sendable box (a bare mutable capture isn't
        // Sendable under Swift 6 strict concurrency).
        //
        // The pipeline is launched from a DEDICATED thread (not directly from the
        // caller) and the blocking `done.wait()` runs on THAT dedicated thread, so
        // the semaphore wait never parks a Swift cooperative-pool thread (the
        // caller is an actor whose continuation runs on the pool). The async
        // pipeline itself runs at .userInitiated priority - it only awaits (it does
        // not block), so it yields its pool thread across each RTSP/ENet suspension
        // rather than hogging a capped pool thread.
        let resultBox = ErrorBox()
        let bridge = DispatchSemaphore(value: 0)   // signals when the bridge thread finishes
        let timedOutBox = AtomicCounter()           // 1 = the bridge timed out
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
            // Overall safety cap. Each sub-stage is individually bounded, but this
            // guards any unforeseen stall (a host that accepts the TCP socket then
            // never responds, or a dropped ENet handshake). On timeout we interrupt
            // - cancelling the in-flight RTSP/ENet connections so the async pipeline
            // unwinds - and fail cleanly rather than blocking forever.
            if done.wait(timeout: .now() + 30) == .timedOut {
                timedOutBox.increment()
            }
            bridge.signal()
        }
        bridgeThread.qualityOfService = .userInitiated
        bridgeThread.name = "Glimmer.nativeConnect"
        bridgeThread.start()
        bridge.wait()
        if timedOutBox.value > 0 {
            Diag.error("native backend: connection timed out after 30s - interrupting", Self.logCategory)
            // Cancel the in-flight RTSP/ENet connections so the still-running async
            // pipeline unwinds on its own (its weak self-captures no-op after
            // teardown). We do not block the caller waiting for that unwind.
            interruptConnection()
            throw StreamError.sessionFailed(-1)
        }
        if let thrown = resultBox.get() {
            throw mapToStreamError(thrown)
        }
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
        // P2 CONNECT-HANDSHAKE: established edge - bounds the ENet-connect leg and
        // starts the first-frame leg (established → first decoded frame). Also the
        // RECONNECT signal: a SECOND established edge in one run means the link
        // re-established after a drop, so count it (the first established is the
        // initial connect, not a reconnect). Both always-live; off any hot path.
        let p2 = TelemetryCounters.shared.p2
        if p2.markEstablishedReportingReconnect() {
            TelemetryCounters.shared.reconnectTotal.increment()
        }
        let bridge = StreamBridgeContext.current
        // Observability for the fragile one-shot edge: if the bridge or its
        // continuation is gone at yield time, this established edge is being
        // fired into the void (the UI's connecting→streaming promotion would
        // then rely entirely on the .firstFrame fallback). Surface it instead
        // of silently dropping it so a genuinely-torn yield is diagnosable.
        // This is best-effort recovery insurance, NOT the load-bearing path -
        // the first decoded frame independently promotes the phase.
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
        // P2 DISCONNECT REASON (always-live; a terminate is the rarest event). The
        // host-initiated terminate maps code 0 → clean host close, non-zero → host
        // error. A user stop / watchdog teardown latches its own reason at its own
        // site (StreamSession.stop / watchdog) BEFORE this fires, and the latch
        // keeps the FIRST concrete reason, so this only fills in a host-side cause.
        TelemetryCounters.shared.p2.setDisconnectReason(code == 0 ? .hostClosedClean : .hostError)
        let bridge = StreamBridgeContext.current
        // DON'T unconditionally yield `.connectionTerminated` to the UI here. The
        // session classifies the terminate: a recoverable host close on a LIVE
        // session (Sunshine restarting across a lock / secure-desktop switch, or
        // a brief blip) drives a SILENT RECONNECT under the frozen frame and
        // yields `.reconnecting`; only a fatal/give-up terminate yields
        // `.connectionTerminated`. `handleHostTerminate` owns the input-ready
        // flip and the teardown. If there's somehow no session, fall back to the
        // old behavior so a terminate is never swallowed.
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
