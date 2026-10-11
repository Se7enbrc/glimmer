// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import CoreMedia
import CoreVideo

struct ColorProbeKey: Equatable, Sendable {
    let controlHDR: Bool
    let resolved: VideoColorDescription
    let pixelFormat: OSType
}

struct ColorProbe: Sendable {
    let state: ColorProbeKey
    let rawFormat: String
    let rawAttachments: String
    let videoFormat: Int32
}

extension VideoDecoder {
    // Capture before any attachment edits so the probe can expose a decoder/signalling mismatch.
    nonisolated func beginColorProbe(
        _ buffer: CVPixelBuffer, color: VideoColorDescription, controlHDR: Bool
    ) -> ColorProbe? {
        let state = ColorProbeKey(
            controlHDR: controlHDR, resolved: color,
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer))
        let changed = colorProbeState.withLock { previous in
            guard previous != state else { return false }
            previous = state
            return true
        }
        guard changed else { return nil }
        let extensions = formatDescription.map { String(describing: CMFormatDescriptionGetExtensions($0)) }
        return ColorProbe(state: state, rawFormat: extensions ?? "absent",
                          rawAttachments: colorAttachmentSummary(buffer), videoFormat: streamVideoFormat)
    }

    nonisolated func colorAttachmentSummary(_ buffer: CVPixelBuffer) -> String {
        let propagated = CVBufferCopyAttachments(buffer, .shouldPropagate)
        let local = CVBufferCopyAttachments(buffer, .shouldNotPropagate)
        var spaceName = "absent"
        if let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
           CFGetTypeID(value) == CGColorSpace.typeID {
            spaceName = unsafeDowncast(value, to: CGColorSpace.self).name as String? ?? "unnamed"
        }
        return "CGColorSpaceName=\(spaceName) propagated=\(String(describing: propagated)) "
            + "local=\(String(describing: local))"
    }

    nonisolated func finishColorProbe(_ probe: ColorProbe?, pixelBuffer: CVPixelBuffer) {
        guard let probe else { return }
        let final = colorAttachmentSummary(pixelBuffer)
        Task { @MainActor [weak self] in
            self?.configureLayerColorspace()
            self?.logColorProbe(probe, final: final)
        }
    }

    func probeDisplayTransition(headroom: (@MainActor () -> (current: Double, potential: Double))? = nil) {
        colorDisplayProbeTask?.cancel()
        logDisplayTransition(after: 0, headroom: headroom?())
        guard isHDRActive else { return }
        colorDisplayProbeTask = Task { @MainActor [weak self] in
            for seconds in [1, 3, 5] {
                do { try await Task.sleep(for: .seconds(seconds == 1 ? 1 : 2)) } catch { return }
                guard let self, self.isHDRActive else { return }
                self.logDisplayTransition(after: seconds, headroom: headroom?())
            }
        }
    }

    private func displayHeadroom() -> (current: Double, potential: Double) {
        let view = displayLayer?.delegate as? NSView
        let screen = view?.window?.screen ?? NSScreen.main
        return (Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
    }

    private func logDisplayTransition(after seconds: Int, headroom: (current: Double, potential: Double)?) {
        let values = headroom ?? displayHeadroom()
        let outputHDR = VideoColorDescription.hdrDisplayOutput(inputHDR: isHDRActive, currentEDR: values.current)
        Diag.notice("Colour display transition: after=\(seconds)s currentEDR=\(values.current) "
            + "potentialEDR=\(values.potential) hdrInput=\(isHDRActive) hdrOutput=\(outputHDR) "
            + "preferredDynamicRange=\(displayLayer?.preferredDynamicRange.rawValue ?? "absent")", "Stream")
        if seconds == 5 && isHDRActive && !outputHDR {
            Diag.warn("HDR input has no EDR headroom: currentEDR=\(values.current) "
                + "potentialEDR=\(values.potential)", "Stream")
        }
    }

    private func logColorProbe(_ probe: ColorProbe, final: String) {
        let (current, potential) = displayHeadroom()
        let csc = (requestedColorSpace.cValue << 1) | requestedColorRange.cValue
        let depth = probe.videoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT != 0 ? 10 : 8
        let format = String(probe.videoFormat, radix: 16)
        let codec = Self.codecLabel(for: probe.videoFormat)
        let pixelFormat = fourCCString(from: probe.state.pixelFormat)
        Diag.notice("Colour probe: requestedCSC=\(csc) colorSpace=\(requestedColorSpace.cValue) "
            + "colorRange=\(requestedColorRange.cValue) codec=\(codec) videoFormat=0x\(format) bitDepth=\(depth) "
            + "controlHDR=\(probe.state.controlHDR) pixelFormat=\(pixelFormat) "
            + "resolved=\(probe.state.resolved.summary)", "Stream")
        Diag.notice("Colour probe raw format: \(probe.rawFormat)", "Stream")
        Diag.notice("Colour probe raw attachments: \(probe.rawAttachments)", "Stream")
        Diag.notice("Colour probe final attachments: \(final)", "Stream")
        let outputHDR = VideoColorDescription.hdrDisplayOutput(
            inputHDR: probe.state.resolved.isHDR, currentEDR: Double(current))
        Diag.notice("Colour probe display: currentEDR=\(current) potentialEDR=\(potential) "
            + "hdrInput=\(probe.state.resolved.isHDR) hdrOutput=\(outputHDR) "
            + "preferredDynamicRange=\(displayLayer?.preferredDynamicRange.rawValue ?? "absent")", "Stream")
    }
}
