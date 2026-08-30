//
//  EnetControlChannel+ControlMessages.swift
//
//  The per-message parsers for decrypted host control payloads, one per inner
//  type dispatched by `handleInboundControl`: HDR info + SS_HDR_METADATA,
//  SS_RUMBLE_DATA, SS_RUMBLE_TRIGGERS, SET_RGB_LED, SET_MOTION_EVENT and
//  SET_ADAPTIVE_TRIGGERS. Each carries its wire-layout citation against
//  moonlight-common-c ControlStream.c / Sunshine stream.cpp. Split out of
//  EnetControlChannel+Inbound.swift to keep each unit focused; see
//  EnetControlChannel.swift for the shared stored state and wire facts.
//

import Foundation

extension EnetControlChannel {

    /// Parse SS_HDR_METADATA from a 0x010e payload: payload[0]=enable, then 13
    /// little-endian UInt16 (offsets 1,3,...,25) in HdrMetadata field order
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
    /// BYTE_ORDER_LITTLE - decryptControlMessageToV1 has already stripped the
    /// V2 payloadLength field and the buffer starts at
    /// sizeof(NVCTL_ENET_PACKET_HEADER_V1)=2 past the u16 type, i.e. exactly
    /// our `payload` - then `BbAdvanceBuffer(&bb, 4)` skips 4 unused bytes
    /// before three BbGet16 reads: controllerNumber, lowFreqRumble,
    /// highFreqRumble. So the 10-byte payload is
    /// [4 unused][u16 LE controllerNumber][u16 LE lowFreq][u16 LE highFreq].
    ///
    /// (0,0) is "motors off" and is forwarded like any other value - the
    /// actuator relies on it to idle the pad. A truncated payload is dropped
    /// log-quietly (rumble is fire-and-forget state, the next event ≤~10ms
    /// away during active rumble supersedes it, and logging per event would
    /// re-create the per-datagram flood the suppression machinery exists to
    /// prevent) - but COUNTED: see the receipt-counter contract below.
    func handleRumbleData(_ payload: [UInt8]) {
        // Receipt is counted HERE, at dispatch, before any validity guard -
        // so `rumble_events_total == 0` PROVES zero 0x010b arrived, full stop.
        // (It previously incremented behind the actuator's slot guard, which
        // weakened the contract to "none arrived well-formed with a valid
        // slot" - exactly the ambiguity that muddied the host-sent-nothing
        // forensics.) Defects then land in rumble_dropped_invalid_total, so
        // deposited-to-actuator = events_total − dropped_invalid_total.
        TelemetryCounters.shared.rumbleEventTotal.increment()
        // Receipt INSTANT next to the receipt COUNT: the detach-context
        // breadcrumb (ControllerForwarder.detach) reads this as last-rumble
        // age, the discriminator that separates a mid-rumble radio drop from
        // pad idle auto-sleep - both observed BT drops needed a three-file
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
    /// with NO leading skip (unlike 0x010b's 4 unused bytes) - three BbGet16
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
    /// leading skip - one BbGet16 (controllerNumber) then three BbGet8
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
    /// skip - BbGet16 controllerNumber, BbGet8 eventFlags, BbGet8 typeLeft,
    /// BbGet8 typeRight, then two DS_EFFECT_PAYLOAD_SIZE (10-byte) param arrays
    /// (left, then right). So the 25-byte payload is
    /// [u16 LE controllerNumber][u8 eventFlags][u8 typeLeft][u8 typeRight]
    /// [10 left params][10 right params]. eventFlags carries
    /// DS_EFFECT_RIGHT_TRIGGER (0x04) / DS_EFFECT_LEFT_TRIGGER (0x08) for which
    /// trigger blocks the host wants applied. typeLeft/typeRight are the
    /// DualSense-native mode bytes (no abstract enum - passed through verbatim
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
}
