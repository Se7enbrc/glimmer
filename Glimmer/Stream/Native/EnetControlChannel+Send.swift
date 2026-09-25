//
//  EnetControlChannel+Send.swift
//
//  The outbound send path: the low-level datagram submit, the client→host input
//  uplink, the client→host control requests (IDR / RFI / LTR), and the encrypted
//  control-V2 SEND_RELIABLE builder. Split out of EnetControlChannel.swift to keep
//  each unit focused; see that file for the shared stored state and wire facts.
//

import Foundation

extension EnetControlChannel {
    /// Submit one datagram to the wire. The actual connection.send is hopped onto
    /// the dedicated sendQueue so it can NEVER serialize ahead of (and starve) the
    /// inbound receive/ACK callback running on `queue`. stateLock is NEVER held
    /// across this call - callers always invoke it OUTSIDE their withState blocks,
    /// matching moonlight's "release the mutex before any blocking op" invariant.
    /// In-flight backpressure: count up before the send, down in its completion,
    /// so the input flush path can back off via `sendBacklogged`.
    func sendDatagram(_ bytes: [UInt8]) {
        withState { lastSendMs = serviceTimeMs }
        // Locked read (see connLock): retains the connection under the lock so
        // close()'s concurrent take-and-nil can never free it mid-load. nil
        // here means teardown already took it - drop the datagram.
        let conn = currentConnection()
        inFlightSends.increment()
        let counter = inFlightSends
        sendQueue.async {
            guard let conn else { counter.decrement(); return }
            conn.send(content: Data(bytes),
                      completion: .contentProcessed { _ in counter.decrement() })
        }
    }

    // MARK: - Public client→host input uplink

    /// Send one already-built plaintext NV_INPUT_HEADER+body (from InputEncoder)
    /// as control-V2 input data (type 0x0206 = IDX_INPUT_DATA, gen7Enc), sealed +
    /// sent reliably on `channel`. Fire-and-forget: like sendInputPacketOnControlStream
    /// → sendMessageAndForget (ControlStream.c:1693), it does NOT block on the ACK
    /// (the reliable command is tracked in sentReliable for retransmit by the
    /// control loop). Returns false if the seal/send failed (e.g. MTU) so the
    /// caller can surface -2/-1 to InputForwarder.
    @discardableResult
    func sendInputPacket(_ plaintext: [UInt8], channel: UInt8) -> Bool {
        do {
            _ = try sendEncryptedControl(
                type: CtrlV2.inputData, payload: plaintext,
                channel: channel, label: "INPUT")
            return true
        } catch {
            Diag.error("ENet input send failed (ch \(channel)): \(error, privacy: .private)", Self.logCategory)
            return false
        }
    }

    /// Motion uses unacknowledged control-V2 input so superseded samples cannot
    /// hold up the reliable stream (InputStream.c). Returns false on seal/send failure.
    @discardableResult
    func sendInputPacketUnreliable(_ plaintext: [UInt8], channel: UInt8) -> Bool {
        // enet_peer_send promotes at 0xFFFF so the receiver accepts later samples.
        // The serial batcher owns sensor sends, so the check and send need no wider lock.
        let needsReliable = withState {
            let effective = Enet.effectiveChannel(channel, negotiatedCount: negotiatedChannelCount)
            return (channelOutgoingUnreliableSeq[effective] ?? 0) >= 0xFFFF
        }
        if needsReliable { return sendInputPacket(plaintext, channel: channel) }
        do {
            try sendEncryptedControlUnreliable(
                type: CtrlV2.inputData, payload: plaintext,
                channel: channel, label: "INPUT_UNREL")
            return true
        } catch {
            Diag.error("ENet unreliable input send failed (ch \(channel)): \(error, privacy: .private)",
                       Self.logCategory)
            return false
        }
    }

    // MARK: - Public client→host control (IDR / RFI / LTR)

    /// Request an IDR frame - COALESCED, like LiRequestIdrFrame (ControlStream.c:415-422):
    /// flushes any queued RFI and wakes the control loop, which sends at most one
    /// REQUEST_IDR per `recoveryMinSpacingMs`. Safe from any thread (takes stateLock).
    func requestIdrFrame() {
        let wake = withState { () -> Bool in
            let wasIdle = !idrPending
            idrPending = true
            // A full IDR makes any queued RFI redundant (LiRequestIdrFrame
            // freeBasicLbqList(referenceFrameControlQueue)).
            pendingRfi = nil
            return wasIdle
        }
        if wake { recoveryWake.signal() }
    }

    /// Invalidate reference frames (RFI) - COALESCED, like queueFrameInvalidationTuple
    /// (ControlStream.c:388-410): sets or widens the pending window and wakes the loop;
    /// a pending IDR already covers the span, so none is queued. Safe from any thread.
    func invalidateReferenceFrames(from firstFrame: Int, to lastFrame: Int) {
        let wake = withState { () -> Bool in
            // An IDR already supersedes an RFI; don't bother queuing one.
            guard !idrPending else { return false }
            if let existing = pendingRfi {
                pendingRfi = (min(existing.from, firstFrame), max(existing.to, lastFrame))
                return false
            }
            pendingRfi = (firstFrame, lastFrame)
            return true
        }
        if wake { recoveryWake.signal() }
    }

    /// Minimum spacing (ms) between wire IDRs, and between wire RFIs: the first
    /// request of a loss event leaves at once, repeats keep the old 20ms tick's volume.
    static let recoveryMinSpacingMs: UInt32 = 20

    /// Drain coalesced IDR/RFI requests on the control loop's thread (moonlight's
    /// requestIdrFrameFunc, ControlStream.c:1624-1640): at most one REQUEST_IDR or RFI,
    /// each kind spaced `recoveryMinSpacingMs`. Returns how long the loop may wait.
    func drainPendingRecoveryRequests() -> UInt32 {
        let now = serviceTimeMs
        let spacing = Self.recoveryMinSpacingMs
        let sinceIdr = lastIdrSentMs.map { now &- $0 } ?? spacing
        let sinceRfi = lastRfiSentMs.map { now &- $0 } ?? spacing
        // No RFI is ever pending beside an IDR: requestIdrFrame flushes it.
        let (sendIdr, rfi, wait): (Bool, (from: Int, to: Int)?, UInt32) = withState {
            let idr = idrPending && sinceIdr >= spacing
            if idr { idrPending = false }
            let window = sinceRfi >= spacing ? pendingRfi : nil
            if window != nil { pendingRfi = nil }
            // A held request ends the wait the moment it comes due.
            if idrPending { return (idr, window, spacing - sinceIdr) }
            return (idr, window, pendingRfi == nil ? Self.controlTickMs : spacing - sinceRfi)
        }
        if sendIdr {
            lastIdrSentMs = now
            sendIdrFrameNow()
        } else if let rfi {
            lastRfiSentMs = now
            sendRfiNow(from: rfi.from, to: rfi.to)
        }
        return wait
    }

    /// Send one REQUEST_IDR on the wire (gen7Enc: type 0x0302, payload {0,0},
    /// URGENT chan, RELIABLE). ControlStream.c:1521. Only reached from
    /// `drainPendingRecoveryRequests`, which spaces repeats `recoveryMinSpacingMs`.
    private func sendIdrFrameNow() {
        do {
            _ = try sendEncryptedControl(
                type: CtrlV2.requestIdrFrame, payload: [0, 0],
                channel: Enet.ctrlChannelUrgent, label: "REQUEST_IDR")
            TelemetryCounters.shared.idrRequestedTotal.increment()
            armIdrRoundTrip()
            Diag.notice("ENet IDR frame requested", Self.logCategory)
        } catch {
            Diag.error("ENet IDR request failed: \(error, privacy: .private)", Self.logCategory)
        }
    }

    /// Send one RFI on the wire. type 0x0301, SS_RFI_REQUEST = 24 bytes all LE:
    /// {firstFrameIndex, reserved1, lastFrameIndex, reserved2[3]}. URGENT channel,
    /// RELIABLE (Video.h:80-86, ControlStream.c:1538). Only reached from
    /// `drainPendingRecoveryRequests`.
    private func sendRfiNow(from firstFrame: Int, to lastFrame: Int) {
        var w = ByteWriter()
        w.u32LE(UInt32(truncatingIfNeeded: firstFrame))
        w.u32LE(0)
        w.u32LE(UInt32(truncatingIfNeeded: lastFrame))
        w.u32LE(0); w.u32LE(0); w.u32LE(0)
        do {
            _ = try sendEncryptedControl(
                type: CtrlV2.invalidateRefFrames, payload: w.bytes,
                channel: Enet.ctrlChannelUrgent, label: "RFI")
            TelemetryCounters.shared.rfiTotal.increment()
            // Deliberately NOT arming a round-trip: an RFI's stamp was mostly
            // superseded mid-loss-burst before any recovery frame landed,
            // turning the request/matched pair unreadable (measured: the large
            // majority of outstanding requests were unmatched RFIs). RFI volume
            // rides `rfiTotal`; the round-trip pair is explicit-IDR-only now.
            Diag.notice("ENet RFI sent (\(firstFrame)..\(lastFrame))", Self.logCategory)
        } catch {
            Diag.error("ENet RFI failed: \(error, privacy: .private)", Self.logCategory)
        }
    }

    /// Only explicit IDR requests arm this round trip; RFIs use loss episodes.
    /// Gate the stamp on the tracker so it pairs with the gated IDR resolver
    /// and costs only an optional load when telemetry is off.
    private func armIdrRoundTrip() {
        guard FrameTimingTracker.shared != nil else { return }
        TelemetryCounters.shared.p2.stampIdrRequest(TelemetryCounters.monotonicNowNanos())
        TelemetryCounters.shared.idrRoundTripRequestTotal.increment()
    }

    /// Seal `type`+`payload` as a control-V2 message and send it as a reliable
    /// SEND_RELIABLE ENet command on `channel`, tracking it in sentReliable for
    /// ACK/retransmit. Does NOT block on the ACK (fire-and-track, like
    /// sendMessageAndForget). Returns the per-channel reliable seq used.
    ///
    /// enetSeq + the per-channel reliable counter are both incremented under the
    /// SAME lock that orders the send (StreamCrypto's seq-uniqueness contract:
    /// reusing an enetSeq = GCM nonce reuse = catastrophic).
    @discardableResult
    func sendEncryptedControl(type: UInt16, payload: [UInt8], channel requested: UInt8,
                              label: String) throws -> UInt16 {
        let channel = withState { Enet.effectiveChannel(requested, negotiatedCount: negotiatedChannelCount) }
        let (seq, relSeq): (UInt32, UInt16) = withState {
            let currentSeq = enetSeq
            enetSeq += 1
            // ENet reliable sequence numbers are 16-bit and WRAP (the vendored C
            // does `++` on a u16, which wraps silently); the receiver compares
            // with wraparound arithmetic. Must use &+ - plain + traps on overflow
            // after 65535 reliable sends on a channel (the mouse channel hits this
            // in ~20min of play → arithmetic-overflow crash on the input path).
            let next = (channelOutgoingReliableSeq[channel] ?? 0) &+ 1
            channelOutgoingReliableSeq[channel] = next
            // ENet zeroes the channel's outgoing UNRELIABLE counter whenever a
            // reliable command goes out on it (enet_peer_setup_outgoing_command,
            // peer.c:658), so a subsequent unreliable's reliableSequenceNumber
            // (this `next`) pairs with a fresh unreliable counter starting at 1.
            channelOutgoingUnreliableSeq[channel] = 0
            return (currentSeq, next)
        }

        let encrypted: [UInt8]
        do {
            encrypted = try crypto.seal(type: type, payload: payload, seq: seq)
        } catch {
            throw EnetError.startFailed("\(label) encrypt: \(error)")
        }

        // SEND_RELIABLE command: header (0x86, channel, relSeq) + u16 dataLength
        // + inline ciphertext.
        var cmd = ByteWriter()
        cmd.u8(Enet.cmdSendReliable | Enet.flagAcknowledge) // 0x86
        cmd.u8(channel)
        cmd.u16BE(relSeq)
        cmd.u16BE(UInt16(encrypted.count))
        cmd.append(encrypted)

        if cmd.bytes.count + 4 > Int(Enet.defaultMTU) {
            throw EnetError.mtuExceeded
        }

        let commandBytes = cmd.bytes
        withState {
            let nowMs = serviceTimeMs
            sentReliable.append(SentReliable(
                channelID: channel, reliableSequenceNumber: relSeq,
                commandBytes: commandBytes, sentAtMs: nowMs, firstSentAtMs: nowMs,
                attempts: 1))
            unackedReliables.increment() // mirror sentReliable.count
        }

        sendDatagram(wrapDatagram(commands: [commandBytes], sentTime: true))
        // NO per-packet logging here: this is the hot send path (input fires many
        // times/sec) and Diag → LogStore.log takes a process-global NSLock from
        // every thread, adding cross-thread contention exactly when input is hot.
        // Handshake milestones (CONNECT/VERIFY_CONNECT/START_A/B ACKed + stage
        // transitions) are logged separately at their own call sites.
        return relSeq
    }

    /// Seal `type`+`payload` as a control-V2 message and send it as an ENet
    /// SEND_UNRELIABLE command on `channel`. Mirrors `sendEncryptedControl`
    /// EXACTLY for the encryption (same `crypto.seal`, same globally-monotonic
    /// `enetSeq` GCM nonce - NEVER reused across reliable AND unreliable), but:
    ///   (a) emits the 0x07 SEND_UNRELIABLE command (no ACKNOWLEDGE flag) carrying
    ///       the channel's CURRENT reliable seq (NOT incremented) + a pre-
    ///       incremented per-channel unreliable seq;
    ///   (b) does NOT append to sentReliable and does NOT touch unackedReliables -
    ///       an unreliable command is never ACKed or retransmitted;
    ///   (c) does NOT reset the unreliable counter (only a RELIABLE send zeroes it,
    ///       per enet_peer_setup_outgoing_command / peer.c:658).
    ///
    /// enetSeq and the per-channel unreliable counter advance under the SAME lock
    /// (withState/stateLock) so the GCM nonce and the wire sequence numbers can
    /// never tear (StreamCrypto's seq-uniqueness contract: a reused enetSeq = GCM
    /// nonce reuse = catastrophic).
    func sendEncryptedControlUnreliable(type: UInt16, payload: [UInt8],
                                        channel requested: UInt8, label: String) throws {
        let channel = withState { Enet.effectiveChannel(requested, negotiatedCount: negotiatedChannelCount) }
        let (seq, relSeq, unrelSeq): (UInt32, UInt16, UInt16) = withState {
            let currentSeq = enetSeq
            enetSeq += 1
            // reliableSequenceNumber = the channel's CURRENT outgoing reliable seq,
            // NOT incremented (enet_peer_setup_outgoing_command). Default 0 if no
            // reliable has gone out on this channel yet.
            let curRel = channelOutgoingReliableSeq[channel] ?? 0
            // unreliableSequenceNumber = per-channel counter, PRE-incremented (first
            // unreliable on a channel = 1). &+ to wrap like the 16-bit C counter.
            let nextUnrel = (channelOutgoingUnreliableSeq[channel] ?? 0) &+ 1
            channelOutgoingUnreliableSeq[channel] = nextUnrel
            return (currentSeq, curRel, nextUnrel)
        }

        let encrypted: [UInt8]
        do {
            encrypted = try crypto.seal(type: type, payload: payload, seq: seq)
        } catch {
            throw EnetError.startFailed("\(label) encrypt: \(error)")
        }

        // SEND_UNRELIABLE command: header (0x07, channel, reliableSeq,
        // unreliableSeq) + u16 dataLength + inline ciphertext. NO ACKNOWLEDGE flag.
        var cmd = ByteWriter()
        cmd.u8(Enet.cmdSendUnreliable)        // 0x07, no flags
        cmd.u8(channel)
        cmd.u16BE(relSeq)                     // current reliable seq (not bumped)
        cmd.u16BE(unrelSeq)                   // pre-incremented unreliable seq
        cmd.u16BE(UInt16(encrypted.count))
        cmd.append(encrypted)

        if cmd.bytes.count + 4 > Int(Enet.defaultMTU) {
            throw EnetError.mtuExceeded
        }

        // Fire-and-forget: no reliable tracking or RTT stamp, since no ACK consumes either.
        sendDatagram(wrapDatagram(commands: [cmd.bytes], sentTime: true, recordRtt: false))
    }
}
