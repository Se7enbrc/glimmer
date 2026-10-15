// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors
// SPDX-FileCopyrightText: 2002-2024 Lee Salzman

// ENet wire primitives from enet.h / protocol.h; transport provenance is in CREDITS.md.
// All multibyte fields are big-endian except connectID, which stays in native bytes so the
// VERIFY_CONNECT echo can be byte-compared without conversion.

import Foundation

// MARK: - ENet constants (enet.h / protocol.h)

package enum Enet {
    /// Wrapping u16 sequence: newer means a nonzero forward distance below half the window.
    /// The PC's small ACK-clocked backlog keeps the half-space comparison safe (enet outgoing ++ wraps too).
    static func reliableSeqIsNewer(_ seq: UInt16, than last: UInt16) -> Bool {
        seq != last && (seq &- last) < 0x8000
    }

    static let cmdNone: UInt8 = 0
    package static let cmdAcknowledge: UInt8 = 1
    package static let cmdConnect: UInt8 = 2
    package static let cmdVerifyConnect: UInt8 = 3
    package static let cmdDisconnect: UInt8 = 4
    package static let cmdPing: UInt8 = 5
    package static let cmdSendReliable: UInt8 = 6
    package static let cmdSendUnreliable: UInt8 = 7
    package static let cmdSendFragment: UInt8 = 8
    package static let cmdSendUnsequenced: UInt8 = 9 // ENET_PROTOCOL_COMMAND_SEND_UNSEQUENCED
    package static let cmdBandwidthLimit: UInt8 = 10
    package static let cmdThrottleConfigure: UInt8 = 11
    package static let cmdSendUnreliableFragment: UInt8 = 12

    package static let flagAcknowledge: UInt8 = 1 << 7
    static let flagUnsequenced: UInt8 = 1 << 6
    package static let commandMask: UInt8 = 0x0F

    package static let headerFlagCompressed: UInt16 = 1 << 14
    package static let headerFlagSentTime: UInt16 = 1 << 15
    package static let headerSessionShift: UInt16 = 12
    static let headerSessionMask: UInt16 = 3 << 12
    package static let maximumPeerID: UInt16 = 0xFFF

    package static let defaultMTU: UInt32 = 900
    package static let maximumWindowSize: UInt32 = 65536
    package static let packetThrottleInterval: UInt32 = 5000
    package static let packetThrottleAcceleration: UInt32 = 2
    package static let packetThrottleDeceleration: UInt32 = 2
    package static let defaultRoundTripTimeMs: UInt32 = 500

    package static let ctrlChannelCount: UInt32 = 0x30 // 48
    package static let ctrlChannelGeneric: UInt8 = 0    // CTRL_CHANNEL_GENERIC
    package static let ctrlChannelUrgent: UInt8 = 1     // CTRL_CHANNEL_URGENT (IDR/RFI/LTR)
    package static let peerChannelID: UInt8 = 0xFF      // CONNECT / PING

    // Input uplink channels (Limelight-internal.h CTRL_CHANNEL_*). Each input
    // class rides its own ENet channel so retransmit ordering is per-class.
    package static let ctrlChannelKeyboard: UInt8 = 0x02  // CTRL_CHANNEL_KEYBOARD
    package static let ctrlChannelMouse: UInt8 = 0x03     // CTRL_CHANNEL_MOUSE (mouse/scroll/hscroll)
    package static let ctrlChannelUtf8: UInt8 = 0x06      // CTRL_CHANNEL_UTF8 (paste as text)
    package static let ctrlChannelGamepadBase: UInt8 = 0x10 // CTRL_CHANNEL_GAMEPAD_BASE + (num % 16)
    /// CTRL_CHANNEL_SENSOR_BASE + (num % 16) - controller motion uplink rides
    /// its own per-pad channel, apart from the button/axis stream, so a
    /// retransmitted sensor sample can never stall a button edge.
    package static let ctrlChannelSensorBase: UInt8 = 0x20

    /// The channel a send may actually use: the requested one when the peer
    /// granted it, else the generic channel (ControlStream.c sendMessageEnet).
    package static func effectiveChannel(_ requested: UInt8, negotiatedCount: UInt32) -> UInt8 {
        UInt32(requested) < negotiatedCount ? requested : ctrlChannelGeneric
    }
    /// MAX_GAMEPADS - Sunshine supports up to 16; controllerNumber %= this.
    package static let maxGamepads: Int = 16

    /// ENET_PEER_PING_INTERVAL (enet.h) - transport keepalive cadence.
    package static let pingIntervalMs: UInt32 = 500
    /// PERIODIC_PING_INTERVAL_MS (ControlStream.c) - app-level keepalive.
    package static let periodicPingIntervalMs: UInt32 = 100
}

/// Gen7-encrypted control message types (ControlStream.c packetTypesGen7Enc).
package enum CtrlV2 {
    package static let requestIdrFrame: UInt16 = 0x0302
    package static let invalidateRefFrames: UInt16 = 0x0301  // SS_RFI_REQUEST_PTYPE
    static let ltrFrameAck: UInt16 = 0x0350          // SS_LTR_FRAME_ACK_PTYPE
    package static let periodicPing: UInt16 = 0x0200         // Loss Stats / keepalive
    // NOTE: no frameFecStatus type. SS_FRAME_FEC_PTYPE (0x5502) collides with
    // Sunshine's IDX_SET_RGB_LED, so Glimmer cannot send per-frame FEC status.
    package static let termination: UInt16 = 0x0109          // extended termination
    /// Controller rumble - packetTypesGen7Enc[IDX_RUMBLE_DATA]. Dispatched by handleInboundControl → handleRumbleData →
    /// onRumble → ControllerHaptics (GameController force feedback). Payload layout + the C-source citation live on
    /// handleRumbleData (EnetControlChannel+Inbound.swift).
    package static let rumbleData: UInt16 = 0x010b
    /// Trigger rumble - packetTypesGen7Enc[IDX_RUMBLE_TRIGGER_DATA] (Sunshine protocol extension; the host only sends
    /// it to pads that advertised LI_CCAP_TRIGGER_RUMBLE). Dispatched by handleInboundControl → handleRumbleTriggers →
    /// onRumbleTriggers → ControllerHaptics. Payload layout + the C-source citation live on handleRumbleTriggers.
    package static let rumbleTriggers: UInt16 = 0x5500
    /// IDX_SET_MOTION_EVENT, enabled by LI_CCAP_ACCEL/GYRO. handleSetMotionEvent carries layout/citations
    /// and routes through onSetMotionEvent to ControllerMotion sampling at the requested rate.
    package static let setMotionEvent: UInt16 = 0x5501
    /// IDX_SET_RGB_LED shares outbound SS_FRAME_FEC_PTYPE's value but is unambiguous inbound.
    /// LI_CCAP_RGB_LED opts in; handleSetRgbLed → GCDeviceLight sets slot color at startup or during games.
    package static let setRgbLed: UInt16 = 0x5502
    /// IDX_DS_ADAPTIVE_TRIGGERS is a Sunshine DualSense extension routed by handleSetAdaptiveTriggers
    /// through NativeConnectionEvents to DualSenseHID; that handler retains the payload layout and C citation.
    package static let setAdaptiveTriggers: UInt16 = 0x5503
    /// Set player indicator LEDs - Sunshine 2026.906+ extension (IDX_SET_PLAYER_LEDS):
    /// [u16 LE controllerNumber][u8 solid mask][u8 flashing mask], four bits each.
    package static let setPlayerLeds: UInt16 = 0x5504
    package static let hdrInfo: UInt16 = 0x010e              // HDR mode
    /// Input data - packetTypesGen7Enc[IDX_INPUT_DATA] (ControlStream.c:209).
    /// Carries the NV_INPUT_HEADER+body that InputEncoder builds.
    package static let inputData: UInt16 = 0x0206
}

package enum EnetError: Error, CustomStringConvertible {
    case interrupted
    case socketFailure(String)
    case connectTimeout
    case verifyConnectRejected(String)
    case disconnected
    case startFailed(String)
    case mtuExceeded

    package var description: String {
        switch self {
        case .interrupted: return "ENet interrupted"
        case .socketFailure(let reason): return "ENet UDP socket failure: \(reason)"
        case .connectTimeout: return "ENet CONNECT timed out (no VERIFY_CONNECT)"
        case .verifyConnectRejected(let reason): return "ENet VERIFY_CONNECT rejected: \(reason)"
        case .disconnected: return "ENet peer disconnected during handshake"
        case .startFailed(let reason): return "ENet START packet failed: \(reason)"
        case .mtuExceeded: return "ENet reliable payload exceeds MTU (fragmentation unsupported)"
        }
    }
}

// MARK: - Big-endian byte writer/reader

package struct ByteWriter {
    package init() {}

    package var bytes = [UInt8]()
    package mutating func u8(_ value: UInt8) { bytes.append(value) }
    package mutating func u16BE(_ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    package mutating func u32BE(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF)); bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    /// connectID is written RAW (native bytes, no byteswap) so it round-trips.
    package mutating func u32Raw(_ value: UInt32) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }
    /// Little-endian u32 - for control-V2 payloads (RFI/LTR fields are LE).
    package mutating func u32LE(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF)); bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF)); bytes.append(UInt8((value >> 24) & 0xFF))
    }
    package mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
}

package struct ByteReader {
    package let bytes: [UInt8]
    package var offset: Int
    package init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }

    package var remaining: Int { bytes.count - offset }
    package mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }; return bytes[offset]
    }
    package mutating func u16BE() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
    package mutating func u32BE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
    /// Read `count` bytes, advancing the offset. Returns nil if insufficient.
    package mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
    /// connectID is read RAW (native bytes) to compare against what we sent.
    package mutating func u32Raw() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            for idx in 0..<4 { dst[idx] = bytes[offset + idx] }
        }
        return value
    }
}

// MARK: - Reliable command tracking

package struct SentReliable {
    package let channelID: UInt8
    package let reliableSequenceNumber: UInt16
    /// The fully-assembled command bytes (header + inline payload) for resend.
    package let commandBytes: [UInt8]
    /// Last time (ms) this command was (re)sent - drives the retransmit timer.
    package var sentAtMs: UInt32
    /// First time (ms) this command was ever sent - drives the age-based give-up eviction (mirrors
    /// enet_protocol_check_timeouts' timeoutMinimum=5000ms, protocol.c:1371-1379) so a wedged peer is detected instead
    /// of resending forever. Set once at append; never updated on resend.
    package var firstSentAtMs: UInt32
    package var attempts: Int

    package init(channelID: UInt8, reliableSequenceNumber: UInt16, commandBytes: [UInt8],
                 sentAtMs: UInt32, firstSentAtMs: UInt32, attempts: Int) {
        self.channelID = channelID
        self.reliableSequenceNumber = reliableSequenceNumber
        self.commandBytes = commandBytes
        self.sentAtMs = sentAtMs
        self.firstSentAtMs = firstSentAtMs
        self.attempts = attempts
    }
}

/// ENet's in-order delivery (enet_peer_queue_incoming_command): authenticated messages wait behind
/// a missing reliable until the PC resends it, which ENet always does. Skipping ahead instead would
/// acknowledge the late resend as stale and lose that message for good.
package struct EnetInboundOrder {
    package init() {}

    // Rumble runs about 135/s, so 2048 is about 15 s: a backstop for a reliable that never comes.
    static let maxHeld = 2048
    package var next: UInt16 = 1
    private(set) var held: [UInt16: [UInt8]] = [:]

    package func isDuplicate(_ seq: UInt16) -> Bool {
        held[seq] != nil || (seq != next && !Enet.reliableSeqIsNewer(seq, than: next))
    }

    package mutating func accept(_ seq: UInt16, payload: [UInt8]) -> (due: [[UInt8]], skipped: Int) {
        if seq == next {
            next &+= 1
            return ([payload] + drain(), 0)
        }
        held[seq] = payload
        return held.count >= Self.maxHeld ? skipGap() : ([], 0)
    }

    private mutating func skipGap() -> (due: [[UInt8]], skipped: Int) {
        guard let first = held.keys.min(by: { ($0 &- next) < ($1 &- next) }) else { return ([], 0) }
        let skipped = Int(first &- next)
        next = first
        return (drain(), skipped)
    }

    private mutating func drain() -> [[UInt8]] {
        var due: [[UInt8]] = []
        while let payload = held.removeValue(forKey: next) {
            due.append(payload)
            next &+= 1
        }
        return due
    }
}
