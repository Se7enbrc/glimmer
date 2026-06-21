//
//  VideoRtpReceiver.swift
//
//  Owns the video UDP flow for the Swift-native backend: ONE UNCONNECTED POSIX
//  UDP socket (bind a wildcard ephemeral local port; NEVER connect()) used for
//  BOTH the periodic ping (sendto host:VideoPortNumber - punches NAT + tells the
//  host where to send video) and RTP receive (recvfrom from ANY source). A
//  *connected* NWConnection silently drops video because Sunshine sources RTP
//  from a port != VideoPortNumber and a connected UDP flow filters by the full
//  4-tuple - that was the "no frames render" bug. Source: VideoStream.c +
//  PlatformSockets.c (bindUdpSocket = bind only; recvUdpSocket = recvfrom NULL
//  src).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  PING (VideoStream.c:54-82): send a 20-byte SS_PING
//  { char payload[16]; uint32 sequenceNumber (BIG-endian) } on the CONDITIONAL
//  steady cadence (EnvSignalController.steadyPingInterval - 75ms Wi-Fi-doze
//  keepalive / 500ms relaxed; upstream pings a flat 500ms). payload = the 16
//  raw bytes captured from SETUP-video X-SS-Ping-Payload. sequenceNumber starts
//  at 1, incremented BEFORE each send. If no payload captured (legacy GFE),
//  send the 4-byte { 0x50,0x49,0x4E,0x47 } ("PING") instead. The host will NOT
//  start sending video until it receives a ping - this is the most likely fix
//  for the frame watchdog firing on the native path today.
//
//  RECEIVE (VideoStream.c:85-236): for our SDP (encEnabled=0 ⇒ SS_ENC_VIDEO
//  unset) video is PLAINTEXT - NO decryption. Drop runt packets (< 12 bytes),
//  hand the rest to RtpVideoQueue which host-byteswaps the RTP header, runs FEC,
//  and feeds the depacketizer → VideoSink.
//
//  Teardown is bounded: the recv loop blocks in recvfrom with a 100ms SO_RCVTIMEO
//  so it polls `interrupted` and exits within 100ms; stop() also close()s the fd,
//  which unblocks any in-flight recvfrom immediately. The ping Task is cancellable.

import Foundation
import Network
import Darwin

final class VideoRtpReceiver: VideoDepacketizerDelegate, @unchecked Sendable {
    private static let cat = "NativeVideo"

    private let host: NWEndpoint.Host
    private let videoPort: UInt16
    private let pingPayload: [UInt8]   // 16 bytes, or empty for legacy
    private let packetSize: Int
    /// Negotiated stream bitrate (kbps). Sizes SO_RCVBUF by bandwidth-delay
    /// product (see `openSocket`) instead of a fixed packet count.
    private let bitrateKbps: Int
    private let encryptionFeaturesEnabled: UInt32
    private weak var sink: VideoSink?
    /// Called when the depacketizer wants an IDR (host should resend a key
    /// frame). Wired to the ENet control loop by NativeBackend.
    private let requestIdr: () -> Void
    /// Called when the depacketizer detects frame loss (RFI window). Wired to
    /// the ENet control loop by NativeBackend.
    private let invalidateReferenceFrames: (_ from: Int, _ to: Int) -> Void
    /// Called per-frame as FEC blocks complete-with-recovery or are abandoned
    /// (= moonlight's connectionSendFrameFecStatus). Wired to the ENet control
    /// loop's bounded FEC-status queue by NativeBackend. Best-effort.
    private let sendFrameFecStatus: (FrameFecStatus) -> Void

    /// Dedicated high-priority queue for the RTP receive loop. `.userInteractive`
    /// so recvfrom is never starved behind default-QoS work while the host fires
    /// ~14k pkts/s at 4K240 - matching moonlight-common-c's dedicated
    /// high-priority RTP receive thread (VideoStream.c VideoReceiveThreadProc).
    /// A default-QoS queue (the prior value) let the receive loop get preempted
    /// under load, which let the kernel socket buffer back up and serviced
    /// frames in bursts.
    private let recvQueue = DispatchQueue(
        label: "io.ugfugl.Glimmer.videortp", qos: .userInteractive)
    /// Unconnected bound UDP socket fd: bind to a wildcard ephemeral local port,
    /// recvfrom from ANY source. A connected NWConnection would drop video that
    /// Sunshine sources from a port != videoPort.
    private var fd: Int32 = -1
    /// Precomputed destination (host:videoPort) for the ping sendto.
    private var destAddr = sockaddr_storage()
    private var destAddrLen: socklen_t = 0
    private var pingThread: Thread?
    private let interrupted = ManagedAtomicFlag()

    private var rtpQueue: RtpVideoQueue!
    private var depacketizer: VideoDepacketizer!

    // Diagnostics latches.
    private var loggedFirstPacket = false
    private var pingCount: UInt32 = 0

    // SS_ENC_VIDEO bit (Limelight: ENCFLG_VIDEO maps to SS_ENC_VIDEO on the
    // EncryptionFeaturesEnabled bitmask). For our SDP this is 0 → plaintext.
    private static let SS_ENC_VIDEO: UInt32 = 0x02

    // SO_RCVBUF bandwidth-delay-product sizing (see openSocket). Kept LOCAL to
    // this file (not EnetWire) so the change stays self-contained.
    //
    /// Headroom RTT the receive buffer is sized to cover. Generous on purpose -
    /// the live RTT estimate isn't available yet at socket setup, and a too-small
    /// buffer turns a brief client-side scheduling stall into invisible wire loss.
    private static let rcvbufMaxExpectedRttSec = 0.15
    /// Extra fixed slack on top of the BDP for short bursts above the mean rate.
    private static let rcvbufBurstMarginBytes = 256 * 1024

    init(host: NWEndpoint.Host,
         videoPort: UInt16,
         pingPayload: [UInt8],
         packetSize: Int,
         bitrateKbps: Int,
         negotiatedVideoFormat: Int32,
         encryptionFeaturesEnabled: UInt32,
         appVersionQuad: [Int32],
         colorSpace: Int32,
         multiFecCapable: Bool,
         sink: VideoSink,
         requestIdr: @escaping () -> Void,
         invalidateReferenceFrames: @escaping (_ from: Int, _ to: Int) -> Void,
         sendFrameFecStatus: @escaping (FrameFecStatus) -> Void) {
        self.host = host
        self.videoPort = videoPort
        self.pingPayload = pingPayload
        self.packetSize = packetSize
        self.bitrateKbps = bitrateKbps
        self.encryptionFeaturesEnabled = encryptionFeaturesEnabled
        self.sink = sink
        self.requestIdr = requestIdr
        self.invalidateReferenceFrames = invalidateReferenceFrames
        self.sendFrameFecStatus = sendFrameFecStatus

        self.depacketizer = VideoDepacketizer(
            delegate: self,
            negotiatedVideoFormat: negotiatedVideoFormat,
            appVersionQuad: appVersionQuad,
            colorSpace: colorSpace)
        self.rtpQueue = RtpVideoQueue(
            depacketizer: depacketizer,
            packetSize: packetSize,
            multiFecCapable: multiFecCapable)
        // Route per-frame FEC status from the queue's reportFinalFrameFecStatus()
        // call sites out to the ENet control loop (Sunshine SS_FRAME_FEC_PTYPE).
        self.rtpQueue.frameFecStatusSink = sendFrameFecStatus
    }

    private var encrypted: Bool {
        (encryptionFeaturesEnabled & Self.SS_ENC_VIDEO) != 0
    }

    // MARK: - Lifecycle

    /// Open the socket, start the receive loop, then start pinging. Mirrors
    /// VideoStream.c start order: receive thread BEFORE ping thread so we're
    /// already listening when the first ping goes out.
    func start() async throws {
        if encrypted {
            // Defensive: our negotiated SDP has encEnabled=0. We do not yet
            // implement the AES-GCM ENC_VIDEO_HEADER path; fail loudly rather
            // than silently AES-fail every packet.
            Diag.error("NativeVideo SS_ENC_VIDEO set but native video decrypt "
                + "is unimplemented; aborting video receive", Self.cat)
            throw EnetError.socketFailure("encrypted video not supported on native path")
        }

        try openSocket()
        startReceiveLoop()
        startPingLoop()
        Diag.notice("NativeVideo receiver started → \(host):\(videoPort) "
            + "(packetSize=\(packetSize), \(pingPayload.isEmpty ? "legacy ping" : "16-byte ping"))",
            Self.cat)
    }

    func stop() {
        interrupted.set()
        pingThread = nil // the dedicated ping thread exits on the interrupted flag
        if fd >= 0 { close(fd); fd = -1 } // unblocks the in-flight recvfrom
    }

    // MARK: - Socket

    private func openSocket() throws {
        guard let (dest, destLen, family) = UdpPinger.makeSockaddr(for: host, port: videoPort) else {
            throw EnetError.socketFailure("could not build video host address for \(host)")
        }
        destAddr = dest
        destAddrLen = destLen

        let sock = socket(family, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EnetError.socketFailure("socket() errno \(errno)") }

        // Wi-Fi QoS: tag the socket NET_SERVICE_TYPE_VI (Interactive Video) - the
        // 802.11e WMM video access category - so the radio prioritizes video over
        // bulk/best-effort traffic while leaving the strictly-higher VOICE category
        // for audio. moonlight binds the video socket SOCK_QOS_TYPE_VIDEO →
        // SO_NET_SERVICE_TYPE=NET_SERVICE_TYPE_VI (PlatformSockets.c:253-254); the
        // audio socket gets the higher VO so audio keeps priority over video.
        var serviceType = Int32(NET_SERVICE_TYPE_VI)
        if setsockopt(sock, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                      &serviceType, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            Diag.warn("NativeVideo SO_NET_SERVICE_TYPE=VI failed errno \(errno) (non-fatal)", Self.cat)
        }
        // Large receive buffer, sized by BANDWIDTH-DELAY PRODUCT rather than a
        // fixed packet count. The old size (2048*(packetSize+16)) is a constant
        // number of packets whose TIME headroom shrinks as bitrate rises - at a
        // high bitrate those 2048 packets drain in a fraction of the RTT, so a
        // brief client-side scheduling stall silently overflows the kernel
        // buffer (= invisible wire loss). BDP sizing instead targets a fixed
        // TIME budget: rcvbuf ≈ bytes/sec * maxExpectedRttSec + burstMargin.
        // maxExpectedRttSec is a generous fixed assumption (the live RTT estimate
        // isn't available yet at socket setup). We clamp UP to the old fixed
        // value (never request LESS headroom than before) and DOWN to the
        // kernel's kern.ipc.maxsockbuf ceiling (requesting above it just clips,
        // wasting the request) before reading back what was actually granted -
        // the kernel can still grant less (mbuf-cluster accounting).
        let bitrateBytesPerSec = Double(bitrateKbps) * 1000.0 / 8.0
        let bdpBytes = Int(bitrateBytesPerSec * Self.rcvbufMaxExpectedRttSec)
            + Self.rcvbufBurstMarginBytes
        let floorBytes = 2048 * (packetSize + 16)
        var requested = max(bdpBytes, floorBytes)
        // Clamp DOWN to kern.ipc.maxsockbuf so we don't ask above the kernel cap.
        if let maxSockBuf = Self.kernMaxSockBuf(), requested > maxSockBuf {
            requested = maxSockBuf
        }
        var rcvbuf = Int32(clamping: requested)
        if setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            Diag.warn("NativeVideo SO_RCVBUF=\(rcvbuf) failed errno \(errno) (non-fatal)", Self.cat)
        } else {
            var granted: Int32 = 0
            var grantedLen = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_RCVBUF, &granted, &grantedLen) == 0 {
                Diag.info("NativeVideo SO_RCVBUF requested \(rcvbuf) → granted \(granted) "
                    + "(BDP \(bdpBytes)B @ \(bitrateKbps)kbps, floor \(floorBytes)B)", Self.cat)
            }
        }
        // 100ms recv timeout so the receive loop polls `interrupted` and exits
        // (UDP_RECV_POLL_TIMEOUT_MS in Limelight-internal.h).
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to a wildcard ephemeral local port - UNCONNECTED, so recvfrom
        // accepts RTP from any source port (Sunshine does NOT source video from
        // videoPort). The host learns our return port from the ping's UDP source.
        let bound: Bool
        if family == AF_INET {
            var ba = sockaddr_in()
            ba.sin_family = sa_family_t(AF_INET)
            ba.sin_addr.s_addr = 0 // INADDR_ANY
            ba.sin_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        } else {
            var ba = sockaddr_in6()
            ba.sin6_family = sa_family_t(AF_INET6)
            ba.sin6_addr = in6addr_any
            ba.sin6_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        guard bound else { close(sock); throw EnetError.socketFailure("bind() errno \(errno)") }

        fd = sock
        Diag.info("NativeVideo UDP socket ready (unconnected, recvfrom-any) → \(host):\(videoPort)",
                  Self.cat)
    }

    /// Read the kernel's per-socket buffer ceiling (`kern.ipc.maxsockbuf`) so we
    /// never request a SO_RCVBUF above it. Returns nil on any sysctl failure (the
    /// caller then leaves the request unclamped - the kernel still clips it).
    private static func kernMaxSockBuf() -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname("kern.ipc.maxsockbuf", &value, &size, nil, 0) == 0,
              value > 0 else { return nil }
        return value
    }

    // sockaddr construction is shared with UdpPinger (UdpPinger.makeSockaddr).

    // MARK: - Receive loop (callback-driven, cancellable)

    private func startReceiveLoop() {
        let sock = fd
        let bufSize = packetSize + 64
        recvQueue.async { [weak self] in
            // Name the thread this loop OWNS for the session: the blocking
            // recv loop occupies one worker until teardown, so this is an
            // owned entry point, not a transient pool block - and the hottest
            // thread in the process was sampling as an unresolvable `tid-NNN`
            // in the per-thread CPU telemetry (every hot sample unresolved in
            // testing; dispatch labels are not pthread names).
            // Cleared at loop exit so the borrowed worker returns to the pool
            // anonymous instead of mislabeling later unrelated work.
            pthread_setname_np("Glimmer.videoRecv")
            defer { pthread_setname_np("") }
            // Batched receive (issue #24): up to `cap` datagrams per recvmsg_x
            // syscall, cutting the ~14k recvfrom/s floor at 4K240 (measurably
            // smoother). Buffers allocated once and reused; handleDatagram
            // copies each out - the win is the syscall COUNT. recvmsg_x is a
            // Darwin-PRIVATE syscall with no public contract; if a future kernel
            // ever drops it the call returns ENOSYS and we fall back to one
            // recvfrom per datagram (slower - the syscall-count win is gone - but
            // correct) for the rest of the session. A removed SPI then degrades
            // the stream, it doesn't kill it.
            let cap = 32
            let stride = bufSize
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: cap * stride)
            let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
            defer { storage.deallocate(); lengths.deallocate() }
            var batched = true
            while let self, !self.interrupted.isSet {
                if batched {
                    let n = gl_recvmsg_x_batch(sock, storage, Int32(stride), Int32(cap), lengths)
                    if n > 0 {
                        for i in 0..<Int(n) {
                            // Clamp to stride: a bad length (never observed, but a
                            // private-API misread would be) must not read OOB.
                            let len = min(Int(lengths[i]), stride)
                            guard len > 0 else { continue }
                            self.handleDatagram(Array(UnsafeBufferPointer(start: storage + i * stride, count: len)))
                        }
                    } else if n < 0 {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { continue } // poll timeout
                        if err == ENOSYS {
                            // Batched receive not implemented on this kernel - drop
                            // to the per-datagram path for the rest of the session.
                            Diag.notice("recvmsg_x unavailable (ENOSYS) - falling back to recvfrom", Self.cat)
                            batched = false
                            continue
                        }
                        break // socket closed (stop) or fatal
                    }
                } else {
                    // Fallback: one recvfrom per datagram. Same SO_RCVTIMEO-driven
                    // EAGAIN cancellation as the batched path; close(fd) unblocks it.
                    let len = recvfrom(sock, storage, stride, 0, nil, nil)
                    if len > 0 {
                        self.handleDatagram(Array(UnsafeBufferPointer(start: storage, count: min(len, stride))))
                    } else if len < 0 {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { continue }
                        break
                    }
                }
            }
        }
    }

    private func handleDatagram(_ bytes: [UInt8]) {
        // minSize = sizeof(RTP_PACKET) = 12 (plaintext). Drop runts.
        guard bytes.count >= RtpVideoQueue.FIXED_RTP_HEADER_SIZE else { return }

        if !loggedFirstPacket {
            loggedFirstPacket = true
            // Peek the RTP seq + NV frameIndex/flags for the log.
            let seq = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
            var dataOffset = RtpVideoQueue.FIXED_RTP_HEADER_SIZE
            if bytes[0] & 0x10 != 0 { dataOffset += 4 }
            var frameIndex: UInt32 = 0
            var flags: UInt8 = 0
            if bytes.count >= dataOffset + 16 {
                frameIndex = UInt32(bytes[dataOffset + 4]) | (UInt32(bytes[dataOffset + 5]) << 8)
                    | (UInt32(bytes[dataOffset + 6]) << 16) | (UInt32(bytes[dataOffset + 7]) << 24)
                flags = bytes[dataOffset + 8]
            }
            Diag.notice("NativeVideo first RTP packet received "
                + "(seq=\(seq) frameIndex=\(frameIndex) flags=0x\(String(flags, radix: 16)) "
                + "len=\(bytes.count))", Self.cat)
        }

        let nowUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        rtpQueue.addRawDatagram(bytes, receiveTimeUs: nowUs)
    }

    // MARK: - Ping loop (steady keepalive, dedicated thread)

    /// Dedicated OS thread - NOT the Swift cooperative pool - so the keepalive
    /// can never be starved. Sunshine times out the whole session (~5s) if these
    /// pings stop, so this MUST keep firing under any load. Mirrors moonlight's
    /// VideoPingThreadProc dedicated pthread (VideoStream.c:55-81). The cadence
    /// is CONDITIONAL (EnvSignalController.steadyPingInterval): 75ms - the
    /// Wi-Fi-doze keepalive, WHY/VERDICT/COST on UdpPinger's dial - on a
    /// wifi/unknown stream route while input-idle or under link caution; 500ms
    /// (upstream's rate) on a confirmed-wired route or active-input clear wifi
    /// play. The thread always WAKES at the fast quantum (exactly the
    /// pre-conditional wake rate, so the thread cost is unchanged) and gates
    /// the SEND on the live interval: a cadence flip (idle onset, route
    /// change) takes effect within one quantum, and protocol safety never
    /// rides the slow path - even relaxed is 20x inside the 10s ping timeout.
    private func startPingLoop() {
        EnvSignalController.shared.noteVideoPingLoopStart()
        let thread = Thread { [weak self] in
            // 0 = "never pinged", so the first wake always sends (the
            // pre-conditional first-iteration behavior).
            var lastPingNanos: UInt64 = 0
            while let self, !self.interrupted.isSet {
                let interval = EnvSignalController.shared.steadyPingInterval()
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPingNanos >= EnvSignalController.dueNanos(for: interval) {
                    self.sendPing()
                    lastPingNanos = now
                }
                Thread.sleep(forTimeInterval: UdpPinger.steadyPingIntervalSeconds)
            }
        }
        thread.name = "Glimmer.videoPing"
        thread.qualityOfService = .userInitiated
        pingThread = thread
        thread.start()
    }

    private func sendPing() {
        guard fd >= 0 else { return }
        let datagram: [UInt8]
        if !pingPayload.isEmpty {
            pingCount &+= 1
            var out = pingPayload                 // 16 bytes
            let beSeq = pingCount.bigEndian
            withUnsafeBytes(of: beSeq) { out.append(contentsOf: $0) }  // 4 bytes BE
            datagram = out
        } else {
            // Legacy GFE 4-byte "PING".
            datagram = [0x50, 0x49, 0x4E, 0x47]
        }
        _ = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &destAddr) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fd, raw.baseAddress, raw.count, 0, sap, destAddrLen)
                }
            }
        }
        // pings_sent (the keepalive cadence judge): counts datagrams handed
        // to sendto - the counter whose absence made the 75ms experiment
        // unjudgeable from data. Always-live integer add at ≤13.3Hz.
        EnvSignalController.shared.videoPingsSentTotal.increment()
        if pingCount == 1 {
            Diag.notice("NativeVideo first video ping sent → \(host):\(videoPort) "
                + "(\(pingPayload.isEmpty ? "legacy" : "payload") seq=\(pingCount))", Self.cat)
        }
    }

    // MARK: - VideoDepacketizerDelegate

    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {
        guard let sink else { return }
        // Latency telemetry (opt-in; nil = zero cost). t_receive + t_assemble are
        // both already captured upstream - `receiveTimeUs` is the frame's
        // last/first-packet arrival and `enqueueTimeUs` is the reassemble
        // instant - so this is a pure map insert, no new clock read. Keyed by
        // rtpTimestamp (the only identity that survives the VideoToolbox boundary).
        // Done BEFORE the synchronous submit so the entry exists when the
        // submit/output stages record against it. us → ns (the upstream stamps
        // are `uptimeNanoseconds / 1000`, so ×1000 recovers the same monotonic
        // clock the later stages read).
        if let tracker = FrameTimingTracker.shared {
            tracker.recordAssembled(
                rtpTimestamp: unit.rtpTimestamp,
                frameIndex: unit.frameNumber,
                receiveNanos: unit.receiveTimeUs &* 1000,
                assembleNanos: unit.enqueueTimeUs &* 1000,
                frameBytes: unit.fullLength,
                isIDR: unit.frameType == StreamProtocol.FRAME_TYPE_IDR,
                // Host capture+encode latency for THIS frame, so glass-to-glass is
                // per-frame (the host-encode leg). 1/10 ms on the wire; converted
                // to ms inside the tracker.
                hostEncodeTenthsMs: unit.frameHostProcessingLatency)
            // P2 IDR/RFI ROUND-TRIP (signal: IDR-RTT): if an IDR landed while a
            // request was outstanding, this IS the resulting frame - resolve the
            // round-trip (request-send → arrival) into the histogram + trace.
            // Gate-on only (the tracker exists), so this is paired with the gate-on
            // arm in EnetControlChannel and costs nothing off. An unsolicited IDR
            // (the host's own keyframe cadence, no request pending) resolves to nil
            // and records nothing.
            if unit.frameType == StreamProtocol.FRAME_TYPE_IDR,
               let roundTripMs = TelemetryCounters.shared.p2.resolveIdrArrival(
                    TelemetryCounters.monotonicNowNanos()) {
                TelemetryCounters.shared.idrRoundTripMatchedTotal.increment()
                tracker.recordIdrRoundTrip(frameIndex: unit.frameNumber, roundTripMs: roundTripMs)
            }
        }
        let result = sink.submitDecodeUnit(unit)
        if result == StreamProtocol.DR_NEED_IDR {
            // Two producers share this return (VideoDecoder+Decode.swift
            // decodeAssembledFrame): a GENUINE sustained backlog stall
            // (reserveDecodeSlot - transient VPN bursts are absorbed by the
            // deeper in-flight bound and only a backlog that stays full while VT
            // produces no output reaches here), and the hidden-window decode
            // gate's DESIGNED resume resync (`.resyncToIdr` - the first
            // post-gate frame is a P-frame by timing on nearly every gated
            // resume: 8.3ms frame cadence vs the ~12ms IDR round-trip).
            // Recoverable, designed behavior logs quietly - warnings are for
            // faults - so the resume edge gets at most ONE info line (one by
            // construction: requestDecoderRefresh below puts the depacketizer
            // into wait-for-IDR on this thread, so no further non-IDR frame can
            // reach the submit boundary until the resync IDR lands); the stall
            // keeps its WARN.
            if isExpectedPostGateResync(isIDR: unit.frameType == StreamProtocol.FRAME_TYPE_IDR) {
                Diag.info("NativeVideo dropping pre-IDR frames until resync IDR "
                    + "(expected after decode gate; frame \(unit.frameNumber))", Self.cat)
            } else {
                Diag.warn("NativeVideo decoder backlog stall (frame \(unit.frameNumber)) "
                    + "- flushing to next IDR", Self.cat)
            }
            // Either cause needs the same recovery. moonlight's matching
            // overflow path (VideoDepacketizer.c:513-532) does NOT just request
            // a wire IDR - it flushes-to-IDR: waitingForIdrFrame +
            // dropFrameState + drop everything until the next real IDR. Driving
            // the depacketizer into wait-for-IDR here (we're on its owning
            // receive thread) means it STOPS emitting reference-broken P-frames
            // into VideoToolbox - that's what was causing the white/purple HDR
            // corruption, and the load-bearing concealment we must preserve.
            // requestDecoderRefresh also requests the IDR (coalesced to one per
            // loss event by ENet).
            depacketizer.requestDecoderRefresh()
        }
    }

    /// How recently the decode gate must have lifted for a DR_NEED_IDR on a
    /// non-IDR frame to read as the gate's designed resume resync (info)
    /// instead of a backlog stall (WARN). Generous next to the ≤~10ms the
    /// first post-gate submit actually takes (frames keep arriving at stream
    /// cadence through the gate). The worst misread - a genuine stall inside
    /// this window - costs one demoted log line, never recovery: the
    /// consumer's flush-to-IDR runs for both causes.
    private static let postGateResyncWindowSeconds = 1.0

    /// True iff a DR_NEED_IDR from the decoder is the hidden-window decode
    /// gate's designed resume resync rather than a genuine backlog stall. The
    /// gate's one-shot latch is consumed inside the decoder before
    /// `.resyncToIdr` returns, so it can't be read back directly; what
    /// survives the edge is the gate-lift stamp the decoder exposes
    /// (`secondsSinceDecodeGateLifted()`), and the resync conversion is by
    /// construction the FIRST frame to reach the submit boundary after that
    /// lift. An IDR can never take the resync path (it feeds and clears the
    /// latch), so a stall on the resync IDR itself still reads as a fault.
    /// The downcast is deliberate: `VideoSink` carries no gate-state surface
    /// and this only picks a LOG SEVERITY, so widening the protocol for it
    /// isn't warranted - a non-decoder sink keeps the conservative WARN.
    private func isExpectedPostGateResync(isIDR: Bool) -> Bool {
        !isIDR && secondsSinceGateLift < Self.postGateResyncWindowSeconds
    }

    /// Seconds since the decode gate last lifted, `.infinity` when the sink
    /// isn't the decoder (a non-decoder sink keeps every conservative WARN).
    private var secondsSinceGateLift: Double {
        (sink as? VideoDecoder)?.secondsSinceDecodeGateLifted() ?? .infinity
    }

    func depacketizerDetectedFrameLoss(from: Int, to: Int) {
        Diag.info("NativeVideo frame loss detected \(from)..\(to) → RFI", Self.cat)
        invalidateReferenceFrames(from, to)
    }

    func depacketizerNeedsIdr() {
        // Inside the gate-lift resync window this is the DESIGNED refocus path
        // (the post-gate P-frame drove the depacketizer into wait-for-IDR and
        // it now asks for one) - nearly all of one measured session's WARNINGs
        // were exactly this, each within 1s of a 'decode gate lifted' NOTICE.
        // Expected behavior logs quietly; WARN stays reserved for genuine IDR
        // starvation (loss-driven), where it still fires unchanged.
        if secondsSinceGateLift < Self.postGateResyncWindowSeconds {
            Diag.info("NativeVideo depacketizer needs IDR "
                + "(expected: gate-lift resync window)", Self.cat)
        } else {
            Diag.warn("NativeVideo depacketizer needs IDR", Self.cat)
        }
        requestIdr()
    }

    func depacketizerReceivedKeyFrame(frameNumber: Int) {
        Diag.info("NativeVideo key frame received (frame \(frameNumber))", Self.cat)
    }
}
