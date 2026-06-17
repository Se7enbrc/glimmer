//
//  EnetWireTests.swift
//
//  Round-trip + known-answer coverage for the ByteWriter/ByteReader primitives
//  in EnetWire.swift. These are the byte-exact ENet wire helpers; a regression
//  here silently corrupts every control packet, so the tests pin both the
//  produced bytes and the read-back values, plus the EOF behaviour.
//

import Testing
@testable import Glimmer

struct EnetWireTests {

    // MARK: - Writer known-answer (endianness is the whole point)

    @Test func writerU16BEKnownAnswer() {
        var w = ByteWriter()
        w.u16BE(0x1234)
        #expect(w.bytes == [0x12, 0x34])
    }

    @Test func writerU32BEKnownAnswer() {
        var w = ByteWriter()
        w.u32BE(0x1122_3344)
        #expect(w.bytes == [0x11, 0x22, 0x33, 0x44])
    }

    @Test func writerU32LEKnownAnswer() {
        var w = ByteWriter()
        w.u32LE(0x1122_3344)
        #expect(w.bytes == [0x44, 0x33, 0x22, 0x11])
    }

    @Test func writerU32RawIsLittleEndianOnArm() {
        // u32Raw writes native bytes (arm64/x86_64 are little-endian) so the
        // connectID round-trips byte-identically against the VERIFY_CONNECT echo.
        var w = ByteWriter()
        w.u32Raw(0x1122_3344)
        #expect(w.bytes == [0x44, 0x33, 0x22, 0x11])
    }

    @Test func writerU8AndAppend() {
        var w = ByteWriter()
        w.u8(0xAB)
        w.append([0x01, 0x02, 0x03])
        #expect(w.bytes == [0xAB, 0x01, 0x02, 0x03])
    }

    // MARK: - Reader round-trip: write then read back byte-identical

    @Test func roundTripU16BE() {
        for value: UInt16 in [0, 1, 0x1234, 0x00FF, 0xFF00, 0xFFFF] {
            var w = ByteWriter()
            w.u16BE(value)
            var r = ByteReader(w.bytes)
            #expect(r.u16BE() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripU32BE() {
        for value: UInt32 in [0, 1, 0x1122_3344, 0x0000_00FF, 0xFF00_0000, 0xFFFF_FFFF] {
            var w = ByteWriter()
            w.u32BE(value)
            var r = ByteReader(w.bytes)
            #expect(r.u32BE() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripU32Raw() {
        for value: UInt32 in [0, 1, 0x1122_3344, 0xDEAD_BEEF, 0xFFFF_FFFF] {
            var w = ByteWriter()
            w.u32Raw(value)
            var r = ByteReader(w.bytes)
            #expect(r.u32Raw() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripMixedSequence() {
        var w = ByteWriter()
        w.u8(0x7F)
        w.u16BE(0xBEEF)
        w.u32BE(0x0102_0304)
        w.u32Raw(0xCAFE_F00D)
        var r = ByteReader(w.bytes)
        #expect(r.u8() == 0x7F)
        #expect(r.u16BE() == 0xBEEF)
        #expect(r.u32BE() == 0x0102_0304)
        #expect(r.u32Raw() == 0xCAFE_F00D)
        #expect(r.remaining == 0)
    }

    @Test func readerTakeReturnsExactSlice() {
        var r = ByteReader([0x10, 0x20, 0x30, 0x40, 0x50], offset: 1)
        #expect(r.take(3) == [0x20, 0x30, 0x40])
        #expect(r.remaining == 1)
        #expect(r.u8() == 0x50)
    }

    // MARK: - Reads past EOF return nil

    @Test func u8PastEOFReturnsNil() {
        var r = ByteReader([0x01])
        #expect(r.u8() == 0x01)
        #expect(r.u8() == nil)
    }

    @Test func u16BEShortBufferReturnsNil() {
        var r = ByteReader([0x01]) // only 1 byte, need 2
        #expect(r.u16BE() == nil)
        #expect(r.remaining == 1) // offset not advanced on failure
    }

    @Test func u32BEShortBufferReturnsNil() {
        var r = ByteReader([0x01, 0x02, 0x03]) // only 3 bytes, need 4
        #expect(r.u32BE() == nil)
        #expect(r.remaining == 3)
    }

    @Test func u32RawShortBufferReturnsNil() {
        var r = ByteReader([0x01, 0x02]) // only 2 bytes, need 4
        #expect(r.u32Raw() == nil)
        #expect(r.remaining == 2)
    }

    @Test func takeBeyondRemainingReturnsNil() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(3) == nil)
        #expect(r.remaining == 2)
    }

    @Test func takeNegativeCountReturnsNil() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(-1) == nil)
    }

    @Test func takeZeroReturnsEmptyArray() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(0) == [])
        #expect(r.remaining == 2)
    }

    @Test func emptyReaderReadsReturnNil() {
        var r = ByteReader([])
        #expect(r.remaining == 0)
        #expect(r.u8() == nil)
        #expect(r.u16BE() == nil)
        #expect(r.u32BE() == nil)
        #expect(r.u32Raw() == nil)
    }
}
