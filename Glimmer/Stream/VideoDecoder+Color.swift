// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import CoreMedia
import CoreVideo

// The CF dictionary is created once from immutable values and never mutated after publication.
struct VideoColorDescription: Equatable, @unchecked Sendable {
    let primaries: String
    let transfer: String
    let matrix: String
    let range: String
    let gamma: Double?

    var isHDR: Bool {
        transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    }

    var summary: String {
        let gammaLabel = gamma.map { String($0) } ?? "absent"
        return "primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) range=\(range) gamma=\(gammaLabel)"
    }

    let attachments: CFDictionary

    init(primaries: String, transfer: String, matrix: String, range: String, gamma: Double?) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.gamma = gamma
        var values: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: primaries,
            kCVImageBufferTransferFunctionKey as String: transfer,
            kCVImageBufferYCbCrMatrixKey as String: matrix
        ]
        if let gamma { values[kCVImageBufferGammaLevelKey as String] = gamma }
        attachments = values as CFDictionary
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.primaries == rhs.primaries && lhs.transfer == rhs.transfer && lhs.matrix == rhs.matrix
            && lhs.range == rhs.range && lhs.gamma == rhs.gamma
    }

    func makeColorSpace() -> CGColorSpace? {
        CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }

    static func hdrDisplayOutput(inputHDR: Bool, currentEDR: Double) -> Bool {
        inputHDR && currentEDR > 1
    }
}

extension VideoDecoder {
    nonisolated func resolveColorDescription(
        for buffer: CVPixelBuffer, controlHDR: Bool
    ) -> VideoColorDescription {
        let input = formatDescription
        func tag(_ key: CFString) -> String? {
            if let value = CVBufferCopyAttachment(buffer, key, nil) as? String { return value }
            return input.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
        }
        let primaries = tag(kCVImageBufferColorPrimariesKey)
        let transfer = tag(kCVImageBufferTransferFunctionKey)
        let matrix = tag(kCVImageBufferYCbCrMatrixKey)
        let tenBit = streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT != 0
        let declaredHDR = transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let inferPQ = transfer == nil && controlHDR && tenBit
            && (primaries == nil || primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        let space: ColorSpace = declaredHDR || inferPQ || primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String
            ? .rec2020 : requestedColorSpace
        let fallback = fallbackColorTags(space: space, hdr: inferPQ)
        let range = outputColorRange(for: CVPixelBufferGetPixelFormatType(buffer))
        let gamma = CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) as? Double
            ?? input.flatMap {
                CMFormatDescriptionGetExtension($0, extensionKey: kCVImageBufferGammaLevelKey) as? Double
            }
        if let cached = resolvedColor.withLock({ $0 }),
           cached.primaries == primaries ?? fallback.primaries,
           cached.transfer == transfer ?? fallback.transfer,
           cached.matrix == matrix ?? fallback.matrix, cached.range == range, cached.gamma == gamma {
            return cached
        }
        return VideoColorDescription(primaries: primaries ?? fallback.primaries,
                                     transfer: transfer ?? fallback.transfer, matrix: matrix ?? fallback.matrix,
                                     range: range, gamma: gamma)
    }

    // VT can convert full-range input to video-range output. The output format owns its range.
    nonisolated func outputColorRange(for pixelFormat: OSType) -> String {
        pixelFormatRanges.withLock { ranges in
            if let cached = ranges[pixelFormat] { return cached }
            let description = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, pixelFormat) as? [String: Any]
            let range = description?[kCVPixelFormatComponentRange as String] as? String
                ?? (requestedColorRange == .full ? kCVPixelFormatComponentRange_FullRange as String
                    : kCVPixelFormatComponentRange_VideoRange as String)
            ranges[pixelFormat] = range
            return range
        }
    }

    private nonisolated func fallbackColorTags(
        space: ColorSpace, hdr: Bool
    ) -> (primaries: String, transfer: String, matrix: String) {
        let primaries: CFString
        let matrix: CFString
        switch space {
        case .rec601:
            primaries = kCVImageBufferColorPrimaries_SMPTE_C
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case .rec709:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .rec2020:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
        let transfer = hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            : kCVImageBufferTransferFunction_ITU_R_709_2
        return (primaries as String, transfer as String, matrix as String)
    }

    nonisolated func attachColorAndHDRMetadata(to buffer: CVPixelBuffer, color: VideoColorDescription) {
        let changed = resolvedColor.withLock { previous in
            guard previous != color else { return false }
            previous = color
            return true
        }
        if changed {
            lastColorSpace = color.makeColorSpace()
            cachedHDRFormatDescription = nil
            noteColorSpaceChangeTelemetry(color.summary)
            Task { @MainActor [weak self] in self?.configureLayerColorspace() }
        }
        CVBufferSetAttachments(buffer, color.attachments, .shouldPropagate)
        if let space = lastColorSpace {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferCGColorSpaceKey)
        }
        let metadata = hdrMetadataStore.snapshot
        let blobs = [(kCVImageBufferMasteringDisplayColorVolumeKey, metadata.mdcv),
                     (kCVImageBufferContentLightLevelInfoKey, metadata.contentLightLevel)]
        for (key, data) in blobs {
            if !color.isHDR {
                CVBufferRemoveAttachment(buffer, key)
            } else if let data {
                CVBufferSetAttachment(buffer, key, data as CFData, .shouldPropagate)
            }
        }
    }
}
