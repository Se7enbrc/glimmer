// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import VideoToolbox
import os

extension VideoFormats {
    /// Probe once per process; a codec-family query does not establish 4:4:4 support.
    public static let hardwareSupported: VideoFormats = {
        let formats = probeHardwareSupport(isSupported: VTIsHardwareDecodeSupported)
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Capabilities")
        log.info("VT 4:2:0 capability probe: raw=0x\(String(formats.rawValue, radix: 16), privacy: .public)")
        if !formats.contains(.h264) {
            log.warning("VT reports no hardware H.264 decode on this device")
        }
        return formats
    }()

    static func probeHardwareSupport(isSupported: (CMVideoCodecType) -> Bool) -> VideoFormats {
        var formats: VideoFormats = []
        if isSupported(kCMVideoCodecType_H264) { formats.insert(.h264) }
        // Apple's hardware HEVC and AV1 Main paths support both 8-bit and 10-bit 4:2:0.
        // Session creation still requires hardware; unavailable resources never enable software decode.
        if isSupported(kCMVideoCodecType_HEVC) { formats.formUnion([.hevc, .hevcMain10]) }
        if isSupported(kCMVideoCodecType_AV1) { formats.formUnion([.av1, .av1Main10]) }
        return formats
    }

    /// Potential headroom describes the panel; current headroom can fall to one temporarily.
    public func forDisplay(potentialEDRHeadroom: Double) -> VideoFormats {
        StreamQuality.videoFormats(self, hdr: potentialEDRHeadroom.isFinite && potentialEDRHeadroom > 1)
    }
}
