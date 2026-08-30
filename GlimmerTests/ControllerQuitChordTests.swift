//
//  ControllerQuitChordTests.swift
//
//  Hardware-free coverage for the two pure halves of the controller quit
//  chord: the DualSense raw-report decode (DualSenseHID.decodeInputReport)
//  fed synthetic USB 0x01 / BT 0x31 / BT-simple / foreign-ID byte arrays, and
//  the chord predicate (InputForwarder.chordSatisfied) over held-button sets.
//  The measured macOS layout these pin: report ID at bytes[0], BT 0x31 carries
//  one tag byte before LX, buttons[1] at LX+8 with L1 0x01 / R1 0x02 /
//  Create 0x10 / Options 0x20, buttons[2] at LX+9 with PS 0x01 / Mute 0x04,
//  battery status at LX+52.
//

import Testing
@testable import Glimmer

struct ControllerQuitChordTests {

    // MARK: - Report builders

    private func decode(_ bytes: [UInt8], reportID: UInt32) -> DualSenseDecodedReport? {
        bytes.withUnsafeBufferPointer { DualSenseHID.decodeInputReport(reportID: reportID, bytes: $0) }
    }

    /// 78-byte Bluetooth full report: [0x31][tag][LX LY RX RY L2 R2 seq b0 b1 b2]...
    private func btFull(b1: UInt8, b2: UInt8 = 0, status: UInt8 = 0x0C) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 78)
        r[0] = 0x31; r[1] = 0x01
        r[2] = 0x80; r[3] = 0x80; r[4] = 0x80; r[5] = 0x80   // sticks centred
        r[9] = 0x08                                          // hat neutral
        r[10] = b1; r[11] = b2
        r[2 + 52] = status
        return r
    }

    /// 64-byte USB full report: [0x01][LX LY RX RY L2 R2 seq b0 b1 b2]...
    private func usbFull(b1: UInt8, b2: UInt8 = 0, status: UInt8 = 0x0C) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x01
        r[1] = 0x80; r[2] = 0x80; r[3] = 0x80; r[4] = 0x80
        r[8] = 0x08
        r[9] = b1; r[10] = b2
        r[1 + 52] = status
        return r
    }

    // MARK: - Decode

    @Test func btFullReportDecodesChordBits() {
        let d = decode(btFull(b1: 0x33), reportID: 0x31)   // L1|R1|Create|Options
        #expect(d?.buttons == DualSenseExtraButtons(options: true, create: true, ps: false, mute: false, l1: true, r1: true))
        #expect(d?.battery == nil)   // 0x0C sentinel = not reporting
    }

    @Test func usbFullReportUsesSameMasksOneByteEarlier() {
        let d = decode(usbFull(b1: 0x30, b2: 0x05), reportID: 0x01)
        #expect(d?.buttons == DualSenseExtraButtons(options: true, create: true, ps: true, mute: true, l1: false, r1: false))
    }

    @Test func shouldersOnlyAreNotACentrePress() {
        let d = decode(btFull(b1: 0x03), reportID: 0x31)
        #expect(d?.buttons == DualSenseExtraButtons(l1: true, r1: true))
    }

    @Test func btSimpleReportIsIgnored() {
        // 10-byte BT report before enhanced mode: [0x01] LX LY RX RY b0 b1 b2 L2 R2.
        // Its buttons sit at a different offset; the length guard must drop it
        // rather than read past the end or misplace the bits.
        let simple: [UInt8] = [0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x33, 0x00, 0x00, 0x00]
        #expect(decode(simple, reportID: 0x01) == nil)
    }

    @Test func foreignReportIDsAreIgnored() {
        // Any non-state report ID must decode to nothing - reading its bytes as
        // button state would flip the decoded bits and cancel a live dwell.
        for id: UInt8 in [0x05, 0x09, 0x20, 0x22, 0xF2] {
            var r = btFull(b1: 0x33)
            r[0] = id
            #expect(decode(r, reportID: UInt32(id)) == nil, "report id 0x\(String(id, radix: 16))")
        }
        // Stack that strips the ID and hands a first payload byte that is not
        // a known ID: `reportID` is the only ID, and 0x05 is not a state report.
        var stripped = Array(btFull(b1: 0x33).dropFirst())
        stripped[0] = 0x00
        #expect(decode(stripped, reportID: 0x05) == nil)
    }

    @Test func emptyAndShortBuffersAreSafe() {
        #expect(decode([], reportID: 0x31) == nil)
        #expect(decode([0x31, 0x01, 0x80], reportID: 0x31) == nil)
        #expect(decode(Array(btFull(b1: 0x33).prefix(11)), reportID: 0x31) == nil)  // one byte short of b2
        #expect(decode(Array(btFull(b1: 0x33).prefix(12)), reportID: 0x31)?.buttons.l1 == true)
    }

    @Test func batteryDecodesFromStatusByte() {
        #expect(decode(btFull(b1: 0, status: 0x09), reportID: 0x31)?.battery
            == DualSenseBattery(percent: 95, charging: false))
        #expect(decode(btFull(b1: 0, status: 0x15), reportID: 0x31)?.battery
            == DualSenseBattery(percent: 55, charging: true))
        #expect(decode(btFull(b1: 0, status: 0x2A), reportID: 0x31)?.battery
            == DualSenseBattery(percent: 100, charging: true))
        #expect(decode(usbFull(b1: 0, status: 0x0A), reportID: 0x01)?.battery
            == DualSenseBattery(percent: 100, charging: false))
    }

    // MARK: - Chord predicate

    @Test func moonlightDefaultNeedsAllFour() {
        let full: Set<ControllerButton> = [.options, .create, .l1, .r1]
        #expect(InputForwarder.chordSatisfied(.startSelectL1R1, custom: [], held: full))
        #expect(InputForwarder.chordSatisfied(.startSelectL1R1, custom: [], held: full.union([.faceDown, .touchpad])))
        for missing in full {
            #expect(!InputForwarder.chordSatisfied(.startSelectL1R1, custom: [], held: full.subtracting([missing])),
                    "missing \(missing)")
        }
    }

    @Test func presetsMatchTheirButtonSets() {
        #expect(InputForwarder.chordSatisfied(.l1r1, custom: [], held: [.l1, .r1]))
        #expect(!InputForwarder.chordSatisfied(.l1r1, custom: [], held: [.l1]))
        #expect(InputForwarder.chordSatisfied(.l1r1l2r2, custom: [], held: [.l1, .r1, .l2, .r2]))
        #expect(!InputForwarder.chordSatisfied(.l1r1l2r2, custom: [], held: [.l1, .r1, .l2]))
        #expect(InputForwarder.chordSatisfied(.l3r3, custom: [], held: [.l3, .r3]))
        #expect(!InputForwarder.chordSatisfied(.l3r3, custom: [], held: [.l3, .r1]))
    }

    @Test func noneAndEmptyCustomNeverMatch() {
        let everything = Set(ControllerButton.allCases)
        #expect(!InputForwarder.chordSatisfied(.none, custom: [], held: everything))
        #expect(!InputForwarder.chordSatisfied(.custom, custom: [], held: everything))
        #expect(InputForwarder.chordSatisfied(.custom, custom: [.mute, .touchpad], held: [.mute, .touchpad, .l1]))
        #expect(!InputForwarder.chordSatisfied(.custom, custom: [.mute, .touchpad], held: [.mute]))
    }
}
