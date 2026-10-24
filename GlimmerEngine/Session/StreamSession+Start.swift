// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Shared startup verifies the PC, launches, adopts prepared media and arms the existing timers.
// Native preparation runs on MainActor; pending preparation belongs to the same teardown owner.

import Foundation
import os

extension StreamSession {

    // MARK: Shared startup

    /// Start a stream. Returns an AsyncStream of events the caller can consume
    /// to drive UI (connecting / streaming / reconnecting / disconnected).
    package func start(server: ServerInfo, request config: StreamRequest, appID: Int,
                       cachedNetwork: NetworkClient? = nil,
                       makeSampler: (@Sendable () -> RttSampler)? = nil,
                       prepare: @escaping @MainActor @Sendable (Int) throws -> SessionMedia) async throws
        -> AsyncStream<StreamEvent>? {
        guard !publicTerminal, !isStreaming, !stopInProgress else {
            throw StreamError.sessionFailed(-1)
        }
        teardown = SharedTeardown()
        stopCause = nil
        ownsHostSession = false
        isStreaming = true
        // Capture launch and teardown even when Cancel prevents the backend handshake.
        services.startLog()

        // Capture the inputs a SILENT RECONNECT needs to rebuild the connection
        // in place (see StreamSession+Reconnect.swift): the original server (for
        // a fresh NetworkClient + handshake), the requested mode, and the app id.
        self.reconnectServer = server
        self.reconnectConfig = config
        self.reconnectAppID = appID

        // Keep the Mac (and its display) awake AND opt OUT of App Nap for the
        // whole session. Begun here so a slow handshake can't let the machine
        // sleep before the first frame; released in `stop()`. Idempotent against
        // the `!isStreaming` guard above, so we never stack assertions.
        beginPowerAssertion()
        // Release the assertion on any UNSUCCESSFUL exit from start() - an early
        // throw (pairing failure, host unreachable) happens before stop() is
        // reachable, so without this the Mac would stay awake forever after a
        // failed connect. On success this is skipped and stop() owns the
        // release; on the startConnection-failure path stop() runs first and
        // nils the token, so this defer's release is a safe no-op.
        var startHandedOff = false
        defer {
            if !startHandedOff { endPowerAssertion() }
        }

        // --- 1) Pair or verify pairing ---------------------------------
        let network = cachedNetwork ?? makeNetwork(server)
        self.network = network
        // Sample latency from the click, on a host that is still idle. The gate
        // bands on the samples taken before /launch: once the game starts and
        // the display switches, handshakes read 3-7x the path's true RTT.
        let rttSampler = makeSampler?()
        // A throw below must still stop its loop, or it keeps probing the PC.
        defer { _ = rttSampler?.harvest() }
        let serverInfo: ServerInfo
        if cachedNetwork != nil {
            serverInfo = await network.server
            if serverInfo.isRealGFE { throw StreamError.gameStreamHost }
            guard serverInfo.pairStatus == .paired, serverInfo.serverCertPEM != nil else {
                throw NetworkClient.notPaired(server.serverName)
            }
        } else {
            serverInfo = try await fetchAndVerifyServerInfo(network: network, pcName: server.serverName)
        }
        try checkAttempt()
        await rttSampler?.awaitPreLaunchWindow()
        try checkAttempt()
        rttSampler?.markLaunch()

        let launch = try await launchWithDeadline(network: network, appID: appID, config: config, info: serverInfo)
        try checkAttempt()
        takeoverAuthorized = false
        await network.setRequestDeadline(nil)
        try checkAttempt()

        if publicMedia != nil { try launch.validateSessionKey() }

        // --- 3) Build the backend stream config -------------------------
        let backendConfig = makeBackendConfig(
            config: config, launch: launch, server: serverInfo,
            rtt: rttSampler?.harvest(), rttPreLaunch: rttSampler?.usesPreLaunchWindow ?? false)

        await services.logConfig(backendConfig)
        let setup = try await buildAndAdoptSubsystems(config: config, bitrate: Int(backendConfig.bitrate), prepare: prepare)

        if isTearingDown { throw CancellationError() }

        // --- 4a) Build + publish the session bridge (see publishBridge): weak
        // refs to every subsystem + self so a torn-down subsystem just makes its
        // callbacks no-op, with a +1 retain (stored in bridgePtr) that `stop()`
        // is responsible for releasing.
        //
        // Lifetime safety net: the +1 retain pins the bridge for the whole
        // session even if every weak ref it holds nils out. If any step between
        // publishBridge and a successful startConnection throws - which is not
        // the case today, but would silently leak the bridge if a future edit
        // slips a `try await` through this region - the defer below mops up.
        // `lifecycleOK` flips to true once `stop()` (success or failure path)
        // has run, so the defer only fires on the throw-without-stop scenario.
        let bridge = publishBridge(setup: setup)
        var lifecycleOK = false
        defer {
            // If we exit by `throw` without having handed the +1 retain off
            // to stop()'s teardown, release it here.
            if !lifecycleOK { releaseUnhandedBridgeRetain() }
        }

        // --- 4b) Build the event AsyncStream *before* startConnection.
        //
        // The native stack can fire stageStarting / stageComplete while the
        // RTSP / control-connect / launch handshake runs inside
        // startConnection; building the stream after startConnection would drop
        // those early stage events. The bridge is published first, so the
        // native callback path resolves through
        // `StreamBridgeContext.current?.eventContinuation` and yields directly
        // without an actor hop.
        bridge.beginAttempt(attemptID)
        let stream = makeEventStream(bridge: bridge)
        publicInput?.rebind(to: backend, attempt: attemptID)

        // Inject the streaming engine into the input forwarder + decoder, and
        // wire the quit/stats/bookmark/HDR/first-frame callbacks now that the
        // bridge + its event continuation exist.
        await wireSubsystemBackends(setup: setup, bridge: bridge, backend: self.backend, attempt: attemptID)

        // --- 5) Start the connection through the backend ----------------
        do {
            try await connectBackend(
                serverInfo: serverInfo, launch: launch,
                backendConfig: backendConfig, setup: setup, network: network)
        } catch {
            // connectBackend already cancelled the host session and ran stop()
            // on the startConnection-failure path; stop() released the bridge
            // retain, so suppress the leak-safety defer before propagating.
            lifecycleOK = true
            throw error
        }

        // --- 6) Arm the stats-overlay timer, the watchdogs, and (if opted in)
        // the telemetry exporter now that the connection is up.
        await armSessionTimers(decoder: setup.video)

        // Event stream was built and bound to the bridge in step 4b so
        // synchronous stageStarting / stageComplete callbacks fired inside
        // startConnection had somewhere to yield. From here, the bridge's
        // +1 retain is owned across the connection lifetime; stop() will
        // release it. Mark the lifecycle complete so the leak-safety defer
        // doesn't double-release.
        lifecycleOK = true
        // Stream is live; hand ownership of the keep-awake assertion to stop().
        startHandedOff = true
        return stream
    }

    // MARK: Start helpers

    /// Keep the Mac and visible display awake during connection; stop() or
    /// start()'s failure defer ends the token.
    package func beginPowerAssertion() {
        services.beginActivity()
        activityHeld = true
    }

    package func endPowerAssertion() {
        guard activityHeld else { return }
        services.endActivity()
        activityHeld = false
    }

    package func refreshPowerAssertion() {
        guard isStreaming, !stopInProgress, activityHeld else { return }
        services.refreshActivity(videoDecoder?.presentSuppressed ?? false)
    }

    /// Step 1 of start(): fetch /serverinfo, stamp its launch sub-leg, log the handshake line, and
    /// refuse a GameStream or unpaired PC, named as the user knows it. A throw unwinds through
    /// start()'s power-assertion defer; the caller then awaits stop() for network cleanup.
    package func fetchAndVerifyServerInfo(network: NetworkClient, pcName: String) async throws -> ServerInfo {
        // Telemetry: stamp the /serverinfo leg (launch sub-leg, part of launch_path_ms).
        let serverinfoStart = Date()
        let serverInfo = try await fetchInitialServerInfo { try await network.fetchServerInfo() }
        ConnectTimingTelemetry.shared.recordLaunchLeg(
            serverinfoMs: Date().timeIntervalSince(serverinfoStart) * 1000.0)
        log.info("""
            fetchServerInfo done: pairStatus=\(String(describing: serverInfo.pairStatus), privacy: .public) \
            currentGame=\(serverInfo.currentGameID) httpsPort=\(serverInfo.httpsPort) \
            codecSupport=0x\(String(serverInfo.serverCodecSupport.rawValue, radix: 16))
            """)
        if serverInfo.isRealGFE { throw StreamError.gameStreamHost }
        if serverInfo.pairStatus != .paired { throw NetworkClient.notPaired(pcName) }
        return serverInfo
    }

    /// Stop must also cancel the first request, before a launch task exists to interrupt.
    package func fetchInitialServerInfo(
        operation: @escaping @Sendable () async throws -> ServerInfo
    ) async throws -> ServerInfo {
        let task = Task { try await operation() }
        initialServerInfoTask = task
        defer { if initialServerInfoTask == task { initialServerInfoTask = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Adopt prepared media on MainActor and measure that setup separately from network launch.
    /// Stop awaits an already-running factory so its native resources have exactly one cleanup owner.
    private func buildAndAdoptSubsystems(
        config: StreamRequest, bitrate: Int,
        prepare: @escaping @MainActor @Sendable (Int) throws -> SessionMedia) async throws -> SessionMedia {
        try checkAttempt()
        audioDecoder.setOutputMuted(config.playAudioOnHost)
        let buildStart = Date()
        let pending = Task { @MainActor in
            try Task.checkCancellation()
            return try prepare(bitrate)
        }
        mediaPreparation = pending
        defer { if mediaPreparation == pending, !stopInProgress { mediaPreparation = nil } }
        let setup = try await pending.value
        guard !isTearingDown else { throw CancellationError() }
        ConnectTimingTelemetry.shared.recordLaunchLeg(buildMs: Date().timeIntervalSince(buildStart) * 1000)
        self.presentation = setup.presentation
        self.input = setup.input
        adoptVideoDecoder(setup.video)
        return setup
    }

    package func adoptVideoDecoder(_ decoder: VideoDecoder) {
        videoDecoder = decoder
        refreshPowerAssertion()
    }

    /// Release the bridge's +1 retain on the throw-without-stop path (start()'s
    /// leak-safety defer). No-op when there is no retain to release - the
    /// success and backend-failure paths hand ownership to `stop()`, which nils
    /// `bridgePtr` itself, so this can never double-release.
    private func releaseUnhandedBridgeRetain() {
        guard self.bridgePtr != nil else { return }
        if StreamBridgeContext.current === self.bridge {
            StreamBridgeContext.current = nil
        }
        if let ptr = self.bridgePtr {
            Unmanaged<StreamBridgeContext>.fromOpaque(ptr).release()
        }
        self.bridgePtr = nil
        self.bridge = nil
        self.isStreaming = false
    }

    /// Build the session bridge (weak refs to every subsystem + self so a
    /// torn-down subsystem just makes its callbacks no-op), retain it with a +1
    /// (stored in `bridgePtr`) that `stop()` is responsible for releasing, and
    /// publish it as `StreamBridgeContext.current` so the native stack's
    /// connection callbacks + HDR-active hook resolve through it. Returns the
    /// bridge; the caller's leak-safety defer owns the throw-without-stop path.
    private func publishBridge(
        setup: SessionMedia
    ) -> StreamBridgeContext {
        let bridge = StreamBridgeContext(
            session: self,
            videoDecoder: setup.video,
            audioDecoder: audioDecoder, feedback: services.feedback,
            publicEvents: publicInput == nil ? nil : eventSource
        )
        let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()
        self.bridge = bridge
        self.bridgePtr = bridgePtr
        StreamBridgeContext.current = bridge
        return bridge
    }

    /// Build the event AsyncStream and bind its continuation to the bridge so
    /// the native callback path can yield directly without an actor hop. The
    /// `onTermination` attributes a reason-less consumer drop as
    /// `.consumerDropped` (a concrete reason already latched still wins).
    private func makeEventStream(
        bridge: StreamBridgeContext
    ) -> AsyncStream<StreamEvent>? {
        guard publicInput == nil else { return nil }
        return AsyncStream<StreamEvent> { continuation in
            bridge.eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                // The consumer's `for await` loop ended (or the stream was
                // otherwise dropped) - NOT an explicit user quit. Attribute it
                // as `.consumerDropped` so a reason-less teardown of a healthy
                // stream is distinguishable from a user quit in the scorecard.
                // (If a concrete reason already latched - host terminate /
                // watchdog / connect-fail - that one still wins; this only
                // labels the otherwise-default case.)
                Task { await self?.stop(cause: .consumerDropped) }
            }
        }
    }

    /// Emit the one-line stream-config diagnostic on the main actor (it reads
    /// NSScreen). See the call site for what requestedFps vs displayMaxFps mean.
    private func armSessionTimers(decoder: VideoDecoder) async {
        // ACTOR RE-ENTRANCY: re-check the lifecycle flags after EVERY await in
        // here. start() holds the actor's executor synchronously through
        // backend.startConnection (a semaphore wait, up to 30s on a slow
        // handshake), so a quit pressed mid-"Connecting..." enqueues stop()
        // behind it - and that queued stop() lands at this function's FIRST
        // suspension (actors are re-entrant at await boundaries). stop()
        // flips isStreaming/stopInProgress synchronously before its own first
        // await, so a guard evaluated ON the actor between awaits reliably
        // observes the teardown. Without these, the remainder of this
        // function re-armed repeating watchdog timers and built a whole
        // TelemetryExporter AFTER stop() already ran - nothing ever stopped
        // them again (the next stop() refuses on `guard isStreaming`), so the
        // timers and the exporter's port listener leaked for process
        // lifetime. Ordering for the steps that DO run is safe: each arm
        // block is enqueued on the MainActor before this actor can resume, so
        // a stop() that starts after a passed guard enqueues its timer-
        // invalidation block BEHIND that arm block and sweeps it.
        guard isStreaming, !stopInProgress else { return }
        // The stats-overlay update timer. 2 Hz is deliberate - text updates
        // faster than that are unreadable, and at this rate the per-tick cost
        // (one snapshot read, one RTT-estimate read, one CATextLayer string
        // assignment) is negligible. The timer is torn down at the very top of
        // `stop()` so it never outlives the connection the RTT estimate requires.
        await presentation?.startStats()
        guard isStreaming, !stopInProgress else { return }
        await startFrameWatchdog()
        guard isStreaming, !stopInProgress else { return }
        // Present-path self-heal watchdog + NOTICE instrumentation. The frame
        // watchdog above gates on VT decode output, which is structurally blind
        // to a stall DOWNSTREAM of decode (a stopped CADisplayLink or a
        // latched-false pacer `due` gate - the 4K240 HDR hard-freeze).
        // These two cover that gap: the watchdog self-heals the present path so
        // it can never hard-freeze, and the metric timer logs the present/decode
        // liveness so a recurrence is pinpointed from the log alone.
        await startPresentWatchdog()
        guard isStreaming, !stopInProgress else { return }
        await startPresentMetricTimer()

        // The native snapshot crosses MainActor; the exporter rechecks its lifecycle fence afterward.
        guard isStreaming, !stopInProgress else { return }
        // `host` label = the Sunshine server, latched at the connect anchor.
        await startTelemetryExporter(decoder: decoder, serverName: telemetryServerName)

        // Arm the sleep/wake fast-reconnect observers now the stream is live;
        // torn down in stop(). Only armed during a live stream (see +Wake).
        guard isStreaming, !stopInProgress else { return }
        armWakeObservers()
    }
    @MainActor
    package func wireSubsystemBackends(
        setup: SessionMedia, bridge: StreamBridgeContext,
        backend: any StreamingBackend, attempt: UUID) {
        setup.input.setBackend(backend)
        setup.video.setBackend(backend)
        wireMediaCallbacks(setup: setup, bridge: bridge, attempt: attempt)
    }

    @MainActor
    package func wireMediaCallbacks(setup: SessionMedia, bridge: StreamBridgeContext, attempt: UUID) {
        setup.video.onHDRActiveChanged = { [weak bridge] active in bridge?.emit(.hdrActive(active), attempt: attempt) }
        let firstFrame = setup.presentation.firstFrame
        setup.video.onFirstDecodedFrame = { [weak bridge] in
            guard bridge?.currentAttempt == attempt else { return }
            firstFrame()
            bridge?.emit(.firstFrame, attempt: attempt)
        }
    }
}
