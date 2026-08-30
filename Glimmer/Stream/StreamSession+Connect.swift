//
//  StreamSession+Connect.swift
//
//  The BACKEND-FACING half of the start path, shared with the silent-reconnect
//  driver: building the `BackendStreamConfig` value type from the user-facing
//  `StreamConfig` + the launch handshake (including the connect-time link
//  quality gate that picks the bitrate and packet size), and the connect leg
//  itself - signpost interval, telemetry anchor, Swift-sink attach, and the
//  startConnection failure cleanup. Split out of StreamSession+Start.swift to
//  keep each unit under the length limit; both are pure moves, called from the
//  orchestrating start() there and from StreamSession+Reconnect.swift.
//

import Foundation
import os

extension StreamSession {

    /// Build the value type the backend protocol consumes from the user-facing
    /// `StreamConfig` + the launch handshake. The actual stream-configuration
    /// fill (the remoteInputAesKey/Iv copy + the SCM_* handling) lives in
    /// NativeBackend.startConnection; this just builds the value type.
    /// gcmKey/gcmKeyId are the 16-byte per-session AES key + IV-id from the
    /// launch handshake.
    func makeBackendConfig(
        config: StreamConfig, launch: LaunchResponse, server: ServerInfo,
        rtt: RttStats? = nil
    ) -> BackendStreamConfig {
        // Resolve `.auto` from the route we will actually egress on. Without
        // this, `.auto` (STREAM_CFG_AUTO = 2) never equals STREAM_CFG_REMOTE and
        // every remote-only SDP behaviour - the 1024 packet-size clamp, the
        // remote bitrate headroom, the remote qosTrafficType - stays dead, so a
        // 1392-byte LAN packet gets advertised onto a 1280-MTU tunnel and every
        // video packet fragments. An explicit .local/.remote from the caller is
        // honoured as-is; only `.auto` consults the probe.
        let path = config.remoteness == .auto
            ? StreamPathMTU.probe(host: server.address,
                                  rttPort: UInt16(server.httpsPort), rtt: rtt) : StreamPathProbe()
        let resolvedRemoteness: Remoteness
        switch config.remoteness {
        case .local, .remote:
            resolvedRemoteness = config.remoteness
        case .auto:
            resolvedRemoteness = path.isRemotePath ? .remote : .local
        }
        // CONNECT-TIME QUALITY GATE. The demand-based bitrate from
        // QualityCalculator answers "what does this resolution need?" - it was
        // measured on a LAN harness and never asks what the PATH will deliver.
        // Asking for a LAN-measured 84 Mbps over a 50 ms tunnel is not a
        // considered choice, it is the absence of one. Since bitrate is fixed at
        // ANNOUNCE (no client→host rate message exists, and the host never
        // changes it after), choosing well HERE is the only cheap lever there is.
        let cappedBitrateKbps = StreamPathMTU.cappedBitrateKbps(
            configured: config.bitrateKbps, path: path)
        if config.remoteness == .auto {
            log.info("""
                Path probe: if=\(path.interfaceName ?? "?", privacy: .public) \
                mtu=\(path.mtu ?? -1, privacy: .public) \
                tunnel=\(path.isTunnel, privacy: .public) \
                rtt=p95 \(path.rtt.map { String(format: "%.0f", $0.p95Ms) } ?? "?", privacy: .public)ms \
                (min \(path.rtt.map { String(format: "%.0f", $0.minMs) } ?? "?", privacy: .public) \
                p50 \(path.rtt.map { String(format: "%.0f", $0.p50Ms) } ?? "?", privacy: .public) \
                n=\(path.rtt?.count ?? 0, privacy: .public)) \
                → remoteness=\(resolvedRemoteness == .remote ? "remote" : "local", privacy: .public) \
                bitrate=\(config.bitrateKbps, privacy: .public)→\(cappedBitrateKbps, privacy: .public)kbps
                """)
        }
        if cappedBitrateKbps < config.bitrateKbps {
            Diag.notice(
                "Link quality gate: p95 \(path.rttMs.map { String(format: "%.0f", $0) } ?? "?")ms RTT "
                + "(min \(path.rtt.map { String(format: "%.0f", $0.minMs) } ?? "?")ms, "
                + "\(path.rtt?.count ?? 0) samples) over "
                + "\(path.isTunnel ? "a tunnel" : "this path") - asking for "
                + "\(cappedBitrateKbps / 1000) Mbps instead of \(config.bitrateKbps / 1000) "
                + "(a LAN-measured rate isn't a defensible ask at this distance).", "Stream")
        }
        // Latch for the downshift tier. Set on EVERY build - including each
        // reconnect - so a route that moved mid-session is re-judged, never
        // inherited from the original connect.
        isRemotePathSession = resolvedRemoteness == .remote
        // ONE packet size, resolved here and used EVERYWHERE - the SDP we
        // advertise, the receive buffer, and (load-bearing) the Reed-Solomon
        // shard length the FEC reconstructor rebuilds recovered packets at
        // (RtpVideoQueue+Reconstruct). Advertising one size while reconstructing
        // at another rebuilds every FEC-recovered packet at the wrong length and
        // feeds garbage to the decoder - visible as the purple/white HDR
        // corruption, and ONLY on a lossy link, because a clean one never
        // exercises FEC recovery. The receive buffer adds its own headroom on
        // top (packetSize + 64, + MAX_RTP_HEADER_SIZE), so a smaller value is
        // safe there; there is no case for keeping the two apart.
        let resolvedPacketSize = StreamPathMTU.advertisedPacketSize(
            configured: config.packetSize,
            isRemote: resolvedRemoteness == .remote,
            mtu: path.mtu)
        // Latch the whole decision for the telemetry config event - the session
        // log doesn't capture anything emitted this early (see LinkGateDecision).
        StreamPathMTU.latchGateDecision(LinkGateDecision(
            interfaceName: path.interfaceName, mtu: path.mtu, isTunnel: path.isTunnel,
            rtt: path.rtt, configuredBitrateKbps: config.bitrateKbps,
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
            encryptionFlags: config.encryption.encryptionFlags,
            remoteInputAesKey: [UInt8](launch.gcmKey),
            remoteInputAesIv: [UInt8](launch.gcmKeyId))
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
            // Async connect: await the bridge rather than block this actor, so a
            // hanging host can't freeze stop/cancel/telemetry (bounded by the 30s
            // cap). Cancelling this task interrupts the in-flight connect.
            try await backend.startConnectionAsync(server: backendServer, config: backendConfig)
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
}
