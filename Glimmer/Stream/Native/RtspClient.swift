//
//  RtspClient.swift
//
//  RTSP/SDP handshake over plain TCP for the Swift-native streaming engine.
//  Source: RtspConnection.c (performRtspHandshake + transactRtspMessageTcp).
//  Targets Sunshine 7.1.450 (AppVersionQuad [7,1,450,0]): useEnet=FALSE ⇒ RTSP
//  over plain TCP, and APP_VERSION_AT_LEAST(7,1,431) ⇒ single PLAY "/" + control
//  stream id "streamid=control/13/0".
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  TRANSPORT: one FRESH NWConnection(.tcp) per RTSP message (the C code opens
//  AND closes a socket for every request). TCP_NODELAY on. Connect retries on
//  ECONNREFUSED every 500ms up to 10s (Sunshine 200-OKs /launch before the RTSP
//  port is listening). The response is delimited by the SERVER CLOSING the
//  connection (EOF) - there is no Content-Length framing on responses, so we
//  read until isComplete.
//
//  ENCRYPTED RTSP: if the launch URL is rtspenc:// (Sunshine's default), every
//  message is wrapped in a 24-byte header { typeAndLength BE (0x80000000|len),
//  sequenceNumber BE, tag[16] } over AES-128-GCM with StreamConfig.remoteInputAesKey.
//  IV is 12 bytes: seq little-endian in [0..3], then 'C''R' (client) outbound /
//  'H''R' (host) inbound. Outbound seq increments per message from 1; inbound seq
//  comes from each response header. Same TCP transport - only the payload is
//  sealed/unsealed. Ported from RtspConnection.c sealRtspMessage/unsealRtspMessage.

import Foundation
import Network
import CryptoKit

/// Outputs of a successful RTSP handshake, handed to the ENet/control stage.
struct RtspHandshakeResult {
    var audioPort: UInt16
    var videoPort: UInt16
    var controlPort: UInt16
    var controlConnectData: UInt32
    var sessionId: String
    var negotiatedVideoFormat: Int32
    var encryptionFeaturesSupported: UInt32
    var encryptionFeaturesEnabled: UInt32
    var referenceFrameInvalidationSupported: Bool
    /// Sunshine x-ss-general.featureFlags from the DESCRIBE SDP (RtspConnection.c:1145).
    /// 0 if absent. Bit 0x02 = LI_FF_CONTROLLER_TOUCH_EVENTS gates controllerTouch.
    var featureFlags: UInt32 = 0
    /// 16 raw bytes from SETUP-video X-SS-Ping-Payload. Empty → legacy 4-byte
    /// ("PING") video ping. Captured verbatim (NOT hex/base64-decoded), and only
    /// if the header value is exactly 16 chars (else the host ignores it).
    var videoPingPayload: [UInt8] = []
    /// Same for SETUP-audio - the 16-byte ping the RtpAudioReceiver sends.
    var audioPingPayload: [UInt8] = []
    /// The OPUS_MULTISTREAM config seed. Stereo default (sampleRate 48000,
    /// channelCount 2, streams 1, coupledStreams 1, mapping [0,1],
    /// samplesPerFrame 240). The RTSP SETUP-audio response carries NO explicit
    /// per-channel opus stream layout, so for surround the decoder derives the
    /// real {streams, coupledStreams, mapping} from the negotiated channel count
    /// (the host encodes from the same table) - see
    /// `AudioDecoder.opusMultistreamConfig(forChannels:)`. This seed supplies
    /// sampleRate + samplesPerFrame for every tier.
    var opusConfig: OpusConfig = RtspHandshakeResult.defaultOpusConfig

    /// Stereo default OPUS_MULTISTREAM config - the single source the struct
    /// default and the fast-start audio ping (constructed mid-handshake, before
    /// opus is otherwise referenced) both use.
    static let defaultOpusConfig = OpusConfig(
        sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 1,
        samplesPerFrame: 240, mapping: [0, 1])
    /// AudioPacketDuration in ms (5 default; SDP sends x-nv-aqos.packetDuration 5).
    var audioPacketDuration: Int = 5
    /// True iff the host negotiated AES-CBC audio (SS_ENC_AUDIO). Plaintext on
    /// the live host (encEnabled=0) - deferred encrypted path.
    var audioEncryption: Bool = false
}

enum RtspError: Error, CustomStringConvertible {
    case interrupted
    case connectTimeout(UInt16)
    case transportFailure(String)
    case badResponse(String)
    case nonOK(step: String, code: Int)
    case encryptedRtspUnsupported
    case noSdp

    var description: String {
        switch self {
        case .interrupted: return "RTSP interrupted"
        case .connectTimeout(let port): return "TCP connect to RTSP port \(port) timed out"
        case .transportFailure(let reason): return "RTSP transport failure: \(reason)"
        case .badResponse(let reason): return "RTSP bad response: \(reason)"
        case .nonOK(let step, let code): return "RTSP \(step) returned \(code)"
        case .encryptedRtspUnsupported:
            return "rtspenc:// (encrypted RTSP) not yet supported by the native backend"
        case .noSdp: return "RTSP DESCRIBE returned no SDP payload"
        }
    }
}

/// Drives the RTSP handshake. One instance per connection attempt.
final class RtspClient: @unchecked Sendable {
    static let logCategory = "NativeConnection"

    let host: NWEndpoint.Host
    let rtspPort: UInt16
    let rtspTargetUrl: String
    /// host portion used for the Host: header and SDP o= line.
    let urlAddr: String
    let urlSafeAddr: String
    let addrFamilyToken: String
    let rtspClientVersion: Int
    let config: BackendStreamConfig
    let serverCodecModeRaw: Int32
    let appVersionQuad: [Int32]

    /// Global CSeq counter, starts at 1, increments per request.
    var currentSeqNumber = 1
    var sessionIdString = ""
    var hasSessionId = false

    /// True when the launch URL is rtspenc:// - every message is AES-GCM sealed.
    let encryptedRtspEnabled: Bool
    /// Outbound GCM sequence number (pre-incremented per sealed message from 1).
    var encryptionSeq: UInt32 = 0

    /// Invoked the instant SETUP-audio is parsed (audioPort + audioPingPayload
    /// known), BEFORE SETUP video / ANNOUNCE / PLAY. The pipeline uses this to
    /// open the audio socket + start the burst ping mid-handshake, mirroring
    /// moonlight's notifyAudioPortNegotiationComplete() - Sunshine won't aim audio
    /// at us (and GFE 3.22 won't even reply to PLAY) until it has seen a ping.
    /// Synchronous so the ping is provably running before the handshake proceeds.
    var onAudioPortNegotiated: ((_ audioPort: UInt16, _ pingPayload: [UInt8]) -> Void)?

    /// Cancellation flag flipped by the orchestrator on interrupt.
    let interrupted = ManagedAtomicFlag()
    // The in-flight TCP connection, retained so interrupt()/timeout can cancel
    // a stalled connect or recv (without this, a host that accepts but never
    // responds would hang the receive loop forever). Lock-guarded: set on the
    // async pipeline, cancelled from interrupt() on another thread.
    let connLock = NSLock()
    var activeConnection: NWConnection?

    func setActiveConnection(_ conn: NWConnection?) {
        connLock.lock(); activeConnection = conn; connLock.unlock()
    }

    static let controlStreamId = "streamid=control/13/0"

    init(
        host: NWEndpoint.Host,
        rtspPort: UInt16,
        rtspTargetUrl: String,
        urlAddr: String,
        urlSafeAddr: String,
        addrFamilyToken: String,
        rtspClientVersion: Int,
        config: BackendStreamConfig,
        serverCodecModeRaw: Int32,
        appVersionQuad: [Int32]
    ) {
        self.host = host
        self.rtspPort = rtspPort
        self.rtspTargetUrl = rtspTargetUrl
        self.encryptedRtspEnabled = rtspTargetUrl.lowercased().contains("rtspenc://")
        self.urlAddr = urlAddr
        self.urlSafeAddr = urlSafeAddr
        self.addrFamilyToken = addrFamilyToken
        self.rtspClientVersion = rtspClientVersion
        self.config = config
        self.serverCodecModeRaw = serverCodecModeRaw
        self.appVersionQuad = appVersionQuad
    }

    func interrupt() {
        interrupted.set()
        connLock.lock(); let conn = activeConnection; connLock.unlock()
        conn?.cancel() // unblocks a stalled connect/recv → the await throws
    }

    // MARK: - Request building (initializeRtspRequest)

    func makeRequest(_ command: String, _ target: String) -> RtspMessage {
        var msg = RtspMessage(command: command, target: target)
        msg.headers.append(("CSeq", "\(currentSeqNumber)"))
        currentSeqNumber += 1
        msg.headers.append(("X-GS-ClientVersion", "\(rtspClientVersion)"))
        // The C code adds Host on the !useEnet (TCP) path with value = urlAddr.
        msg.headers.append(("Host", urlAddr))
        return msg
    }

    // MARK: - TCP transaction (transactRtspMessageTcp)

    /// Open a fresh TCP connection, send the serialized request, read until the
    /// server closes (EOF), then close. Retries connect on refused.
    func transact(_ request: RtspMessage) async throws -> RtspMessage {
        if interrupted.isSet { throw RtspError.interrupted }
        let plaintext = request.serialize()
        let toSend = encryptedRtspEnabled ? try sealRtsp(plaintext) : plaintext
        let responseData = try await sendAndReceive(toSend)
        let responseBytes = encryptedRtspEnabled ? try unsealRtsp(responseData) : responseData
        guard let response = RtspMessage.parseResponse(responseBytes) else {
            throw RtspError.badResponse("could not parse \(responseBytes.count) bytes")
        }
        return response
    }

    // MARK: - Encrypted RTSP (sealRtspMessage / unsealRtspMessage)

    static let encryptedRtspBit: UInt32 = 0x8000_0000

    /// Wrap a serialized RTSP message in the 24-byte encrypted header + GCM
    /// ciphertext. IV = seq (LE) + 'C''R'; seq pre-increments from 1.
    func sealRtsp(_ plaintext: Data) throws -> Data {
        encryptionSeq &+= 1
        let key = SymmetricKey(data: Data(config.remoteInputAesKey))
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(encryptionSeq & 0xff)
        iv[1] = UInt8((encryptionSeq >> 8) & 0xff)
        iv[2] = UInt8((encryptionSeq >> 16) & 0xff)
        iv[3] = UInt8((encryptionSeq >> 24) & 0xff)
        iv[10] = 0x43 // 'C' client-originated
        iv[11] = 0x52 // 'R' RTSP stream
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: Data(iv)))
        let typeAndLength = Self.encryptedRtspBit | UInt32(plaintext.count)
        var out = Data(capacity: 24 + plaintext.count)
        out.append(contentsOf: Self.beBytes(typeAndLength))
        out.append(contentsOf: Self.beBytes(encryptionSeq))
        out.append(Data(sealed.tag))        // 16 bytes
        out.append(Data(sealed.ciphertext)) // == plaintext.count bytes
        return out
    }

    /// Parse + decrypt an encrypted RTSP response. Rejects unencrypted or
    /// partial/excess frames exactly like unsealRtspMessage.
    func unsealRtsp(_ raw: Data) throws -> Data {
        guard raw.count > 24 else {
            throw RtspError.badResponse("encrypted RTSP header too small (\(raw.count))")
        }
        let bytes = [UInt8](raw)
        let typeAndLen = Self.beUInt32(bytes, 0)
        guard (typeAndLen & Self.encryptedRtspBit) != 0 else {
            throw RtspError.badResponse("rejecting unencrypted RTSP response")
        }
        let len = typeAndLen & ~Self.encryptedRtspBit
        guard Int(len) + 24 == raw.count else {
            throw RtspError.badResponse("encrypted RTSP length mismatch (len=\(len), raw=\(raw.count))")
        }
        let seq = Self.beUInt32(bytes, 4)
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xff)
        iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff)
        iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = 0x48 // 'H' host-originated
        iv[11] = 0x52 // 'R' RTSP stream
        let tag = raw.subdata(in: 8..<24)
        let ciphertext = raw.subdata(in: 24..<raw.count)
        let key = SymmetricKey(data: Data(config.remoteInputAesKey))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(iv)),
                                        ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    static func beBytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func beUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    /// One TCP round trip with ECONNREFUSED retry (500ms, up to 10s).
    func sendAndReceive(_ bytes: Data) async throws -> Data {
        let deadline = Date().addingTimeInterval(10)
        var attempt = 0
        while true {
            if interrupted.isSet { throw RtspError.interrupted }
            do {
                return try await oneShot(bytes)
            } catch let rtspError as RtspError {
                // Connection-refused-style failures get retried until the
                // deadline; everything else propagates.
                if case .transportFailure = rtspError, Date() < deadline {
                    attempt += 1
                    Diag.info("RTSP TCP connect not ready (attempt \(attempt)); retry in 500ms",
                              Self.logCategory)
                    try await Self.sleep(ms: 500)
                    continue
                }
                throw rtspError
            }
        }
    }

    /// A single connect → send → recv-until-EOF → close cycle.
    func oneShot(_ bytes: Data) async throws -> Data {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        guard let nwPort = NWEndpoint.Port(rawValue: rtspPort) else {
            throw RtspError.transportFailure("invalid RTSP port \(rtspPort)")
        }
        let connection = NWConnection(host: host, port: nwPort, using: params)
        setActiveConnection(connection)
        defer { setActiveConnection(nil) }
        let queue = DispatchQueue(label: "io.ugfugl.Glimmer.rtsp")

        // 1) Wait for the connection to become ready (or fail).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ManagedAtomicFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.testAndSet() { cont.resume() }
                case .failed(let err):
                    if resumed.testAndSet() {
                        cont.resume(throwing: RtspError.transportFailure("\(err)"))
                    }
                case .waiting(let err):
                    // .waiting on UDP/TCP usually means the endpoint isn't
                    // accepting yet (connection refused). Treat as retryable.
                    if resumed.testAndSet() {
                        connection.cancel()
                        cont.resume(throwing: RtspError.transportFailure("waiting: \(err)"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        // 2) Send the request.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: RtspError.transportFailure("send: \(err)"))
                } else {
                    cont.resume()
                }
            })
        }

        // 3) Receive until the server closes (isComplete) - EOF delimits.
        var accumulated = Data()
        while true {
            let (chunk, isComplete) = try await receiveChunk(connection)
            if let chunk { accumulated.append(chunk) }
            if isComplete { break }
        }
        connection.cancel()
        return accumulated
    }

    func receiveChunk(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: RtspError.transportFailure("recv: \(err)"))
                } else {
                    cont.resume(returning: (data, isComplete))
                }
            }
        }
    }

    static func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    // MARK: - The handshake (performRtspHandshake)

    func performHandshake() async throws -> RtspHandshakeResult {
        // Reset per-handshake state.
        currentSeqNumber = 1
        sessionIdString = ""
        hasSessionId = false

        var result = RtspHandshakeResult(
            audioPort: 48000, videoPort: 47998, controlPort: 47999,
            controlConnectData: 0, sessionId: "",
            negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H264,
            encryptionFeaturesSupported: 0, encryptionFeaturesEnabled: 0,
            referenceFrameInvalidationSupported: false)

        // 1) OPTIONS
        Diag.info("RTSP OPTIONS \(rtspTargetUrl)", Self.logCategory)
        let optionsResp = try await transact(makeRequest("OPTIONS", rtspTargetUrl))
        try check(optionsResp, step: "OPTIONS")

        // 2) DESCRIBE → parse SDP.
        Diag.info("RTSP DESCRIBE \(rtspTargetUrl)", Self.logCategory)
        var describe = makeRequest("DESCRIBE", rtspTargetUrl)
        describe.headers.append(("Accept", "application/sdp"))
        describe.headers.append(("If-Modified-Since", "Thu, 01 Jan 1970 00:00:00 GMT"))
        let describeResp = try await transact(describe)
        try check(describeResp, step: "DESCRIBE")
        guard let sdpData = describeResp.payload,
              let sdp = String(data: sdpData, encoding: .utf8)
                ?? String(data: sdpData, encoding: .isoLatin1) else {
            throw RtspError.noSdp
        }
        negotiate(sdp: sdp, into: &result)
        Diag.info("RTSP negotiated codec=\(codecName(result.negotiatedVideoFormat)) "
            + "encSupported=\(result.encryptionFeaturesSupported) "
            + "encEnabled=\(result.encryptionFeaturesEnabled) "
            + "RFI=\(result.referenceFrameInvalidationSupported)", Self.logCategory)

        // 3-5) SETUP audio / video / control.
        try await performSetupRounds(into: &result)

        // 6) ANNOUNCE (control stream id) with the SDP payload.
        result.encryptionFeaturesEnabled = computeEncryptionEnabled(
            supported: result.encryptionFeaturesSupported)
        // Audio is AES-CBC only if SS_ENC_AUDIO (0x04) was negotiated; our
        // connect-only SDP never enables it, so this stays false (plaintext).
        let ssEncAudio: UInt32 = 0x04
        result.audioEncryption = result.encryptionFeaturesEnabled & ssEncAudio != 0
        let sdpBuilder = SdpBuilder(
            config: config,
            videoPort: result.videoPort,
            urlSafeAddr: urlSafeAddr,
            addrFamilyToken: addrFamilyToken,
            rtspClientVersion: rtspClientVersion,
            negotiatedVideoFormat: result.negotiatedVideoFormat,
            encryptionFeaturesEnabled: result.encryptionFeaturesEnabled,
            appVersionQuad: appVersionQuad,
            // RFI is advertised (maxNumReferenceFrames=0) only when the host
            // offered it (DESCRIBE SDP) AND our decoder supports it for the
            // negotiated codec - the VideoSink's RFI capability bits.
            serverSupportsRfi: result.referenceFrameInvalidationSupported,
            decoderRfiCapabilities: VideoDecoder.rfiCapabilities)
        let sdpPayload = sdpBuilder.build()
        Diag.info("RTSP ANNOUNCE \(Self.controlStreamId) (SDP \(sdpPayload.count) bytes)",
                  Self.logCategory)
        var announce = makeRequest("ANNOUNCE", Self.controlStreamId)
        announce.headers.append(("Session", sessionIdString))
        announce.headers.append(("Content-type", "application/sdp"))
        announce.headers.append(("Content-length", "\(sdpPayload.count)"))
        announce.payload = sdpPayload
        let announceResp = try await transact(announce)
        try check(announceResp, step: "ANNOUNCE")

        // 7) PLAY "/" (single PLAY for 7.1.431+).
        Diag.info("RTSP PLAY /", Self.logCategory)
        var play = makeRequest("PLAY", "/")
        play.headers.append(("Session", sessionIdString))
        let playResp = try await transact(play)
        try check(playResp, step: "PLAY")

        Diag.notice("RTSP handshake complete → control port \(result.controlPort), "
            + "connectData=0x\(String(result.controlConnectData, radix: 16))",
            Self.logCategory)
        return result
    }

    /// SETUP rounds (steps 3-5 of the handshake), split out of
    /// `performHandshake`: SETUP audio (captures the Session id), SETUP video,
    /// then SETUP control (carries X-SS-Connect-Data + the control port).
    private func performSetupRounds(into result: inout RtspHandshakeResult) async throws {
        // 3) SETUP audio (no Session on the first SETUP - capture it here).
        Diag.info("RTSP SETUP streamid=audio/0/0", Self.logCategory)
        let audioResp = try await transact(makeSetup("streamid=audio/0/0"))
        try check(audioResp, step: "SETUP audio")
        result.audioPort = parsePort(audioResp) ?? 48000
        result.audioPingPayload = parsePingPayload(audioResp)

        // Fast-start: open the audio socket + start the burst ping NOW - before
        // SETUP video / ANNOUNCE / PLAY - so the host has our ping (and our return
        // port) in hand by PLAY and can aim audio immediately. moonlight calls
        // notifyAudioPortNegotiationComplete() at exactly this point
        // (RtspConnection.c:1212). The callback is best-effort: a ping failure
        // must not abort the handshake (audio is non-fatal); the pipeline logs it.
        onAudioPortNegotiated?(result.audioPort, result.audioPingPayload)

        try captureSession(from: audioResp, step: "SETUP audio")
        result.sessionId = sessionIdString

        // 4) SETUP video.
        Diag.info("RTSP SETUP streamid=video/0/0", Self.logCategory)
        let videoResp = try await transact(makeSetup("streamid=video/0/0"))
        try check(videoResp, step: "SETUP video")
        result.videoPort = parsePort(videoResp) ?? 47998
        result.videoPingPayload = parsePingPayload(videoResp)
        Diag.info("RTSP video ping payload: "
            + (result.videoPingPayload.isEmpty ? "absent (legacy PING)" : "captured 16 bytes"),
            Self.logCategory)

        // 5) SETUP control (carries X-SS-Connect-Data + control port).
        Diag.info("RTSP SETUP \(Self.controlStreamId)", Self.logCategory)
        let controlResp = try await transact(makeSetup(Self.controlStreamId))
        try check(controlResp, step: "SETUP control")
        if let cd = controlResp.headerValue("X-SS-Connect-Data") {
            result.controlConnectData = parseUInt32Auto(cd)
        }
        result.controlPort = parsePort(controlResp) ?? 47999
    }
}

/// A tiny lock-free-ish atomic flag built on os_unfair_lock-free semantics via
/// NSLock. Sufficient for the few cross-thread test-and-set sites in the RTSP
/// continuation glue.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    /// Set the flag; return true if THIS call was the one that set it (i.e. it
    /// was previously clear). Used to resume a continuation exactly once.
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}
