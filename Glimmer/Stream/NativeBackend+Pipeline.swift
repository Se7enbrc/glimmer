//
//  NativeBackend+Pipeline.swift
//
//  The async native connection pipeline: run() and its per-stage helpers (RTSP
//  handshake, ENet control CONNECT/START_A/B, and the audio/video stage bring-up
//  that follows "connected"). Split out of NativeBackend.swift to keep each unit
//  focused; see that file for the backend's stored state and lifecycle.
//

import Foundation
import Network

extension NativeBackend {
    /// The async native pipeline. Fires ConnectionEvents-equivalent StreamEvents
    /// + Diag at each stage and throws (after stageFailed) on any failure.
    func run(server: BackendServerInfo, config: BackendStreamConfig) async throws {
        let events = NativeConnectionEvents()

        if server.rtspSessionUrl.lowercased().contains("rtspenc://") {
            Diag.info("native backend: encrypted RTSP (rtspenc://) - sealing messages", Self.logCategory)
        }

        // Resolve the host address ONCE, here, before any stage (issue #70).
        // A hostname/FQDN used to ride through RTSP and ENet control (whose C
        // connect paths run their own getaddrinfo) and then kill BOTH RTP
        // receivers at makeSockaddr - "CONNECTED" followed by an instant,
        // 100%-reproducible video failure whenever a host was added by name.
        // Resolving at the pipeline edge gives every stage the same IP literal,
        // keeps DNS off the socket-setup paths, and fails a bad name in one
        // place with an error that says so.
        guard let host = UdpPinger.resolveHost(server.address) else {
            Diag.error("native backend: could not resolve host \"\(server.address, privacy: .private)\" "
                + "- check the name resolves (DNS/mDNS) from this Mac", Self.logCategory)
            throw EnetError.socketFailure(
                "could not resolve host \"\(server.address)\"")
        }
        if case .name = NWEndpoint.Host(server.address) {
            Diag.notice("native backend: resolved \"\(server.address, privacy: .private)\" → \(host, privacy: .private) "
                + "(one resolve for all channels)", Self.logCategory)
        }

        // The audio ping can start MID-handshake (rtsp.onAudioPortNegotiated fires
        // at SETUP-audio time, before PLAY - moonlight's
        // notifyAudioPortNegotiationComplete ordering), so the audio receiver may
        // be live before any of these stages return. Wrap everything from the
        // handshake onward so a failure in ANY later step (SETUP video/control,
        // ANNOUNCE, PLAY, ENet control, video bring-up) tears down the audio
        // ping/socket cleanly - run() only rethrows; the synchronous bridge in
        // startConnection does NOT auto-call stopConnection on a thrown error.
        do {
            let handshake = try await performRtspStage(server: server, config: config,
                                                       host: host, events: events)

            // Capture the host feature flags for the input-uplink gating (touch).
            withState { featureFlags = handshake.featureFlags }

            try await performControlStage(handshake: handshake, config: config,
                                          host: host, events: events)

            // Control is up: input can seal/send, and the batcher coalesces send*.
            // Like InputStream.c's initialized edge, both become ready together;
            // a stop that already took its snapshot must not revive either.
            guard adoptWhileConnecting({
                didConnect = true
                inputReady = true
                if let enet = enetChannel {
                    inputBatcher = InputBatcher(enet: enet)
                }
            }) else { throw EnetError.interrupted }
            Diag.notice("native backend: CONNECTED (RTSP + ENet control + START_A/B complete). "
                + "Native input uplink ready. Starting native video receive.", Self.logCategory)

            try await startVideoStage(handshake: handshake, config: config, host: host, events: events)

            // Audio receive after the video ping (moonlight's control, video,
            // audio order): the host answers that ping with its first frame, so
            // the 35-130 ms decoder and engine bring-up no longer delays it.
            startAudioReceive(handshake: handshake, config: config, server: server, host: host)
        } catch {
            // Any failure after the audio ping may have started must not leak the
            // ping thread/socket (and recv loop, if it reached startAudioReceive).
            tearDownAudio()
            throw error
        }

        try publishConnectionStarted { events.connectionStarted() }

        // startConnection() returns here (success); the control loop + video
        // receive run in detached tasks until stop()/interrupt(). This mirrors
        // LiStartConnection returning 0 while the engine's threads keep running.
    }

    func publishConnectionStarted(_ publish: () -> Void) throws {
        // Publish success under the stop latch so cancellation cannot win
        // between the final check and the connection-established event.
        guard adoptWhileConnecting(publish) else { throw EnetError.interrupted }
    }

    /// Tear down + drop the audio receiver (idempotent). Used on a handshake/
    /// control/video-stage failure so the mid-handshake audio ping never leaks.
    func tearDownAudio() {
        let audio = withState { () -> RtpAudioReceiver? in
            let r = audioReceiver
            audioReceiver = nil
            return r
        }
        audio?.stop()
    }

    /// Bring up the video flow (ping + RTP receive → FEC → depacketize →
    /// VideoSink) and the persistent ENet control loop. Detached tasks own the
    /// long-lived loops so `run()` can return "connected".
    func startVideoStage(
        handshake: RtspHandshakeResult, config: BackendStreamConfig,
        host: NWEndpoint.Host, events: NativeConnectionEvents
    ) async throws {
        events.stageStarting("video stream initialization")

        guard let sink = withState({ videoSink }) else {
            Diag.error("native backend: no video sink injected; cannot start video", Self.logCategory)
            events.stageFailed("video stream initialization", code: -1)
            throw StreamError.sessionFailed(-1)
        }
        guard let enet = withState({ enetChannel }) else {
            events.stageFailed("video stream initialization", code: -1)
            throw StreamError.sessionFailed(-1)
        }

        wireVideoControl(enet: enet, events: events)
        guard wireControllerFeedback(enet: enet, events: events) else { throw EnetError.interrupted }
        if checkInterrupted() {
            enet.interrupt()
            throw EnetError.interrupted
        }

        // Decoder setup() BEFORE first frame, then start() once.
        let videoFormat = handshake.negotiatedVideoFormat
        if checkInterrupted() { throw EnetError.interrupted }
        let setupResult = sink.setup(
            videoFormat: videoFormat, width: config.width, height: config.height,
            redrawRate: config.fps)
        guard setupResult == 0 else {
            Diag.error("native backend: video sink setup failed (\(setupResult))", Self.logCategory)
            events.stageFailed("video stream initialization", code: setupResult)
            throw StreamError.sessionFailed(setupResult)
        }
        sink.start()

        let receiver = makeVideoReceiver(handshake: handshake, config: config, host: host, sink: sink, enet: enet)
        receiver.onReceiveFailed = { [weak self] in
            events.connectionTerminated(code: -1)
            self?.stopConnection()
        }
        guard adoptWhileConnecting({ videoReceiver = receiver }) else {
            // Stop may have cleaned this sink before setup/start finished.
            // Until adoption succeeds, this stage owns the final cleanup.
            sink.stop()
            sink.cleanup()
            events.stageFailed("video stream initialization", code: -4)
            throw EnetError.interrupted
        }

        do {
            try await receiver.start()
        } catch {
            Diag.error("native backend: video receiver start failed: \(error, privacy: .private)", Self.logCategory)
            events.stageFailed("video stream initialization", code: -1)
            throw StreamError.sessionFailed(-1)
        }
        events.stageComplete("video stream initialization")

        // The ENet control loop gets a DEDICATED userInteractive Thread, not the pool:
        // its tick is a blocking semaphore wait (runControlLoopSync) that an IDR/RFI
        // request ends early. No strong ref to self; exits on interrupt or disconnect.
        let controlThread = Thread { [weak enet] in
            enet?.runControlLoopSync()
        }
        controlThread.qualityOfService = .userInteractive
        controlThread.name = "Glimmer.enetControl"
        controlThread.start()
    }

    private func wireVideoControl(enet: EnetControlChannel, events: NativeConnectionEvents) {
        // Wire the host TERMINATION → connectionTerminated + teardown.
        enet.onTerminated = { [weak self] code in
            Diag.error("native backend: host terminated session (code \(code))", Self.logCategory)
            events.connectionTerminated(code: code)
            self?.stopConnection()
        }

        // HDR engagement pulls mastering metadata through this channel;
        // without it a 10-bit stream renders as washed-out SDR.
        enet.onHdrMode = { [weak self] enabled in
            guard let self,
                  let decoder = self.withState({ self.videoSink }) as? VideoDecoder else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { decoder.setHDR(enabled: enabled) } }
        }
    }

    private func makeVideoReceiver(
        handshake: RtspHandshakeResult, config: BackendStreamConfig,
        host: NWEndpoint.Host, sink: VideoSink, enet: EnetControlChannel
    ) -> VideoRtpReceiver {
        VideoRtpReceiver(
            host: host,
            videoPort: handshake.videoPort,
            pingPayload: handshake.videoPingPayload,
            packetSize: VideoDecryptor.packetSize(
                Int(config.packetSize), encryptionFeaturesEnabled: handshake.encryptionFeaturesEnabled),
            bitrateKbps: Int(config.bitrate),
            negotiatedVideoFormat: handshake.negotiatedVideoFormat,
            encryptionFeaturesEnabled: handshake.encryptionFeaturesEnabled,
            aesKey: config.remoteInputAesKey,
            colorSpace: config.colorSpace,
            sink: sink,
            requestIdr: { [weak enet] in enet?.requestIdrFrame() },
            invalidateReferenceFrames: { [weak enet] from, to in
                enet?.invalidateReferenceFrames(from: from, to: to)
            })
    }

    /// Publish teardown and enqueue activation under the stop latch, so a
    /// stopped channel cannot miss its cleanup or activate controller state.
    func wireControllerFeedback(enet: EnetControlChannel, events: NativeConnectionEvents) -> Bool {
        adoptWhileConnecting {
            installControllerFeedback(enet: enet, events: events)
            ControllerHaptics.shared.streamActivated()
            ControllerMotion.shared.streamActivated(backend: self)
        }
    }

    private func installControllerFeedback(enet: EnetControlChannel, events: NativeConnectionEvents) {
        // Activation hops through main before reaching the haptics queue.
        // Teardown must take the same route so quiescing always follows it.
        // Motion already uses one main-queue hop for both lifecycle edges.
        enet.onTeardown = {
            DispatchQueue.main.async {
                ControllerHaptics.shared.stopAll(reason: "stream teardown")
            }
            ControllerMotion.shared.stopAll(reason: "stream teardown")
        }
        // Feedback stays off the receive thread; actuators coalesce updates.
        // Teardown parks motors and motion because a dead PC cannot clear them.
        enet.onRumble = { controllerNumber, lowFreq, highFreq in
            events.rumble(controller: controllerNumber, lowFreq: lowFreq, highFreq: highFreq)
        }
        // Advertised caps gate trigger rumble and RGB LED feedback; trigger
        // motors share rumble's teardown, while the light needs no parking.
        enet.onRumbleTriggers = { controllerNumber, left, right in
            events.rumbleTriggers(controller: controllerNumber, left: left, right: right)
        }
        enet.onSetRgbLed = { controllerNumber, red, green, blue in
            events.setControllerLED(controller: controllerNumber, r: red, g: green, b: blue)
        }
        enet.onSetPlayerLeds = { controllerNumber, solid, flashing in
            events.setPlayerLEDs(controller: controllerNumber, solid: solid, flashing: flashing)
        }
        // Motion reports use the existing input batcher; the sampler hops to
        // main and its uplink is armed only while this stream can still start.
        enet.onSetMotionEvent = { controllerNumber, motionType, reportRateHz in
            events.setMotionEventState(controller: controllerNumber,
                                       motionType: motionType, reportRateHz: reportRateHz)
        }
        // Adaptive triggers use DualSense HID off-thread. Final HID release
        // resets the effect so a stream ending cannot strand a stiff trigger.
        enet.onSetAdaptiveTriggers = { controllerNumber, eventFlags, typeLeft, typeRight, left, right in
            events.setAdaptiveTriggers(controller: controllerNumber, eventFlags: eventFlags,
                                       typeLeft: typeLeft, typeRight: typeRight,
                                       left: left, right: right)
        }
    }

    /// FAST-START at SETUP-audio, like moonlight's notifyAudioPortNegotiationComplete: build the receiver and
    /// start only its ping, so Sunshine has our ping and return port by PLAY. Best-effort (audio is non-fatal);
    /// startAudioReceive() later brings up the SAME receiver's recv side, and run()'s catch tears it down.
    func startAudioPing(
        audioPort: UInt16, pingPayload: [UInt8], audioEncryption: Bool, opusConfig: OpusConfig,
        config: BackendStreamConfig, host: NWEndpoint.Host
    ) {
        guard let sink = withState({ audioSink }) else {
            Diag.error("native backend: no audio sink injected; audio receive disabled",
                       Self.logCategory)
            return
        }
        let receiver = RtpAudioReceiver(
            host: host,
            audioPort: audioPort,
            pingPayload: pingPayload,
            audioPacketDuration: 5,                 // SDP x-nv-aqos.packetDuration default
            opusConfig: opusConfig,
            audioConfig: config.audioConfiguration,
            audioEncryption: audioEncryption,
            aesKey: config.remoteInputAesKey,
            aesIvId: config.remoteInputAesIv,
            sink: sink)
        guard adoptWhileConnecting({ audioReceiver = receiver }) else { return }
        do {
            try receiver.startPing()
        } catch {
            Diag.error("native backend: audio ping start failed: \(error, privacy: .private)", Self.logCategory)
            withState { audioReceiver = nil }
        }
    }

    /// RECEIVE (post-connect): bring up the audio RECEIVE side on the receiver that
    /// startAudioPing already created mid-handshake - init the decoder/engine +
    /// start the recv loop. If the early-ping path was skipped (no audio sink), the
    /// receiver doesn't exist; that's fine (audio off, but the video flow keeps the
    /// session alive). startReceive() is idempotent and will open the ping itself
    /// if it somehow wasn't running. Best-effort - non-fatal.
    func startAudioReceive(
        handshake: RtspHandshakeResult, config: BackendStreamConfig,
        server: BackendServerInfo, host: NWEndpoint.Host
    ) {
        guard let receiver = withState({ audioReceiver }) else {
            // No early-ping receiver (e.g. no audio sink). Nothing to receive.
            return
        }
        do {
            try receiver.startReceive()
        } catch {
            Diag.error("native backend: audio receive start failed: \(error, privacy: .private)", Self.logCategory)
            // Keep the ping alive (it keeps the A/V session up); only receive failed.
            // H7: surface the video-only state instead of swallowing it - a
            // queryable counter + a non-fatal event (the visual stream is fine).
            TelemetryCounters.shared.audioReceiveFailedTotal.increment()
            StreamBridgeContext.current?.eventContinuation?.yield(
                .audioFailed("\(error)"))
        }
    }

    /// Name resolution + the RTSP/SDP handshake stages.
    func performRtspStage(
        server: BackendServerInfo, config: BackendStreamConfig,
        host: NWEndpoint.Host, events: NativeConnectionEvents
    ) async throws -> RtspHandshakeResult {
        // --- Stage: name resolution ---
        events.stageStarting("name resolution")
        let rtspPort = Self.rtspPort(from: server.rtspSessionUrl)
        // Network.framework resolves the host lazily on connect; we surface the
        // address family from the URL/raw address for the SDP o= line.
        let (urlAddr, urlSafeAddr, familyToken) = Self.addressInfo(
            rtspSessionUrl: server.rtspSessionUrl, fallbackAddress: server.address)
        let rtspTargetUrl = server.rtspSessionUrl.isEmpty
            ? "rtsp://\(urlAddr):\(rtspPort)"
            : server.rtspSessionUrl
        Diag.info("name resolution: host=\(server.address, privacy: .private) rtspPort=\(rtspPort) "
            + "appVer=\(server.appVersion, privacy: .private)", Self.logCategory)
        events.stageComplete("name resolution")

        if checkInterrupted() {
            events.stageFailed("name resolution", code: -4)
            throw EnetError.interrupted
        }

        // --- Stage: RTSP handshake ---
        events.stageStarting("RTSP handshake")
        let rtsp = RtspClient(
            host: host,
            rtspPort: rtspPort,
            rtspTargetUrl: rtspTargetUrl,
            urlAddr: urlAddr,
            urlSafeAddr: urlSafeAddr,
            addrFamilyToken: familyToken,
            config: config,
            serverCodecModeRaw: server.serverCodecModeRaw)
        // Fast-start audio: the instant the handshake parses SETUP-audio (BEFORE
        // PLAY), open the audio socket + start the burst ping so the host has our
        // ping by PLAY. moonlight's notifyAudioPortNegotiationComplete() ordering.
        rtsp.onAudioPortNegotiated = { [weak self] audioPort, pingPayload, audioEncryption, opus in
            self?.startAudioPing(audioPort: audioPort, pingPayload: pingPayload,
                                 audioEncryption: audioEncryption, opusConfig: opus,
                                 config: config, host: host)
        }
        guard adoptWhileConnecting({ rtspClient = rtsp }) else {
            events.stageFailed("RTSP handshake", code: -4)
            throw EnetError.interrupted
        }

        let handshake: RtspHandshakeResult
        do {
            handshake = try await rtsp.performHandshake()
        } catch {
            Diag.error("native backend: RTSP handshake failed: \(error, privacy: .private)", Self.logCategory)
            events.stageFailed("RTSP handshake", code: Self.rtspCode(error))
            throw error
        }
        events.stageComplete("RTSP handshake")

        if checkInterrupted() {
            events.stageFailed("RTSP handshake", code: -4)
            throw EnetError.interrupted
        }
        return handshake
    }

    /// ENet control-stream CONNECT + START_A/B (the "connected" goalposts).
    func performControlStage(
        handshake: RtspHandshakeResult, config: BackendStreamConfig,
        host: NWEndpoint.Host, events: NativeConnectionEvents
    ) async throws {
        // Control-V2 must be negotiated for the encrypted START packets; if the
        // host didn't enable it, fail cleanly rather than send plaintext garbage.
        guard handshake.encryptionFeaturesEnabled & RtspClient.ssEncControlV2 != 0 else {
            Diag.error("native backend: control-V2 not negotiated "
                + "(encEnabled=\(handshake.encryptionFeaturesEnabled)); "
                + "native control stream requires it", Self.logCategory)
            events.stageFailed("control stream initialization", code: -1)
            throw StreamError.sessionFailed(-1)
        }

        let crypto: ControlCrypto
        do {
            crypto = try ControlCrypto(rikey: config.remoteInputAesKey)
        } catch {
            Diag.error("native backend: control crypto init failed: \(error, privacy: .private)", Self.logCategory)
            events.stageFailed("control stream initialization", code: -1)
            throw StreamError.crypto("\(error)")
        }

        let enet = EnetControlChannel(
            host: host,
            port: handshake.controlPort,
            controlConnectData: handshake.controlConnectData,
            crypto: crypto)
        guard adoptWhileConnecting({ enetChannel = enet }) else {
            events.stageFailed("control stream initialization", code: -4)
            throw EnetError.interrupted
        }

        do {
            try await enet.establishAndStart(
                stage: { name in events.stageStarting(name) },
                stageDone: { name in events.stageComplete(name) },
                stageFailed: { name, code in events.stageFailed(name, code: code) })
        } catch {
            Diag.error("native backend: control stream failed: \(error, privacy: .private)", Self.logCategory)
            // establishAndStart already fired the specific stageFailed. No
            // VERIFY_CONNECT means the control port's UDP never got through.
            if case EnetError.connectTimeout = error {
                throw StreamError.streamPortsBlocked(proto: "UDP", port: handshake.controlPort)
            }
            throw error
        }
    }
}

// MARK: - ConnectionEvents controller feedback → the actuator

extension NativeConnectionEvents {
    /// The native event adapter's controller-feedback slots, routing host
    /// control events into the haptics/light actuator and the motion sampler.
    /// All four are declared protocol REQUIREMENTS on ConnectionEvents
    /// (StreamingBackend.swift), so these implementations are reached through
    /// the witness table even at an `any ConnectionEvents` call site - the
    /// no-op defaults exist only to keep actuator-less conformers
    /// source-compatible. Lives here, beside the startVideoStage wiring that
    /// feeds it, rather than in the (size-capped) actuator file.
    func rumble(controller: UInt16, lowFreq: UInt16, highFreq: UInt16) {
        ControllerHaptics.shared.setRumble(controllerNumber: controller,
                                           lowFreq: lowFreq, highFreq: highFreq)
    }

    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        ControllerHaptics.shared.setTriggerRumble(controllerNumber: controller,
                                                  left: left, right: right)
    }

    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        ControllerHaptics.shared.setLight(controllerNumber: controller,
                                          red: r, green: g, blue: b)
    }

    func setPlayerLEDs(controller: UInt16, solid: UInt8, flashing: UInt8) {
        ControllerHaptics.shared.setPlayerLEDs(controllerNumber: controller,
                                               solid: solid, flashing: flashing)
    }

    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        ControllerMotion.shared.setMotionEventState(controllerNumber: controller,
                                                    motionType: motionType,
                                                    reportRateHz: reportRateHz)
    }

    /// SET_ADAPTIVE_TRIGGERS (0x5503) to the bound pad's OUTPUT report: GameController
    /// has no adaptive-trigger API, so this is the one feedback that must take the
    /// raw-HID path. A no-op when the feature is off or the write is refused.
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8,
                             typeLeft: UInt8, typeRight: UInt8,
                             left: [UInt8], right: [UInt8]) {
        guard let device = DualSenseRouting.shared.device(slot: controller) else { return }
        DualSenseHID.shared.setAdaptiveTriggers(device: device, eventFlags: eventFlags,
                                                typeLeft: typeLeft, typeRight: typeRight,
                                                left: left, right: right)
    }
}
