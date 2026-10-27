// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Initial startup and recovery share configuration, transport binding and failure cleanup.
// Measured bitrate and route policies remain unchanged across the native adapter boundary.

import Foundation
import os

extension StreamSession {

    /// Resolve the existing measured bitrate/route policy and copy launch material into backend values.
    /// Public callers validate key sizes before this boundary; native launch compatibility is preserved.
    package func makeBackendConfig(
        config: StreamRequest, launch: LaunchResponse, server: ServerInfo,
        rtt: RttStats? = nil, rttPreLaunch: Bool = false, exactBitrate: Bool = false
    ) -> BackendStreamConfig {
        // Explicit remoteness wins. Unknown public paths keep conservative packets until destination evidence arrives.
        let path = config.remoteness == .auto
            ? services.route(server, rtt) : StreamPathProbe()
        let resolvedRemoteness: Remoteness
        switch config.remoteness {
        case .local, .remote:
            resolvedRemoteness = config.remoteness
        case .auto:
            let facts = publicMedia == nil ? nil : services.bandwidthInputs?.snapshot().path
            let conservative = facts.map { path.interfaceName == nil || $0.needsConservativePacketSize } ?? false
            resolvedRemoteness = path.isRemotePath || conservative ? .remote : .local
        }
        // Retain Mac compatibility gates; current-environment shadow decisions do not inherit a latency-based cap.
        let pathCappedKbps = publicMedia == nil
            ? StreamPathMTU.cappedBitrateKbps(configured: config.bitrateKbps, path: path) : config.bitrateKbps
        // The wired boost assumed Ethernet at both ends; the measured RTT is
        // the host side's answer, and a Wi-Fi hop there takes the boost off.
        let routeAskKbps = exactBitrate ? config.bitrateKbps : StreamPathMTU.wiredAskKbps(
            capped: pathCappedKbps, boost: config.bitrateBoost, steadyRttMs: path.rttMs)
        let cappedBitrateKbps = seedBandwidth(config: config, appliedKbps: routeAskKbps, rtt: rtt, preLaunch: rttPreLaunch)
        if routeAskKbps < pathCappedKbps {
            Diag.notice("Wired bitrate boost withdrawn: steady RTT "
                + "\(path.rttMs.map { String(format: "%.1f", $0) } ?? "?") ms says a Wi-Fi hop is on the path - "
                + "asking for \(routeAskKbps / 1000) Mbps instead of \(pathCappedKbps / 1000).", "Stream")
        }
        if config.remoteness == .auto {
            log.info("""
                Path probe: if=\(path.interfaceName ?? "?", privacy: .public) \
                mtu=\(path.mtu ?? -1, privacy: .public) \
                tunnel=\(path.isTunnel, privacy: .public) \
                rtt=steady \(path.rtt.map { String(format: "%.0f", $0.steadyMs) } ?? "?", privacy: .public)ms \
                (min \(path.rtt.map { String(format: "%.0f", $0.minMs) } ?? "?", privacy: .public) \
                p50 \(path.rtt.map { String(format: "%.0f", $0.p50Ms) } ?? "?", privacy: .public) \
                p95 \(path.rtt.map { String(format: "%.0f", $0.p95Ms) } ?? "?", privacy: .public) \
                n=\(path.rtt?.count ?? 0, privacy: .public) \
                \(rttPreLaunch ? "pre-launch" : "all", privacy: .public)) \
                → remoteness=\(resolvedRemoteness == .remote ? "remote" : "local", privacy: .public) \
                bitrate=\(config.bitrateKbps, privacy: .public)→\(cappedBitrateKbps, privacy: .public)kbps
                """)
        }
        if !exactBitrate, pathCappedKbps < config.bitrateKbps {
            Diag.notice(
                "Link quality gate: steady \(path.rttMs.map { String(format: "%.0f", $0) } ?? "?")ms RTT "
                + "(min \(path.rtt.map { String(format: "%.0f", $0.minMs) } ?? "?")ms, "
                + "p95 \(path.rtt.map { String(format: "%.0f", $0.p95Ms) } ?? "?")ms, "
                + "\(path.rtt?.count ?? 0) samples\(rttPreLaunch ? " before launch" : "")) over "
                + "\(path.isTunnel ? "a tunnel" : "this path") - asking for "
                + "\(pathCappedKbps / 1000) Mbps instead of \(config.bitrateKbps / 1000) "
                + "(a LAN-measured rate isn't a defensible ask at this distance).", "Stream")
        }
        // Latch for the downshift tier. Set on EVERY build - including each
        // reconnect - so a route that moved mid-session is re-judged, never
        // inherited from the original connect.
        isRemotePathSession = resolvedRemoteness == .remote
        // One size for the SDP and the receiver, less the 32-byte header when video is encrypted
        // (VideoPacketLayout.packetSize). FEC rebuilds at each block's longest shard, capped at that
        // size plus the RTP header, so a PC that sends shorter shards still recovers cleanly.
        let routeMTU = suppliedRouteMTU ?? path.mtu
        let resolvedPacketSize = StreamPathMTU.advertisedPacketSize(
            configured: config.packetSize,
            isRemote: resolvedRemoteness == .remote,
            mtu: routeMTU)
        // Latch the whole decision for the telemetry config event - the session
        // log doesn't capture anything emitted this early (see LinkGateDecision).
        StreamPathMTU.latchGateDecision(LinkGateDecision(
            interfaceName: path.interfaceName, mtu: routeMTU, isTunnel: path.isTunnel,
            rtt: path.rtt, rttPreLaunch: rttPreLaunch, configuredBitrateKbps: config.bitrateKbps,
            askedBitrateKbps: cappedBitrateKbps, packetSize: resolvedPacketSize))
        return BackendStreamConfig(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: Int32(config.fps),
            bitrate: Int32(cappedBitrateKbps),
            packetSize: Int32(resolvedPacketSize),
            streamingRemotely: resolvedRemoteness.cValue,
            audioConfiguration: config.audio.cValue,
            supportedVideoFormats: config.videoFormats.rawValue,
            clientRefreshRateX100: Int32(config.fps * 100),
            colorSpace: config.colorSpace.cValue,
            colorRange: config.colorRange.cValue,
            encryptionFlags: 0,
            remoteInputAesKey: [UInt8](launch.gcmKey),
            remoteInputAesIv: [UInt8](launch.gcmKeyId), collectBandwidthSamples: adaptiveBandwidth)
    }

    /// Attach the media sinks and start this transport attempt. Failure cleanup follows
    /// the required host disposition; initial failure also joins full local teardown.
    package func connectBackend(
        serverInfo: ServerInfo,
        launch: LaunchResponse,
        backendConfig: BackendStreamConfig,
        setup: SessionMedia,
        network: NetworkClient,
        duringReconnect: Bool = false,
        deadline: Date? = nil
    ) async throws {
        let backendServer = BackendServerInfo(
            address: serverInfo.address,
            appVersion: serverInfo.appVersion ?? "unknown",
            rtspSessionUrl: launch.sessionURL,
            // RAW SCM_* bitmask from /serverinfo - see the landmine note in
            // StreamProtocol.SCM_*.
            serverCodecModeRaw: NetworkClient.backendCodecModeMask(serverInfo.serverCodecModeRaw))

        // Open the `ConnectFlow` interval right before startConnection so the
        // timeline captures the full handshake (RTSP negotiation + control
        // channel + ENet setup). Closed in `deliver(.connectionEstablished)` on
        // success, or in `stop()` on failure. The interval ID was created up
        // front so the close side can address it even if the actor's strong-ref
        // to the state has been cleared.
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        connectFlowState = OSSignposter.network.beginInterval(
            "ConnectFlow",
            id: connectFlowSignpostID,
            "host=\(serverInfo.address, privacy: .private)")
        #endif

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

        do {
            // Wiring awaited the main actor; stop may have finished meanwhile.
            // Check before attaching sinks so teardown cannot regain the decoder.
            try checkAttempt(deadline: deadline)
            if let native = backend as? NativeBackend {
                bridge?.setEventSource(native, attempt: attemptID)
                native.attachConnectionEvents(NativeConnectionEvents(bridge: bridge, backend: native,
                    feedback: publicInput.map { SessionFeedback.input($0, attempt: attemptID) }))
            }
            backend.attachVideoSink(setup.video)
            backend.attachAudioSink(audioDecoder)

            // Await the bridge so stop stays responsive during a hanging connect.
            // Cancelling this task interrupts the in-flight connection.
            let connectingBackend = backend
            if let deadline {
                try await StreamAttempt.run(until: deadline) {
                    try await connectingBackend.startConnectionAsync(server: backendServer, config: backendConfig)
                }
            } else {
                try await connectingBackend.startConnectionAsync(server: backendServer, config: backendConfig)
            }
            try checkAttempt(deadline: deadline)
            if bitrateChange == nil { appliedBitrateKbps = Int(backendConfig.bitrate) }
        } catch {
            // A failed transport follows the session-wide host disposition.
            let code: Int32
            if case let StreamError.sessionFailed(failureCode) = error {
                code = failureCode
            } else {
                code = -1
            }
            log.error("startConnection failed with \(code)")
            // Reconnect cancels only its failed launch, preserving the frozen frame and event stream
            // while the driver retries. Initial connect failure runs the full teardown.
            if duringReconnect {
                try checkAttempt(deadline: deadline)
                if bitrateChange == nil, let cancellation = hostDisposition.cancellation {
                    try? await cancellation.cancel(network)
                }
                try checkAttempt(deadline: deadline)
                throw StreamError.sessionFailed(code)
            }
            // P2 DISCONNECT REASON: the connection never reached established -
            // latch connect-failed before the teardown so the cause is attributed
            // to the handshake, not the host terminate that may follow.
            let interruptedBy = stopCause
            if !isTearingDown { noteTelemetryDisconnect(.connectFailed) }
            await stop(cause: .connectFailed)
            throw Self.connectLegError(error, stoppedBy: interruptedBy)
        }
    }

    /// What a failed initial connect reports: the user's stop (the quit chord,
    /// the close button, Cancel) is a cancel, not a failure. Anything else, the
    /// PC ending it included, keeps the engine's cause so the banner names the fix.
    package static func connectLegError(_ error: Error, stoppedBy cause: DisconnectReason?) -> Error {
        if cause == .userStopped { return CancellationError() }
        return error as? StreamError ?? .sessionFailed(-1)
    }
}
