// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

import Foundation

extension VideoDepacketizer {

    // MARK: - H.264/HEVC Annex-B helpers

    static func isIdrFrameStart<Bytes: RandomAccessCollection>(_ payload: Bytes, hevc: Bool) -> Bool
    where Bytes.Element == UInt8, Bytes.Index == Int {
        idrEvidence(payload, hevc: hevc) == true
    }

    // Nil when the bytes end before the answer: a payload cut inside a start code, a NAL header
    // or a metadata NAL. The caller decides again once the access unit is whole.
    static func idrEvidence<Bytes: RandomAccessCollection>(_ payload: Bytes, hevc: Bool) -> Bool?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard var marker = nextNALMarker(payload, from: payload.startIndex) else {
            return payload.allSatisfy { $0 == 0 } ? nil : false
        }
        guard payload[payload.startIndex..<marker.start].allSatisfy({ $0 == 0 }) else { return false }
        while true {
            let headerSize = hevc ? 2 : 1
            guard payload.endIndex - marker.header >= headerSize else {
                return payload.endIndex > marker.header && payload[marker.header] & 0x80 != 0 ? false : nil
            }
            let byte = payload[marker.header]
            guard byte & 0x80 == 0 else { return false }
            if hevc, payload[marker.header + 1] & 7 == 0 { return false }
            let kind = hevc ? (byte >> 1) & 63 : byte & 31
            if kind == (hevc ? 32 : 7) {
                return hevc ? payload[marker.header + 1] & 7 == 1 : byte & 0x60 != 0
            }
            let metadata = hevc ? kind == 35 || kind == 39 : kind == 9 || kind == 6
            guard metadata, hevc || byte & 0x60 == 0 else { return false }
            guard let following = nextNALMarker(payload, from: marker.header) else { return nil }
            guard following.start - marker.header > headerSize else { return false }
            marker = following
        }
    }

    // A zero run is scanned once; emulation prevention breaks the run before a marker can form.
    private static func nextNALMarker<Bytes: RandomAccessCollection>(
        _ bytes: Bytes, from start: Int
    ) -> (start: Int, header: Int)? where Bytes.Element == UInt8, Bytes.Index == Int {
        var zeros = 0
        for index in start..<bytes.endIndex {
            let byte = bytes[index]
            if byte == 1, zeros >= 2 { return (index - min(zeros, 3), index + 1) }
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return nil
    }

    // Keep metadata in picture order while exposing parameter sets to format negotiation.
    func splitAnnexBParamSets(_ au: Data) -> [DecodeBuffer] {
        let bytes = [UInt8](au)
        var vps: Data?, sps: Data?, pps: Data?
        var picData = Data()
        picData.reserveCapacity(bytes.count)

        var markers: [(start: Int, header: Int)] = []
        var cursor = bytes.startIndex
        while let marker = Self.nextNALMarker(bytes, from: cursor) {
            let start = markers.isEmpty && bytes[..<marker.start].allSatisfy({ $0 == 0 }) ? 0 : marker.start
            markers.append((start, marker.header))
            cursor = marker.header
        }
        guard !markers.isEmpty else {
            return [DecodeBuffer(kind: .picData, data: au)]
        }

        for (index, marker) in markers.enumerated() {
            let start = marker.start
            let end = index + 1 < markers.count ? markers[index + 1].start : bytes.count
            let headerIndex = marker.header
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

    // NAL types come from H.264/H.265; non-parameter units retain their original order.
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
