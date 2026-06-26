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

        let host = NWEndpoint.Host(server.address)

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

            // The audio PING already started mid-handshake; now (post-handshake)
            // bring up the audio RECEIVE side: init the decoder + start the recv
            // loop on the SAME unconnected socket. If the early ping path didn't run
            // (no audio sink), startAudioReceive() still opens the ping so the
            // combined A/V session stays alive (Sunshine withholds video RTP until
            // it has seen the audio ping too).
            startAudioReceive(handshake: handshake, config: config, server: server, host: host)

            // --- Connected. Bring up native video receive + keepalive loop. ---
            // Flip inputReady here (the InputStream.c `initialized` analogue): the
            // control stream is now up, so send* can seal + send input packets.
            // Spin up the input batcher (InputStream.c's input thread) on the same
            // edge so all send* coalesce through it.
            withState {
                didConnect = true
                inputReady = true
                if let enet = enetChannel {
                    inputBatcher = InputBatcher(enet: enet)
                }
            }
            Diag.notice("native backend: CONNECTED (RTSP + ENet control + START_A/B complete). "
                + "Native input uplink ready. Starting native video receive.", Self.logCategory)

            try await startVideoStage(handshake: handshake, config: config,
                                      server: server, host: host, events: events)
        } catch {
            // Any failure after the audio ping may have started must not leak the
            // ping thread/socket (and recv loop, if it reached startAudioReceive).
            tearDownAudio()
            throw error
        }

        events.connectionStarted()

        // startConnection() returns here (success); the control loop + video
        // receive run in detached tasks until stop()/interrupt(). This mirrors
        // LiStartConnection returning 0 while the engine's threads keep running.
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
        server: BackendServerInfo, host: NWEndpoint.Host, events: NativeConnectionEvents
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

        // Wire the host TERMINATION → connectionTerminated + teardown.
        enet.onTerminated = { [weak self] code in
            Diag.error("native backend: host terminated session (code \(code))", Self.logCategory)
            events.connectionTerminated(code: code)
            self?.stopConnection()
        }

        // Wire host HDR-mode (control 0x010e) → the decoder's HDR engagement.
        // Without this the 10-bit HDR stream renders as washed-out SDR. setHDR
        // pulls the mastering metadata back via backend.hdrMetadata() (our
        // enetChannel's).
        enet.onHdrMode = { [weak self] enabled in
            guard let self,
                  let decoder = self.withState({ self.videoSink }) as? VideoDecoder else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { decoder.setHDR(enabled: enabled) } }
        }

        // Controller feedback (rumble / triggers / LED / motion enable) is one
        // cohesive wiring unit; split out so this stage body stays inside the
        // size cap as the protocol surface grows.
        wireControllerFeedback(enet: enet, events: events)

        // Decoder setup() BEFORE first frame, then start() once.
        let videoFormat = handshake.negotiatedVideoFormat
        let setupResult = sink.setup(
            videoFormat: videoFormat, width: config.width, height: config.height,
            redrawRate: config.fps)
        guard setupResult == 0 else {
            Diag.error("native backend: video sink setup failed (\(setupResult))", Self.logCategory)
            events.stageFailed("video stream initialization", code: setupResult)
            throw StreamError.sessionFailed(setupResult)
        }
        sink.start()

        let appVersionQuad = Self.versionQuad(server.appVersion)
        let multiFecCapable = Self.appVersionAtLeast(appVersionQuad, 7, 1, 431)

        let receiver = VideoRtpReceiver(
            host: host,
            videoPort: handshake.videoPort,
            pingPayload: handshake.videoPingPayload,
            packetSize: Int(config.packetSize),
            bitrateKbps: Int(config.bitrate),
            negotiatedVideoFormat: videoFormat,
            encryptionFeaturesEnabled: handshake.encryptionFeaturesEnabled,
            appVersionQuad: appVersionQuad,
            colorSpace: config.colorSpace,
            multiFecCapable: multiFecCapable,
            sink: sink,
            requestIdr: { [weak enet] in enet?.requestIdrFrame() },
            invalidateReferenceFrames: { [weak enet] from, to in
                enet?.invalidateReferenceFrames(from: from, to: to)
            },
            sendFrameFecStatus: { [weak enet] status in
                enet?.queueFrameFecStatus(status)
            })
        withState { videoReceiver = receiver }

        do {
            try await receiver.start()
        } catch {
            Diag.error("native backend: video receiver start failed: \(error)", Self.logCategory)
            events.stageFailed("video stream initialization", code: -1)
            throw StreamError.sessionFailed(-1)
        }
        events.stageComplete("video stream initialization")

        // Kick off the persistent ENet control loop (keepalives) on a DEDICATED
        // elevated-QoS Thread - NOT the Swift cooperative pool. The loop that must
        // emit ACKs/keepalives to keep the host's ENet peer alive cannot be allowed
        // to starve behind high-QoS main-thread controller input (the cooperative
        // pool is capped at ~CPU-count threads and these Tasks ran at default QoS).
        // This is moonlight's dedicated LossStats/ControlRecv pthread guarantee; the
        // loop's tick is a blocking Thread.sleep (runControlLoopSync) so it never
        // depends on pool availability. The Thread holds no strong ref to self and
        // exits when the channel is interrupted/disconnected.
        let controlThread = Thread { [weak enet] in
            enet?.runControlLoopSync()
        }
        controlThread.qualityOfService = .userInteractive
        controlThread.name = "Glimmer.enetControl"
        controlThread.start()
    }

    /// Wire the host's controller-feedback control messages into the actuator
    /// and the motion sampler, and arm both singletons' stream gates. Pure
    /// move out of startVideoStage (size cap); behavior unchanged.
    private func wireControllerFeedback(enet: EnetControlChannel, events: NativeConnectionEvents) {
        // Wire host rumble (control 0x010b) → ConnectionEvents.rumble → the
        // GameController haptics actuator, the same shape as the HDR path
        // in startVideoStage. The enet receive thread only forwards the trio;
        // the actuator does its own latest-wins hop onto a serial queue so the
        // control channel can never block on Core Haptics. streamActivated()
        // lifts the actuator's quiesce gate (armed at init and on every stream
        // teardown) - without it a late event from a PREVIOUS session could
        // re-spin motors with no host left to send the (0,0) clear.
        ControllerHaptics.shared.streamActivated()
        enet.onRumble = { controllerNumber, lowFreq, highFreq in
            events.rumble(controller: controllerNumber, lowFreq: lowFreq, highFreq: highFreq)
        }
        // No stuck motors, no ghost sampling: whatever ends this control
        // channel (user stop, watchdog teardown, host TERMINATION - all
        // funnel into the channel's interrupt()/close() pair, which fires
        // this at most once) parks every pad at (0,0), tears the haptic
        // engines down, and halts motion sampling. The host's own "motors
        // off" / "reporting off" events can't arrive on a dead channel.
        enet.onTeardown = {
            ControllerHaptics.shared.stopAll(reason: "stream teardown")
            ControllerMotion.shared.stopAll(reason: "stream teardown")
        }
        // The other two in-protocol controller-feedback messages ride the same
        // shape as rumble: the receive thread only forwards values, and the
        // actuator does its own latest-wins hop. Both arrive only for pads
        // whose advertised caps invited them (ControllerForwarder gates
        // LI_CCAP_TRIGGER_RUMBLE on probed trigger localities and
        // LI_CCAP_RGB_LED on gamepad.light), and both are parked by the same
        // stopAll/teardown path above (trigger motors at zero; the light bar
        // needs no parking - it is lit hardware state, not motion).
        enet.onRumbleTriggers = { controllerNumber, left, right in
            events.rumbleTriggers(controller: controllerNumber, left: left, right: right)
        }
        enet.onSetRgbLed = { controllerNumber, red, green, blue in
            events.setControllerLED(controller: controllerNumber, r: red, g: green, b: blue)
        }
        // Motion (0x5501) closes the loop the LI_CCAP_ACCEL/GYRO caps open:
        // the host asks for sensor reports at a rate, the sampler reads
        // GCMotion on main, and the samples ride the EXISTING input batcher
        // back up (sendControllerMotion). The receive thread only forwards
        // the trio; ControllerMotion hops to main itself. streamActivated
        // arms the sampler's uplink - the same quiesce discipline as the
        // haptics actuator's streamActivated above.
        ControllerMotion.shared.streamActivated(backend: self)
        enet.onSetMotionEvent = { controllerNumber, motionType, reportRateHz in
            events.setMotionEventState(controller: controllerNumber,
                                       motionType: motionType, reportRateHz: reportRateHz)
        }
        // Adaptive triggers (0x5503) ride the same shape: the receive thread
        // only forwards the mode + params; DualSenseHID does its IOKit OUTPUT
        // report write off-thread on its own serial path. Only DualSense pads
        // receive this (Sunshine extension). Parked by the same teardown path
        // above - DualSenseHID resets the trigger blocks to "off" on the final
        // release(), so a stream ending mid-effect can't strand a stiff trigger.
        enet.onSetAdaptiveTriggers = { controllerNumber, eventFlags, typeLeft, typeRight, left, right in
            events.setAdaptiveTriggers(controller: controllerNumber, eventFlags: eventFlags,
                                       typeLeft: typeLeft, typeRight: typeRight,
                                       left: left, right: right)
        }
    }

    /// FAST-START (mid-handshake, at SETUP-audio): construct the RtpAudioReceiver
    /// and start ONLY the burst-ping side (socket open + ping thread) so the host
    /// has our ping - and our return UDP port - in hand by PLAY. This is the
    /// ordering fix for the ~2min audio-cold-start: moonlight opens the audio
    /// socket + starts the ping thread the instant SETUP-audio is parsed
    /// (notifyAudioPortNegotiationComplete), because Sunshine won't aim audio at us
    /// (and GFE 3.22 won't even reply to PLAY) until it has received a ping.
    ///
    /// Only audioPort + pingPayload are negotiated; opus/packetDuration use the
    /// fixed defaults (they're never mutated by later handshake steps) and
    /// audioEncryption is structurally false for our connect-only SDP
    /// (computeEncryptionEnabled never enables SS_ENC_AUDIO). The recv side +
    /// decoder init happen later in startAudioReceive() on the SAME receiver.
    ///
    /// Best-effort: a ping failure logs but does NOT abort the handshake (audio is
    /// non-fatal). The receiver is stored so a later-stage failure tears it down
    /// (run()'s catch → tearDownAudio).
    func startAudioPing(
        audioPort: UInt16, pingPayload: [UInt8],
        config: BackendStreamConfig, server: BackendServerInfo, host: NWEndpoint.Host
    ) {
        guard let sink = withState({ audioSink }) else {
            Diag.error("native backend: no audio sink injected; audio receive disabled",
                       Self.logCategory)
            return
        }
        let appVersionQuad = Self.versionQuad(server.appVersion)
        let receiver = RtpAudioReceiver(
            host: host,
            audioPort: audioPort,
            pingPayload: pingPayload,
            appVersionQuad: appVersionQuad,
            audioPacketDuration: 5,                 // SDP x-nv-aqos.packetDuration default
            opusConfig: RtspHandshakeResult.defaultOpusConfig,
            audioConfig: config.audioConfiguration,
            audioEncryption: false,                 // plaintext on the connect-only SDP
            aesKey: config.remoteInputAesKey,
            aesIvId: config.remoteInputAesIv,
            sink: sink)
        withState { audioReceiver = receiver }
        do {
            try receiver.startPing()
        } catch {
            Diag.error("native backend: audio ping start failed: \(error)", Self.logCategory)
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
            Diag.error("native backend: audio receive start failed: \(error)", Self.logCategory)
            // Keep the ping alive (it keeps the A/V session up); only receive failed.
            // H7: surface the video-only state instead of swallowing it - a
            // queryable counter + a non-fatal event (the visual stream is fine).
            TelemetryCounters.shared.audioReceiveFailedTotal.increment()
            StreamBridgeContext.current?.eventContinuation?.yield(
                .audioFailed("\(error)"))
        }
    }

    /// APP_VERSION_AT_LEAST helper for the quad.
    static func appVersionAtLeast(_ quad: [Int32], _ major: Int32, _ minor: Int32,
                                  _ patch: Int32) -> Bool {
        guard quad.count >= 3 else { return false }
        if quad[0] != major { return quad[0] > major }
        if quad[1] != minor { return quad[1] > minor }
        return quad[2] >= patch
    }

    /// Name resolution + the RTSP/SDP handshake stages.
    func performRtspStage(
        server: BackendServerInfo, config: BackendStreamConfig,
        host: NWEndpoint.Host, events: NativeConnectionEvents
    ) async throws -> RtspHandshakeResult {
        // --- Stage: name resolution ---
        events.stageStarting("name resolution")
        let appVersionQuad = Self.versionQuad(server.appVersion)
        let rtspPort = Self.rtspPort(from: server.rtspSessionUrl)
        // Network.framework resolves the host lazily on connect; we surface the
        // address family from the URL/raw address for the SDP o= line.
        let (urlAddr, urlSafeAddr, familyToken) = Self.addressInfo(
            rtspSessionUrl: server.rtspSessionUrl, fallbackAddress: server.address)
        let rtspTargetUrl = server.rtspSessionUrl.isEmpty
            ? "rtsp://\(urlAddr):\(rtspPort)"
            : server.rtspSessionUrl
        Diag.info("name resolution: host=\(server.address) rtspPort=\(rtspPort) "
            + "appVer=\(server.appVersion) quad=\(appVersionQuad)", Self.logCategory)
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
            rtspClientVersion: Self.rtspClientVersion(quad: appVersionQuad),
            config: config,
            serverCodecModeRaw: server.serverCodecModeRaw,
            appVersionQuad: appVersionQuad)
        // Fast-start audio: the instant the handshake parses SETUP-audio (BEFORE
        // PLAY), open the audio socket + start the burst ping so the host has our
        // ping by PLAY. moonlight's notifyAudioPortNegotiationComplete() ordering.
        rtsp.onAudioPortNegotiated = { [weak self] audioPort, pingPayload in
            self?.startAudioPing(audioPort: audioPort, pingPayload: pingPayload,
                                 config: config, server: server, host: host)
        }
        withState { rtspClient = rtsp }

        let handshake: RtspHandshakeResult
        do {
            handshake = try await rtsp.performHandshake()
        } catch {
            Diag.error("native backend: RTSP handshake failed: \(error)", Self.logCategory)
            events.stageFailed("RTSP handshake", code: rtspCode(error))
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
        let ssEncControlV2: UInt32 = 0x01
        guard handshake.encryptionFeaturesEnabled & ssEncControlV2 != 0 else {
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
            Diag.error("native backend: control crypto init failed: \(error)", Self.logCategory)
            events.stageFailed("control stream initialization", code: -1)
            throw StreamError.crypto("\(error)")
        }

        let enet = EnetControlChannel(
            host: host,
            port: handshake.controlPort,
            controlConnectData: handshake.controlConnectData,
            crypto: crypto)
        withState { enetChannel = enet }

        do {
            try await enet.establishAndStart(
                stage: { name in events.stageStarting(name) },
                stageDone: { name in events.stageComplete(name) },
                stageFailed: { name, code in events.stageFailed(name, code: code) })
        } catch {
            Diag.error("native backend: control stream failed: \(error)", Self.logCategory)
            // establishAndStart already fired the specific stageFailed.
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

    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        ControllerMotion.shared.setMotionEventState(controllerNumber: controller,
                                                    motionType: motionType,
                                                    reportRateHz: reportRateHz)
    }

    /// Adaptive triggers (SET_ADAPTIVE_TRIGGERS 0x5503) → the DualSense raw-HID
    /// OUTPUT report. Unlike rumble/light (which route through GameController),
    /// GameController exposes NO adaptive-trigger API, so this is the one host
    /// feedback that MUST take the raw-HID write path. Single-pad assumption
    /// matches DualSenseHID's reader; the singleton resolves the open device
    /// and merges these params with the current lightbar + rumble before
    /// writing (the 0x02/0x31 report is all-or-nothing). A no-op when the
    /// raw-HID feature is off or the write is refused (e.g. gamecontrollerd
    /// grabbed the device) - adaptive triggers simply don't engage, nothing
    /// else is affected.
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8,
                             typeLeft: UInt8, typeRight: UInt8,
                             left: [UInt8], right: [UInt8]) {
        DualSenseHID.shared.setAdaptiveTriggers(eventFlags: eventFlags,
                                                typeLeft: typeLeft, typeRight: typeRight,
                                                left: left, right: right)
    }
}
