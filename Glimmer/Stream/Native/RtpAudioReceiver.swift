//
//  RtpAudioReceiver.swift
//
//  Owns the audio UDP flow for the Swift-native backend: ONE UNCONNECTED POSIX
//  UDP socket (bind a wildcard ephemeral local port; NEVER connect()) used for
//  BOTH the periodic ping (sendto host:audioPort) and RTP receive (recvfrom from
//  ANY source). The host sources audio RTP from a port != audioPort and aims it
//  at the ping's UDP source port, so a *connected* NWConnection would silently
//  drop audio - exactly the bug VideoRtpReceiver was built to avoid. This MIRRORS
//  VideoRtpReceiver's socket/ping pattern. Source: AudioStream.c
//  (AudioReceiveThreadProc + AudioPingThreadProc) + RtpAudioQueue.c.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  PING (AudioStream.c:38-65): send a 20-byte SS_PING
//  { payload[16] + sequenceNumber (UInt32 BE) } - the fast-start burst first,
//  then the CONDITIONAL steady cadence (EnvSignalController.steadyPingInterval
//  - 75ms Wi-Fi-doze keepalive / 500ms relaxed; upstream pings a flat
//  500ms) - payload =
//  the 16 raw bytes from the SETUP-audio X-SS-Ping-Payload header. seq starts
//  at 1, incremented BEFORE each send. If no payload captured (legacy GFE), send the 4-byte "PING"
//  { 0x50,0x49,0x4E,0x47 }. The host won't reply to RTSP PLAY (GFE 3.22) and
//  won't aim audio at us until it has received a ping - so ping + receive MUST
//  share one socket.
//
//  RECEIVE (AudioStream.c:239-383): drop runt packets (< 12 bytes); byteswap
//  the RTP header BE→host; feed the queue; dispatch the queue result to the
//  decoder. Where the C drops a fixed first-500ms of audio (GFE buffers samples
//  before the client is ready), we run a backlog-aware startup gate instead -
//  Sunshine paces audio live from seq ~0, so the fixed drop cost half a second
//  of LIVE audio per session (see the gate state docs below). For our SDP
//  (encEnabled=0) audio is PLAINTEXT - no AES-CBC decrypt. (Encryption support
//  is deferred; see the host constraints.)
//
//  Teardown is bounded: recvfrom blocks with a 100ms SO_RCVTIMEO so the loop
//  polls `interrupted` and exits within 100ms; stop() also close()s the fd, which
//  unblocks any in-flight recvfrom immediately. The ping Task is cancellable.
//
//  Code map (this type is split across same-module extension files)
//  ----------------------------------------------------------------
//    * RtpAudioReceiver.swift             - the class decl, stored state, the
//                                           StartupPacing enum, init, lifecycle,
//                                           and the receive loop / datagram path.
//    * RtpAudioReceiver+Socket.swift      - the unconnected-UDP socket bring-up.
//    * RtpAudioReceiver+Ping.swift        - the burst→steady keepalive thread.
//    * RtpAudioReceiver+StartupGate.swift - the backlog-aware startup gate.
//    * RtpAudioReceiver+Decrypt.swift     - the decode hand-off + AES-CBC path.
//    * RtpAudioReceiver+Events.swift      - the audio_ttf / audio_pending rows.
//    * RtpAudioReceiver+Telemetry.swift   - the per-window receive-quality fold.

import Foundation
import Network
import Darwin

/// The decode/playback sink the native audio receiver feeds. The concrete
/// implementation (AudioDecoder, adapted by the integrate step) already owns the
/// OpusMSDecoder + AVAudioEngine; this is just the call surface the receiver
/// needs. Distinct from `StreamingBackend.AudioSink` because the receiver hands
/// raw opus BYTES (post-FEC, post-decrypt) and needs an explicit packet-loss
/// concealment entry point that the existing `AudioSink` lacks.
public protocol NativeAudioSink: AnyObject, Sendable {
    /// Configure the opus decoder + audio engine. Returns 0 on success.
    /// `opus` is the negotiated multistream config; `audioConfig` is the
    /// GFE/Sunshine channel-layout code.
    func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32
    /// Decode + play one opus packet (raw bytes, after FEC + any decrypt).
    func decodeAndPlay(_ opus: [UInt8])
    /// Packet-loss concealment for one unrecovered/missing frame: invoke the opus
    /// decoder with no input so libopus conceals the gap (AudioStream.c:166-169).
    func decodeAndPlayPLC()
    /// Tear down the decoder + engine.
    func cleanup()
}

final class RtpAudioReceiver: @unchecked Sendable {
    static let cat = "NativeAudio"

    // Access note: many members below are module-internal (not private) so the
    // same-module split files (+Socket / +Ping / +StartupGate / +Decrypt /
    // +Events / +Telemetry - see the code map above) can reach them. The
    // threading contracts are unchanged: each field's docs say which thread
    // owns it.

    let host: NWEndpoint.Host
    let audioPort: UInt16
    let pingPayload: [UInt8]   // 16 bytes, or empty for legacy "PING"
    let audioPacketDuration: Int
    private let opusConfig: OpusConfig
    private let audioConfig: Int32

    // Audio encryption (AES-128-CBC). For our connect-only SDP (encEnabled=0)
    // this is false → plaintext. Support is wired but the live host is plaintext.
    let audioEncryption: Bool
    let aesKey: [UInt8]      // remoteInputAesKey (16 bytes)
    let avRiKeyId: UInt32    // BE32 of the first 4 bytes of remoteInputAesIv

    weak var sink: NativeAudioSink?

    /// Dedicated high-priority queue for the RTP receive loop. `.userInteractive`
    /// so recvfrom is never starved behind default-QoS work - the same
    /// scheduler-starvation bug the video path hit and fixed (see
    /// VideoRtpReceiver.recvQueue). A default-QoS queue (the prior value) let
    /// the receive loop get preempted under load for 70-215ms at a time, which
    /// let the kernel socket buffer back up and serviced the 5ms audio packets
    /// in bursts - draining the playout cushion (audible gap), then slamming the
    /// catch-up clump into the playout trim gates (audible crackle).
    private let recvQueue = DispatchQueue(
        label: "io.ugfugl.Glimmer.audiortp", qos: .userInteractive)
    /// Unconnected bound UDP socket fd (bind wildcard ephemeral; recvfrom any).
    var fd: Int32 = -1
    /// Precomputed destination (host:audioPort) for the ping sendto.
    var destAddr = sockaddr_storage()
    var destAddrLen: socklen_t = 0
    var pingThread: Thread?
    let interrupted = ManagedAtomicFlag()

    // `internal` so the RtpAudioReceiver+Telemetry extension can read `queue.stats`
    // for the per-window receive-quality fold; touched only on `recvQueue`.
    var queue: RtpAudioQueue!

    // Receive-thread state (all touched only on recvQueue).
    private var receivedDataFromPeer = false
    private var loggedFirstPacket = false

    // --- Backlog-aware startup gate (recvQueue-confined, one-shot). ---
    // moonlight-common-c discards a fixed 500ms of audio at start because GFE
    // pre-buffers samples before the client is ready. Sunshine never front-loads:
    // audio arrives at real-time pace from seq ~0 (proven on this host's session
    // data), so the fixed drop was throwing away half a second of LIVE audio
    // every session - over half the <1s time-to-first-audio budget. Instead we
    // MEASURE the first window's arrival pacing: a live source can only deliver
    // ~1x real time (one packetDuration of audio per packetDuration of wall
    // clock), so ≥2x sustained across ~100ms proves a flushed backlog (a
    // GFE-style host pre-buffer, or our own SO_RCVBUF holding early-start
    // arrivals) - and only then do we drop, and only the measured stale excess,
    // keeping the decision window's worth (already decoded) as the playout
    // cushion. Cost on the hot path: integer counts per packet plus a clock
    // read only at the window edges (and per packet during a burst drain,
    // which is over in a few ms); once latched, a single enum compare.
    enum StartupPacing {
        /// First window after the first data packet: decode everything (paced is
        /// the proven norm, and withholding live audio is exactly the cost this
        /// gate removes) while counting the arrival pacing.
        case measuring
        /// Burst verdict: a backlog is flushing - discard decodes until the
        /// backlog-ahead estimate stops growing (the live edge).
        case draining
        /// Verdict latched (one-shot); the gate is a single compare per packet.
        case decided
    }
    var startupPacing: StartupPacing = .measuring
    /// Data (type-97) packets since the first one - arrived audio-ms is this ×
    /// `audioPacketDuration`. FEC datagrams carry no audio-ms and are never
    /// counted (under loss the pacing estimate then reads LOW, biasing toward
    /// the paced verdict - the safe direction: nothing gets dropped).
    var startupDataPackets = 0
    /// Monotonic stamp of the first data packet - the pacing clock's zero.
    var startupFirstDataNanos: UInt64 = 0
    /// Backlog-ahead estimate (arrived-audio-ms − elapsed-ms) at the previous
    /// drain packet; the drain stops the moment this stops growing.
    var startupPrevAheadMs = 0.0
    /// Queue outputs the drain discarded at the decode hand-off - the verdict
    /// log's and audio_ttf's dropped_ms is this × `audioPacketDuration`.
    var startupDroppedPackets = 0
    /// Latched verdict, kept for the audio_ttf event fields.
    var startupVerdictBurst = false

    // --- P1 AUDIO telemetry: ~1s metrics window (Track B, opt-in). The audio
    // receive-quality totals are folded into the always-live `TelemetryCounters`
    // once per window - NOT per packet - so the hot per-datagram path stays a
    // straight decode. We read RtpAudioQueue's cumulative `Stats` (which it
    // already maintains) and publish the per-window DELTAS, exactly mirroring how
    // the video receive path batches its receive-quality totals. All touched only
    // on recvQueue (single receive thread), so no lock is needed here. The flush
    // logic lives in RtpAudioReceiver+Telemetry.swift (extensions can't hold stored
    // state, so the fields stay here `internal` while the method moves out - which
    // keeps this file under the SwiftLint length limit, like the video split). ---
    var audioMetricsWindowStartNanos: UInt64 = 0
    static let audioMetricsWindowNanos: UInt64 = 1_000_000_000  // 1s
    /// Last-flushed cumulative RtpAudioQueue stats, so each window publishes the
    /// delta into the monotonic TelemetryCounters audio totals.
    var lastFlushedAudioPackets: UInt32 = 0
    var lastFlushedFecRecovered: UInt32 = 0
    /// Unrecovered audio-loss this window, counted as the PLC placeholders the
    /// queue emits for missing data shards FEC couldn't recover - the precise
    /// audible-gap count (one per data packet the user won't hear). Folded into the
    /// loss total each window, then zeroed.
    var audioLostInWindow: Int = 0
    /// Last datagram-arrival instant (uptime ns) for the per-socket GAP-EVENT
    /// counters (the audio leg of the 20/50/100ms family); 0 until the first
    /// datagram. recvQueue-confined like the rest of the receive-thread state.
    var lastDatagramArrivalNanos: UInt64 = 0

    // Ping/receive bring-up latches. `pingStarted`/`receiveStarted` make
    // startPing()/startReceive() idempotent so the early-start (mid-handshake)
    // and the post-connect path can't double-open the socket or double-init the
    // sink. `pingCount` is owned by the ping thread.
    private var pingStarted = false
    private var receiveStarted = false
    var pingCount: UInt32 = 0
    private var initialized = false

    // --- Time-to-first-packet metric (Track B; logged via Diag since we don't
    // own StatsCollector). `pingStartTimeUs` is stamped by the ping thread when
    // the first ping goes out; `pingsSent` mirrors pingCount so the recv thread
    // can read "pings until first RTP". Both cross the ping↔recv thread boundary,
    // so they're atomics. The recv thread reads them when the first RTP arrives. ---
    let pingStartTimeUs = AtomicUInt64()
    let pingsSent = AtomicUInt64()

    /// Cross-thread first-RTP latch for the silent-audio probe: SET on the first
    /// audio RTP datagram (any type). `receivedDataFromPeer` carries the same
    /// fact but is confined to `recvQueue` - which the blocking receive loop
    /// occupies for the whole session, so the probe can't hop there to read it.
    let firstRtpReceived = ManagedAtomicFlag()
    /// `audio_ttf` event fields stashed at the first-DATAGRAM latch and emitted
    /// at the startup-pacing verdict (≲200ms later), so one event row carries
    /// both honest TTF spans plus the gate's verdict. recvQueue-confined.
    var firstRtpPingToRtpMs: Double?
    var firstRtpPings: UInt64 = 0
    /// Consecutive ping sendto() failures - for STREAK-EDGE logging only (first
    /// failure + recovery, never per packet). Owned by the ping thread.
    var pingSendFailureStreak = 0

    static let maxPacketSize = 1400  // MAX_PACKET_SIZE

    /// Startup-pacing decision window: enough audio-ms that a PACED flow through
    /// this link's clumpy radio (routine 40-110ms coalesced deliveries) still
    /// averages out to ~1x - a live source only EMITS ~100ms of audio in 100ms
    /// no matter how delivery clumps - while a real backlog flush lands the
    /// whole window in a few ms. Small enough that the kept window doubles as a
    /// healthy playout cushion (between the decoder's 30ms base and 150ms cap).
    private static let startupDecisionWindowMs = 100
    /// The decision window in data packets (set from audioPacketDuration; ~20 at
    /// 5ms). Min 2 so the rate comparison always has an interval to measure.
    let startupDecisionPackets: Int
    /// Burst-verdict floor for the measured rate (arrived-audio-ms ÷
    /// elapsed-wall-ms) across the decision window. A live source physically
    /// cannot sustain >1x - clumpy radio delivery re-times packets WITHIN the
    /// window but cannot mint extra audio-ms across it - so ≥2x sustained
    /// means at least half the window pre-existed it: a backlog. The worst
    /// misread (a delivery clump landing exactly at audio start) costs a few
    /// ms of drain overshoot (see updateStartupPacing), never a permanent
    /// give-up - the gate latches and gets out of the way either way.
    static let startupBurstRateFloor = 2.0

    // Audio ping cadence (the fast-start burst). moonlight sends a steady 500ms
    // keepalive; we BURST the first ~2s every 80ms so the host receives a ping
    // (and starts aiming audio) within a few tens of ms of the socket opening,
    // then settle to the steady keepalive (Sunshine times out if it stops).
    // The steady tail is CONDITIONAL: the loop wakes at the fast quantum
    // (steadyIntervalSec = UdpPinger.steadyPingIntervalSeconds, the 75ms
    // Wi-Fi-doze keepalive - WHY/VERDICT/COST live on that dial) and gates
    // each send on EnvSignalController.steadyPingInterval(), which relaxes to
    // UdpPinger.relaxedPingIntervalSeconds (500ms, upstream's rate) on a
    // confirmed-wired route or active-input clear wifi play. The burst stays
    // a separate, UNCONDITIONAL connect-time mechanism either way: its job is
    // the first-ping latency, not the radio-doze hold, and no cadence policy
    // change must ever slow it down.
    static let burstIntervalSec = 0.08
    static let burstDurationSec = 2.0
    static let steadyIntervalSec = UdpPinger.steadyPingIntervalSeconds

    /// Silent-audio probe delay: how long after the receive path comes up (the
    /// post-connect bring-up, when video is starting - the closest
    /// receiver-visible proxy for "video started") before flagging that no audio
    /// RTP has arrived. Host cold-start audio bring-up of 4-40s is the observed
    /// norm; the probe only makes the silence VISIBLE - the ping loop keeps
    /// retrying regardless (it never gives up).
    static let audioPendingProbeSeconds = 3.0

    /// - Parameters:
    ///   - host: the host IP (from RTSP), IP literal expected.
    ///   - audioPort: the negotiated SETUP-audio server port (fallback 48000).
    ///   - pingPayload: 16 raw bytes from X-SS-Ping-Payload, or empty for legacy.
    ///   - appVersionQuad: parsed host version [major, minor, patch, build].
    ///   - audioPacketDuration: AudioPacketDuration in ms (5 default).
    ///   - opusConfig: the negotiated OPUS_MULTISTREAM config (samplesPerFrame is
    ///     expected to already be 48 * audioPacketDuration).
    ///   - audioConfig: GFE/Sunshine channel-layout code (STREAM_CFG audio config).
    ///   - audioEncryption: true iff the host negotiated AES-CBC audio (deferred;
    ///     plaintext on the live host).
    ///   - aesKey: remoteInputAesKey (16 bytes). Unused when not encrypting.
    ///   - aesIvId: remoteInputAesIv (first 4 bytes seed the per-packet IV).
    ///   - sink: the decode/playback sink.
    init(host: NWEndpoint.Host,
         audioPort: UInt16,
         pingPayload: [UInt8],
         appVersionQuad: [Int32],
         audioPacketDuration: Int,
         opusConfig: OpusConfig,
         audioConfig: Int32,
         audioEncryption: Bool,
         aesKey: [UInt8],
         aesIvId: [UInt8],
         sink: NativeAudioSink) {
        self.host = host
        self.audioPort = audioPort
        self.pingPayload = pingPayload
        self.audioPacketDuration = max(1, audioPacketDuration)
        self.opusConfig = opusConfig
        self.audioConfig = audioConfig
        self.audioEncryption = audioEncryption
        self.aesKey = aesKey
        self.sink = sink

        // avRiKeyId = BE32 of the first 4 bytes of remoteInputAesIv (AudioStream.c:80-82).
        var keyId: UInt32 = 0
        for i in 0..<4 where i < aesIvId.count {
            keyId = (keyId << 8) | UInt32(aesIvId[i])
        }
        self.avRiKeyId = keyId

        // Backlog-aware startup gate window, in data packets (see the gate state
        // docs; replaces the C's fixed 500ms drop, AudioStream.c:248).
        self.startupDecisionPackets =
            max(2, Self.startupDecisionWindowMs / self.audioPacketDuration)
        self.queue = RtpAudioQueue(appVersionQuad: appVersionQuad,
                                   audioPacketDuration: self.audioPacketDuration)
    }

    // MARK: - Lifecycle

    /// FAST-START phase (mid-handshake): open the socket + start the burst-ping
    /// loop. Mirrors moonlight's notifyAudioPortNegotiationComplete(), which opens
    /// the audio socket and starts the ping thread the instant SETUP-audio is
    /// parsed - BEFORE PLAY - because Sunshine won't aim audio at us (GFE 3.22
    /// won't even reply to PLAY) until it has received a ping. Needs only
    /// host/audioPort/pingPayload, all known at SETUP-audio time. Idempotent.
    ///
    /// We may receive audio before startReceive() opens the recv loop; that's
    /// fine - the kernel buffers it in SO_RCVBUF, and when the recv loop drains
    /// that buffer back-to-back the startup gate reads it as a BURST and drops
    /// the stale excess (the fixed 500ms drop this replaced handled at most
    /// 500ms of such backlog; the gate handles any depth).
    func startPing() throws {
        if pingStarted { return }
        try openSocket()
        pingStarted = true
        // P1 AUDIO cold-start anchor: stamp STREAM START the instant the audio
        // socket opens (mid-handshake, the earliest well-defined audio start), so
        // the first-decoded-audio metric measures the true cold-start window (the
        // known ~5-7s-on-lossy-link issue). Always-live + idempotent; read only
        // when telemetry is on.
        TelemetryCounters.shared.anchorAudioStreamStart()
        startPingLoop()
        Diag.notice("NativeAudio ping started → \(host):\(audioPort) "
            + "(\(pingPayload.isEmpty ? "legacy ping" : "16-byte ping"), "
            + "burst \(Int(Self.burstIntervalSec * 1000))ms for "
            + "\(Int(Self.burstDurationSec))s → steady conditional "
            + "\(Int(Self.steadyIntervalSec * 1000))ms fast / "
            + "\(Int(UdpPinger.relaxedPingIntervalSeconds * 1000))ms relaxed)", Self.cat)
    }

    /// RECEIVE phase (post-connect): initialize the decoder/engine and start the
    /// recv loop. The ping must already be running (startPing); if it isn't (e.g.
    /// the early-start path was skipped) we bring it up here for safety. Idempotent.
    func startReceive() throws {
        if receiveStarted { return }
        // The ping side normally started mid-handshake; ensure the socket is open.
        if !pingStarted { try startPing() }

        // Configure the decoder/engine before any audio is dispatched.
        if let sink {
            let rc = sink.initialize(audioConfig: audioConfig, opus: opusConfig)
            if rc != 0 {
                Diag.error("NativeAudio sink initialize failed (\(rc))", Self.cat)
                throw EnetError.socketFailure("audio sink initialize failed (\(rc))")
            }
            initialized = true
        }
        receiveStarted = true
        startReceiveLoop()
        armAudioPendingProbe()
        Diag.notice("NativeAudio receive started → \(host):\(audioPort) "
            + "(packetDuration=\(audioPacketDuration)ms, "
            + "\(audioEncryption ? "AES-CBC" : "plaintext"))", Self.cat)
    }

    /// Convenience: bring up both phases at once (ping + receive). Retained for
    /// callers/tests that don't split the bring-up across the handshake.
    func start() throws {
        try startPing()
        try startReceive()
    }

    func stop() {
        interrupted.set()
        // Stamp the stream-end instant for the NEXT session's `host_idle_s`
        // covariate (the warm/cold TTF classification): this teardown trails the
        // last audio packet by well under a second - close enough for a covariate
        // whose interesting scale is minutes. The stamp deliberately survives
        // `resetForNewSession` (it anchors the next session's measurement);
        // last-writer-wins, so a repeated stop() harmlessly re-stamps.
        TelemetryCounters.shared.audioTtf.markStreamEnd()
        pingThread = nil // the dedicated ping thread exits on the interrupted flag
        if fd >= 0 { close(fd); fd = -1 }  // unblocks the in-flight recvfrom
        if initialized {
            sink?.cleanup()
            initialized = false
        }
    }

    // MARK: - Receive loop (callback-driven, cancellable)

    private func startReceiveLoop() {
        let sock = fd
        let bufSize = Self.maxPacketSize
        recvQueue.async { [weak self] in
            // Session-long owned loop: name it so the per-thread CPU telemetry
            // resolves it (cleared at exit; same medicine as the video loop).
            pthread_setname_np("Glimmer.audioRecv")
            defer { pthread_setname_np("") }
            var buf = [UInt8](repeating: 0, count: bufSize)
            while let self, !self.interrupted.isSet {
                let received = recvfrom(sock, &buf, bufSize, 0, nil, nil)
                if received > 0 {
                    self.handleDatagram(buf, count: received)
                } else if received == 0 {
                    // Quiet socket after we've heard from the peer: no kernel
                    // backlog remains, so a pending startup-pacing measurement
                    // resolves to the live edge (AudioStream.c:276-288 clears
                    // its pendingDrops on the same evidence).
                    self.resolveStartupPacingOnIdle()
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                        // Poll timeout (100ms of recv silence): same quiet-socket
                        // proof as above - whatever arrives NEXT is delayed LIVE
                        // audio (a radio-coalesced clump), not a host backlog,
                        // and must not be eaten by the startup gate.
                        self.resolveStartupPacingOnIdle()
                        continue
                    }
                    break // socket closed (stop) or fatal
                }
            }
        }
    }

    private func handleDatagram(_ buf: [UInt8], count: Int) {
        // Per-socket GAP-EVENT accumulation first (before the runt check - a runt
        // is still a socket arrival, and the counters measure the ARRIVAL process).
        noteAudioArrivalGap()

        // Runt check: must be at least a full 12-byte RTP header (AudioStream.c:290).
        if count < RtpAudioQueue.fixedRtpHeaderSize {
            return
        }

        if !receivedDataFromPeer {
            receivedDataFromPeer = true
            firstRtpReceived.set()
            // Time-to-first-packet metric: how long from the first ping until the
            // host aimed audio at us, and how many pings it took. Target <1s -
            // met on warm reconnects (~284ms), but a COLD host takes 4-40s to
            // bring its audio pipeline up (host-side; the ping cadence never
            // pauses), so over-target reads are expected and flagged by the
            // `audio_ttf` event emitted at the startup-pacing verdict latch.
            let startUs = pingStartTimeUs.load()
            firstRtpPings = pingsSent.load()
            if startUs != 0 {
                let nowUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
                let ttfpMs = Double(nowUs &- startUs) / 1000.0
                firstRtpPingToRtpMs = ttfpMs
                Diag.notice("NativeAudio METRIC time-to-first-packet=\(String(format: "%.0f", ttfpMs))ms "
                    + "pings-until-first-RTP=\(firstRtpPings) (target <1000ms; len=\(count))", Self.cat)
            } else {
                Diag.notice("NativeAudio first audio packet received (len=\(count))", Self.cat)
            }
        }

        // Peek the packet type (single byte, no swap).
        let packetType = buf[1]

        // Backlog-aware startup gate (replaces the C's fixed 500ms drop,
        // AudioStream.c:312-318): classify the first window's arrivals as PACED
        // (live - decode everything, withhold nothing) or BURST (a flushed
        // backlog - drain the stale excess). Either way this datagram still
        // feeds the queue below, so sequence/FEC/stats bookkeeping stays
        // coherent (an early return here would read to the queue as a giant
        // loss gap and churn the FEC/PLC machinery when feeding resumed); the
        // discard happens at the decode hand-off instead.
        var dropForStartup = false
        if startupPacing != .decided {
            dropForStartup =
                updateStartupPacing(isData: packetType == RtpAudioQueue.payloadTypeAudio)
        }

        // Byteswap the multi-byte RTP fields BE→host (AudioStream.c:321-323). The
        // header + packetType bytes are single bytes (no swap).
        let packet = Array(buf[0..<count])
        let rtp = RtpAudioQueue.RtpHeader(
            header: packet[0],
            packetType: packet[1],
            sequenceNumber: UInt16(packet[2]) << 8 | UInt16(packet[3]),
            timestamp: UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16
                | UInt32(packet[6]) << 8 | UInt32(packet[7]),
            ssrc: UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16
                | UInt32(packet[10]) << 8 | UInt32(packet[11]))

        if !loggedFirstPacket {
            loggedFirstPacket = true
            // P1 AUDIO cold-start: record the first DECODED audio RTP instant -
            // the exporter surfaces (this − the stream-start anchor) as the
            // time-to-first-audio gauge. Always-live; read only when telemetry
            // on. With the backlog-aware gate the first arrival IS the first
            // decode (the measuring phase withholds nothing), so this lands
            // ~500ms earlier than under the old fixed drop. The audio_ttf event
            // row is emitted later, at the gate's verdict latch, so it can carry
            // the verdict alongside both TTF spans.
            TelemetryCounters.shared.recordAudioFirstPacket()
            Diag.notice("NativeAudio first decoded RTP "
                + "(seq=\(rtp.sequenceNumber) type=\(rtp.packetType) len=\(count))", Self.cat)
        }

        let result = queue.addPacket(packet, rtp: rtp)
        // P1 AUDIO receive-quality: fold the queue's cumulative stats into the
        // always-live telemetry totals once per ~1s window (off the per-packet
        // path). Done after addPacket so the window sees this packet's effect.
        flushAudioMetricsIfDue()
        switch result {
        case .handleNow:
            // In-order fast path: decode this packet immediately - unless the
            // startup gate marked it stale (burst drain), in which case the
            // queue bookkeeping above already ran and only the listener-facing
            // decode is withheld.
            if dropForStartup {
                startupDroppedPackets += 1
            } else {
                decodePacket(packet)
            }
        case .packetReady:
            // Drain ready packets (and PLC placeholders) until none remain. The
            // whole batch shares this datagram's startup-gate verdict: queue
            // outputs lag the newest arrival by at most the small OOS window,
            // so the verdict-boundary error is a packet or two of extra
            // cushion - noise next to the decoder's trim machinery.
            while let queued = queue.getQueuedPacket() {
                switch queued {
                case .bytes(let bytes):
                    if dropForStartup {
                        startupDroppedPackets += 1
                    } else {
                        decodePacket(bytes)
                    }
                case .lostPlaceholder:
                    // P1 AUDIO: an unrecovered missing data shard. Count the
                    // wire loss either way (it happened; a single integer add
                    // on the receive thread, no lock) - but only conceal a gap
                    // the user will actually hear: during a startup drain the
                    // surrounding audio is being discarded, so PLC would just
                    // synthesize filler into a timeline nobody plays. Dropped
                    // placeholders still count toward dropped_ms because it
                    // measures the TIMELINE removed, not just decodable audio.
                    audioLostInWindow += 1
                    if dropForStartup {
                        startupDroppedPackets += 1
                    } else {
                        sink?.decodeAndPlayPLC()
                    }
                }
            }
        case .none:
            break
        }
    }

    /// Per-socket GAP-EVENT accumulation - the AUDIO leg of the 20/50/100ms
    /// family (cumulative: a 100ms gap counts in all three). The video socket
    /// already tracked inter-arrival gaps; this completes the trio so "all
    /// sockets gapped together" (NIC doze) vs "one path stalled" is a single
    /// NDJSON-row query instead of a three-source manual cross-correlation.
    /// Cost per datagram (~200/s at 5ms packets): one monotonic clock read +
    /// one compare - far below the 5ms audio budget (the ~1s metrics fold pays
    /// its own read; merging the two would mean restructuring its call
    /// signature for a ~40ns saving). The counters' locked add fires only on a
    /// >20ms gap, i.e. only after the socket just sat idle that long.
    /// recvQueue-confined; always-live, read only when telemetry is on.
    private func noteAudioArrivalGap() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastDatagramArrivalNanos != 0 {
            let gap = now &- lastDatagramArrivalNanos
            if gap > 20_000_000 {
                let counters = TelemetryCounters.shared
                counters.audioGapOver20msTotal.increment()
                if gap > 50_000_000 { counters.audioGapOver50msTotal.increment() }
                if gap > 100_000_000 { counters.audioGapOver100msTotal.increment() }
            }
        }
        lastDatagramArrivalNanos = now
    }

    // The P1 AUDIO per-window receive-quality fold (`flushAudioMetricsIfDue`) lives
    // in RtpAudioReceiver+Telemetry.swift, split out to keep this type's body under
    // the SwiftLint length limit (the same pattern the video receive path uses for
    // its receive-quality accumulation). The window-state fields above are
    // `internal` so that extension can reach them; everything still runs on the
    // single receive thread (`recvQueue`).
}
