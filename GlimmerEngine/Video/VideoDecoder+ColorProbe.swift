// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS) || GLIMMER_DIAGNOSTICS
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

    @discardableResult
    nonisolated func finishColorProbe(_ probe: ColorProbe?, pixelBuffer: CVPixelBuffer) -> Task<Void, Never>? {
        guard let probe else { return nil }
        let final = colorAttachmentSummary(pixelBuffer)
        let generation = attachmentGeneration
        return Task { @MainActor [weak self] in
            guard let self, self.attachmentGeneration == generation else { return }
            self.configureLayerColorspace()
            self.logColorProbe(probe, final: final)
        }
    }

    func probeDisplayTransition(headroom: (@MainActor () -> (current: Double, potential: Double))? = nil) {
        colorDisplayProbeTask?.cancel()
        logDisplayTransition(after: 0, headroom: headroom?())
        guard isHDRActive else { return }
        let sleep = colorProbeSleep
        colorDisplayProbeTask = Task { @MainActor [weak self] in
            for seconds in [1, 3, 5] {
                do { try await sleep(.seconds(seconds == 1 ? 1 : 2)) } catch { return }
                guard let self, self.isHDRActive else { return }
                self.logDisplayTransition(after: seconds, headroom: headroom?())
            }
        }
    }

    private var layerDynamicRange: String { displayLayer?.dynamicRangeLabel ?? "absent" }

    private func displayHeadroom() -> (current: Double, potential: Double) {
        let display = displayInfo()
        return (display?.currentHeadroom ?? 1, display?.potentialHeadroom ?? 1)
    }

    private func logDisplayTransition(after seconds: Int, headroom: (current: Double, potential: Double)?) {
        let values = headroom ?? displayHeadroom()
        let outputHDR = VideoColorDescription.hdrDisplayOutput(inputHDR: isHDRActive, currentEDR: values.current)
        colorProbeLog("Colour display transition: after=\(seconds)s currentEDR=\(values.current) "
            + "potentialEDR=\(values.potential) hdrInput=\(isHDRActive) hdrOutput=\(outputHDR) "
            + "preferredDynamicRange=\(layerDynamicRange)", false)
        if seconds == 5 && isHDRActive && !outputHDR {
            colorProbeLog("HDR input has no EDR headroom: currentEDR=\(values.current) "
                + "potentialEDR=\(values.potential)", true)
        }
    }

    private func logColorProbe(_ probe: ColorProbe, final: String) {
        let (current, potential) = displayHeadroom()
        let csc = (requestedColorSpace.cValue << 1) | requestedColorRange.cValue
        let depth = probe.videoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT != 0 ? 10 : 8
        let format = String(probe.videoFormat, radix: 16)
        let codec = Self.codecLabel(for: probe.videoFormat)
        let pixelFormat = fourCCString(from: probe.state.pixelFormat)
        colorProbeLog("Colour probe: requestedCSC=\(csc) colorSpace=\(requestedColorSpace.cValue) "
            + "colorRange=\(requestedColorRange.cValue) codec=\(codec) videoFormat=0x\(format) bitDepth=\(depth) "
            + "controlHDR=\(probe.state.controlHDR) pixelFormat=\(pixelFormat) "
            + "resolved=\(probe.state.resolved.summary)", false)
        colorProbeLog("Colour probe raw format: \(probe.rawFormat)", false)
        colorProbeLog("Colour probe raw attachments: \(probe.rawAttachments)", false)
        colorProbeLog("Colour probe final attachments: \(final)", false)
        let outputHDR = VideoColorDescription.hdrDisplayOutput(
            inputHDR: probe.state.resolved.isHDR, currentEDR: Double(current))
        colorProbeLog("Colour probe display: currentEDR=\(current) potentialEDR=\(potential) "
            + "hdrInput=\(probe.state.resolved.isHDR) hdrOutput=\(outputHDR) "
            + "preferredDynamicRange=\(layerDynamicRange)", false)
    }
}

#endif
