// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  DualSenseOutputReportTests.swift
//
//  Exact DualSense OUTPUT report bytes per transport. The CRC vectors come from zlib's crc32.
//

import Testing
@testable import Glimmer

struct DualSenseOutputReportTests {

    private static let rightBlock: [UInt8] = [0x21, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    private static let leftBlock: [UInt8] = [0x26, 0x0A, 0x0B, 0, 0, 0, 0, 0, 0, 0, 0]

    private static var loaded: DualSenseOutputState {
        var state = DualSenseOutputState()
        state.rumbleLeft = 0x40
        state.rumbleRight = 0x80
        state.lightR = 0x11; state.lightG = 0x22; state.lightB = 0x33
        state.lightSet = true
        state.rightTrigger = DualSenseOutputState.triggerBlock(mode: 0x21, params: Array(1...10))
        state.leftTrigger = DualSenseOutputState.triggerBlock(mode: 0x26, params: [0x0A, 0x0B])
        return state
    }

    private static var loadedEffects: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 47)
        bytes[0] = 0x03; bytes[1] = 0x04; bytes[2] = 0x80; bytes[3] = 0x40
        bytes.replaceSubrange(10...20, with: rightBlock)
        bytes.replaceSubrange(21...31, with: leftBlock)
        bytes.replaceSubrange(44...46, with: [0x11, 0x22, 0x33])
        return bytes
    }

    @Test func usbCarriesRumbleTriggersAndLightAtTheirOffsets() {
        let report = Self.loaded.report(bluetooth: false)
        #expect(report.reportID == 0x02)
        #expect(report.data == Self.loadedEffects)
    }

    @Test func bluetoothWrapsTheEffectsAndAppendsTheCRCLittleEndian() {
        let report = Self.loaded.report(bluetooth: true)
        var expected = [UInt8](repeating: 0, count: 77)
        expected[0] = 0x02
        expected.replaceSubrange(1...47, with: Self.loadedEffects)
        expected.replaceSubrange(73...76, with: [0x8F, 0xA6, 0xBF, 0xAA])
        #expect(report.reportID == 0x31)
        #expect(report.data == expected)
    }

    /// Light unset leaves the light flag and colour zero: the neutral park report.
    @Test func neutralStateParksMotorsTriggersAndLight() {
        let usb = DualSenseOutputState().report(bluetooth: false)
        #expect(usb.data == [0x03] + [UInt8](repeating: 0, count: 46))
        let bluetooth = DualSenseOutputState().report(bluetooth: true)
        #expect(Array(bluetooth.data[0...1]) == [0x02, 0x03])
        #expect(bluetooth.data[2..<73].allSatisfy { $0 == 0 })
        #expect(Array(bluetooth.data[73...]) == [0xDB, 0x53, 0x8B, 0xDE])
        #expect(DualSenseOutputState.bluetoothCRC(reportID: 0x31, data: bluetooth.data[0..<73]) == 0xDE8B_53DB)
    }

    @Test func triggerBlocksClampParamsAndRefuseDebugModes() {
        #expect(DualSenseOutputState.triggerBlock(mode: 0x21, params: Array(1...12)) == Self.rightBlock)
        #expect(DualSenseOutputState.triggerBlock(mode: 0x26, params: [0x0A, 0x0B]) == Self.leftBlock)
        for mode: UInt8 in [0xFC, 0xFD, 0xFE, 0xFF] {
            #expect(DualSenseOutputState.triggerBlock(mode: mode, params: [1, 2]) == [UInt8](repeating: 0, count: 11))
        }
        #expect(DualSenseOutputState.triggerBlock(mode: 0xFB, params: [])[0] == 0xFB)
    }
}
