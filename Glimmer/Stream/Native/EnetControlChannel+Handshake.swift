//
//  EnetControlChannel+Handshake.swift
//
//  The CONNECT → VERIFY_CONNECT → ACK handshake and the reliable START_A /
//  START_B sends that follow it - everything establishAndStart() drives to reach
//  "connected". Split out of EnetControlChannel.swift to keep each unit focused;
//  see that file for the shared stored state and wire facts.
//

import Foundation
import Network

extension EnetControlChannel {
    // MARK: - Public: establish + START_A/B

    /// Open the UDP socket, run the CONNECT handshake to VERIFY_CONNECT + ACK,
    /// then send START_A and START_B reliably. Returns once both are ACKed
    /// (= "connected"). Throws at the specific failing stage otherwise.
    func establishAndStart(stage: (String) -> Void,
                           stageDone: (String) -> Void,
                           stageFailed: (String, Int32) -> Void) async throws {
        // --- ENET_CONNECT stage ---
        stage("ENET_CONNECT")
        do {
            try await openSocket()
            try queueAndSendConnect()
            try await awaitVerifyConnect(timeoutMs: 10_000)
        } catch {
            stageFailed("ENET_CONNECT", enetCode(error))
            throw error
        }
        stageDone("ENET_CONNECT")

        // --- START_A stage ---
        stage("START_A")
        do {
            try await sendStart(index: 0, label: "START_A")
        } catch {
            stageFailed("START_A", enetCode(error))
            throw error
        }
        stageDone("START_A")

        // --- START_B stage ---
        stage("START_B")
        do {
            try await sendStart(index: 1, label: "START_B")
        } catch {
            stageFailed("START_B", enetCode(error))
            throw error
        }
        stageDone("START_B")
    }

    // MARK: - UDP socket

    func openSocket() async throws {
        let params = NWParameters.udp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw EnetError.socketFailure("invalid control port \(port)")
        }
        let conn = NWConnection(host: host, port: nwPort, using: params)
        setConnection(conn) // locked write - see connLock

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ManagedAtomicFlag()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resumed.testAndSet() { cont.resume() }
                    self?.startReceiveLoop()
                case .failed(let err):
                    if resumed.testAndSet() {
                        cont.resume(throwing: EnetError.socketFailure("\(err)"))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        Diag.info("ENet UDP socket ready → \(host):\(port)", Self.logCategory)
    }

    // MARK: - CONNECT (host.c enet_host_connect)

    /// Build + send the 48-byte CONNECT command (command 0x82, channel 0xFF,
    /// reliableSequenceNumber 1) inside a SENT_TIME-flagged datagram.
    func queueAndSendConnect() throws {
        stateLock.lock()
        peerOutgoingReliableSeq += 1 // → 1
        let relSeq = peerOutgoingReliableSeq
        stateLock.unlock()

        var cmd = ByteWriter()
        // CommandHeader
        cmd.u8(Enet.cmdConnect | Enet.flagAcknowledge) // 0x82
        cmd.u8(0xFF)                                     // channelID
        cmd.u16BE(relSeq)                                // reliableSequenceNumber = 1
        // Connect body (all BE except connectID raw)
        cmd.u16BE(incomingPeerID)                        // outgoingPeerID = our slot (0)
        cmd.u8(0xFF)                                     // incomingSessionID
        cmd.u8(0xFF)                                     // outgoingSessionID
        cmd.u32BE(Enet.defaultMTU)                       // 900
        cmd.u32BE(Enet.maximumWindowSize)                // 65536
        cmd.u32BE(Enet.ctrlChannelCount)                 // 48
        cmd.u32BE(0)                                      // incomingBandwidth
        cmd.u32BE(0)                                      // outgoingBandwidth
        cmd.u32BE(Enet.packetThrottleInterval)           // 5000
        cmd.u32BE(Enet.packetThrottleAcceleration)       // 2
        cmd.u32BE(Enet.packetThrottleDeceleration)       // 2
        cmd.u32Raw(connectID)                            // RAW
        cmd.u32BE(controlConnectData)                    // data

        let commandBytes = cmd.bytes
        stateLock.lock()
        let connectNowMs = serviceTimeMs
        sentReliable.append(SentReliable(
            channelID: 0xFF, reliableSequenceNumber: relSeq,
            commandBytes: commandBytes, sentAtMs: connectNowMs,
            firstSentAtMs: connectNowMs, attempts: 1))
        unackedReliables.increment() // mirror sentReliable.count
        stateLock.unlock()

        let datagram = wrapDatagram(commands: [commandBytes], sentTime: true)
        sendDatagram(datagram)
        Diag.info("ENet CONNECT sent (connectID=0x\(String(connectID, radix: 16)), "
            + "connectData=0x\(String(controlConnectData, radix: 16)), 48 bytes)",
            Self.logCategory)
    }

    /// Wrap one or more commands in a ProtocolHeader datagram. When `sentTime`
    /// is set, include the 4-byte header (peerID + sentTime) and the SENT_TIME
    /// flag; else the 2-byte header (peerID only).
    ///
    /// SUB-MS RTT: the wire `sentTime` is still the 16-bit-ms token the host
    /// echoes (unchanged on the wire), but we ALSO stamp a high-res local
    /// monotonic instant keyed by that token so `handleAcknowledge` can measure
    /// the round trip from our own clock instead of the quantized wire ms. The
    /// stamp is taken under stateLock (the same lock the ack-side lookup uses) and
    /// from the SAME monotonic base as the token, so the token and stamp can never
    /// disagree. NOTE: a retransmit re-wraps with a FRESH token+stamp, so RTT is
    /// always measured against the most-recent send of a reliable command.
    ///
    /// `recordRtt: false` keeps the wire byte-identical (the SENT_TIME flag +
    /// token still go out - wire fact: SENT_TIME is set on any datagram carrying
    /// an ack-flagged or ACK command) but skips the local RTT stamp. Used by the
    /// ACK emission path: the host never echoes an ACK datagram's token back, so
    /// recording it only loads `localSentByToken` with dead weight - at rumble
    /// rates (~135 ACKs/s) enough to permanently exceed the cap and degrade
    /// every send into a full-map sweep (see recordLocalSent).
    func wrapDatagram(commands: [[UInt8]], sentTime: Bool,
                      recordRtt: Bool = true) -> [UInt8] {
        var headerFlags: UInt16 = 0
        if sentTime { headerFlags |= Enet.headerFlagSentTime }
        // Session bits only after we've learned outgoingPeerID (< 0xFFF).
        if outgoingPeerID < Enet.maximumPeerID {
            headerFlags |= UInt16(outgoingSessionID) << Enet.headerSessionShift
        }
        var out = ByteWriter()
        out.u16BE(outgoingPeerID | headerFlags)
        if sentTime {
            // Token + high-res stamp must read the monotonic clock atomically so
            // the u16 token truncates exactly the local instant we record.
            withState {
                let nowMs = monotonicMs
                // Truncate to the low 16 bits the SAME way serviceTimeMs does
                // (truncatingIfNeeded - never traps on long uptime).
                let token = UInt16(truncatingIfNeeded: Int64(nowMs))
                out.u16BE(token)
                if recordRtt {
                    recordLocalSent(token: token, atMs: nowMs)
                }
            }
        }
        for command in commands { out.append(command) }
        return out.bytes
    }

    /// Wait for the host's VERIFY_CONNECT (handled in onDatagram). Drives a
    /// retransmit timer for the unacked CONNECT.
    func awaitVerifyConnect(timeoutMs: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMs) * 1_000_000
        while true {
            if interrupted.isSet { throw EnetError.interrupted }
            let (done, dead) = withState { (connected, disconnected) }
            if dead { throw EnetError.disconnected }
            if done { return }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw EnetError.connectTimeout
            }
            checkRetransmit()
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms tick
        }
    }

    /// handle_verify_connect (protocol.c:948-1008). Validate connectID +
    /// throttle params; learn outgoingPeerID + session ids; mark connected.
    func handleVerifyConnect(_ reader: inout ByteReader) {
        guard let vcOutgoingPeerID = reader.u16BE(),
              let vcIncomingSession = reader.u8(),
              let vcOutgoingSession = reader.u8(),
              reader.u32BE() != nil,      // mtu (unused for connect-only)
              reader.u32BE() != nil,      // windowSize (unused)
              let channelCount = reader.u32BE(),
              reader.u32BE() != nil,      // incomingBandwidth (unused)
              reader.u32BE() != nil,      // outgoingBandwidth (unused)
              let throttleInterval = reader.u32BE(),
              let throttleAccel = reader.u32BE(),
              let throttleDecel = reader.u32BE(),
              let vcConnectID = reader.u32Raw() else {
            Diag.error("ENet VERIFY_CONNECT truncated", Self.logCategory)
            return
        }

        // Strict validation - any mismatch zombies the peer in the C code.
        if channelCount < 1 || channelCount > 255
            || throttleInterval != Enet.packetThrottleInterval
            || throttleAccel != Enet.packetThrottleAcceleration
            || throttleDecel != Enet.packetThrottleDeceleration
            || vcConnectID != connectID {
            stateLock.lock(); disconnected = true; stateLock.unlock()
            Diag.error("ENet VERIFY_CONNECT validation failed "
                + "(connectID match=\(vcConnectID == connectID), "
                + "throttle=\(throttleInterval)/\(throttleAccel)/\(throttleDecel))",
                Self.logCategory)
            return
        }

        stateLock.lock()
        outgoingPeerID = vcOutgoingPeerID
        incomingSessionID = vcIncomingSession
        outgoingSessionID = vcOutgoingSession
        // The CONNECT (channel 0xFF, seq 1) is now acknowledged implicitly.
        let beforeRemove = sentReliable.count
        sentReliable.removeAll { $0.channelID == 0xFF && $0.reliableSequenceNumber == 1 }
        // Mirror sentReliable.count: decrement by however many were removed (the
        // implicitly-ACKed CONNECT - normally exactly one).
        for _ in 0..<(beforeRemove - sentReliable.count) { unackedReliables.decrement() }
        connected = true
        stateLock.unlock()

        Diag.notice("ENet VERIFY_CONNECT accepted → outgoingPeerID=\(vcOutgoingPeerID), "
            + "sessions in=\(vcIncomingSession)/out=\(vcOutgoingSession), channels=\(channelCount)",
            Self.logCategory)
    }

    // MARK: - START_A / START_B (ControlStream.c)

    /// Gen7-encrypted preconstructed payloads:
    ///   index 0 (START_A slot) → type 0x0302 (requestIdrFrameGen7Enc), payload {0,0}
    ///   index 1 (START_B slot) → type 0x0307 (startBGen5),             payload {0}
    func startPacket(index: Int) -> (type: UInt16, payload: [UInt8]) {
        if index == 0 {
            return (0x0302, [0, 0])
        } else {
            return (0x0307, [0])
        }
    }

    /// Build the encrypted control packet, queue it as a reliable SEND_RELIABLE
    /// on channel 0, send, and wait for its ACK (up to ~10ms loops, like
    /// sendMessageAndDiscardReply). Returns once ACKed or throws on timeout.
    func sendStart(index: Int, label: String) async throws {
        let (type, payload) = startPacket(index: index)
        let relSeq = try sendEncryptedControl(
            type: type, payload: payload, channel: Enet.ctrlChannelGeneric, label: label)
        try await awaitAck(channelID: Enet.ctrlChannelGeneric, relSeq: relSeq,
                           timeoutMs: 10_000, label: label)
        Diag.notice("ENet \(label) ACKed", Self.logCategory)
    }

    /// Wait until the given reliable command is removed from sentReliable (i.e.
    /// ACKed), driving the retransmit timer in the meantime.
    func awaitAck(channelID: UInt8, relSeq: UInt16, timeoutMs: Int,
                  label: String) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        while true {
            if interrupted.isSet { throw EnetError.interrupted }
            let (stillPending, dead): (Bool, Bool) = withState {
                let pending = sentReliable.contains {
                    $0.channelID == channelID && $0.reliableSequenceNumber == relSeq
                }
                return (pending, disconnected)
            }
            if dead { throw EnetError.disconnected }
            if !stillPending { return }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw EnetError.startFailed("\(label) not ACKed within \(timeoutMs)ms")
            }
            checkRetransmit()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
