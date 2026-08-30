//
//  VideoDepacketizer+AnnexB.swift
//
//  The H.264/HEVC Annex-B helpers: the isIdrFrameStart sniff that decides IDR by
//  NAL inspection (the C path takes the frame-header type byte only for
//  non-H.264/HEVC), and the IDR parameter-set split that routes leading
//  VPS/SPS/PPS NALs into their own DecodeBuffers (the C slow path's
//  getBufferFlags routing). Split out of VideoDepacketizer.swift to keep each
//  unit focused; see that file for the depacketizer's stored state.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//

import Foundation

extension VideoDepacketizer {

    // MARK: - H.264/HEVC Annex-B helpers

    // internal for testability
    /// isIdrFrameStart port: the frame's first payload must open with the
    /// 4-byte start code (NV's frame-start marker; 3-byte means mid-frame)
    /// followed by SPS (H.264, nal_unit_type 7) or VPS (HEVC, type 32) -
    /// the host rides parameter sets on every IDR.
    static func isIdrFrameStart(_ payload: [UInt8], hevc: Bool) -> Bool {
        guard payload.count >= 5,
              payload[0] == 0, payload[1] == 0, payload[2] == 0, payload[3] == 1
        else { return false }
        if hevc {
            return (payload[4] >> 1) & 0x3F == 32      // H265_NAL_TYPE_VPS
        }
        return payload[4] & 0x1F == 7                  // H264_NAL_TYPE_SPS
    }

    // internal for testability
    /// Split an Annex-B access unit into typed DecodeBuffers: VPS/SPS/PPS
    /// NALs (H.264: 7/8; HEVC: 32/33/34) each become their own buffer -
    /// start code kept; the decoder strips it - and every other NAL (SEI,
    /// slices) stays in ONE picData buffer in arrival order. Runs only on
    /// IDR frames, so the per-byte scan is off the steady-state path.
    func splitAnnexBParamSets(_ au: Data) -> [DecodeBuffer] {
        let bytes = [UInt8](au)
        var vps: Data?, sps: Data?, pps: Data?
        var picData = Data()
        picData.reserveCapacity(bytes.count)

        let starts = Self.annexBStartCodeOffsets(bytes)
        guard !starts.isEmpty else {
            return [DecodeBuffer(kind: .picData, data: au)]
        }

        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] : bytes.count
            let scLen = bytes[start + 2] == 1 ? 3 : 4
            let headerIndex = start + scLen
            guard headerIndex < end else { continue }
            let nal = au.subdata(in: start..<end)
            switch bufferKind(nalHeaderByte: bytes[headerIndex]) {
            case .vps: vps = nal
            case .sps: sps = nal
            case .pps: pps = nal
            case .picData: picData.append(nal)
            }
        }

        var out: [DecodeBuffer] = []
        if let vps { out.append(DecodeBuffer(kind: .vps, data: vps)) }
        if let sps { out.append(DecodeBuffer(kind: .sps, data: sps)) }
        if let pps { out.append(DecodeBuffer(kind: .pps, data: pps)) }
        out.append(DecodeBuffer(kind: .picData, data: picData))
        return out
    }

    /// NAL boundaries: each starts at a 00 00 01 / 00 00 00 01 start code
    /// and runs to the next start code (or end of AU). Returns the index OF
    /// each start code, in order. Split out of `splitAnnexBParamSets` so the
    /// byte scan and the NAL routing stay separately readable; the scan order
    /// and the 3-vs-4-byte precedence are unchanged.
    private static func annexBStartCodeOffsets(_ bytes: [UInt8]) -> [Int] {
        var starts: [Int] = []           // index OF the start code
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i); i += 3; continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append(i); i += 4; continue
                }
            }
            i += 1
        }
        return starts
    }

    /// Route one NAL to its DecodeBuffer kind off its first post-start-code
    /// byte (the C slow path's getBufferFlags): HEVC reads nal_unit_type from
    /// bits 6..1, H.264 from the low 5 bits. Anything that isn't a parameter
    /// set is picture data.
    private func bufferKind(nalHeaderByte: UInt8) -> DecodeBuffer.Kind {
        if isHEVC {
            switch (nalHeaderByte >> 1) & 0x3F {
            case 32: return .vps
            case 33: return .sps
            case 34: return .pps
            default: return .picData
            }
        }
        switch nalHeaderByte & 0x1F {
        case 7: return .sps
        case 8: return .pps
        default: return .picData
        }
    }
}
