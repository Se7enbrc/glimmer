// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// Plaintext NV_INPUT_HEADER + body (InputStream.c / Input.h); provenance is in CREDITS.md.
// EnetControlChannel seals these as control-V2 type 0x0206; Sunshine 7.1.431 needs no per-input encryption.
// Header size and mouse fields are BE; magic, controller fields and netfloat's IEEE-754 bits are LE.

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
    /// (floatToNetfloat, InputStream.c:309 - memcpy on little-endian hosts).
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
    static let utf8Text: UInt32 = 0x0000_0017         // UTF8_TEXT_EVENT_MAGIC
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

/// Stateless builders, one per input message, each returning the plaintext NV_INPUT_HEADER + body the control
/// channel seals. They mirror the C with IS_SUNSHINE true, since a GameStream PC is refused before a stream
/// starts: GameStream's keyboard modifier fix-ups are skipped and the Sunshine extension fields always filled.
package enum InputEncoder {

    // MARK: Header helper

    /// Writes NV_INPUT_HEADER: u32 size BIG-endian (= bodyLength, i.e. the rest of the packet excluding this 4-byte
    /// size field) then u32 magic LITTLE-endian. `bodyLength` = sizeof(struct) - sizeof(NV_INPUT_HEADER.size field's
    /// u32... ) - in C terms BE32(sizeof(STRUCT) - sizeof(uint32_t)).
    private static func writeHeader(into w: inout InputWriter, magicLE: UInt32, bodyLength: UInt32) {
        w.u32BE(bodyLength)
        w.u32LE(magicLE)
    }

    // MARK: 1. Keyboard - LiSendKeyboardEvent2 (14 bytes)

    /// NV_KEYBOARD_PACKET: header + char flags + short keyCode LE + char modifiers + short zero2.
    /// `action` = KEY_ACTION_DOWN (0x03) / KEY_ACTION_UP (0x04). Sunshine passes
    /// `flags` and `modifiers` through unchanged (GFE modifier fix-ups skipped).
    package static func keyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> [UInt8] {
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

    // MARK: 2. Mouse move (relative) - LiSendMouseMoveEvent (12 bytes)

    /// NV_REL_MOUSE_MOVE_PACKET: header + short deltaX BE + short deltaY BE.
    /// Callers must split deltas that exceed Int16 range into multiple packets
    /// (InputStream.c:382-410) - this builder encodes one already-clamped chunk.
    package static func mouseMove(dx: Int16, dy: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.mouseMoveRelGen5, bodyLength: 8) // 12 - 4
        w.i16BE(dx)
        w.i16BE(dy)
        assert(w.bytes.count == 12, "NV_REL_MOUSE_MOVE_PACKET must be 12 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 3. Mouse position (absolute) - LiSendMousePositionEvent (18 bytes)

    /// NV_ABS_MOUSE_MOVE_PACKET (Input.h #pragma pack(1), sizeof = 18): header + short x BE + short y BE + short
    /// unused(0) + short width BE (= refW - 1) + short height BE (= refH - 1). The -1 is the GFE rounding workaround
    /// (InputStream.c:458-459).
    package static func mousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> [UInt8] {
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

    // MARK: 4. Mouse button - LiSendMouseButtonEvent (9 bytes)

    /// NV_MOUSE_BUTTON_PACKET: header + uint8 button. magic = LE32(action + 1)
    /// for Gen5+ → PRESS(0x07)→0x08 DOWN, RELEASE(0x08)→0x09 UP (InputStream.c:869).
    package static func mouseButton(action: Int8, button: UInt8) -> [UInt8] {
        var w = InputWriter()
        let magic = UInt32(UInt8(bitPattern: action)) &+ 1
        writeHeader(into: &w, magicLE: magic, bodyLength: 5) // 9 - 4
        w.u8(button)
        assert(w.bytes.count == 9, "NV_MOUSE_BUTTON_PACKET must be 9 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 5. Scroll (vertical) - LiSendHighResScrollEvent (14 bytes)

    /// NV_SCROLL_PACKET: header + short scrollAmt1 BE + short scrollAmt2 BE (= amt1)
    /// + short zero3(0). Sunshine: NO WHEEL_DELTA batching - raw amount sent.
    package static func scroll(_ amount: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.scrollGen5, bodyLength: 10) // 14 - 4
        w.i16BE(amount)
        w.i16BE(amount)
        w.u16BE(0) // short zero3
        assert(w.bytes.count == 14, "NV_SCROLL_PACKET must be 14 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 6. Horizontal scroll - LiSendHighResHScrollEvent (10 bytes)

    /// SS_HSCROLL_PACKET: header + short scrollAmount BE. Sunshine-only on the wire, which is the only
    /// kind of PC a stream reaches, so the C's !IS_SUNSHINE → LI_ERR_UNSUPPORTED guard has no case here.
    package static func hscroll(_ amount: Int16) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssHscroll, bodyLength: 6) // 10 - 4
        w.i16BE(amount)
        assert(w.bytes.count == 10, "SS_HSCROLL_PACKET must be 10 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 7. Multi-controller - LiSendMultiControllerEvent (30 bytes)

    /// Input.h's NV_MULTI_CONTROLLER_PACKET body is LE, including MC_* constants and Sunshine's upper flags.
    /// Negative legacy sign-extended `buttons` collapse to the low 16 bits (InputStream.c:1017).
    package static func multiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> [UInt8] {
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

    // MARK: 8. Controller arrival - LiSendControllerArrivalEvent (16 bytes)

    /// Arrival uses LE capabilities/buttons; dual touchpad implies the legacy single cap (InputStream.c:1439).
    /// The caller must also send fallback multiController(num, mask, 0, ...) afterward (InputStream.c:1471).
    package static func controllerArrival(num: UInt8, mask: UInt16, type: UInt8,
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

    // MARK: 9. Controller touch - LiSendControllerTouchEvent2 (24 bytes)

    /// SS_CONTROLLER_TOUCH_PACKET: header + u8 controllerNumber + u8 eventType + u8 zero(0) + u8 touchpadIndex + u32
    /// pointerId LE + netfloat x + netfloat y + netfloat pressure. Requires SunshineFeatureFlags &
    /// LI_FF_CONTROLLER_TOUCH_EVENTS (enforced by the caller).
    package static func controllerTouch(num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
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

    // MARK: 10. Controller motion - LiSendControllerMotionEvent (24 bytes)

    /// Input.h motion uses reserved zero bytes and netfloat axes: accel m/s² including gravity, gyro deg/s,
    /// SDL sensor axes. The caller gates on LI_FF_CONTROLLER_TOUCH_EVENTS, shared with touch (Limelight.h).
    package static func controllerMotion(num: UInt8, motionType: UInt8,
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

    // MARK: 11. Controller battery - LiSendControllerBatteryEvent (12 bytes)

    /// Input.h battery uses LI_BATTERY_STATE_* and percentage 0...100 or LI_BATTERY_PERCENTAGE_UNKNOWN.
    /// No touch/motion feature flag: LiSendControllerBatteryEvent checks initialized + IS_SUNSHINE only.
    package static func controllerBattery(num: UInt8, state: UInt8, percentage: UInt8) -> [UInt8] {
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.ssControllerBattery, bodyLength: 8) // 12 - 4
        w.u8(num)
        w.u8(state)
        w.u8(percentage)
        w.u8(0) // zero[1]
        assert(w.bytes.count == 12, "SS_CONTROLLER_BATTERY_PACKET must be 12 bytes, got \(w.bytes.count)")
        return w.bytes
    }

    // MARK: 12. UTF-8 text - LiSendUtf8TextEvent (8 + up to 32 bytes)

    /// UTF8_TEXT_EVENT_MAX_COUNT: the most text bytes one packet may carry.
    package static let utf8TextMaxBytes = 32

    /// NV_UNICODE_PACKET: header (size = magic + text length) + the UTF-8
    /// bytes, unterminated. The host decodes each packet on its own, so the
    /// text must be whole code points.
    package static func utf8Text(_ text: [UInt8]) -> [UInt8] {
        assert(text.count <= utf8TextMaxBytes, "NV_UNICODE_PACKET carries at most 32 text bytes, got \(text.count)")
        var w = InputWriter()
        writeHeader(into: &w, magicLE: InputMagic.utf8Text, bodyLength: UInt32(4 + text.count))
        w.bytes += text
        return w.bytes
    }

    /// The text as packets of whole code points, as many as fit in each.
    /// moonlight sends one code point a packet; packing sends fewer.
    package static func utf8TextPackets(_ text: String) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var chunk: [UInt8] = []
        for scalar in text.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if chunk.count + bytes.count > utf8TextMaxBytes {
                packets.append(utf8Text(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
            chunk += bytes
        }
        if !chunk.isEmpty { packets.append(utf8Text(chunk)) }
        return packets
    }
}
