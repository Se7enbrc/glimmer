// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

// macOS 15 has no preferredDynamicRange; it opts into EDR instead and reports that under
// the same key. iOS targets 26, so the fallback is compiled for macOS only.
extension CALayer {
    package var dynamicRangeLabel: String {
        #if os(macOS)
        guard #available(macOS 26, *) else { return wantsExtendedDynamicRangeContent ? "edr" : "standard" }
        #endif
        return preferredDynamicRange.rawValue
    }

    package func setDynamicRange(high: Bool) {
        #if os(macOS)
        guard #available(macOS 26, *) else {
            wantsExtendedDynamicRangeContent = high
            return
        }
        #endif
        preferredDynamicRange = high ? .high : .standard
    }
}

extension VideoDecoder {

    // MARK: - Display-layer configuration

    // Source tags determine dynamic range; macOS maps HDR input to the destination display.
    package func configureLayerColorspace(headroom: (@MainActor () -> (current: Double, potential: Double))? = nil) {
        guard let layer = displayLayer else { return }
        let active = resolvedColor.withLock { $0?.isHDR ?? false }
        layer.setDynamicRange(high: active)
        if active != isHDRActive {
            isHDRActive = active
            onHDRActiveChanged?(active)
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            probeDisplayTransition(headroom: headroom)
            #endif
        }
    }

    // MARK: - HDR metadata

    /// CoreVideo expects the HDR10 SEI byte layout: big-endian MDCV in GBR order and CLL in nits.
    package func refreshHDRMetadataFromHost() {
        // Pull the flattened HDR10 static metadata through the backend (was the
        // gl_get_hdr_metadata C shim around LiGetHdrMetadata). HdrMetadata is
        // the Limelight-free value type with the exact same fields/units.
        guard let hdr = backend?.hdrMetadata() else {
            log.info("hdrMetadata() returned nil; no HDR metadata to attach")
            hdrMetadataStore.publish(.empty)
            return
        }

        // Mastering display color volume - only meaningful if the host
        // populated primaries. Sunshine fills these from the OS-reported
        // monitor EDID; GFE may leave them zeroed.
        var metadataMDCV: Data?
        var contentLightLevel: Data?
        if hdr.displayPrimariesRX != 0 && hdr.maxDisplayLuminance != 0 {
            var mdcv = Data()
            mdcv.reserveCapacity(24)
            // GBR order, all big-endian.
            appendBE16(&mdcv, hdr.displayPrimariesGX)
            appendBE16(&mdcv, hdr.displayPrimariesGY)
            appendBE16(&mdcv, hdr.displayPrimariesBX)
            appendBE16(&mdcv, hdr.displayPrimariesBY)
            appendBE16(&mdcv, hdr.displayPrimariesRX)
            appendBE16(&mdcv, hdr.displayPrimariesRY)
            appendBE16(&mdcv, hdr.whitePointX)
            appendBE16(&mdcv, hdr.whitePointY)
            // SS_HDR_METADATA.maxDisplayLuminance is in nits; mdcv wants
            // 0.0001-nit units, so multiply by 10000.
            appendBE32(&mdcv, UInt32(hdr.maxDisplayLuminance) * 10000)
            // minDisplayLuminance is already in 1/10000-nit units per
            // Limelight.h, so no scaling needed.
            appendBE32(&mdcv, UInt32(hdr.minDisplayLuminance))
            metadataMDCV = mdcv
        }

        // Content light level - host may omit these even when MDCV is present
        // (GFE typically does). The OS will tonemap conservatively from MDCV
        // alone, which is still better than nothing.
        if hdr.maxContentLightLevel != 0 && hdr.maxFrameAverageLightLevel != 0 {
            var cll = Data()
            cll.reserveCapacity(4)
            appendBE16(&cll, hdr.maxContentLightLevel)
            appendBE16(&cll, hdr.maxFrameAverageLightLevel)
            contentLightLevel = cll
        }

        hdrMetadataStore.publish(HDRMetadata(
            mdcv: metadataMDCV, contentLightLevel: contentLightLevel))
        let mdcvBytes = metadataMDCV?.count ?? 0
        let cllBytes = contentLightLevel?.count ?? 0
        log.info(
            """
            HDR metadata refreshed: mdcv=\(mdcvBytes)B cll=\(cllBytes)B \
            maxLum=\(hdr.maxDisplayLuminance) maxCLL=\(hdr.maxContentLightLevel)
            """
        )
    }

    // MARK: - Big-endian helpers (for HDR metadata blob construction)

    func appendBE16(_ data: inout Data, _ value: UInt16) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    func appendBE32(_ data: inout Data, _ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    /// FourCC encoder for diagnostic logging. e.g. `'x420'` for video-range
    /// 10-bit 4:2:0 biplanar. Prints non-printable bytes as hex escapes.
    package nonisolated func fourCCString(from code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        var out = ""
        for b in bytes {
            if b >= 0x20 && b < 0x7F {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out.append(String(format: "\\x%02x", b))
            }
        }
        return out
    }
}
