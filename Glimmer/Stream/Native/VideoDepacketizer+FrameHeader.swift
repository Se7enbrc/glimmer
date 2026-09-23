//
//  VideoDepacketizer+FrameHeader.swift
//
//  The NV frame-header parse (VideoDepacketizer.c:851-972): the frame type that drives IDR and RFI
//  recovery, Sunshine's host-processing latency, the AV1 last-packet length and the header length
//  to skip. Split out of VideoDepacketizer.swift, which holds the depacketizer's state.
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
            // The receiver logs the episode it ends once the frame assembles.
            if waitingForRefInvalFrame {
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

        // Sunshine reports 7.1.431, the [7.1.415, 7.1.446) rung of c:914-965; the others were GameStream's.
        return payload[0] == 0x01 ? 8 : 24
    }
}
