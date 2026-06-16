//
//  EnetControlChannel+Inbound.swift
//
//  Inbound datagram parsing (protocol.c recv loop): the receive loop, per-command
//  dispatch, ACK emission/matching, and decryption + dispatch of host control
//  messages (TERMINATION / HDR / RUMBLE / TRIGGER RUMBLE / RGB LED / MOTION
//  ENABLE). Split out of EnetControlChannel.swift to keep each unit focused;
//  see that file for the shared stored state and wire facts.
//

import Foundation

extension EnetControlChannel {
    func startReceiveLoop() {
        guard let conn = currentConnection() else { return }
        conn.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onDatagram([UInt8](data))
            }
            if err == nil && !self.interrupted.isSet {
                self.startReceiveLoop()
            }
        }
    }

    // MARK: - Inbound datagram parsing (protocol.c recv loop)

    func onDatagram(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        var reader = ByteReader(bytes)
        guard let rawPeerID = reader.u16BE() else { return }
        let flags = rawPeerID & (Enet.headerFlagCompressed | Enet.headerFlagSentTime)
        // (peerID and sessionID parsed but not strictly needed for a single peer)
        var sentTime: UInt16 = 0
        if flags & Enet.headerFlagSentTime != 0 {
            sentTime = reader.u16BE() ?? 0
        }
        if flags & Enet.headerFlagCompressed != 0 {
            // moonlight never compresses; ignore.
            return
        }

        // Parse commands back-to-back.
        while reader.remaining >= 4 {
            guard let commandByte = reader.u8(),
                  let channelID = reader.u8(),
                  let relSeq = reader.u16BE() else { return }
            let command = commandByte & Enet.commandMask

            // Each command either consumes its body and signals "keep parsing
            // the next coalesced command" (true), or hits a truncated / unknown
            // / DISCONNECT case that means "stop parsing THIS datagram" (false).
            let keepParsing = handleEnetCommand(
                command: command,
                commandByte: commandByte,
                channelID: channelID,
                relSeq: relSeq,
                flags: flags,
                sentTime: sentTime,
                reader: &reader)
            if !keepParsing { return }
        }
    }

    /// Per-socket GAP-EVENT accumulation — the ENet leg of the 20/50/100ms
    /// family (cumulative: a 100ms gap counts in all three). Completes the
    /// video/audio/ENet trio that makes "all sockets gapped together" (NIC
    /// doze) vs "one path stalled" a single NDJSON-row query instead of a
    /// three-source manual cross-correlation.
    ///
    /// Dispatch one ENet command parsed off the inbound datagram. Returns true
    /// to keep parsing subsequent coalesced commands, false to stop parsing this
    /// datagram (truncated body, unknown command, or DISCONNECT). Split out of
    /// `onDatagram` so each unit stays focused; the per-command behaviour —
    /// body-length advance, ACK emission, and dispatch — is unchanged.
    private func handleEnetCommand(
        command: UInt8,
        commandByte: UInt8,
        channelID: UInt8,
        relSeq: UInt16,
        flags: UInt16,
        sentTime: UInt16,
        reader: inout ByteReader
    ) -> Bool {
        switch command {
        case Enet.cmdVerifyConnect:
            handleVerifyConnect(&reader)
            // VERIFY_CONNECT has FLAG_ACKNOWLEDGE → must ACK it.
            ackIfRequested(commandByte, channelID: channelID, relSeq: relSeq,
                           flags: flags, sentTime: sentTime)
        case Enet.cmdAcknowledge:
            handleAcknowledge(ackChannelID: channelID, &reader)
        case Enet.cmdDisconnect:
            stateLock.lock(); disconnected = true; stateLock.unlock()
            Diag.error("ENet received DISCONNECT during/after handshake", Self.logCategory)
            return false
        case Enet.cmdPing:
            // PING has no body; ACK if requested.
            ackIfRequested(commandByte, channelID: channelID, relSeq: relSeq,
                           flags: flags, sentTime: sentTime)
        case Enet.cmdSendReliable:
            // The host delivers control payloads as SEND_RELIABLE. Parse the
            // u16 dataLength + inline bytes (advancing the reader correctly
            // so multi-command datagrams stay in sync), ACK it, then decrypt
            // + dispatch. This is the path the old `default: return` silently
            // dropped — the literal "onDatagram bails on unknown commands".
            guard let dataLength = reader.u16BE(),
                  let inner = reader.take(Int(dataLength)) else {
                return false // truncated; can't safely continue parsing
            }
            // ACK UNCONDITIONALLY — including stale/duplicates. Real enet
            // returns a dummy command for a discarded duplicate precisely so
            // it still gets ACKed (enet_peer_queue_incoming_command's
            // discardCommand path); withholding the ACK would keep the host
            // retransmitting until its peer timeout.
            ackIfRequested(commandByte, channelID: channelID, relSeq: relSeq,
                           flags: flags, sentTime: sentTime)
            // Per-channel staleness gate (see lastDispatchedInboundRelSeq):
            // dispatch only a STRICTLY-NEWER reliable seq. A host retransmit
            // (lost client ACK) or UDP reorder of an already-superseded
            // command — the rumble(x,y) that would land after motors-off and
            // latch the pad buzzing — is dropped here instead of dispatched.
            guard Self.reliableSeqIsNewer(relSeq,
                                          than: lastDispatchedInboundRelSeq[channelID] ?? 0) else {
                if !loggedFirstStaleReliableDrop {
                    loggedFirstStaleReliableDrop = true
                    Diag.info("ENet dropped stale/duplicate inbound reliable "
                        + "(ch \(channelID) relSeq \(relSeq), last dispatched "
                        + "\(lastDispatchedInboundRelSeq[channelID] ?? 0)); "
                        + "ACKed, not re-dispatched — first sighting this session",
                        Self.logCategory)
                }
                return true
            }
            lastDispatchedInboundRelSeq[channelID] = relSeq
            handleInboundControl(inner)
        default:
            // Remaining commands carry a body we don't act on but MUST consume
            // exactly so multi-command datagrams stay in sync — a RELIABLE
            // command (e.g. a retransmitted HDR) is often coalesced AFTER one of
            // these, and dropping it stalls the host's reliable backlog (~6s peer
            // timeout). `skipCommandBody` advances past the body or, for a truly
            // unknown command / truncation, signals stop.
            guard skipCommandBody(command: command, reader: &reader) else { return false }
            ackIfRequested(commandByte, channelID: channelID, relSeq: relSeq,
                           flags: flags, sentTime: sentTime)
        }
        return true
    }

    /// Advance `reader` past the body of a known fixed/variable-length ENet
    /// command (the ones `handleEnetCommand` consumes but doesn't dispatch).
    /// Returns false on a truncated body or a truly unknown command — both mean
    /// "stop parsing this datagram" because the next command offset is unknown.
    private func skipCommandBody(command: UInt8, reader: inout ByteReader) -> Bool {
        switch command {
        case Enet.cmdSendUnreliable, Enet.cmdSendUnsequenced:
            // SEND_UNRELIABLE: u16 unreliableSeq + u16 dataLength + dataLength.
            // SEND_UNSEQUENCED: u16 unsequencedGroup + u16 dataLength + dataLength.
            guard reader.take(2) != nil, let dl = reader.u16BE(),
                  reader.take(Int(dl)) != nil else { return false }
        case Enet.cmdSendFragment, Enet.cmdSendUnreliableFragment:
            // body = u16 startSeq + u16 dataLength + 4×u32 (16B) + dataLength bytes.
            guard reader.take(2) != nil, let dl = reader.u16BE(),
                  reader.take(16) != nil, reader.take(Int(dl)) != nil else { return false }
        case Enet.cmdBandwidthLimit:
            // body = 2×u32 = 8 bytes (incoming/outgoing bandwidth).
            guard reader.take(8) != nil else { return false }
        case Enet.cmdThrottleConfigure:
            // body = 3×u32 = 12 bytes (interval/accel/decel).
            guard reader.take(12) != nil else { return false }
        default:
            // Truly unknown command — its body length is unknown, so we cannot
            // safely advance to the next command; stop parsing THIS datagram.
            return false
        }
        return true
    }

    /// Serial-number "newer than" for the 16-bit wrapping per-channel reliable
    /// sequence (pre-incremented u16, wraps 65535 → 0 — the same silent `++`
    /// wrap the vendored C does on the outgoing side). `seq` is strictly newer
    /// than `last` when the forward distance is nonzero and under half the
    /// window — the standard half-space rule, safe because the host can never
    /// be more than its (small, ACK-clocked) retransmit backlog ahead of us.
    static func reliableSeqIsNewer(_ seq: UInt16, than last: UInt16) -> Bool {
        seq != last && (seq &- last) < 0x8000
    }

    /// Send an ACK for a received command iff it requested one AND the datagram
    /// carried a sent-time (ENet's ACK echoes the sender's serviceTime).
    func ackIfRequested(_ commandByte: UInt8, channelID: UInt8, relSeq: UInt16,
                        flags: UInt16, sentTime: UInt16) {
        guard commandByte & Enet.flagAcknowledge != 0 else { return }
        // ENet ACKs a reliable command whenever it carries the ACKNOWLEDGE flag.
        // The SENT_TIME header flag ONLY governs whether a timestamp is present
        // to echo back (enet_protocol_handle_incoming_commands passes the header
        // sentTime, which is 0 when the flag is absent) — it is NOT a condition
        // on whether to acknowledge. The old code ALSO required headerFlagSentTime,
        // so a host reliable arriving in a datagram WITHOUT a sent-time went
        // silently un-ACKed: the host then retransmitted it until its ~10s ENet
        // peer-timeout elapsed and tore the whole session down (0x80030023). That
        // is the lock-screen / secure-desktop disconnect — Sunshine emits a
        // control message across the transition in a datagram that omits
        // SENT_TIME, we never ACK it, and ~10s later we're closed (matching the
        // observed "fine for ~10s, then terminated" signature). Echo `sentTime`
        // as-is (0 when the flag is absent — a harmless throwaway RTT sample on
        // the host, infinitely better than withholding the ACK).
        if flags & Enet.headerFlagSentTime == 0, !loggedFirstReliableWithoutSentTime {
            loggedFirstReliableWithoutSentTime = true
            Diag.notice("ENet inbound reliable WITHOUT sent-time flag (ch \(channelID) "
                + "relSeq \(relSeq)) — ACKing with sentTime=0 (was previously skipped, "
                + "the host-retransmit→peer-timeout teardown cause); first sighting this session",
                Self.logCategory)
        }
        queueAndSendAck(channelID: channelID, relSeq: relSeq, sentTime: sentTime)
    }

    /// Decrypt + dispatch one inbound host control payload (the inner bytes of a
    /// SEND_RELIABLE). Every host control message on the encrypted stream is the
    /// envelope type 0x0001 → crypto.open() yields [type LE][len LE][payload].
    /// Dispatch on the inner type: TERMINATION → onTerminated; HDR → onHdrMode
    /// (transition-gated); RUMBLE → onRumble; TRIGGER RUMBLE → onRumbleTriggers;
    /// RGB LED → onSetRgbLed; MOTION ENABLE → onSetMotionEvent; unknown →
    /// count + once-per-type log + continue (NOT bail). Mirrors
    /// controlReceiveThreadFunc.
    /// Parse SS_HDR_METADATA from a 0x010e payload: payload[0]=enable, then 13
    /// little-endian UInt16 (offsets 1,3,…,25) in HdrMetadata field order
    /// (R/G/B primaries x,y, white point x,y, max/min display luminance,
    /// maxCLL, maxFALL, maxFullFrameLuminance). Verified against the live host
    /// (decodes to Rec.2020 primaries + D65 white point).
    /// Handle a 0x010e HDR-info message: cache the metadata, and fire onHdrMode
    /// + log only on a true transition (the host re-announces ~10×/s).
    func handleHdrInfo(_ payload: [UInt8]) {
        let enabled = (payload.first ?? 0) != 0
        if enabled, payload.count >= 27 {
            withState { lastHdrMetadata = Self.parseHdrMetadata(payload) }
        }
        let changed = withState { () -> Bool in
            guard lastHdrEnabled != enabled else { return false }
            lastHdrEnabled = enabled
            return true
        }
        if changed {
            Diag.info("ENet HDR mode = \(enabled)", Self.logCategory)
            onHdrMode?(enabled)
        }
    }

    static func parseHdrMetadata(_ payload: [UInt8]) -> HdrMetadata {
        func u16(_ idx: Int) -> UInt16 { UInt16(payload[idx]) | (UInt16(payload[idx + 1]) << 8) }
        return HdrMetadata(
            displayPrimariesRX: u16(1), displayPrimariesRY: u16(3),
            displayPrimariesGX: u16(5), displayPrimariesGY: u16(7),
            displayPrimariesBX: u16(9), displayPrimariesBY: u16(11),
            whitePointX: u16(13), whitePointY: u16(15),
            maxDisplayLuminance: u16(17), minDisplayLuminance: u16(19),
            maxContentLightLevel: u16(21), maxFrameAverageLightLevel: u16(23),
            maxFullFrameLuminance: u16(25))
    }

    /// Parse SS_RUMBLE_DATA (0x010b) and hand the motor pair to onRumble.
    ///
    /// Layout verified against moonlight-common-c ControlStream.c
    /// (https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/ControlStream.c):
    /// queueAsyncCallback (~:1001-1020) wraps the post-header bytes
    /// BYTE_ORDER_LITTLE — decryptControlMessageToV1 has already stripped the
    /// V2 payloadLength field and the buffer starts at
    /// sizeof(NVCTL_ENET_PACKET_HEADER_V1)=2 past the u16 type, i.e. exactly
    /// our `payload` — then `BbAdvanceBuffer(&bb, 4)` skips 4 unused bytes
    /// before three BbGet16 reads: controllerNumber, lowFreqRumble,
    /// highFreqRumble. So the 10-byte payload is
    /// [4 unused][u16 LE controllerNumber][u16 LE lowFreq][u16 LE highFreq].
    ///
    /// (0,0) is "motors off" and is forwarded like any other value — the
    /// actuator relies on it to idle the pad. A truncated payload is dropped
    /// log-quietly (rumble is fire-and-forget state, the next event ≤~10ms
    /// away during active rumble supersedes it, and logging per event would
    /// re-create the per-datagram flood the suppression machinery exists to
    /// prevent) — but COUNTED: see the receipt-counter contract below.
    func handleRumbleData(_ payload: [UInt8]) {
        // Receipt is counted HERE, at dispatch, before any validity guard —
        // so `rumble_events_total == 0` PROVES zero 0x010b arrived, full stop.
        // (It previously incremented behind the actuator's slot guard, which
        // weakened the contract to "none arrived well-formed with a valid
        // slot" — exactly the ambiguity that muddied the host-sent-nothing
        // forensics.) Defects then land in rumble_dropped_invalid_total, so
        // deposited-to-actuator = events_total − dropped_invalid_total.
        TelemetryCounters.shared.rumbleEventTotal.increment()
        // Receipt INSTANT next to the receipt COUNT: the detach-context
        // breadcrumb (ControllerForwarder.detach) reads this as last-rumble
        // age, the discriminator that separates a mid-rumble radio drop from
        // pad idle auto-sleep — both observed BT drops needed a three-file
        // join to recover exactly this number. Sub-µs locked store at ~135/s.
        TelemetryCounters.shared.rumbleActivity.stamp()
        guard payload.count >= 10 else {
            TelemetryCounters.shared.rumbleDroppedInvalidTotal.increment()
            return
        }
        func u16(_ idx: Int) -> UInt16 { UInt16(payload[idx]) | (UInt16(payload[idx + 1]) << 8) }
        let controllerNumber = u16(4)
        let lowFreq = u16(6)
        let highFreq = u16(8)
        if !loggedFirstRumble {
            loggedFirstRumble = true
            // Once per session (see the latch's doc): the single sighting that
            // proves the host's wire layout and slot addressing postmortem.
            Diag.info("first host rumble (0x010b): ctl=\(controllerNumber) "
                + "low=\(lowFreq) high=\(highFreq)", Self.logCategory)
        }
        onRumble?(controllerNumber, lowFreq, highFreq)
    }

    /// Parse SS_RUMBLE_TRIGGERS (0x5500) and hand the trigger pair to
    /// onRumbleTriggers.
    ///
    /// Layout verified against moonlight-common-c ControlStream.c
    /// queueAsyncCallback (IDX_RUMBLE_TRIGGER_DATA branch): BYTE_ORDER_LITTLE
    /// with NO leading skip (unlike 0x010b's 4 unused bytes) — three BbGet16
    /// reads: controllerNumber, leftTriggerMotor, rightTriggerMotor. So the
    /// 6-byte payload is [u16 LE controllerNumber][u16 LE left][u16 LE right].
    ///
    /// (0,0) is "trigger motors off" and is forwarded like any other value; a
    /// truncated payload is dropped silently for the same reason as
    /// handleRumbleData (fire-and-forget latest-state, superseded within
    /// ~10ms; logging would re-create the per-datagram flood).
    func handleRumbleTriggers(_ payload: [UInt8]) {
        guard payload.count >= 6 else { return }
        func u16(_ idx: Int) -> UInt16 { UInt16(payload[idx]) | (UInt16(payload[idx + 1]) << 8) }
        onRumbleTriggers?(u16(0), u16(2), u16(4))
    }

    /// Parse SET_RGB_LED (0x5502) and hand the color to onSetRgbLed.
    ///
    /// Layout verified against moonlight-common-c ControlStream.c
    /// queueAsyncCallback (IDX_SET_RGB_LED branch): BYTE_ORDER_LITTLE, no
    /// leading skip — one BbGet16 (controllerNumber) then three BbGet8
    /// (r, g, b). So the 5-byte payload is
    /// [u16 LE controllerNumber][u8 r][u8 g][u8 b].
    ///
    /// Truncated → dropped silently: the light bar is latest-wins cosmetic
    /// state and Sunshine re-sends on the next color change.
    func handleSetRgbLed(_ payload: [UInt8]) {
        guard payload.count >= 5 else { return }
        let controllerNumber = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        onSetRgbLed?(controllerNumber, payload[2], payload[3], payload[4])
    }

    /// Parse SET_MOTION_EVENT (0x5501) and hand the enable to onSetMotionEvent.
    ///
    /// Layout verified against BOTH ends of the wire: Sunshine's
    /// control_set_motion_event_t (stream.cpp) writes
    /// [u16 LE controllerNumber][u16 LE reportRateHz][u8 motionType], and
    /// moonlight-common-c ControlStream.c parses the identical order (BbGet16
    /// controllerNumber, BbGet16 reportRateHz, BbGet8 motionType,
    /// BYTE_ORDER_LITTLE, no leading skip). reportRateHz == 0 means stop;
    /// motionType is LI_MOTION_TYPE_ACCEL/GYRO.
    ///
    /// Truncated → dropped but LOGGED (unlike rumble's silent drop): this is
    /// a rare one-shot state change with no ~10ms supersede coming, so a
    /// malformed one would otherwise mean a sensor silently never turns on.
    func handleSetMotionEvent(_ payload: [UInt8]) {
        guard payload.count >= 5 else {
            Diag.info("ENet SET_MOTION_EVENT truncated (\(payload.count) bytes); dropped",
                      Self.logCategory)
            return
        }
        func u16(_ idx: Int) -> UInt16 { UInt16(payload[idx]) | (UInt16(payload[idx + 1]) << 8) }
        onSetMotionEvent?(u16(0), payload[4], u16(2))
    }

    /// Parse SET_ADAPTIVE_TRIGGERS (0x5503) and hand the per-trigger mode +
    /// params to onSetAdaptiveTriggers.
    ///
    /// Layout verified against moonlight-common-c ControlStream.c
    /// (queueAsyncCallback, IDX_DS_ADAPTIVE_TRIGGERS branch) and Sunshine
    /// stream.cpp control_adaptive_triggers_t: BYTE_ORDER_LITTLE, no leading
    /// skip — BbGet16 controllerNumber, BbGet8 eventFlags, BbGet8 typeLeft,
    /// BbGet8 typeRight, then two DS_EFFECT_PAYLOAD_SIZE (10-byte) param arrays
    /// (left, then right). So the 25-byte payload is
    /// [u16 LE controllerNumber][u8 eventFlags][u8 typeLeft][u8 typeRight]
    /// [10 left params][10 right params]. eventFlags carries
    /// DS_EFFECT_RIGHT_TRIGGER (0x04) / DS_EFFECT_LEFT_TRIGGER (0x08) for which
    /// trigger blocks the host wants applied. typeLeft/typeRight are the
    /// DualSense-native mode bytes (no abstract enum — passed through verbatim
    /// to the HID output report, the moonlight-qt shape).
    ///
    /// Truncated → dropped but LOGGED (the handleSetMotionEvent discipline, not
    /// rumble's silent drop): a one-shot trigger arm with no ~10ms supersede
    /// coming, so a malformed one would silently leave the trigger un-armed.
    func handleSetAdaptiveTriggers(_ payload: [UInt8]) {
        // 2 (ctl) + 1 (flags) + 1 (typeL) + 1 (typeR) + 10 (left) + 10 (right).
        guard payload.count >= 25 else {
            Diag.info("ENet SET_ADAPTIVE_TRIGGERS truncated (\(payload.count) bytes); dropped",
                      Self.logCategory)
            return
        }
        let controllerNumber = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        let eventFlags = payload[2]
        let typeLeft = payload[3]
        let typeRight = payload[4]
        let left = Array(payload[5..<15])
        let right = Array(payload[15..<25])
        if !loggedFirstAdaptiveTriggers {
            loggedFirstAdaptiveTriggers = true
            Diag.info("first host adaptive triggers (0x5503): ctl=\(controllerNumber) "
                + "flags=0x\(String(eventFlags, radix: 16)) "
                + "typeL=0x\(String(typeLeft, radix: 16)) typeR=0x\(String(typeRight, radix: 16))",
                Self.logCategory)
        }
        onSetAdaptiveTriggers?(controllerNumber, eventFlags, typeLeft, typeRight, left, right)
    }

    func handleInboundControl(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        let envelopeType = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard envelopeType == 0x0001 else {
            Diag.info("ENet inbound non-encrypted control type 0x\(String(envelopeType, radix: 16)); ignoring",
                      Self.logCategory)
            return
        }

        let inner: [UInt8]
        do {
            inner = try crypto.open(bytes)
        } catch {
            Diag.error("ENet failed to decrypt inbound control: \(error)", Self.logCategory)
            return
        }
        // inner = [type LE][payloadLength LE][payload]
        guard inner.count >= 4 else { return }
        let innerType = UInt16(inner[0]) | (UInt16(inner[1]) << 8)
        let payloadLen = Int(inner[2]) | (Int(inner[3]) << 8)
        let payload = (inner.count >= 4 + payloadLen) ? Array(inner[4..<(4 + payloadLen)]) : Array(inner[4...])

        switch innerType {
        case CtrlV2.termination:
            let code = parseTerminationCode(payload)
            Diag.error("ENet TERMINATION received (code 0x\(String(UInt32(bitPattern: code), radix: 16)))",
                       Self.logCategory)
            withState { disconnected = true }
            onTerminated?(code)
        case CtrlV2.hdrInfo:
            handleHdrInfo(payload)
        case CtrlV2.rumbleData:
            handleRumbleData(payload)
        case CtrlV2.rumbleTriggers:
            handleRumbleTriggers(payload)
        case CtrlV2.setRgbLed:
            handleSetRgbLed(payload)
        case CtrlV2.setMotionEvent:
            handleSetMotionEvent(payload)
        case CtrlV2.setAdaptiveTriggers:
            handleSetAdaptiveTriggers(payload)
        default:
            // ACKed + decrypted but not dispatched — truly-unknown types now
            // (rumble 0x010b, triggers 0x5500, and RGB LED 0x5502 each lived
            // here until they grew a dispatch above). Such types can arrive at
            // game-frame rate (rumble hit ~135/s here), so logging per datagram
            // would evict the diagnostic ring; log each type ONCE (the
            // handleHdrInfo transition-gating discipline) and preserve the
            // volume signal in the counters. ONE call bumps the aggregate AND
            // the bounded per-type tally together so they can never skew — the
            // per-type counts are durable in the session scorecard, because the
            // teardown Diag NOTICE alone is lossy (a crash or a still-running
            // session loses it).
            TelemetryCounters.shared.noteCtrlIgnored(type: innerType)
            let firstSighting = withState { () -> Bool in
                let seen = ignoredControlCounts[innerType] != nil
                ignoredControlCounts[innerType, default: 0] += 1
                return !seen
            }
            if firstSighting {
                // Bounded payload peek (≤16 bytes, once per type per session):
                // enough to identify the wire layout against moonlight-common-c
                // in a 30-second lookup — 0x010b cost a whole investigation
                // precisely because nothing ever logged its bytes. Post-decrypt
                // host CONTROL data, the same class as the HDR metadata we
                // already parse — never key material.
                let peek = payload.prefix(16).map { String(format: "%02x", $0) }
                    .joined(separator: " ")
                let suffix = payload.count > 16 ? "…" : ""
                Diag.info("ENet inbound control type 0x\(String(innerType, radix: 16))"
                    + "\(Self.ignoredControlTypeName(innerType)) (\(payloadLen) bytes"
                    + "\(peek.isEmpty ? "" : ": \(peek)\(suffix)")); "
                    + "ignoring + suppressing further occurrences of this type", Self.logCategory)
            }
        }
    }

    /// Parse a TERMINATION payload (ControlStream.c:1305-1342). Extended form
    /// (>=4 bytes) = BIG-endian u32 HRESULT; short form = LITTLE-endian u16.
    func parseTerminationCode(_ payload: [UInt8]) -> Int32 {
        if payload.count >= 4 {
            let be = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
                | (UInt32(payload[2]) << 8) | UInt32(payload[3])
            return Int32(bitPattern: be)
        } else if payload.count >= 2 {
            let le = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
            return Int32(le)
        }
        return -1
    }

    /// handle_acknowledge: match by (reliableSequenceNumber, channelID) and drop
    /// the sent reliable command. Body: receivedReliableSeq, receivedSentTime.
    func handleAcknowledge(ackChannelID: UInt8, _ reader: inout ByteReader) {
        guard let receivedRelSeq = reader.u16BE(),
              let receivedSentTime = reader.u16BE() else { return }
        var ackDelayMs: UInt32 = 0
        withState {
            // Any inbound ACK is proof the host is alive and draining our reliable
            // backlog — refresh the silence clock the control loop watches.
            lastAckRecvMs = serviceTimeMs
            // SUB-MS RTT: the host echoes back the 16-bit `sentTime` token we
            // stamped on the datagram. We use that token ONLY to look up the
            // HIGH-RES local instant we recorded when sending (localSentByToken),
            // then measure the round trip = monotonicMs - localSent as FRACTIONAL
            // ms — not the quantized whole-ms wire delta the old code computed
            // (UInt16 now - receivedSentTime), which floored every sample to an
            // integer and made the overlay read "9.00 ms" while jitter showed
            // 0.09. Only update the EWMA when we have a matching stamp; a token we
            // never sent (or one already swept by TTL) yields no sample, so a
            // stray/duplicate ack can't corrupt the estimate. The matched entry is
            // consumed (removed) so a duplicate ack for it doesn't double-count.
            if let localSent = localSentByToken.removeValue(forKey: receivedSentTime) {
                // Floor at a tiny positive value: the round trip is physically > 0,
                // and a 0 (same-tick send+ack, impossible over UDP but cheap to
                // guard) would understate the EWMA. EWMA gains mirror ENet's peer
                // update (1/8 mean, 1/4 variance), now in Double for sub-ms signal.
                let rtt = max(monotonicMs - localSent, 0.001)
                if hasRttSample {
                    rttVariance -= rttVariance / 4
                    if rtt >= roundTripTime {
                        let diff = rtt - roundTripTime
                        roundTripTime += diff / 8
                        rttVariance += diff / 4
                    } else {
                        let diff = roundTripTime - rtt
                        roundTripTime -= diff / 8
                        rttVariance += diff / 4
                    }
                } else {
                    roundTripTime = rtt
                    rttVariance = rtt / 2
                    hasRttSample = true
                }
            }
            // Match on BOTH channelID and reliableSequenceNumber, like ENet's
            // remove_sent_reliable_command. Matching relSeq alone would let a
            // delayed/duplicate ACK with relSeq==1 (which CONNECT on ch0xFF and
            // START_A on ch0 both carry) drop the wrong in-flight command.
            if let idx = sentReliable.firstIndex(where: {
                $0.reliableSequenceNumber == receivedRelSeq && $0.channelID == ackChannelID
            }) {
                // ENet leg of the per-socket GAP-EVENT family: how long did the
                // host leave this reliable command unanswered? Measured at the
                // matched ACK (first send → ACK, wrap-safe), so this channel's
                // designed inter-message idle can never read as a gap — and a
                // doze/radio stall is visible the moment the late ACK lands,
                // even when the stall began with nothing outstanding (the
                // failure mode the earlier arrival-gap gate was blind to: in
                // idle, the previous arrival is old, so gap ≫ outstanding age
                // and the gate never passed exactly where doze lives).
                // Retransmits count from FIRST send: a lost-then-resent
                // datagram is genuine link trouble for this discriminator.
                ackDelayMs = serviceTimeMs &- sentReliable[idx].firstSentAtMs
                sentReliable.remove(at: idx)
                unackedReliables.decrement() // mirror sentReliable.count
            }
        }
        if ackDelayMs > 20 {
            let counters = TelemetryCounters.shared
            counters.enetGapOver20msTotal.increment()
            if ackDelayMs > 50 { counters.enetGapOver50msTotal.increment() }
            if ackDelayMs > 100 { counters.enetGapOver100msTotal.increment() }
        }
    }

    /// send_acknowledgements (protocol.c:1294-1344). 8-byte ACK command echoing
    /// the received reliableSequenceNumber + sentTime, in a SENT_TIME datagram
    /// addressed with our learned outgoingPeerID|session.
    func queueAndSendAck(channelID: UInt8, relSeq: UInt16, sentTime: UInt16) {
        var cmd = ByteWriter()
        cmd.u8(Enet.cmdAcknowledge)  // 0x01, no flags
        cmd.u8(channelID)
        cmd.u16BE(relSeq)
        cmd.u16BE(relSeq)            // receivedReliableSequenceNumber
        cmd.u16BE(sentTime)         // receivedSentTime (echo host's sentTime)
        // recordRtt: false — the host never echoes an ACK datagram's token, so
        // an RTT stamp for it is unconsumable dead weight in localSentByToken
        // (at rumble's ~135 ACKs/s it kept the map pinned over its cap and
        // turned every send into a full-map sweep). The wire is unchanged:
        // SENT_TIME flag + token still go out per the ENet wire facts.
        sendDatagram(wrapDatagram(commands: [cmd.bytes], sentTime: true,
                                  recordRtt: false))
        // SAMPLED 1-in-256 (log diet): this line fired per reliable packet —
        // ~76% of one measured session log, evicting the 2,000-entry diagnostic
        // ring in ~2 minutes of streaming. The DATA
        // already rides telemetry (ACK delays feed the enet gap counters; the
        // 1Hz health snapshot carries the unacked trend), so the per-line value
        // is pure liveness. Keying on the host's relSeq keeps a deterministic
        // heartbeat (no new stored state): ~one line per 256 reliable commands
        // proves the ACK path is alive without drowning everything else.
        if relSeq & 0xFF == 0 {
            Diag.debug("ENet ACK path alive: relSeq=\(relSeq) (channel \(channelID), 1-in-256 sample)",
                       Self.logCategory)
        }
    }
}
