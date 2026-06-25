//
//  VideoDecoder+Bitstream.swift
//
//  Bitstream parsing and CMVideoFormatDescription / CMSampleBuffer construction
//  for H.264, HEVC, and AV1. Lives separate from the decoder lifecycle so the
//  per-codec parameter-set assembly + Annex-B ↔ AVCC plumbing reads in one
//  place.

import CoreMedia
import Foundation
import VideoToolbox

extension VideoDecoder {

    // MARK: - Format description builders

    nonisolated func rebuildH264FormatDescription() -> Bool {
        guard let sps = spsData, let pps = ppsData else { return false }
        return sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return false
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                var newFormat: CMVideoFormatDescription?
                let status = pointers.withUnsafeBufferPointer { ptrs -> OSStatus in
                    sizes.withUnsafeBufferPointer { szs -> OSStatus in
                        guard let ptrsBase = ptrs.baseAddress, let szsBase = szs.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBase,
                            parameterSetSizes: szsBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormat)
                    }
                }
                if status != noErr {
                    log.error("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(status)")
                    return false
                }
                self.formatDescription = newFormat
                self.cachedHDRFormatDescription = nil
                self.tearDownDecompressionSession()
                return true
            }
        }
    }

    nonisolated func rebuildHEVCFormatDescription() -> Bool {
        guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return false }
        return vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard
                        let vpsBase = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else {
                        return false
                    }
                    let pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    var newFormat: CMVideoFormatDescription?
                    let status = pointers.withUnsafeBufferPointer { ptrs -> OSStatus in
                        sizes.withUnsafeBufferPointer { szs -> OSStatus in
                            guard let ptrsBase = ptrs.baseAddress, let szsBase = szs.baseAddress else {
                                return kCMFormatDescriptionError_InvalidParameter
                            }
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrsBase,
                                parameterSetSizes: szsBase,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &newFormat)
                        }
                    }
                    if status != noErr {
                        log.error("CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: \(status)")
                        return false
                    }
                    self.formatDescription = newFormat
                    self.cachedHDRFormatDescription = nil
                    self.tearDownDecompressionSession()
                    return true
                }
            }
        }
    }

    nonisolated func rebuildAV1FormatDescription(obuData: Data) -> Bool {
        // For AV1 we need a CMFormatDescription with the AV1C extension
        // (av1C box per ISO/IEC 23091-2). VideoToolbox surfaces this via
        // CMVideoFormatDescriptionCreate with a kCMFormatDescriptionExtension
        // for sample-description-extension-atoms.
        //
        // The av1C config record encodes (per the AV1 ISO Base Media File
        // Format spec) seq_profile / seq_level / seq_tier / high_bitdepth /
        // twelve_bit / monochrome / chroma_subsampling_x / _y. These come
        // from the AV1 sequence header OBU's `color_config` block (AV1 spec
        // §5.5.1, §5.5.2). We parse them out of the first SEQUENCE_HEADER_OBU
        // in the bitstream so 4:4:4 (HIGH8_444 / HIGH10_444) streams describe
        // themselves correctly to VT - hardcoding 4:2:0 here silently breaks
        // any future 4:4:4 path.
        //
        // Parser is intentionally minimal: it walks OBU headers (with optional
        // extension byte + leb128 size), finds the SEQUENCE_HEADER_OBU
        // (type=1), and bit-reads enough of §5.5.1 to recover the eight
        // av1C-relevant fields. If parsing fails we fall back to the
        // negotiated-format hint (Main8/Main10, 4:2:0) - VT's HW AV1 decoder
        // re-derives the truth from the OBU at decode time, so a mis-tagged
        // av1C is recoverable for Main; the parser fail-safe just keeps the
        // pre-fix behavior on edge-case bitstreams.
        guard !obuData.isEmpty else { return false }

        let parsed = parseAV1SequenceHeader(obuData)
        if let parsed {
            log.info(
                """
                AV1 seq header parsed: profile=\(parsed.seqProfile, privacy: .public) \
                bitDepth=\(parsed.bitDepth, privacy: .public) \
                mono=\(parsed.monochrome, privacy: .public) \
                ssx=\(parsed.subsamplingX, privacy: .public) \
                ssy=\(parsed.subsamplingY, privacy: .public)
                """
            )
        } else {
            log.warning("AV1 seq header parse failed; falling back to Main 4:2:0 av1C")
        }

        let isMain10Hint = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_AV1_MAIN10) != 0
        let seqProfile: UInt8 = parsed?.seqProfile ?? 0
        let bitDepth: UInt8 = parsed?.bitDepth ?? (isMain10Hint ? 10 : 8)
        let monochrome: UInt8 = parsed?.monochrome ?? 0
        let subsamplingX: UInt8 = parsed?.subsamplingX ?? 1
        let subsamplingY: UInt8 = parsed?.subsamplingY ?? 1
        let seqTier: UInt8 = parsed?.seqTier ?? 0
        let level: UInt8 = 0  // 2.0; auto-negotiated by the decoder anyway

        var av1cBytes: [UInt8] = []
        // Marker bit + version (1), then seq_profile(3) + seq_level_idx_0(5)
        av1cBytes.append(0x81)  // marker=1, version=1
        av1cBytes.append((seqProfile << 5) | (level & 0x1F))
        // seq_tier_0(1) + high_bitdepth(1) + twelve_bit(1) + monochrome(1)
        // + chroma_subsampling_x(1) + chroma_subsampling_y(1)
        // + chroma_sample_position(2)
        let highBitDepth: UInt8 = (bitDepth >= 10) ? 1 : 0
        let twelveBit: UInt8 = (bitDepth >= 12) ? 1 : 0
        av1cBytes.append(
            (seqTier << 7) | (highBitDepth << 6) | (twelveBit << 5) | (monochrome << 4)
                | (subsamplingX << 3) | (subsamplingY << 2))
        // initial_presentation_delay_present(1) + reserved(7)
        av1cBytes.append(0x00)

        let av1cData = Data(av1cBytes) as CFData

        let av1CKey = "av1C" as CFString
        // Wrap atoms in a dict keyed by FourCC, matching VT's "sample
        // description extension atoms" contract.
        let atomsDict = [av1CKey: av1cData] as CFDictionary
        let extKey =
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        let extensions = [extKey: atomsDict] as CFDictionary

        var newFormat: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: streamWidth,
            height: streamHeight,
            extensions: extensions,
            formatDescriptionOut: &newFormat)
        if status != noErr {
            log.error("CMVideoFormatDescriptionCreate (AV1) failed: \(status)")
            return false
        }
        self.formatDescription = newFormat
        self.cachedHDRFormatDescription = nil
        self.tearDownDecompressionSession()
        return true
    }

    // MARK: - Annex-B / AVCC conversion

    /// Strip a leading Annex-B start code (00 00 00 01 or 00 00 01) so what
    /// remains is a bare NAL unit suitable for use as a parameter set.
    nonisolated func stripStartCode(_ data: Data) -> Data {
        if data.count >= 4, data[0] == 0, data[1] == 0, data[2] == 0, data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        }
        if data.count >= 3, data[0] == 0, data[1] == 0, data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    /// Replace each Annex-B start code with a 4-byte big-endian length prefix
    /// (AVCC / HVCC, the form VideoToolbox consumes). Scan-then-write over
    /// `withUnsafeBytes` avoids a `Data -> [UInt8] -> Data` copy per frame.
    nonisolated func convertAnnexBToAVCC(_ data: Data) -> Data {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Data()
            }
            let count = raw.count

            // First pass: collect NAL spans and the exact output length.
            var nals: [(start: Int, length: Int)] = []
            var outSize = 0
            var nalStart = -1
            var i = 0
            while i < count {
                let scLen = startCodeLength(at: i, base: base, count: count)
                if scLen > 0 {
                    if nalStart >= 0, i > nalStart {
                        nals.append((nalStart, i - nalStart))
                        outSize += 4 + (i - nalStart)
                    }
                    i += scLen
                    nalStart = i
                } else {
                    i += 1
                }
            }
            if nalStart >= 0, count > nalStart {
                nals.append((nalStart, count - nalStart))
                outSize += 4 + (count - nalStart)
            }

            // Second pass: one pre-sized write of len32-BE || NAL per unit.
            var out = Data(count: outSize)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.baseAddress else { return }
                var offset = 0
                for nal in nals {
                    let lenBE = UInt32(nal.length).bigEndian
                    withUnsafeBytes(of: lenBE) { lenBytes in
                        dstBase.advanced(by: offset).copyMemory(from: lenBytes.baseAddress!, byteCount: 4)
                    }
                    offset += 4
                    dstBase.advanced(by: offset)
                        .copyMemory(from: base.advanced(by: nal.start), byteCount: nal.length)
                    offset += nal.length
                }
            }
            return out
        }
    }

    /// Length of an Annex-B start code at `i` (4 for 00 00 00 01, 3 for
    /// 00 00 01, 0 if none). Helper so the AVCC scan reads in one place.
    private nonisolated func startCodeLength(
        at i: Int, base: UnsafePointer<UInt8>, count: Int
    ) -> Int {
        if i + 3 < count, base[i] == 0, base[i + 1] == 0, base[i + 2] == 0, base[i + 3] == 1 {
            return 4
        }
        if i + 2 < count, base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
            return 3
        }
        return 0
    }

    // MARK: - Sample buffer construction (for VT input)

    nonisolated func makeSampleBuffer(
        rawData: Data, rtpTimestamp: UInt32 = 0
    ) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { return nil }

        // Wrap rawData in a CMBlockBuffer. We copy because moonlight will
        // reuse its buffers after submitDecodeUnit returns; sharing memory
        // here would be a use-after-free hazard.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: rawData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: rawData.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            log.error("CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return nil
        }

        status = CMBlockBufferAssureBlockMemory(bb)
        guard status == kCMBlockBufferNoErr else {
            log.error("CMBlockBufferAssureBlockMemory failed: \(status)")
            return nil
        }

        status = rawData.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: rawData.count)
        }
        guard status == kCMBlockBufferNoErr else {
            log.error("CMBlockBufferReplaceDataBytes failed: \(status)")
            return nil
        }

        // Attach the host's rtpTimestamp (90kHz units, per H.264/HEVC/AV1
        // RTP standard - see DECODE_UNIT.rtpTimestamp in Limelight.h, and
        // the spec note that CMTimeMake((int64_t)du->rtpTimestamp, 90000)
        // is the canonical conversion). VT propagates this onto the output
        // callback's presentationTimeStamp argument so the downstream
        // enqueue path can stamp the output CMSampleBuffer in the host's
        // capture clock rather than our local "now-receive" clock.
        //
        // Why this matters: AVSampleBufferDisplayLayer / VideoRenderer uses
        // the PTS to make drop decisions when frames bunch up. A local
        // mach_absolute_time PTS would be monotonically increasing in
        // *our* clock and give the layer no signal to detect a stale frame
        // post-stutter; host-clock PTS lets it drop stale frames cleanly.
        let timingInfo: CMSampleTimingInfo
        if rtpTimestamp != 0 {
            timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTimeMake(value: Int64(rtpTimestamp), timescale: 90_000),
                decodeTimeStamp: .invalid)
        } else {
            // No host PTS available (older Sunshine builds, defensive path).
            timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid)
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleSize = rawData.count
        status = withUnsafePointer(to: timingInfo) { timingPtr in
            var sampleSizeLocal = sampleSize
            return CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: timingPtr,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizeLocal,
                sampleBufferOut: &sampleBuffer)
        }
        if status != noErr {
            log.error("CMSampleBufferCreateReady failed: \(status)")
            return nil
        }
        return sampleBuffer
    }
}
