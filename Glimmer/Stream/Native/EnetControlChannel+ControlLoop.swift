//
//  EnetControlChannel+ControlLoop.swift
//
//  The persistent post-START_B control loop: the two keepalives (app-level
//  periodic ping + transport ENet PING), dead-peer detection, reliable
//  retransmits, and the 1Hz health snapshot. Split out of EnetControlChannel.swift
//  to keep each unit focused; see that file for the shared stored state.
//

import Foundation

extension EnetControlChannel {
    // MARK: - Persistent control loop (post-START_B)

    /// Mutable cursor for the control-loop's per-iteration bookkeeping. Lives in a
    /// struct so the async and synchronous loop runners share one tick body.
    struct ControlLoopState {
        var lastPeriodicPingMs: UInt32 = 0
        var lastHealthSnapshotMs: UInt32 = 0
    }

    /// Prime the keepalive clocks. Anchors the ACK-silence clock at loop start so a
    /// freshly-connected peer isn't immediately considered stale, and sends the
    /// first periodic ping immediately so the host keeps video flowing without
    /// waiting a full interval.
    func startControlLoop() -> ControlLoopState {
        Diag.notice("ENet control loop started (keepalives active)", Self.logCategory)
        withState {
            lastAckRecvMs = serviceTimeMs
        }
        // Send the first ping immediately so the host keeps video flowing.
        sendPeriodicPing()
        var state = ControlLoopState()
        state.lastPeriodicPingMs = serviceTimeMs
        return state
    }

    /// One control-loop iteration: dead-peer detection, the two keepalives,
    /// retransmits, and the 1Hz health snapshot. Returns false when the loop
    /// should STOP (peer disconnected or declared dead). Holds stateLock only for
    /// brief reads/writes and NEVER across a send - sends happen outside withState.
    func controlLoopTick(_ state: inout ControlLoopState) -> Bool {
        let dead = withState { disconnected }
        if dead {
            Diag.error("ENet control loop ending: peer disconnected", Self.logCategory)
            return false
        }

        let now = serviceTimeMs

        // (0) Dead-peer detection at ENet's 10s envelope. The host can silently
        // reset our peer WITHOUT sending DISCONNECT/TERMINATION; if we have
        // reliable commands in flight and haven't seen a matched ACK for the full
        // ackSilenceDeadMs (= ENet's peer timeout), the peer is genuinely gone.
        // A shorter window would kill a recoverable blip - moonlight rides those
        // out by retransmitting, never self-terminating early, and so do we.
        let (sinceLastAck, unackedCount, oldestUnackedMs, rttMs, haveRtt) = withState {
            () -> (UInt32, Int, UInt32, Double, Bool) in
            let sinceAck = now &- lastAckRecvMs
            let oldest = sentReliable.map { now &- $0.firstSentAtMs }.max() ?? 0
            return (sinceAck, sentReliable.count, oldest, roundTripTime, hasRttSample)
        }
        // RTT-relative input backpressure (do-no-harm on a stable link): mark the
        // host "behind" ONLY on sustained ACK silence relative to RTT, never on a
        // clean link where ACKs return within ~one RTT. Read lock-free by the 1ms
        // InputBatcher flush. floor when no RTT sample yet (handshake/early).
        let bpThreshold = haveRtt
            ? max(Self.backpressureAckSilenceFloorMs,
                  Self.backpressureRttMultiple * UInt32(min(rttMs, 1000)))
            : Self.backpressureAckSilenceFloorMs
        reliableBackloggedFlag = unackedCount > 0 && sinceLastAck > bpThreshold
        if unackedCount > 0 && sinceLastAck >= Self.ackSilenceDeadMs {
            Diag.error("ENet peer silent: no ACK in \(sinceLastAck)ms with "
                + "\(unackedCount) reliable command(s) outstanding "
                + "(oldest \(oldestUnackedMs)ms) - host silently reset peer; terminating",
                Self.logCategory)
            withState { disconnected = true }
            onTerminated?(-1)
            return false
        }

        // (A) app-level periodic ping every 100ms - the Sunshine stream keepalive
        // that keeps video flowing.
        if now &- state.lastPeriodicPingMs >= Enet.periodicPingIntervalMs {
            sendPeriodicPing()
            state.lastPeriodicPingMs = now
        }

        // (B) transport ENet ping if we haven't sent anything in 500ms.
        let lastSend = withState { lastSendMs }
        if now &- lastSend >= Enet.pingIntervalMs {
            sendEnetPing()
        }

        // Drain coalesced IDR/RFI requests: at most ONE REQUEST_IDR (and one
        // RFI) per tick, no matter how many failed frames asked for one since
        // the last drain. This is moonlight's requestIdrFrameFunc dedicated-drain
        // (ControlStream.c:1624-1640) collapsed onto the 20ms control tick - it
        // turns the per-failed-frame IDR storm into one request per loss event.
        drainPendingRecoveryRequests()

        // Reliable retransmits (covers both ping types + IDR/RFI/LTR).
        checkRetransmit()

        // (C) 1Hz health snapshot - the host-timeout fingerprint is
        // sentReliable.count climbing + oldestUnacked/sinceLastAck crossing
        // ~5000ms right before a stall. Lands in the in-app LogStore. DEBUG
        // (demoted from NOTICE, log diet): this exact data now rides every
        // telemetry row (enet_sent_reliable / oldest_unacked / since_last_ack)
        // where the trend is actually read, and at NOTICE the 1Hz line put
        // 9,614 copies in one 2.7h session file. The ring/os_log still carry
        // it live; the dead-peer/stall paths keep their own ERROR lines.
        if now &- state.lastHealthSnapshotMs >= Self.healthSnapshotIntervalMs {
            Diag.debug("ENet health: sentReliable=\(unackedCount) "
                + "oldestUnackedMs=\(oldestUnackedMs) sinceLastAckMs=\(sinceLastAck)",
                Self.logCategory)
            state.lastHealthSnapshotMs = now
        }
        return true
    }

    /// The persistent control loop NativeBackend runs after establishAndStart()
    /// returns "connected". Sustains the session by emitting BOTH keepalives:
    ///   (A) the app-level periodic ping (encrypted 0x0200) every 100ms - the
    ///       Sunshine stream keepalive that keeps video flowing; and
    ///   (B) the transport-level ENet PING (0x85, ch 0xFF) every 500ms of no
    ///       send - keeps the host's ENet peer from timing out.
    /// It also drives checkRetransmit() so reliable sends (including the pings)
    /// get ACKed/resent. Inbound datagrams continue to be handled by the
    /// existing receive loop (onDatagram). Bounded 20ms tick; cancellable via
    /// interrupt().
    ///
    /// SYNCHRONOUS variant - run on a DEDICATED Thread (qos .userInteractive) by
    /// NativeBackend, NOT on the Swift cooperative pool. The 20ms tick is a
    /// blocking Thread.sleep so the loop that must emit ACKs/keepalives cannot be
    /// de-prioritized or starved behind high-QoS main-thread input - the moonlight
    /// LossStats + ControlRecv dedicated-thread guarantee.
    func runControlLoopSync() {
        var state = startControlLoop()
        while !interrupted.isSet {
            if !controlLoopTick(&state) { break }
            Thread.sleep(forTimeInterval: 0.020) // 20ms tick (blocking)
        }
        Diag.notice("ENet control loop stopped", Self.logCategory)
    }

    /// (A) App-level periodic ping (lossStatsThreadFunc, ControlStream.c:1388).
    /// Payload built LE: BbPut16(4) then BbPut32(0) = [04 00 00 00 00 00 00 00].
    /// Encrypted control-V2 type 0x0200 on channel 0, RELIABLE (so RTT is
    /// recomputed on its ACK). Fire-and-track - don't block the loop on its ACK.
    func sendPeriodicPing() {
        let payload: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        do {
            _ = try sendEncryptedControl(
                type: CtrlV2.periodicPing, payload: payload,
                channel: Enet.ctrlChannelGeneric, label: "PERIODIC_PING")
        } catch {
            Diag.error("ENet periodic ping failed: \(error)", Self.logCategory)
        }
    }

    /// (B) Transport ENet PING (enet_peer_ping, peer.c:446): command
    /// PING|FLAG_ACKNOWLEDGE = 0x85, channel 0xFF, peer-counter relSeq, empty
    /// body. RELIABLE - tracked in sentReliable for ACK/retransmit.
    func sendEnetPing() {
        let relSeq: UInt16 = withState {
            // 16-bit ENet reliable seq - wrap (&+), don't trap. The PING fires
            // ~2/s, so plain + would overflow-crash after ~9h of streaming.
            peerOutgoingReliableSeq &+= 1
            return peerOutgoingReliableSeq
        }
        var cmd = ByteWriter()
        cmd.u8(Enet.cmdPing | Enet.flagAcknowledge) // 0x85
        cmd.u8(Enet.peerChannelID)                  // 0xFF
        cmd.u16BE(relSeq)
        let commandBytes = cmd.bytes
        withState {
            let nowMs = serviceTimeMs
            sentReliable.append(SentReliable(
                channelID: Enet.peerChannelID, reliableSequenceNumber: relSeq,
                commandBytes: commandBytes, sentAtMs: nowMs, firstSentAtMs: nowMs,
                attempts: 1))
            unackedReliables.increment() // mirror sentReliable.count
        }
        sendDatagram(wrapDatagram(commands: [commandBytes], sentTime: true))
        Diag.debug("ENet ping sent (relSeq=\(relSeq))", Self.logCategory)
    }

    /// Resend any reliable command whose roundTripTimeout has elapsed (adaptive
    /// base = clamp(srtt + 4*rttvar, 60...1000ms), 500ms until the first RTT sample,
    /// then exponential backoff), COALESCING the due resends into as few
    /// datagrams as possible (chunked under the MTU) instead of one datagram per
    /// entry - the old one-datagram-per-entry behavior turned a transient backlog
    /// into a retransmit storm that compounded the flood. Also adds max-attempt /
    /// age give-up eviction: an entry that has been resent ~10 times OR has been
    /// outstanding >= ~5000ms (host timeoutMinimum, protocol.c:1371-1379) means
    /// the host has stopped ACKing us - declare the peer dead and fire
    /// onTerminated(-1) ONCE rather than resending forever (converts the silent
    /// host-driven kill into an observable, in-app-logged termination).
    func checkRetransmit() {
        stateLock.lock()
        if disconnected { stateLock.unlock(); return }
        let now = serviceTimeMs
        // ADAPTIVE RTO base (was a flat Enet.defaultRoundTripTimeMs=500): once we
        // have a real RTT sample, derive the base timeout from the channel's own
        // EWMA RTT + variance (the same 1/8-mean 1/4-var estimate handleAcknowledge
        // maintains and estimatedRtt() surfaces) instead of a LAN-tuned constant.
        // base = srtt + 4*rttvar (Jacobson/Karels), clamped to [floor, ceil]:
        //   floor 60ms keeps us from retransmitting faster than ~1 RTT on a fast
        //   link (a sub-floor RTO spuriously resends in-flight commands), and ceil
        //   1000ms caps the slow-link base before backoff. Read under the SAME
        //   stateLock the rest of this method holds. Before the first ACK
        //   (hasRttSample == false) fall back to the original 500ms base so an
        //   un-sampled peer behaves exactly as before. The existing exponential
        //   backoff (<< min(attempts,4)) is then applied unchanged.
        let rtoBaseMs: UInt32
        if hasRttSample {
            let base = roundTripTime + 4 * rttVariance
            rtoBaseMs = UInt32(min(max(base, 60), 1000))
        } else {
            rtoBaseMs = Enet.defaultRoundTripTimeMs
        }
        var resends: [[UInt8]] = []
        // No early give-up. Like enet_protocol_check_timeouts (protocol.c:1371-1388)
        // we keep retransmitting with backoff and NEVER self-evict here - the attempt
        // count only caps the backoff, it does not tear down. The sole dead-peer
        // backstop is runControlLoop's ackSilenceDeadMs (= ENet's 10s peer timeout),
        // which is what lets a brief blip self-heal once UDP flows again.
        for i in sentReliable.indices {
            let timeout = rtoBaseMs * UInt32(1 << min(sentReliable[i].attempts, 4))
            if now &- sentReliable[i].sentAtMs >= timeout {
                resends.append(sentReliable[i].commandBytes)
                sentReliable[i].sentAtMs = now
                sentReliable[i].attempts += 1
            }
        }
        stateLock.unlock()

        // P1 NETWORK telemetry: count this tick's reliable retransmits (the climb
        // that precedes a control-stream stall, paired with the oldest-unacked
        // trend the 1Hz health snapshot already surfaces). Always-live integer add
        // at the already-rare retransmit site (sub-2Hz on a healthy link); the
        // exporter only reads it when telemetry is on. Done outside stateLock so the
        // counter's own lock never nests under stateLock.
        if !resends.isEmpty {
            TelemetryCounters.shared.enetRetransmitTotal.increment(by: UInt64(resends.count))
        }

        // Coalesce the due resends into MTU-bounded datagrams (wrapDatagram takes
        // multiple commands). The 4-byte header (peerID + sentTime) is the max
        // overhead since these always carry a sent-time.
        let headerOverhead = 4
        let maxPayload = Int(Enet.defaultMTU) - headerOverhead
        var batch: [[UInt8]] = []
        var batchLen = 0
        for cmd in resends {
            if !batch.isEmpty && batchLen + cmd.count > maxPayload {
                sendDatagram(wrapDatagram(commands: batch, sentTime: true))
                batch.removeAll(keepingCapacity: true)
                batchLen = 0
            }
            batch.append(cmd)
            batchLen += cmd.count
        }
        if !batch.isEmpty {
            sendDatagram(wrapDatagram(commands: batch, sentTime: true))
        }
    }
}
