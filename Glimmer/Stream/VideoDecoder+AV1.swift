// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Parse AV1 sequence colour and chroma declarations so VT receives the same tags as HEVC.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

extension VideoDecoder {

    // MARK: - AV1 OBU sequence-header parsing

    /// Subset of AV1 sequence header §5.5.1 fields that the av1C config record
    /// needs. Decoded straight off the bitstream; do not infer from the
    /// negotiated VIDEO_FORMAT_* hint.
    struct AV1SeqHeader {
        let seqProfile: UInt8
        let seqTier: UInt8
        let bitDepth: UInt8      // 8, 10, or 12
        let monochrome: UInt8    // 0/1
        let subsamplingX: UInt8  // 0/1
        let subsamplingY: UInt8  // 0/1
        let color: ColorConfig
    }

    /// Walk the OBU stream, locate the first SEQUENCE_HEADER_OBU (type=1),
    /// and bit-parse the fields the av1C box advertises. Returns nil on any
    /// parse error; callers fall back to the negotiated-format hint.
    ///
    /// Reference: AV1 Bitstream & Decoding Process Specification, §5.3 (OBU
    /// syntax) and §5.5.1 / §5.5.2 (sequence_header_obu + color_config).
    nonisolated func parseAV1SequenceHeader(_ data: Data) -> AV1SeqHeader? {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            // obu_header: forbidden(1)=0 | obu_type(4) | extension_flag(1)
            //           | has_size_field(1) | reserved(1)
            let header = bytes[i]
            i += 1
            let obuType = (header >> 3) & 0x0F
            let extFlag = (header >> 2) & 0x01
            let hasSize = (header >> 1) & 0x01
            if extFlag == 1 {
                // obu_extension_header: temporal_id(3) | spatial_id(2) | reserved(3)
                guard i < bytes.count else { return nil }
                i += 1
            }
            // obu_size leb128 (when present). Sunshine/GFE ship with
            // has_size_field=1; if absent, the OBU consumes the rest of the
            // packet - we still need to compute the payload length to bit-
            // read it.
            var payloadLen = bytes.count - i
            if hasSize == 1 {
                guard let leb = readLeb128(bytes, &i) else { return nil }
                payloadLen = Int(leb)
                if i + payloadLen > bytes.count { return nil }
            }
            // OBU_SEQUENCE_HEADER = 1
            if obuType == 1 {
                let payload = Array(bytes[i..<(i + payloadLen)])
                return decodeSequenceHeader(payload)
            }
            i += payloadLen
        }
        return nil
    }

    /// leb128 reader per AV1 §4.10.5. Reads up to 8 bytes (the spec ceiling),
    /// returns the integer value plus advances `cursor`.
    nonisolated private func readLeb128(_ bytes: [UInt8], _ cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in 0..<8 {
            guard cursor < bytes.count else { return nil }
            let byte = bytes[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << (shift * 7)
            if (byte & 0x80) == 0 {
                return value
            }
        }
        return nil
    }

    /// Walk §5.5.1 through color_config in spec order; later fields do not affect av1C or colour extensions.
    nonisolated private func decodeSequenceHeader(_ payload: [UInt8]) -> AV1SeqHeader? {
        var reader = BitReader(bytes: payload)
        guard let seqProfile = reader.read(3) else { return nil }
        _ = reader.read(1)  // still_picture
        guard let reducedStillPicture = reader.read(1) else { return nil }
        let seqTier0: UInt32
        if reducedStillPicture == 1 {
            _ = reader.read(5)  // seq_level_idx_0 (irrelevant for av1C tier bit)
            seqTier0 = 0
        } else {
            guard let tier = parseTimingAndOperatingPoints(&reader) else { return nil }
            seqTier0 = tier
        }
        guard skipFrameSizeAndFeatureFlags(&reader,
                                           reducedStillPicture: reducedStillPicture) else {
            return nil
        }
        guard let color = parseColorConfig(&reader, seqProfile: seqProfile) else {
            return nil
        }
        return AV1SeqHeader(
            seqProfile: UInt8(seqProfile),
            seqTier: UInt8(seqTier0),
            bitDepth: color.bitDepth,
            monochrome: color.monochrome,
            subsamplingX: color.subsamplingX,
            subsamplingY: color.subsamplingY,
            color: color)
    }

    /// §5.5.1 timing_info + decoder_model_info + operating_points loop (the
    /// `reduced_still_picture_header == 0` branch). Returns the tier bit of
    /// operating point 0 (`seqTier0`), or nil on a parse error so the caller
    /// can propagate the failure.
    nonisolated private func parseTimingAndOperatingPoints(
        _ reader: inout BitReader) -> UInt32? {
        guard let timingInfoPresent = reader.read(1) else { return nil }
        var decoderModelInfoPresent: UInt32 = 0
        var bufferDelayLength = 0
        if timingInfoPresent == 1 {
            // timing_info(): num_units_in_display_tick(32),
            // time_scale(32), equal_picture_interval(1),
            // [num_ticks_per_picture leb-style if equal]
            _ = reader.read(32)
            _ = reader.read(32)
            guard let equalPicInterval = reader.read(1) else { return nil }
            if equalPicInterval == 1 {
                // num_ticks_per_picture_minus_1: uvlc
                guard reader.readUvlc() != nil else { return nil }
            }
            guard let dmip = reader.read(1) else { return nil }
            decoderModelInfoPresent = dmip
            if dmip == 1 {
                // decoder_model_info(): 5 + 32 + 5 + 5 = 47 bits
                guard let bufferDelayLengthMinus1 = reader.read(5) else { return nil }
                bufferDelayLength = Int(bufferDelayLengthMinus1) + 1
                _ = reader.read(32)
                _ = reader.read(5)
                _ = reader.read(5)
            }
        }
        guard let initialDisplayDelayPresent = reader.read(1) else { return nil }
        guard let opCountMinus1 = reader.read(5) else { return nil }
        let opCount = Int(opCountMinus1) + 1
        return parseOperatingPoints(
            &reader,
            opCount: opCount,
            decoderModelInfoPresent: decoderModelInfoPresent,
            bufferDelayLength: bufferDelayLength,
            initialDisplayDelayPresent: initialDisplayDelayPresent)
    }

    /// §5.5.1 operating_points loop. Reads `opCount` operating-point records
    /// and returns the tier bit of operating point 0 (`seqTier0`), or nil on
    /// a parse error.
    nonisolated private func parseOperatingPoints(
        _ reader: inout BitReader,
        opCount: Int,
        decoderModelInfoPresent: UInt32,
        bufferDelayLength: Int,
        initialDisplayDelayPresent: UInt32) -> UInt32? {
        var seqTier0: UInt32 = 0
        for op in 0..<opCount {
            _ = reader.read(12)  // operating_point_idc
            guard let lv = reader.read(5) else { return nil }
            if lv > 7 {
                guard let tier = reader.read(1) else { return nil }
                if op == 0 { seqTier0 = tier }
            }
            if decoderModelInfoPresent == 1 {
                guard let dmpFlag = reader.read(1) else { return nil }
                if dmpFlag == 1 {
                    // operating_parameters_info(): two delays use the declared width.
                    guard reader.read(bufferDelayLength) != nil else { return nil }
                    guard reader.read(bufferDelayLength) != nil else { return nil }
                    guard reader.read(1) != nil else { return nil }
                }
            }
            if initialDisplayDelayPresent == 1 {
                guard let iddp = reader.read(1) else { return nil }
                if iddp == 1 { _ = reader.read(4) }
            }
        }
        return seqTier0
    }

    /// §5.5.1 frame-size bits, frame-id config, and the enable_* feature
    /// flags that precede color_config. None of these fields feed av1C, so we
    /// only need to consume them in the correct order. Returns false on a
    /// parse error.
    nonisolated private func skipFrameSizeAndFeatureFlags(
        _ reader: inout BitReader,
        reducedStillPicture: UInt32) -> Bool {
        // frame_width_bits_minus_1(4), frame_height_bits_minus_1(4)
        guard let widthBitsM1 = reader.read(4) else { return false }
        guard let heightBitsM1 = reader.read(4) else { return false }
        _ = reader.read(Int(widthBitsM1) + 1)  // max_frame_width_minus_1
        _ = reader.read(Int(heightBitsM1) + 1)  // max_frame_height_minus_1
        var frameIdNumbersPresent: UInt32 = 0
        if reducedStillPicture == 0 {
            guard let framePresent = reader.read(1) else { return false }
            frameIdNumbersPresent = framePresent
        }
        if frameIdNumbersPresent == 1 {
            _ = reader.read(4)  // delta_frame_id_length_minus_2
            _ = reader.read(3)  // additional_frame_id_length_minus_1
        }
        _ = reader.read(1)  // use_128x128_superblock
        _ = reader.read(1)  // enable_filter_intra
        _ = reader.read(1)  // enable_intra_edge_filter
        if reducedStillPicture == 0 {
            guard skipInterFeatureFlags(&reader) else { return false }
        }
        _ = reader.read(1)  // enable_superres
        _ = reader.read(1)  // enable_cdef
        _ = reader.read(1)  // enable_restoration
        return true
    }

    /// §5.5.1 inter-prediction enable_* flags + screen-content-tools config
    /// (only present when `reduced_still_picture_header == 0`). None feed
    /// av1C; we just consume them in order. Returns false on a parse error.
    nonisolated private func skipInterFeatureFlags(_ reader: inout BitReader) -> Bool {
        _ = reader.read(1)  // enable_interintra_compound
        _ = reader.read(1)  // enable_masked_compound
        _ = reader.read(1)  // enable_warped_motion
        _ = reader.read(1)  // enable_dual_filter
        guard let enableOrderHint = reader.read(1) else { return false }
        if enableOrderHint == 1 {
            _ = reader.read(1)  // enable_jnt_comp
            _ = reader.read(1)  // enable_ref_frame_mvs
        }
        guard let seqChooseScreenDetect = reader.read(1) else { return false }
        var seqForceScreenContent: UInt32 = 2  // SELECT_SCREEN_CONTENT_TOOLS
        if seqChooseScreenDetect == 0 {
            guard let forceFlag = reader.read(1) else { return false }
            seqForceScreenContent = forceFlag
        }
        if seqForceScreenContent != 0 {
            guard let chooseIntegerMv = reader.read(1) else { return false }
            if chooseIntegerMv == 0 { _ = reader.read(1) }
        }
        if enableOrderHint == 1 { _ = reader.read(3) }  // order_hint_bits_minus_1
        return true
    }

    struct ColorConfig {
        let bitDepth: UInt8
        let monochrome: UInt8
        let subsamplingX: UInt8
        let subsamplingY: UInt8
        let primaries: UInt32
        let transfer: UInt32
        let matrix: UInt32
        let fullRange: Bool

        var formatExtensions: [String: Any] {
            var result: [String: Any] = [kCMFormatDescriptionExtension_FullRangeVideo as String: fullRange]
            result[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                CVColorPrimariesGetStringForIntegerCodePoint(Int32(primaries))?.takeUnretainedValue()
            result[kCMFormatDescriptionExtension_TransferFunction as String] =
                CVTransferFunctionGetStringForIntegerCodePoint(Int32(transfer))?.takeUnretainedValue()
            result[kCMFormatDescriptionExtension_YCbCrMatrix as String] =
                CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(matrix))?.takeUnretainedValue()
            return result
        }
    }

    // Preserve unspecified CICP values as absent extensions so negotiated fallback still applies.
    nonisolated private func parseColorConfig(
        _ reader: inout BitReader, seqProfile: UInt32
    ) -> ColorConfig? {
        guard let highBitDepth = reader.read(1) else { return nil }
        var bitDepth: UInt8 = highBitDepth == 1 ? 10 : 8
        if seqProfile == 2 && highBitDepth == 1 {
            guard let twelveBit = reader.read(1) else { return nil }
            bitDepth = twelveBit == 1 ? 12 : 10
        }
        var monochrome: UInt8 = 0
        if seqProfile != 1 {
            guard let monoFlag = reader.read(1) else { return nil }
            monochrome = UInt8(monoFlag)
        }
        guard let colorDescPresent = reader.read(1) else { return nil }
        var primaries: UInt32 = 2
        var transfer: UInt32 = 2
        var matrix: UInt32 = 2
        if colorDescPresent == 1 {
            guard let cp = reader.read(8), let tc = reader.read(8), let mc = reader.read(8) else { return nil }
            primaries = cp
            transfer = tc
            matrix = mc
        }
        let identityRGB = primaries == 1 && transfer == 13 && matrix == 0
        let fullRange: Bool
        let chroma: (x: UInt8, y: UInt8)
        if monochrome == 1 {
            guard let range = reader.read(1) else { return nil }
            fullRange = range == 1
            chroma = (1, 1)
        } else {
            if identityRGB {
                fullRange = true
                chroma = (0, 0)
            } else {
                guard let range = reader.read(1),
                      let sampling = parseChromaSubsampling(&reader, seqProfile: seqProfile, bitDepth: bitDepth)
                else { return nil }
                fullRange = range == 1
                chroma = sampling
                if chroma.x == 1 && chroma.y == 1 {
                    guard reader.read(2) != nil else { return nil } // chroma_sample_position
                }
            }
            guard reader.read(1) != nil else { return nil } // separate_uv_delta_q
        }
        return ColorConfig(bitDepth: bitDepth, monochrome: monochrome,
                           subsamplingX: chroma.x, subsamplingY: chroma.y,
                           primaries: primaries, transfer: transfer, matrix: matrix, fullRange: fullRange)
    }

    // Profiles 0/1 imply 4:2:0/4:4:4; only profile 2 carries explicit subsampling bits at 12-bit.
    nonisolated private func parseChromaSubsampling(
        _ reader: inout BitReader,
        seqProfile: UInt32,
        bitDepth: UInt8) -> (x: UInt8, y: UInt8)? {
        if seqProfile == 0 { return (1, 1) }
        if seqProfile == 1 { return (0, 0) }
        guard bitDepth == 12 else { return (1, 0) }
        guard let sx = reader.read(1) else { return nil }
        let subsamplingX = UInt8(sx)
        if sx == 1 {
            guard let sy = reader.read(1) else { return nil }
            return (subsamplingX, UInt8(sy))
        }
        return (subsamplingX, 0)
    }

    /// Bare-minimum MSB-first bit reader. AV1 spec §4.7.1: bits are read
    /// big-endian; the syntax `f(n)` reads n bits from the current position.
    struct BitReader {
        let bytes: [UInt8]
        var byteOffset: Int = 0
        var bitOffset: Int = 0  // 0..7, bits already consumed in `bytes[byteOffset]`

        /// Read `count` bits (0 ≤ count ≤ 32) MSB-first. Returns nil if exhausted.
        mutating func read(_ count: Int) -> UInt32? {
            if count == 0 { return 0 }
            if count > 32 { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                if byteOffset >= bytes.count { return nil }
                let bit = (bytes[byteOffset] >> (7 - bitOffset)) & 0x01
                value = (value << 1) | UInt32(bit)
                bitOffset += 1
                if bitOffset == 8 {
                    bitOffset = 0
                    byteOffset += 1
                }
            }
            return value
        }

        /// AV1 unsigned variable-length code (§4.10.3). Reads leading-zero
        /// length, then `length` bits, returns 2^length - 1 + bits.
        mutating func readUvlc() -> UInt32? {
            var leadingZeros = 0
            while true {
                guard let b = read(1) else { return nil }
                if b == 1 { break }
                leadingZeros += 1
                if leadingZeros >= 32 { return nil }
            }
            if leadingZeros == 0 { return 0 }
            guard let bits = read(leadingZeros) else { return nil }
            return bits + ((1 << leadingZeros) - 1)
        }
    }
}
