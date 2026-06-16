//
//  EnetWire.swift
//
//  Byte-exact ENet wire primitives shared by EnetControlChannel: the protocol
//  constants (enet.h / protocol.h), the error type, big-endian byte
//  writers/readers, and the reliable-command tracking struct. Split out of
//  EnetControlChannel so each file stays focused.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  All multi-byte ENet fields are BIG-ENDIAN (htons/htonl) EXCEPT connectID,
//  which is written/read RAW (native bytes) so it round-trips identically and
//  can be byte-compared against the VERIFY_CONNECT echo.

import Foundation

// MARK: - ENet constants (enet.h / protocol.h)

enum Enet {
    static let cmdNone: UInt8 = 0
    static let cmdAcknowledge: UInt8 = 1
    static let cmdConnect: UInt8 = 2
    static let cmdVerifyConnect: UInt8 = 3
    static let cmdDisconnect: UInt8 = 4
    static let cmdPing: UInt8 = 5
    static let cmdSendReliable: UInt8 = 6
    static let cmdSendUnreliable: UInt8 = 7
    static let cmdSendFragment: UInt8 = 8
    static let cmdSendUnsequenced: UInt8 = 9 // ENET_PROTOCOL_COMMAND_SEND_UNSEQUENCED
    static let cmdBandwidthLimit: UInt8 = 10
    static let cmdThrottleConfigure: UInt8 = 11
    static let cmdSendUnreliableFragment: UInt8 = 12

    static let flagAcknowledge: UInt8 = 1 << 7
    static let flagUnsequenced: UInt8 = 1 << 6
    static let commandMask: UInt8 = 0x0F

    static let headerFlagCompressed: UInt16 = 1 << 14
    static let headerFlagSentTime: UInt16 = 1 << 15
    static let headerSessionShift: UInt16 = 12
    static let headerSessionMask: UInt16 = 3 << 12
    static let maximumPeerID: UInt16 = 0xFFF

    static let defaultMTU: UInt32 = 900
    static let maximumWindowSize: UInt32 = 65536
    static let packetThrottleInterval: UInt32 = 5000
    static let packetThrottleAcceleration: UInt32 = 2
    static let packetThrottleDeceleration: UInt32 = 2
    static let defaultRoundTripTimeMs: UInt32 = 500

    static let ctrlChannelCount: UInt32 = 0x30 // 48
    static let ctrlChannelGeneric: UInt8 = 0    // CTRL_CHANNEL_GENERIC
    static let ctrlChannelUrgent: UInt8 = 1     // CTRL_CHANNEL_URGENT (IDR/RFI/LTR)
    static let peerChannelID: UInt8 = 0xFF      // CONNECT / PING

    // Input uplink channels (Limelight-internal.h CTRL_CHANNEL_*). Each input
    // class rides its own ENet channel so retransmit ordering is per-class.
    static let ctrlChannelKeyboard: UInt8 = 0x02  // CTRL_CHANNEL_KEYBOARD
    static let ctrlChannelMouse: UInt8 = 0x03     // CTRL_CHANNEL_MOUSE (mouse/scroll/hscroll)
    static let ctrlChannelGamepadBase: UInt8 = 0x10 // CTRL_CHANNEL_GAMEPAD_BASE + (num % 16)
    /// CTRL_CHANNEL_SENSOR_BASE + (num % 16) - controller motion uplink rides
    /// its own per-pad channel, apart from the button/axis stream, so a
    /// retransmitted sensor sample can never stall a button edge.
    static let ctrlChannelSensorBase: UInt8 = 0x20
    /// MAX_GAMEPADS - Sunshine supports up to 16; controllerNumber %= this.
    static let maxGamepads: Int = 16

    /// ENET_PEER_PING_INTERVAL (enet.h) - transport keepalive cadence.
    static let pingIntervalMs: UInt32 = 500
    /// PERIODIC_PING_INTERVAL_MS (ControlStream.c) - app-level keepalive.
    static let periodicPingIntervalMs: UInt32 = 100
}

/// Gen7-encrypted control message types (ControlStream.c packetTypesGen7Enc).
enum CtrlV2 {
    static let requestIdrFrame: UInt16 = 0x0302
    static let invalidateRefFrames: UInt16 = 0x0301  // SS_RFI_REQUEST_PTYPE
    static let ltrFrameAck: UInt16 = 0x0350          // SS_LTR_FRAME_ACK_PTYPE
    static let periodicPing: UInt16 = 0x0200         // Loss Stats / keepalive
    // NOTE: no frameFecStatus type. SS_FRAME_FEC_PTYPE (0x5502) collides with
    // Sunshine's IDX_SET_RGB_LED, and Glimmer never sends per-frame FEC status
    // (see EnetControlChannel.queueFrameFecStatus), so the constant is omitted.
    static let termination: UInt16 = 0x0109          // extended termination
    /// Controller rumble - packetTypesGen7Enc[IDX_RUMBLE_DATA]. Dispatched by
    /// handleInboundControl → handleRumbleData → onRumble → ControllerHaptics
    /// (GameController force feedback). Payload layout + the C-source citation
    /// live on handleRumbleData (EnetControlChannel+Inbound.swift).
    static let rumbleData: UInt16 = 0x010b
    /// Trigger rumble - packetTypesGen7Enc[IDX_RUMBLE_TRIGGER_DATA] (Sunshine
    /// protocol extension; the host only sends it to pads that advertised
    /// LI_CCAP_TRIGGER_RUMBLE). Dispatched by handleInboundControl →
    /// handleRumbleTriggers → onRumbleTriggers → ControllerHaptics. Payload
    /// layout + the C-source citation live on handleRumbleTriggers.
    static let rumbleTriggers: UInt16 = 0x5500
    /// Motion enable - Sunshine's IDX_SET_MOTION_EVENT (host→client; arrives
    /// because we advertise LI_CCAP_ACCEL/GYRO on IMU-capable pads).
    /// Dispatched by handleInboundControl → handleSetMotionEvent →
    /// onSetMotionEvent → ControllerMotion (GCMotion sampling at the
    /// requested rate). Payload layout + the dual C-source citation live on
    /// handleSetMotionEvent (EnetControlChannel+Inbound.swift).
    static let setMotionEvent: UInt16 = 0x5501
    /// Set RGB LED - Sunshine's IDX_SET_RGB_LED (host→client). The same wire
    /// value as moonlight's outbound SS_FRAME_FEC_PTYPE (see the NOTE above),
    /// but unambiguous in the inbound direction. Dispatched by
    /// handleInboundControl → handleSetRgbLed → onSetRgbLed → GCDeviceLight on
    /// the mapped pad. Advertised via LI_CCAP_RGB_LED on light-bar pads
    /// (ControllerForwarder); Sunshine paints the slot color at session start.
    static let setRgbLed: UInt16 = 0x5502
    /// Set adaptive triggers - Sunshine's IDX_DS_ADAPTIVE_TRIGGERS (host→client;
    /// Sunshine protocol extension, sent only to DualSense pads). Dispatched by
    /// handleInboundControl → handleSetAdaptiveTriggers → onSetAdaptiveTriggers →
    /// NativeConnectionEvents → DualSenseHID raw-HID OUTPUT report. Payload
    /// layout + the C-source citation live on handleSetAdaptiveTriggers
    /// (EnetControlChannel+Inbound.swift).
    static let setAdaptiveTriggers: UInt16 = 0x5503
    static let hdrInfo: UInt16 = 0x010e              // HDR mode
    /// Input data - packetTypesGen7Enc[IDX_INPUT_DATA] (ControlStream.c:209).
    /// Carries the NV_INPUT_HEADER+body that InputEncoder builds.
    static let inputData: UInt16 = 0x0206
}

enum EnetError: Error, CustomStringConvertible {
    case interrupted
    case socketFailure(String)
    case connectTimeout
    case verifyConnectRejected(String)
    case disconnected
    case startFailed(String)
    case mtuExceeded

    var description: String {
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

struct ByteWriter {
    var bytes = [UInt8]()
    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16BE(_ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    mutating func u32BE(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF)); bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    /// connectID is written RAW (native bytes, no byteswap) so it round-trips.
    mutating func u32Raw(_ value: UInt32) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }
    /// Little-endian u32 - for control-V2 payloads (RFI/LTR fields are LE).
    mutating func u32LE(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF)); bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF)); bytes.append(UInt8((value >> 24) & 0xFF))
    }
    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset: Int
    init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }

    var remaining: Int { bytes.count - offset }
    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }; return bytes[offset]
    }
    mutating func u16BE() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
    mutating func u32BE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
    /// Read `count` bytes, advancing the offset. Returns nil if insufficient.
    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
    /// connectID is read RAW (native bytes) to compare against what we sent.
    mutating func u32Raw() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            for idx in 0..<4 { dst[idx] = bytes[offset + idx] }
        }
        return value
    }
}

// MARK: - SS_FRAME_FEC_STATUS (Video.h:57-70)

/// Per-frame FEC status produced by the video FEC path (RtpVideoQueue's
/// reportFinalFrameFecStatus) as each FEC block completes or is abandoned, and
/// handed to the FEC status sink. Glimmer does NOT transmit it: moonlight only
/// sends FEC status on actual loss, and its Sunshine wire type (0x5502) collides
/// with IDX_SET_RGB_LED - so EnetControlChannel.queueFrameFecStatus is a no-op.
/// The type is retained because the video FEC path constructs and routes it; the
/// fields mirror the C struct (Video.h, "fields are big-endian" on the wire).
struct FrameFecStatus {
    var frameIndex: UInt32
    var highestReceivedSequenceNumber: UInt16
    var nextContiguousSequenceNumber: UInt16
    var missingPacketsBeforeHighestReceived: UInt16
    var totalDataPackets: UInt16
    var totalParityPackets: UInt16
    var receivedDataPackets: UInt16
    var receivedParityPackets: UInt16
    var fecPercentage: UInt8
    var multiFecBlockIndex: UInt8
    var multiFecBlockCount: UInt8
}

// MARK: - Reliable command tracking

struct SentReliable {
    let channelID: UInt8
    let reliableSequenceNumber: UInt16
    /// The fully-assembled command bytes (header + inline payload) for resend.
    let commandBytes: [UInt8]
    /// Last time (ms) this command was (re)sent - drives the retransmit timer.
    var sentAtMs: UInt32
    /// First time (ms) this command was ever sent - drives the age-based give-up
    /// eviction (mirrors enet_protocol_check_timeouts' timeoutMinimum=5000ms,
    /// protocol.c:1371-1379) so a wedged peer is detected instead of resending
    /// forever. Set once at append; never updated on resend.
    var firstSentAtMs: UInt32
    var attempts: Int
}
