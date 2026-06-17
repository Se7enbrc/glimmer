//
//  InputEncoderTests.swift
//
//  Known-answer byte vectors for the InputEncoder packet builders. Each builder
//  emits an NV_INPUT_HEADER (u32 size BIG-endian = body length, then u32 magic
//  LITTLE-endian) followed by a typed body whose fields have explicit per-field
//  endianness (mouse/scroll fields BE; controller fields LE). The vectors below
//  pin the EXACT bytes, total length, and field order against Input.h so a
//  layout regression fails loudly instead of silently mis-driving the host.
//

import Testing
@testable import Glimmer

struct InputEncoderTests {

    // MARK: helpers for building expected headers

    /// NV_INPUT_HEADER: size BE (= bodyLength), then magic LE.
    private func header(bodyLength: UInt32, magicLE: UInt32) -> [UInt8] {
        let sizeBE: [UInt8] = [
            UInt8((bodyLength >> 24) & 0xFF), UInt8((bodyLength >> 16) & 0xFF),
            UInt8((bodyLength >> 8) & 0xFF), UInt8(bodyLength & 0xFF),
        ]
        let magicLEbytes: [UInt8] = [
            UInt8(magicLE & 0xFF), UInt8((magicLE >> 8) & 0xFF),
            UInt8((magicLE >> 16) & 0xFF), UInt8((magicLE >> 24) & 0xFF),
        ]
        return sizeBE + magicLEbytes
    }

    // MARK: 1. Keyboard (14 bytes)

    @Test func keyboardDownKnownAnswer() {
        // keyCode 0x1234, action DOWN(0x03), modifiers 0x02, flags 0x01.
        let out = InputEncoder.keyboard(keyCode: 0x1234, action: 0x03, modifiers: 0x02, flags: 0x01)
        var expected = header(bodyLength: 10, magicLE: 0x0000_0003) // KEY_DOWN
        expected += [0x01]        // flags
        expected += [0x34, 0x12]  // keyCode LE
        expected += [0x02]        // modifiers
        expected += [0x00, 0x00]  // zero2 LE
        #expect(out == expected)
        #expect(out.count == 14)
    }

    @Test func keyboardUpUsesKeyUpMagic() {
        let out = InputEncoder.keyboard(keyCode: 0x0041, action: 0x04, modifiers: 0, flags: 0)
        var expected = header(bodyLength: 10, magicLE: 0x0000_0004) // KEY_UP
        expected += [0x00]        // flags
        expected += [0x41, 0x00]  // keyCode LE
        expected += [0x00]        // modifiers
        expected += [0x00, 0x00]  // zero2 LE
        #expect(out == expected)
    }

    @Test func keyboardNegativeKeyCodeLE() {
        // Int16(-1) two's complement -> 0xFFFF, little-endian = FF FF.
        let out = InputEncoder.keyboard(keyCode: -1, action: 0x03, modifiers: 0, flags: 0)
        // bytes 5..6 are the keyCode field (after 8-byte header + 1 flags byte).
        #expect(Array(out[9..<11]) == [0xFF, 0xFF])
    }

    // MARK: 2. Mouse move relative (12 bytes)

    @Test func mouseMoveKnownAnswer() {
        let out = InputEncoder.mouseMove(dx: 0x0102, dy: -2)
        var expected = header(bodyLength: 8, magicLE: 0x0000_0007) // MOUSE_MOVE_REL_GEN5
        expected += [0x01, 0x02]  // dx BE
        expected += [0xFF, 0xFE]  // dy BE (Int16(-2) = 0xFFFE)
        #expect(out == expected)
        #expect(out.count == 12)
    }

    // MARK: 3. Mouse position absolute (18 bytes)

    @Test func mousePositionKnownAnswer() {
        // x=100, y=200, refW=1920, refH=1080. width/height are sent as refW-1/refH-1.
        let out = InputEncoder.mousePosition(x: 100, y: 200, refW: 1920, refH: 1080)
        var expected = header(bodyLength: 14, magicLE: 0x0000_0005) // MOUSE_MOVE_ABS
        expected += [0x00, 0x64]  // x = 100 BE
        expected += [0x00, 0xC8]  // y = 200 BE
        expected += [0x00, 0x00]  // unused BE
        expected += [0x07, 0x7F]  // 1919 BE
        expected += [0x04, 0x37]  // 1079 BE
        #expect(out == expected)
        #expect(out.count == 18)
    }

    // MARK: 4. Mouse button (9 bytes)

    @Test func mouseButtonPressKnownAnswer() {
        // action PRESS(0x07) -> magic = action+1 = 0x08; button 0x01 (left).
        let out = InputEncoder.mouseButton(action: 0x07, button: 0x01)
        var expected = header(bodyLength: 5, magicLE: 0x0000_0008)
        expected += [0x01]
        #expect(out == expected)
        #expect(out.count == 9)
    }

    @Test func mouseButtonReleaseMagic() {
        // action RELEASE(0x08) -> magic = 0x09.
        let out = InputEncoder.mouseButton(action: 0x08, button: 0x03)
        var expected = header(bodyLength: 5, magicLE: 0x0000_0009)
        expected += [0x03]
        #expect(out == expected)
    }

    // MARK: 5. Vertical scroll (14 bytes)

    @Test func scrollKnownAnswer() {
        let out = InputEncoder.scroll(120)
        var expected = header(bodyLength: 10, magicLE: 0x0000_000A) // SCROLL_GEN5
        expected += [0x00, 0x78]  // scrollAmt1 = 120 BE
        expected += [0x00, 0x78]  // scrollAmt2 = 120 BE (== amt1)
        expected += [0x00, 0x00]  // zero3 BE
        #expect(out == expected)
        #expect(out.count == 14)
    }

    @Test func scrollNegativeBE() {
        let out = InputEncoder.scroll(-120)
        // -120 as Int16 = 0xFF88, big-endian = FF 88, in both amount fields.
        #expect(Array(out[8..<10]) == [0xFF, 0x88])
        #expect(Array(out[10..<12]) == [0xFF, 0x88])
    }

    // MARK: 6. Horizontal scroll (10 bytes)

    @Test func hscrollKnownAnswer() {
        let out = InputEncoder.hscroll(-1)
        var expected = header(bodyLength: 6, magicLE: 0x5500_0001) // SS_HSCROLL
        expected += [0xFF, 0xFF]  // amount BE (Int16(-1))
        #expect(out == expected)
        #expect(out.count == 10)
    }

    // MARK: 7. Multi-controller (34 bytes) - all body fields LITTLE-endian

    @Test func multiControllerKnownAnswer() {
        let analog = GamepadAnalog(
            leftTrigger: 0x10, rightTrigger: 0x20,
            leftStickX: 0x0102, leftStickY: 0x0304,
            rightStickX: 0x0506, rightStickY: 0x0708)
        // buttons low16 = 0x1234, high16 = 0x5678.
        let out = InputEncoder.multiController(num: 1, mask: 0x0001,
                                               buttons: 0x5678_1234, analog: analog)
        var expected = header(bodyLength: 30, magicLE: 0x0000_000C) // MULTI_CONTROLLER_GEN5
        expected += [0x1A, 0x00]  // headerB 0x001A LE
        expected += [0x01, 0x00]  // num LE
        expected += [0x01, 0x00]  // mask LE
        expected += [0x14, 0x00]  // midB 0x0014 LE
        expected += [0x34, 0x12]  // buttonFlags low16 LE
        expected += [0x10]        // leftTrigger
        expected += [0x20]        // rightTrigger
        expected += [0x02, 0x01]  // leftStickX LE
        expected += [0x04, 0x03]  // leftStickY LE
        expected += [0x06, 0x05]  // rightStickX LE
        expected += [0x08, 0x07]  // rightStickY LE
        expected += [0x9C, 0x00]  // tailA 0x009C LE
        expected += [0x78, 0x56]  // buttonFlags2 high16 LE
        expected += [0x55, 0x00]  // tailB 0x0055 LE
        #expect(out == expected)
        #expect(out.count == 34)
    }

    // MARK: 8. Controller arrival (16 bytes)

    @Test func controllerArrivalKnownAnswer() {
        let out = InputEncoder.controllerArrival(num: 2, mask: 0x0003, type: 1,
                                                 supportedButtons: 0x1122_3344, caps: 0x0008)
        var expected = header(bodyLength: 12, magicLE: 0x5500_0004) // SS_CONTROLLER_ARRIVAL
        expected += [0x02]              // num
        expected += [0x01]              // type
        expected += [0x08, 0x00]        // caps 0x0008 LE
        expected += [0x44, 0x33, 0x22, 0x11] // supportedButtons LE
        #expect(out == expected)
        #expect(out.count == 16)
    }

    @Test func controllerArrivalDualTouchpadImpliesTouchpad() {
        // caps with DUAL_TOUCHPAD(0x100) set but not TOUCHPAD(0x08) -> fix-up ORs in 0x08.
        let out = InputEncoder.controllerArrival(num: 0, mask: 0, type: 0,
                                                 supportedButtons: 0, caps: 0x0100)
        // Layout: 8-byte header + u8 num + u8 type + u16 caps LE. Caps is bytes
        // 10..11; 0x0108 little-endian -> 08 01.
        #expect(Array(out[10..<12]) == [0x08, 0x01])
    }

    // MARK: 11. Controller battery (12 bytes)

    @Test func controllerBatteryKnownAnswer() {
        let out = InputEncoder.controllerBattery(num: 3, state: 2, percentage: 75)
        var expected = header(bodyLength: 8, magicLE: 0x5500_0007) // SS_CONTROLLER_BATTERY
        expected += [0x03]  // num
        expected += [0x02]  // state
        expected += [0x4B]  // percentage = 75
        expected += [0x00]  // zero[1]
        #expect(out == expected)
        #expect(out.count == 12)
    }

    // MARK: header invariant: size field == body length == total - 4

    @Test func headerSizeFieldEqualsBodyLength() {
        let packets: [[UInt8]] = [
            InputEncoder.keyboard(keyCode: 1, action: 0x03, modifiers: 0, flags: 0),
            InputEncoder.mouseMove(dx: 1, dy: 1),
            InputEncoder.mousePosition(x: 1, y: 1, refW: 2, refH: 2),
            InputEncoder.mouseButton(action: 0x07, button: 1),
            InputEncoder.scroll(1),
            InputEncoder.hscroll(1),
            InputEncoder.controllerBattery(num: 0, state: 0, percentage: 0),
        ]
        for pkt in packets {
            let sizeField = (UInt32(pkt[0]) << 24) | (UInt32(pkt[1]) << 16)
                | (UInt32(pkt[2]) << 8) | UInt32(pkt[3])
            #expect(Int(sizeField) == pkt.count - 4)
        }
    }
}
