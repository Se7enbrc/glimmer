//
//  StreamProtocolConstantsTests.swift
//
//  Pin a representative span of the GameStream/Sunshine protocol ABI constants
//  in StreamProtocolConstants.swift, plus the StreamStageNames.name(for:) table
//  lookup. These are on-the-wire values; a typo silently mis-negotiates the
//  stream, so the load-bearing ones (and the documented LANDMINE: SCM_* vs
//  VIDEO_FORMAT_* having DIFFERENT bit layouts) are anchored here.
//

import Testing
@testable import Glimmer

struct StreamProtocolConstantsTests {

    // MARK: - Video formats (Limelight.h:225-234)

    @Test func videoFormatValues() {
        #expect(StreamProtocol.VIDEO_FORMAT_H264 == 0x0001)
        #expect(StreamProtocol.VIDEO_FORMAT_H265 == 0x0100)
        #expect(StreamProtocol.VIDEO_FORMAT_H265_MAIN10 == 0x0200)
        #expect(StreamProtocol.VIDEO_FORMAT_AV1_MAIN8 == 0x1000)
        #expect(StreamProtocol.VIDEO_FORMAT_AV1_MAIN10 == 0x2000)
    }

    // MARK: - SCM_* vs VIDEO_FORMAT_* LANDMINE (different bit layouts)

    @Test func scmLayoutDiffersFromVideoFormatLayout() {
        // The documented landmine: AV1 Main10 has a DIFFERENT value in the
        // SCM_* bitmask than in the VIDEO_FORMAT_* bitmask.
        #expect(StreamProtocol.SCM_AV1_MAIN10 == 0x0002_0000)
        #expect(StreamProtocol.VIDEO_FORMAT_AV1_MAIN10 == 0x2000)
        #expect(StreamProtocol.SCM_AV1_MAIN10 != StreamProtocol.VIDEO_FORMAT_AV1_MAIN10)
        #expect(StreamProtocol.SCM_H264 == 0x0000_0001)
        #expect(StreamProtocol.SCM_HEVC == 0x0000_0100)
        #expect(StreamProtocol.SCM_HEVC_MAIN10 == 0x0000_0200)
    }

    // MARK: - Encryption flags + the 0xFFFFFFFF "ALL" wrap

    @Test func encryptionFlags() {
        #expect(StreamProtocol.ENCFLG_NONE == 0)
        #expect(StreamProtocol.ENCFLG_AUDIO == 0x0000_0001)
        #expect(StreamProtocol.ENCFLG_VIDEO == 0x0000_0002)
        #expect(StreamProtocol.ENCFLG_ALL == Int32(bitPattern: 0xFFFF_FFFF))
        #expect(StreamProtocol.ENCFLG_ALL == -1)
    }

    // MARK: - Keyboard actions + modifiers

    @Test func keyboardConstants() {
        #expect(StreamProtocol.KEY_ACTION_DOWN == 0x03)
        #expect(StreamProtocol.KEY_ACTION_UP == 0x04)
        #expect(StreamProtocol.MODIFIER_SHIFT == 0x01)
        #expect(StreamProtocol.MODIFIER_CTRL == 0x02)
        #expect(StreamProtocol.MODIFIER_ALT == 0x04)
        #expect(StreamProtocol.MODIFIER_META == 0x08)
    }

    // MARK: - Gamepad button flags (incl. the sign-bit Y_FLAG)

    @Test func gamepadButtonFlags() {
        #expect(StreamProtocol.A_FLAG == 0x1000)
        #expect(StreamProtocol.B_FLAG == 0x2000)
        #expect(StreamProtocol.X_FLAG == 0x4000)
        // Y_FLAG is the 0x8000 sign bit, constructed via bitPattern.
        #expect(StreamProtocol.Y_FLAG == Int32(bitPattern: 0x0000_8000))
        #expect(StreamProtocol.UP_FLAG == 0x0001)
        #expect(StreamProtocol.DOWN_FLAG == 0x0002)
    }

    // MARK: - Buffer / frame types

    @Test func bufferAndFrameTypes() {
        #expect(StreamProtocol.BUFFER_TYPE_PICDATA == 0x00)
        #expect(StreamProtocol.BUFFER_TYPE_SPS == 0x01)
        #expect(StreamProtocol.BUFFER_TYPE_PPS == 0x02)
        #expect(StreamProtocol.BUFFER_TYPE_VPS == 0x03)
        #expect(StreamProtocol.FRAME_TYPE_PFRAME == 0x00)
        #expect(StreamProtocol.FRAME_TYPE_IDR == 0x01)
    }

    // MARK: - StreamStageNames.name(for:)

    @Test func stageNamesKnownAnswers() {
        #expect(StreamStageNames.name(for: 0) == "none")
        #expect(StreamStageNames.name(for: 4) == "RTSP handshake")
        #expect(StreamStageNames.name(for: 5) == "control stream initialization")
        #expect(StreamStageNames.name(for: 11) == "input stream establishment")
    }

    @Test func stageNamesOutOfRangeFallsBack() {
        // Index past the table -> "Stage N" fallback (not a crash).
        #expect(StreamStageNames.name(for: 12) == "Stage 12")
        #expect(StreamStageNames.name(for: 999) == "Stage 999")
        #expect(StreamStageNames.name(for: -1) == "Stage -1")
    }

    @Test func stageNamesTableIsContiguous() {
        // Every in-range index returns the table entry, never the fallback.
        for i in 0..<StreamStageNames.table.count {
            let name = StreamStageNames.name(for: Int32(i))
            #expect(name == StreamStageNames.table[i])
            #expect(!name.hasPrefix("Stage "))
        }
    }
}
