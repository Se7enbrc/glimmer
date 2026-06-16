//
//  InputEncoder.swift
//
//  Pure value-type builders for the plaintext NV_INPUT_HEADER + body byte
//  arrays sent over the encrypted control stream (ptype 0x0206) to a Sunshine
//  host. Source: InputStream.c / Input.h.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//
//  ADDITIVE: this file produces ONLY bytes — no sockets, no crypto, no control
//  state. The plaintext [UInt8] each method returns is handed verbatim to
//  EnetControlChannel.sendEncryptedControl(type: 0x0206, ...) which performs the
//  control-V2 AES-GCM seal. On Sunshine 7.1.431 encryptedControlStream is TRUE,
//  so input bodies are PLAINTEXT (InputStream.c's per-input encryptData() is
//  dead code on this path and is deliberately NOT ported).
//
//  Byte-order landmine (verified field-by-field against Input.h #pragma pack(1)):
//    - NV_INPUT_HEADER.size is BIG-endian = sizeof(struct) - 4 (the size field).
//    - NV_INPUT_HEADER.magic is LITTLE-endian.
//    - Mouse deltas / abs x,y,w,h / scroll / hscroll amounts are BIG-endian 16-bit.
//    - Controller stick/trigger/flags and all fixed MC_* constants are LITTLE-endian 16-bit.
//    - netfloat is the raw 4 little-endian bytes of an IEEE-754 float (arm64 is LE).
//
//  Every method asserts the produced length matches the C struct size so a wrong
//  layout fails loudly in debug rather than silently mis-driving the host.

import Foundation

// MARK: - Little-endian-aware byte writer (input bodies mix BE and LE fields)

/// A focused writer for input packet bodies. `ByteWriter` in EnetWire.swift is
/// big-endian-first; input packets need explicit per-field endianness plus a
/// netfloat, so this stays local and self-contained for standalone compilation.
private struct InputWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16BE(_ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
    mutating func u16LE(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }
    mutating func u32BE(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
    mutating func u32LE(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    /// 16-bit two's-complement big-endian (mouse delta/abs/scroll fields).
    mutating func i16BE(_ value: Int16) { u16BE(UInt16(bitPattern: value)) }
    /// 16-bit two's-complement little-endian (controller fields).
    mutating func i16LE(_ value: Int16) { u16LE(UInt16(bitPattern: value)) }

    /// netfloat: raw 4 little-endian bytes of the IEEE-754 float
    /// (floatToNetfloat, InputStream.c:309 — memcpy on little-endian hosts).
    mutating func netfloat(_ value: Float) {
        let bits = value.bitPattern   // host-endian; arm64 is little-endian
        u32LE(bits)
    }
}

// MARK: - Input magics & constants (Input.h / Limelight.h)

private enum InputMagic {
    // Header magics (written LITTLE-endian into NV_INPUT_HEADER.magic).
    static let keyDown: UInt32 = 0x0000_0003          // KEY_DOWN_EVENT_MAGIC
    static let keyUp: UInt32 = 0x0000_0004            // KEY_UP_EVENT_MAGIC
    static let mouseMoveRelGen5: UInt32 = 0x0000_0007 // MOUSE_MOVE_REL_MAGIC_GEN5
    static let mouseMoveAbs: UInt32 = 0x0000_0005     // MOUSE_MOVE_ABS_MAGIC
    // Mouse button magic = (action + 1) for Gen5+ → DOWN 0x08 / UP 0x09.
    static let scrollGen5: UInt32 = 0x0000_000A       // SCROLL_MAGIC_GEN5
    static let ssHscroll: UInt32 = 0x5500_0001        // SS_HSCROLL_MAGIC
    static let multiControllerGen5: UInt32 = 0x0000_000C // MULTI_CONTROLLER_MAGIC_GEN5
    static let ssControllerArrival: UInt32 = 0x5500_0004 // SS_CONTROLLER_ARRIVAL_MAGIC
    static let ssControllerTouch: UInt32 = 0x5500_0005   // SS_CONTROLLER_TOUCH_MAGIC
    static let ssControllerMotion: UInt32 = 0x5500_0006  // SS_CONTROLLER_MOTION_MAGIC
    static let ssControllerBattery: UInt32 = 0x5500_0007 // SS_CONTROLLER_BATTERY_MAGIC
}

private enum MultiControllerConst {
    static let headerB: UInt16 = 0x001A // MC_HEADER_B
    static let midB: UInt16 = 0x0014    // MC_MID_B
    static let tailA: UInt16 = 0x009C   // MC_TAIL_A
    static let tailB: UInt16 = 0x0055   // MC_TAIL_B
}

/// Controller capability bits used by the arrival fix-up (Limelight.h).
private enum ControllerCap {
    static let touchpad: UInt16 = 0x08      // LI_CCAP_TOUCHPAD
    static let dualTouchpad: UInt16 = 0x100 // LI_CCAP_DUAL_TOUCHPAD
}

// MARK: - InputEncoder

/// Stateless builders, one per input message. Each returns the plaintext
/// NV_INPUT_HEADER + typed body ready to be sealed by the control channel.
///
/// Mirrors the C exactly, with GFE-only behaviour omitted: this targets
/// Sunshine (IS_SUNSHINE == true), where keyboard modifier fix-ups are skipped
/// and the Sunshine extension fields are always populated.
enum InputEncoder {

    // MARK: Header helper

    /// Writes NV_INPUT_HEADER: u32 size BIG-endian (= bodyLength, i.e. the rest
    /// of the packet excluding this 4-byte size field) then u32 magic LITTLE-endian.
    /// `bodyLength` = sizeof(struct) - sizeof(NV_INPUT_HEADER.size field's u32... )
    /// — in C terms BE32(sizeof(STRUCT) - sizeof(uint32_t)).
    private static func writeHeader(into w: inout InputWriter, magicLE: UInt32, bodyLength: UInt32) {
        w.u32BE(bodyLength)
        w.u32LE(magicLE)
    }

    // MARK: 1. Keyboard — LiSendKeyboardEvent2 (14 bytes)

    /// NV_KEYBOARD_PACKET: header + char flags + short keyCode LE + char modifiers + short zero2.
    /// `action` = KEY_ACTION_DOWN (0x03) / KEY_ACTION_UP (0x04). Sunshine passes
    /// `flags` and `modifiers` through unchanged (GFE modifier fix-ups skipped).
    static func keyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> [UInt8] {
        var w = InputWriter()
        let magic: UInt32 = (action == 0x04) ? InputMagic.keyUp : InputMagic.keyDown
        writeHeader(into: &w, magicLE: magic, bodyLength: 10) // 14 - 4
        w.u8(UInt8(bitPattern: flags))
        w.i16LE(keyCode)
        w.u8(UInt8(bitPattern: modifiers))
        w.u16LE(0) // short zero2
        assert(w.bytes.count == 14, "NV_KEYBOARD_PACKET must be 14 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 2. Mouse move (relative) — LiSendMouseMoveEvent (12 bytes)

    /// NV_REL_MOUSE_MOVE_PACKET: header + short deltaX BE + short deltaY BE.
    /// Callers must split deltas that exceed Int16 range into multiple packets
    /// (InputStream.c:382-410) — this builder encodes one already-clamped chunk.
    static func mouseMove(dx: Int16, dy: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.mouseMoveRelGen5, bodyLength: 8) // 12 - 4
        w.i16BE(dx)
        w.i16BE(dy)
        assert(w.bytes.count == 12, "NV_REL_MOUSE_MOVE_PACKET must be 12 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 3. Mouse position (absolute) — LiSendMousePositionEvent (18 bytes)

    /// NV_ABS_MOUSE_MOVE_PACKET (Input.h #pragma pack(1), sizeof = 18): header +
    /// short x BE + short y BE + short unused(0) + short width BE (= refW - 1) +
    /// short height BE (= refH - 1). The -1 is the GFE rounding workaround
    /// (InputStream.c:458-459).
    static func mousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.mouseMoveAbs, bodyLength: 14) // 18 - 4 (pack(1))
        w.i16BE(x)
        w.i16BE(y)
        w.u16BE(0) // short unused
        w.i16BE(refW &- 1)
        w.i16BE(refH &- 1)
        assert(w.bytes.count == 18, "NV_ABS_MOUSE_MOVE_PACKET must be 18 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 4. Mouse button — LiSendMouseButtonEvent (9 bytes)

    /// NV_MOUSE_BUTTON_PACKET: header + uint8 button. magic = LE32(action + 1)
    /// for Gen5+ → PRESS(0x07)→0x08 DOWN, RELEASE(0x08)→0x09 UP (InputStream.c:869).
    static func mouseButton(action: Int8, button: UInt8) -> [UInt8] {
        var w = InputWriter()
        let magic = UInt32(UInt8(bitPattern: action)) &+ 1
        writeHeader(into: &w, magicLE: magic, bodyLength: 5) // 9 - 4
        w.u8(button)
        assert(w.bytes.count == 9, "NV_MOUSE_BUTTON_PACKET must be 9 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 5. Scroll (vertical) — LiSendHighResScrollEvent (14 bytes)

    /// NV_SCROLL_PACKET: header + short scrollAmt1 BE + short scrollAmt2 BE (= amt1)
    /// + short zero3(0). Sunshine: NO WHEEL_DELTA batching — raw amount sent.
    static func scroll(_ amount: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.scrollGen5, bodyLength: 10) // 14 - 4
        w.i16BE(amount)
        w.i16BE(amount)
        w.u16BE(0) // short zero3
        assert(w.bytes.count == 14, "NV_SCROLL_PACKET must be 14 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 6. Horizontal scroll — LiSendHighResHScrollEvent (10 bytes)

    /// SS_HSCROLL_PACKET: header + short scrollAmount BE. Sunshine-only on the
    /// wire (the !IS_SUNSHINE → LI_ERR_UNSUPPORTED guard is enforced by the caller).
    static func hscroll(_ amount: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssHscroll, bodyLength: 6) // 10 - 4
        w.i16BE(amount)
        assert(w.bytes.count == 10, "SS_HSCROLL_PACKET must be 10 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 7. Multi-controller — LiSendMultiControllerEvent (30 bytes)

    /// NV_MULTI_CONTROLLER_PACKET (all body fields LITTLE-endian):
    /// header + headerB(0x001A) + controllerNumber + activeGamepadMask + midB(0x0014)
    /// + buttonFlags(buttons & 0xFFFF) + leftTrigger(u8) + rightTrigger(u8)
    /// + leftStickX + leftStickY + rightStickX + rightStickY + tailA(0x009C)
    /// + buttonFlags2(buttons >> 16, Sunshine) + tailB(0x0055).
    ///
    /// Sign-extend guard (InputStream.c:1017): a negative `buttons` (legacy short
    /// sign-extension) collapses to the low 16 bits.
    static func multiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> [UInt8] {
        // Sign-extend guard: clients that pass a sign-extended short set every
        // extended bit; mask to the low 16 bits in that case.
        let safeButtons = buttons < 0 ? (buttons & 0xFFFF) : buttons
        let low16 = Int16(truncatingIfNeeded: safeButtons)
        let high16 = Int16(truncatingIfNeeded: safeButtons >> 16)

        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.multiControllerGen5, bodyLength: 30) // 34 - 4 (pack(1))
        w.u16LE(MultiControllerConst.headerB)
        w.i16LE(num)
        w.i16LE(mask)
        w.u16LE(MultiControllerConst.midB)
        w.i16LE(low16)
        w.u8(analog.leftTrigger)
        w.u8(analog.rightTrigger)
        w.i16LE(analog.leftStickX)
        w.i16LE(analog.leftStickY)
        w.i16LE(analog.rightStickX)
        w.i16LE(analog.rightStickY)
        w.u16LE(MultiControllerConst.tailA)
        w.i16LE(high16) // Sunshine extension (buttonFlags2)
        w.u16LE(MultiControllerConst.tailB)
        assert(w.bytes.count == 34, "NV_MULTI_CONTROLLER_PACKET must be 34 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 8. Controller arrival — LiSendControllerArrivalEvent (16 bytes)

    /// SS_CONTROLLER_ARRIVAL_PACKET: header + u8 controllerNumber + u8 type
    /// + u16 capabilities LE + u32 supportedButtonFlags LE. Caps fix-up: dual
    /// touchpad implies the legacy single-touchpad cap (InputStream.c:1439).
    ///
    /// NOTE: the caller must ALSO emit a fallback multiController(num, mask, 0, …)
    /// after this (InputStream.c:1471) — that dual-send is not the encoder's job.
    static func controllerArrival(num: UInt8, mask: UInt16, type: UInt8,
                                  supportedButtons: UInt32, caps: UInt16) -> [UInt8] {
        var fixedCaps = caps
        if fixedCaps & ControllerCap.dualTouchpad != 0 {
            fixedCaps |= ControllerCap.touchpad
        }
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssControllerArrival, bodyLength: 12) // 16 - 4
        w.u8(num)
        w.u8(type)
        w.u16LE(fixedCaps)
        w.u32LE(supportedButtons)
        assert(w.bytes.count == 16, "SS_CONTROLLER_ARRIVAL_PACKET must be 16 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 9. Controller touch — LiSendControllerTouchEvent2 (24 bytes)

    /// SS_CONTROLLER_TOUCH_PACKET: header + u8 controllerNumber + u8 eventType
    /// + u8 zero(0) + u8 touchpadIndex + u32 pointerId LE + netfloat x + netfloat y
    /// + netfloat pressure. Requires SunshineFeatureFlags & LI_FF_CONTROLLER_TOUCH_EVENTS
    /// (enforced by the caller).
    static func controllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
                                pointerId: UInt32, x: Float, y: Float, pressure: Float) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssControllerTouch, bodyLength: 24) // 28 - 4 (pack(1))
        w.u8(num)
        w.u8(eventType)
        w.u8(0) // zero / reserved
        w.u8(touchpadIndex)
        w.u32LE(pointerId)
        w.netfloat(x)
        w.netfloat(y)
        w.netfloat(pressure)
        assert(w.bytes.count == 28, "SS_CONTROLLER_TOUCH_PACKET must be 28 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 10. Controller motion — LiSendControllerMotionEvent (24 bytes)

    /// SS_CONTROLLER_MOTION_PACKET (Input.h): header + u8 controllerNumber
    /// + u8 motionType + u8 zero[2] (alignment/reserved) + netfloat x +
    /// netfloat y + netfloat z. Units are the caller's contract (Limelight.h):
    /// accel m/s^2 inclusive of gravity, gyro deg/s, axes per SDL's sensor
    /// convention. Requires SunshineFeatureFlags & LI_FF_CONTROLLER_TOUCH_EVENTS
    /// — motion shares touch's feature flag (LiSendControllerMotionEvent) —
    /// enforced by the caller.
    static func controllerMotion(num: UInt8, motionType: UInt8,
                                 x: Float, y: Float, z: Float) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssControllerMotion, bodyLength: 20) // 24 - 4 (pack(1))
        w.u8(num)
        w.u8(motionType)
        w.u8(0)
        w.u8(0) // zero[2]
        w.netfloat(x)
        w.netfloat(y)
        w.netfloat(z)
        assert(w.bytes.count == 24, "SS_CONTROLLER_MOTION_PACKET must be 24 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 11. Controller battery — LiSendControllerBatteryEvent (12 bytes)

    /// SS_CONTROLLER_BATTERY_PACKET (Input.h): header + u8 controllerNumber
    /// + u8 batteryState + u8 batteryPercentage + u8 zero[1] (alignment/
    /// reserved). `state` is LI_BATTERY_STATE_*; `percentage` is 0...100 or
    /// LI_BATTERY_PERCENTAGE_UNKNOWN. Unlike touch/motion there is NO
    /// feature-flag requirement: LiSendControllerBatteryEvent (InputStream.c)
    /// checks only `initialized` + IS_SUNSHINE, both structural on this wire.
    static func controllerBattery(num: UInt8, state: UInt8, percentage: UInt8) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssControllerBattery, bodyLength: 8) // 12 - 4
        w.u8(num)
        w.u8(state)
        w.u8(percentage)
        w.u8(0) // zero[1]
        assert(w.bytes.count == 12, "SS_CONTROLLER_BATTERY_PACKET must be 12 bytes, got \(w.bytes.count)")
        return w.bytes
    }
}
