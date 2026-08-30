//
//  VideoDepacketizer+FrameHeader.swift
//
//  The NV frame-header parse (VideoDepacketizer.c:851-972): the frame-type byte
//  that drives the IDR / RFI-recovery state, the Sunshine host-processing-latency
//  field, the AV1 last-packet payload length, and the version + byte0 dependent
//  header length the payload is skipped past. Split out of
//  VideoDepacketizer.swift to keep each unit focused; see that file for the
//  depacketizer's stored state.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//

import Foundation

extension VideoDepacketizer {

    // MARK: - Frame header parse (c:851-972)

    // Internal (not private) so `process(_:)` in VideoDepacketizer.swift can call
    // across the split.
    /// Returns the frame header size to skip, or -1 on parse failure.
    func parseFrameHeader(_ payload: inout [UInt8], frameIndex: UInt32) -> Int {
        guard payload.count >= 4 else { return -1 }

        // Frame type from data[offset+3] (offset==0 here) (c:857-887).
        let typeByte = payload[3]
        switch typeByte {
        case 1:  // Normal P-frame
            break
        case 2:  // IDR
            // For non-H.264/HEVC we trust the header byte (c:861-868).
            if isAV1 {
                waitingForIdrFrame = false
                waitingForNextSuccessfulFrame = false   // c:866
                frameType = Self.FRAME_TYPE_IDR
            }
            fallthrough                                 // c:869 - into 4/5
        case 4, 5:  // intra-refresh / P-frame with RFI
            // Host recovery frame after an RFI request: accept it by clearing
            // the RFI wait so it falls through the lastPacket gate (c:872-878).
            if waitingForRefInvalFrame {
                Diag.notice("NativeVideo post-invalidation recovery frame \(frameIndex) "
                    + "(\(typeByte == 5 ? "P" : "I")-frame)", Self.cat)
                waitingForRefInvalFrame = false
                waitingForNextSuccessfulFrame = false
                // P2 IDR/RFI ROUND-TRIP: this recovery frame resolves an RFI
                // request (the IDR path resolves in the receiver via unit.isIDR).
                frameIsRfiRecovery = true
            }
        case 104:   // Sunshine hardcoded header
            break
        default:
            Diag.warn("NativeVideo unrecognized frame type byte \(typeByte) frame \(frameIndex)", Self.cat)
        }

        // Sunshine host processing latency = u16 LE at offset+1 (c:899-903).
        if payload.count >= 3 {
            frameHostProcessingLatency = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        }

        // AV1 (non-H264/HEVC) lastPacketPayloadLength = u16 LE at offset+4
        // (c:908-912).
        if isAV1 && payload.count >= 6 {
            lastPacketPayloadLength = UInt16(payload[4]) | (UInt16(payload[5]) << 8)
        }

        return frameHeaderSize(byte0: payload[0])
    }

    /// Version + byte0 dependent header length (c:914-965).
    private func frameHeaderSize(byte0: UInt8) -> Int {
        let quad = appVersionQuad
        func atLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Bool {
            if quad.count < 3 { return false }
            if quad[0] != major { return quad[0] > major }
            if quad[1] != minor { return quad[1] > minor }
            return quad[2] >= patch
        }

        if atLeast(7, 1, 450) {
            return byte0 == 0x01 ? 8 : 44
        } else if atLeast(7, 1, 446) {
            return byte0 == 0x01 ? 8 : 41
        } else if atLeast(7, 1, 415) {
            return byte0 == 0x01 ? 8 : 24
        } else if atLeast(7, 1, 350) {
            return 8
        } else if atLeast(7, 1, 320) {
            return 12
        } else if atLeast(5, 0, 0) {
            return 8
        } else {
            return 0
        }
    }
}
