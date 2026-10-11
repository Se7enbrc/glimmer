// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import CoreMedia
import CoreVideo

struct VideoColorDescription: Equatable, Sendable {
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

    var attachments: [String: Any] {
        var result: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: primaries,
            kCVImageBufferTransferFunctionKey as String: transfer,
            kCVImageBufferYCbCrMatrixKey as String: matrix
        ]
        if let gamma { result[kCVImageBufferGammaLevelKey as String] = gamma }
        return result
    }

    func makeColorSpace() -> CGColorSpace? {
        CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)?.takeRetainedValue()
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
        let untagged = primaries == nil && transfer == nil && matrix == nil
        let tenBit = streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT != 0
        let fallbackHDR = untagged && controlHDR && tenBit
        let fallback = fallbackColorTags(hdr: fallbackHDR)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let pixelDescription = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, pixelFormat) as? [String: Any]
        // VT can convert full-range input to video-range output. The output format owns its range.
        let range = pixelDescription?[kCVPixelFormatComponentRange as String] as? String
            ?? (requestedColorRange == .full ? kCVPixelFormatComponentRange_FullRange as String
                : kCVPixelFormatComponentRange_VideoRange as String)
        let gamma = CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) as? Double
            ?? input.flatMap {
                CMFormatDescriptionGetExtension($0, extensionKey: kCVImageBufferGammaLevelKey) as? Double
            }
        return VideoColorDescription(primaries: primaries ?? fallback.primaries,
                                     transfer: transfer ?? fallback.transfer, matrix: matrix ?? fallback.matrix,
                                     range: range, gamma: gamma)
    }

    private nonisolated func fallbackColorTags(hdr: Bool) -> (primaries: String, transfer: String, matrix: String) {
        let space = hdr ? ColorSpace.rec2020 : requestedColorSpace
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
        CVBufferSetAttachments(buffer, color.attachments as CFDictionary, .shouldPropagate)
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
