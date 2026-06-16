//
//  StreamSession+Start.swift
//
//  The session start path: pair/verify → launch/resume → build the backend
//  config → stand up the window/decoder/input subsystems → publish the event
//  stream + bridge → start the connection → arm the watchdogs/timers. Split out
//  of StreamSession.swift to keep that file under the length limit; see that
//  file for the actor's stored state and the callback lifetime contract.
//
//  The phase-by-phase setup blocks that don't touch the start() defers (build
//  the backend config, log it, stand up the subsystems on the main actor, wire
//  the per-subsystem backends) are pure-moved into private helpers below so the
//  orchestrating start() stays readable; behavior is identical to the prior
//  inline form.
//

import Foundation
import AppKit
import os

extension StreamSession {

    // MARK: Public API

    /// Start a stream. Returns an AsyncStream of events the caller can consume
    /// to drive UI (connecting / streaming / reconnecting / disconnected).
    public func start(
        server: ServerInfo,
        config: StreamConfig,
        appID: Int,
        quitHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultQuit },
        statsHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultStats },
        bookmarkHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultBookmark },
        initialStatsOverlay: Bool = false,
        initialStatsCorner: StatsOverlayCorner = .topLeft,
        // Provider closure rather than a captured Set so toggling rows in
        // Settings mid-stream takes effect on the next 1Hz overlay tick.
        // Default = everything except audio, which matches the prior
        // "show all rows" surface for callers that haven't migrated to
        // the preset model yet.
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind> = {
            StatsOverlayDefaults.extendedRows
        },
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds = { .default },
        controllerQuitChordProvider: @escaping @MainActor () -> ControllerQuitChord = { .none },
        customControllerChordProvider: @escaping @MainActor () -> Set<ControllerButton> = { [] },
        onBackgroundedChanged: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> AsyncStream<StreamEvent> {
        guard !isStreaming else {
            throw StreamError.sessionFailed(-1)
        }
        isStreaming = true

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
        // `.userInitiated` + `.latencyCritical` are the options that actually
        // defeat App Nap throttling while unfocused / on a second display; the
        // two `*SleepDisabled` flags keep the screen lit for controller-only
        // sessions (see the field doc above for the full rationale).
        powerAssertion = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated, .latencyCritical,
                .idleDisplaySleepDisabled, .idleSystemSleepDisabled
            ],
            reason: "Glimmer is streaming")
        // Release the assertion on any UNSUCCESSFUL exit from start() - an early
        // throw (pairing failure, host unreachable) happens before stop() is
        // reachable, so without this the Mac would stay awake forever after a
        // failed connect. On success this is skipped and stop() owns the
        // release; on the startConnection-failure path stop() runs first and
        // nils the token, so this defer's release is a safe no-op.
        var startHandedOff = false
        defer {
            if !startHandedOff, let assertion = self.powerAssertion {
                ProcessInfo.processInfo.endActivity(assertion)
                self.powerAssertion = nil
            }
        }

        // --- 1) Pair or verify pairing ---------------------------------
        var serverInfo = server
        let network = NetworkClient(server: serverInfo)
        self.network = network
        // Invalidate the per-session URLSession on any exit where stop() can't
        // own it. URLSession retains its delegate (and connection pool +
        // queues) until explicitly invalidated, so a pre-bridge throw - the
        // serverinfo fetch, the pairing check, or launchWithBusyRecovery below
        // - that just dropped the actor leaked one ephemeral URLSession +
        // TLSDelegate PER ATTEMPT, including every error-banner Retry against
        // a sleeping host. On the success path stop() owns the shutdown (and
        // nils `network`, making the helper a no-op); on the startConnection-
        // failure path stop() has already run inside connectBackend's catch,
        // with the same result. shutdown() is invalidateAndCancel -
        // idempotent, so the belt-and-braces overlap with stop() is harmless.
        defer { if !startHandedOff { shutdownOrphanedNetwork() } }
        serverInfo = try await network.fetchServerInfo()
        // swiftlint:disable:next line_length
        log.info("fetchServerInfo done: pairStatus=\(String(describing: serverInfo.pairStatus), privacy: .public) currentGame=\(serverInfo.currentGameID) httpsPort=\(serverInfo.httpsPort) codecSupport=0x\(String(serverInfo.serverCodecSupport.rawValue, radix: 16))")
        if serverInfo.pairStatus != .paired {
            throw StreamError.pairingFailed("Host is not paired. Use the pair sheet first.")
        }

        // --- 2) Decide launch vs. resume vs. quit-then-launch -----------
        // GameStream hosts only run one session at a time. If a previous
        // attempt left the host busy (orphan session) or someone else is
        // streaming, /launch will fail. Route based on the host's currentgame:
        //   0                  → free, /launch
        //   == our appID       → still ours, /resume
        //   != our appID       → someone else's session, /cancel + /launch
        // Try the obvious path first (launch if idle, resume if our app is
        // already going), then fall back through busy-recovery if the host
        // disagrees. `<currentgame>` parsing is inconsistent across hosts so
        // we treat it as a hint, not gospel.
        let launch: LaunchResponse = try await launchWithBusyRecovery(
            network: network, appID: appID, config: config,
            hintCurrentGame: serverInfo.currentGameID
        )

        // --- 3) Build the backend stream config -------------------------
        let backendConfig = makeBackendConfig(config: config, launch: launch)

        // Diagnostic so "are we actually streaming at the right refresh rate"
        // is a one-line question. requestedFps is what we tell Sunshine;
        // displayMaxFps is what macOS thinks the panel can do right now
        // (NSScreen.maximumFramesPerSecond reflects the panel's CURRENT
        // refresh rate, not its capability - if the user has it at 120Hz
        // in System Settings → Displays, this reads 120 even on a 240Hz
        // panel). The stats overlay (⌃⌥S) reports the actual delivered
        // FPS once frames flow.
        await logStreamConfig(backendConfig)

        // --- 4) Set up the window + decoder + input (MainActor) BEFORE the
        // connection so the decoder's VideoSink has an
        // AVSampleBufferDisplayLayer to enqueue into the moment frames
        // start arriving.
        let setup: (StreamWindow, InputForwarder, VideoDecoder) =
            await buildStreamSubsystems(StreamSetupOptions(
                config: config,
                initialStatsOverlay: initialStatsOverlay,
                initialStatsCorner: initialStatsCorner,
                quitHotkeyProvider: quitHotkeyProvider,
                statsHotkeyProvider: statsHotkeyProvider,
                bookmarkHotkeyProvider: bookmarkHotkeyProvider,
                controllerQuitChordProvider: controllerQuitChordProvider,
                customControllerChordProvider: customControllerChordProvider,
                onBackgroundedChanged: onBackgroundedChanged))
        self.window = setup.0
        self.input = setup.1
        self.videoDecoder = setup.2

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
            if !lifecycleOK, self.bridgePtr != nil {
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
        let stream = makeEventStream(bridge: bridge)

        // Inject the streaming engine into the input forwarder + decoder, and
        // wire the quit/stats/bookmark/HDR/first-frame callbacks now that the
        // bridge + its event continuation exist.
        await wireSubsystemBackends(setup: setup, bridge: bridge, backend: self.backend)

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
        await armSessionTimers(
            statsRowsProvider: statsRowsProvider,
            statsThresholdsProvider: statsThresholdsProvider,
            decoder: setup.2)

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

    /// Shut down + drop the per-session NetworkClient when no stop() owns it
    /// (the pre-bridge throw paths in start() - see the defer there). No-op
    /// when stop() already ran: it shuts the client down and nils the field.
    /// NetworkClient is an actor and this helper runs from a synchronous
    /// `defer`, so the shutdown hops into a detached task. Fire-and-forget is
    /// correct: the client is ORPHANED (no consumer can reach it once the
    /// field is nil'd synchronously below), and shutdown() only closes its
    /// socket + invalidates its URLSession.
    private func shutdownOrphanedNetwork() {
        guard let net = network else { return }
        network = nil
        Task.detached { await net.shutdown() }
    }

    /// Build the session bridge (weak refs to every subsystem + self so a
    /// torn-down subsystem just makes its callbacks no-op), retain it with a +1
    /// (stored in `bridgePtr`) that `stop()` is responsible for releasing, and
    /// publish it as `StreamBridgeContext.current` so the native stack's
    /// connection callbacks + HDR-active hook resolve through it. Returns the
    /// bridge; the caller's leak-safety defer owns the throw-without-stop path.
    private func publishBridge(
        setup: (StreamWindow, InputForwarder, VideoDecoder)
    ) -> StreamBridgeContext {
        let bridge = StreamBridgeContext(
            session: self,
            videoDecoder: setup.2,
            audioDecoder: audioDecoder,
            inputForwarder: setup.1
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
    ) -> AsyncStream<StreamEvent> {
        AsyncStream<StreamEvent> { continuation in
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

    /// Build the value type the backend protocol consumes from the user-facing
    /// `StreamConfig` + the launch handshake. The actual stream-configuration
    /// fill (the remoteInputAesKey/Iv copy + the SCM_* handling) lives in
    /// NativeBackend.startConnection; this just builds the value type.
    /// gcmKey/gcmKeyId are the 16-byte per-session AES key + IV-id from the
    /// launch handshake.
    func makeBackendConfig(
        config: StreamConfig, launch: LaunchResponse
    ) -> BackendStreamConfig {
        BackendStreamConfig(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: Int32(config.fps),
            bitrate: Int32(config.bitrateKbps),
            packetSize: Int32(config.packetSize),
            streamingRemotely: config.remoteness.cValue,
            audioConfiguration: config.audio.cValue,
            supportedVideoFormats: config.videoFormats.rawValue,
            clientRefreshRateX100: Int32(config.fps * 100),
            colorSpace: config.colorSpace.cValue,
            colorRange: config.colorRange.cValue,
            encryptionFlags: config.encryption.encryptionFlags,
            remoteInputAesKey: [UInt8](launch.gcmKey),
            remoteInputAesIv: [UInt8](launch.gcmKeyId))
    }

    /// Emit the one-line stream-config diagnostic on the main actor (it reads
    /// NSScreen). See the call site for what requestedFps vs displayMaxFps mean.
    @MainActor
    private func logStreamConfig(_ cfgSnapshot: BackendStreamConfig) {
        let screen = NSScreen.main
        let displayMaxFps = screen?.maximumFramesPerSecond ?? -1
        let displayName = screen?.localizedName ?? "n/a"
        // swiftlint:disable:next line_length
        self.log.info("Stream config: \(cfgSnapshot.width, privacy: .public)x\(cfgSnapshot.height, privacy: .public)@\(cfgSnapshot.fps, privacy: .public) bitrate=\(cfgSnapshot.bitrate, privacy: .public) packetSize=\(cfgSnapshot.packetSize, privacy: .public) audio=\(cfgSnapshot.audioConfiguration, privacy: .public) videoFormats=0x\(String(cfgSnapshot.supportedVideoFormats, radix: 16), privacy: .public) refreshRateX100=\(cfgSnapshot.clientRefreshRateX100, privacy: .public) colorSpace=\(cfgSnapshot.colorSpace, privacy: .public) colorRange=\(cfgSnapshot.colorRange, privacy: .public) encryption=0x\(String(cfgSnapshot.encryptionFlags, radix: 16), privacy: .public) remote=\(cfgSnapshot.streamingRemotely, privacy: .public) display=\(displayName, privacy: .public) displayMaxFps=\(displayMaxFps, privacy: .public)")
        Diag.notice("Stream config: \(cfgSnapshot.width)x\(cfgSnapshot.height)@\(cfgSnapshot.fps), "
            + "\(cfgSnapshot.bitrate / 1000) Mbps, display \(displayName)", "Stream")
    }

    /// Open the connect-flow signpost interval, anchor the connect telemetry,
    /// attach the native engine's Swift sinks, and start the connection. On
    /// startConnection failure this cancels the host session and tears the
    /// session down (so the next attempt isn't blocked) before throwing - the
    /// caller suppresses its leak-safety defer because stop() already released
    /// the bridge retain.
    func connectBackend(
        serverInfo: ServerInfo,
        launch: LaunchResponse,
        backendConfig: BackendStreamConfig,
        setup: (StreamWindow, InputForwarder, VideoDecoder),
        network: NetworkClient,
        duringReconnect: Bool = false
    ) async throws {
        let backendServer = BackendServerInfo(
            address: serverInfo.address,
            appVersion: serverInfo.appVersion ?? "7.1.451.0",
            gfeVersion: serverInfo.gfeVersion ?? "3.23.0.74",
            rtspSessionUrl: launch.sessionURL,
            // RAW SCM_* bitmask from /serverinfo - see the landmine note in
            // StreamProtocol.SCM_*.
            serverCodecModeRaw: Int32(serverInfo.serverCodecModeRaw))

        // Open the `ConnectFlow` interval right before startConnection so the
        // timeline captures the full handshake (RTSP negotiation + control
        // channel + ENet setup). Closed in `deliver(.connectionEstablished)` on
        // success, or in `stop()` on failure. The interval ID was created up
        // front so the close side can address it even if the actor's strong-ref
        // to the state has been cleared.
        connectFlowState = OSSignposter.network.beginInterval(
            "ConnectFlow",
            id: connectFlowSignpostID,
            "host=\(serverInfo.address, privacy: .public)")

        // SESSION-SCOPED telemetry reset + P2 CONNECT-HANDSHAKE anchor HERE -
        // before startConnection runs the handshake whose stage edges fill the
        // legs AND whose receivers latch the one-shot audio TTF (the exporter
        // starts later; resetting there raced warm-host audio - see
        // anchorTelemetryConnectStart). The host address feeds the stream-route
        // probe (stream_link). Always-live; no-op-cheap off.
        // Latch the server name for the telemetry `host` label here, where
        // serverInfo is in scope (the exporter is built later, in
        // armSessionTimers, which doesn't carry serverInfo).
        telemetryServerName = serverInfo.serverName.isEmpty ? serverInfo.address : serverInfo.serverName
        anchorTelemetryConnectStart(hostAddress: serverInfo.address)

        // Wire the native engine's Swift sinks. The VideoDecoder is injected as
        // a `VideoSink` (its methods are nonisolated, so the native receive
        // thread can call them directly) and the AudioDecoder as a
        // `NativeAudioSink` (the receiver pings + receives audio on one socket
        // and feeds opus bytes here).
        backend.attachVideoSink(setup.2)
        backend.attachAudioSink(audioDecoder)

        do {
            try backend.startConnection(server: backendServer, config: backendConfig)
        } catch {
            // startConnection failed (RTSP handshake, control connect, etc., or
            // the native backend's LI_ERR_UNSUPPORTED stub). We've already told
            // the host to /launch, so it now thinks a session is active - clean
            // up so the next attempt isn't blocked.
            let code: Int32
            if case let StreamError.sessionFailed(failureCode) = error {
                code = failureCode
            } else {
                code = -1
            }
            log.error("startConnection failed with \(code) - cancelling host session")
            // On a RECONNECT attempt, DON'T run the full stop() - that would
            // close the window, drop the decoder (blanking the frozen frame),
            // and finish the event stream (bouncing to the launcher), defeating
            // the whole stall→resume. Just cancel the failed launch on the host
            // and throw so the reconnect driver counts the miss and retries (or
            // gives up to a real teardown after the cap). The initial-connect
            // path keeps its original behavior: latch connect-failed + stop().
            if duringReconnect {
                try? await network.cancel()
                throw StreamError.sessionFailed(code)
            }
            // P2 DISCONNECT REASON: the connection never reached established -
            // latch connect-failed before the teardown so the cause is attributed
            // to the handshake, not the host terminate that may follow.
            noteTelemetryDisconnect(.connectFailed)
            try? await network.cancel()
            await stop()
            throw StreamError.sessionFailed(code)
        }
    }

    /// Arm the post-connection timers: the 2 Hz stats-overlay updater, the
    /// frame/present watchdogs + present-metric instrumentation, and the opt-in
    /// telemetry exporter. Called once the connection is up.
    private func armSessionTimers(
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind>,
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds,
        decoder: VideoDecoder
    ) async {
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
        await startStatsOverlayTimer(
            statsRowsProvider: statsRowsProvider,
            statsThresholdsProvider: statsThresholdsProvider)
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

        // Opt-in telemetry exporter (default OFF; no-op + zero alloc off).
        // Synchronous - no suspension between this guard and the build - so
        // the exporter can never be constructed after a teardown that already
        // ran stopTelemetryExporter() (the leaked-listener / wedged-port /
        // two-exporter EnvSignal race class).
        guard isStreaming, !stopInProgress else { return }
        // `host` label = the Sunshine server, latched at the connect anchor.
        startTelemetryExporter(decoder: decoder, serverName: telemetryServerName)
    }
}
