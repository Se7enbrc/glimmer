// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

import Foundation

extension VideoDepacketizer {

    // MARK: - H.264/HEVC Annex-B helpers

    static func isIdrFrameStart<Bytes: RandomAccessCollection>(_ payload: Bytes, hevc: Bool) -> Bool
    where Bytes.Element == UInt8, Bytes.Index == Int {
        fatalError("clean-room: replace per spec-2")
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
