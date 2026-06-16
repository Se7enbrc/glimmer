//
//  VideoDecoder+HDR.swift
//
//  HDR pipeline extension to `VideoDecoder`. Owns the bits that decide what
//  CGColorSpace to attach, build the HDR10 MDCV/CLL metadata blobs, drive
//  AVSampleBufferDisplayLayer.preferredDynamicRange, and provide the
//  first-frame diagnostic probe.
//
//  Source-of-truth implementation contract is `vt_avsamplelayer.mm` from
//  moonlight-qt; see the call-site comments for the exact line references.

import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

extension VideoDecoder {

    // MARK: - Display-layer configuration

    /// Set the AVSampleBufferDisplayLayer's `preferredDynamicRange` based
    /// on the negotiated stream format + the host's HDR-mode signal. Called
    /// once at stream start from handleStart(), and again from setHDR() if
    /// the host flips HDR mid-stream.
    ///
    /// `preferredDynamicRange` (macOS 26+ replacement for the older
    /// `wantsExtendedDynamicRangeContent` boolean):
    ///   * `.high`     - engage full EDR. Used when the stream is 10-bit
    ///                   AND the host has signalled HDR mode. Per Apple's
    ///                   header, this is the right choice for "situations
    ///                   where the user is expected to be focused on the
    ///                   media" - game streaming is exactly that.
    ///   * `.standard` - SDR. Used for everything else.
    ///
    /// The layer reads the per-frame CGColorSpace off the CVPixelBuffer's
    /// `kCVImageBufferCGColorSpaceKey` attachment (set in
    /// `attachFallbackColorspaceIfNeeded` for untagged-bitstream hosts,
    /// otherwise propagated from the bitstream's VUI by VT). There is no
    /// `colorspace` property on AVSampleBufferDisplayLayer itself -
    /// moonlight-qt's vt_avsamplelayer.mm uses the same per-buffer path.
    @MainActor
    func configureLayerColorspace() {
        guard let layer = displayLayer else { return }

        let is10Bit = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT) != 0
        let active = is10Bit && hdrEnabled

        // preferredDynamicRange is safe to set on every call (idempotent
        // when the value doesn't change). We still guard the first-call
        // log so we can spot stream-start vs. mid-stream HDR transitions
        // in the trace.
        let preferred: CALayer.DynamicRange = active ? .high : .standard
        layer.preferredDynamicRange = preferred

        // Also set the layer's own compositing colorspace. moonlight-qt's
        // vt_avsamplelayer.mm doesn't do this - they rely solely on the
        // per-buffer kCVImageBufferCGColorSpaceKey attachment - but on
        // macOS 26 the EDR-engagement heuristic also reads
        // layer.colorspace. Without it, even with preferredDynamicRange =
        // .high and PQ-tagged content arriving, macOS keeps
        // NSScreen.maximumEDR at 1.0 (display stays in SDR) and tonemaps
        // the PQ codes down → dark/crushed shadows. Setting it to the
        // extended-linear ITU-R 2020 space tells the compositor "this
        // layer composites in HDR." When HDR is off, we clear the property
        // so the layer composites in default sRGB.
        //
        // KVC required: `CALayer.colorspace: CGColorSpace?` is a typed
        // property on the parent class, but Apple's Swift import surface
        // elides it for AVSampleBufferDisplayLayer (the subclass), so a
        // direct `layer.colorspace = ...` fails to compile. The Objective-C
        // runtime still has the setter (inherited and KVC-visible);
        // moonlight-qt reaches it from Objective-C++. We don't have an
        // Objective-C++ bridge for a single call site, so KVC stays until
        // the Swift import widens. Re-confirmed against the released
        // macOS 26 SDK.
        if active {
            if let cs = CGColorSpace(name: CGColorSpace.itur_2100_PQ) {
                layer.setValue(cs, forKey: "colorspace")
            }
        } else {
            layer.setValue(nil, forKey: "colorspace")
        }
        if !didConfigureLayerOnce {
            didConfigureLayerOnce = true
            let formatHex = String(self.streamVideoFormat, radix: 16)
            log.info(
                "Layer preferredDynamicRange=\(preferred.rawValue) is10Bit=\(is10Bit) (videoFormat=0x\(formatHex))"
            )
        } else {
            log.info("Layer preferredDynamicRange updated to \(preferred.rawValue) (HDR active=\(active))")
        }

        // Surface effective HDR state. We treat "HDR mode + 10-bit" as
        // active. The panel may still tonemap to SDR if HDR is off in
        // System Settings, but the pipeline is "on".
        if active != isHDRActive {
            isHDRActive = active
            onHDRActiveChanged?(active)
            let headroom = displayEDRHeadroom()
            log.info("HDR active=\(active) is10Bit=\(is10Bit) hdrEnabled=\(self.hdrEnabled) edrHeadroom=\(headroom)")
            if active && headroom <= 1.0 {
                log.warning(
                    """
                    PQ stream active but display reports no EDR headroom (max=\(headroom)). \
                    The OS will tone-map to SDR; turn on HDR in System Settings → Displays \
                    for the full experience.
                    """
                )
            }
        }
    }

    // MARK: - HDR metadata

    /// Pull mastering-display + content-light from `LiGetHdrMetadata` and
    /// encode them in the EXACT byte layout the HDR10 MDCV/CLL SEI uses.
    /// moonlight-qt's vt_base.mm::setHdrMode builds the same blobs and
    /// hands them to CVBufferSetAttachment with
    /// `kCVImageBufferMasteringDisplayColorVolumeKey` /
    /// `kCVImageBufferContentLightLevelInfoKey`. We mirror it byte-for-byte
    /// so the OS's compositor sees identical input to what it gets from
    /// moonlight-qt.
    ///
    /// Layout - all big-endian:
    ///
    ///   MDCV (mastering-display-color-volume), 24 bytes:
    ///     primaries[3]  (G, B, R order - 3 × { uint16 x, uint16 y })
    ///     whitePoint    ({ uint16 x, uint16 y })
    ///     luminance_max (uint32, in 1/10000-nit units → multiply nits × 10000)
    ///     luminance_min (uint32, already in 1/10000-nit units per Limelight.h)
    ///
    ///   CLL (content-light-level), 4 bytes:
    ///     max_content_light_level         (uint16, in cd/m²)
    ///     max_frame_average_light_level   (uint16, in cd/m²)
    ///
    /// SS_HDR_METADATA stores primaries in RGB order; HDR10 wants GBR. We
    /// reorder here. Same swap moonlight-qt does in VTBaseRenderer::setHdrMode.
    func refreshHDRMetadataFromHost() {
        // Pull the flattened HDR10 static metadata through the backend (was the
        // gl_get_hdr_metadata C shim around LiGetHdrMetadata). HdrMetadata is
        // the Limelight-free value type with the exact same fields/units.
        guard let hdr = backend?.hdrMetadata() else {
            log.info("hdrMetadata() returned nil; no HDR metadata to attach")
            cachedMDCV = nil
            cachedContentLightLevel = nil
            return
        }

        // Mastering display color volume - only meaningful if the host
        // populated primaries. Sunshine fills these from the OS-reported
        // monitor EDID; GFE may leave them zeroed.
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
            cachedMDCV = mdcv
        } else {
            cachedMDCV = nil
        }

        // Content light level - host may omit these even when MDCV is present
        // (GFE typically does). The OS will tonemap conservatively from MDCV
        // alone, which is still better than nothing.
        if hdr.maxContentLightLevel != 0 && hdr.maxFrameAverageLightLevel != 0 {
            var cll = Data()
            cll.reserveCapacity(4)
            appendBE16(&cll, hdr.maxContentLightLevel)
            appendBE16(&cll, hdr.maxFrameAverageLightLevel)
            cachedContentLightLevel = cll
        } else {
            cachedContentLightLevel = nil
        }

        let mdcvBytes = self.cachedMDCV?.count ?? 0
        let cllBytes = self.cachedContentLightLevel?.count ?? 0
        log.info(
            """
            HDR metadata refreshed: mdcv=\(mdcvBytes)B cll=\(cllBytes)B \
            maxLum=\(hdr.maxDisplayLuminance) maxCLL=\(hdr.maxContentLightLevel)
            """
        )
    }

    /// Returns the maximum EDR headroom the layer's current screen reports.
    /// 1.0 → SDR / HDR-off; > 1.0 → HDR-capable and currently in HDR mode.
    /// Used to emit a user-visible warning when an HDR stream is started
    /// but the display isn't in HDR mode - we still engage the PQ pipeline
    /// (the OS tonemaps for us), the user just won't see the full bright-
    /// highlight effect.
    @MainActor
    func displayEDRHeadroom() -> CGFloat {
        // Walk up the layer hierarchy to the host NSWindow's NSScreen to
        // find the display the layer is composited on. Fall back to the
        // main screen when the layer isn't bound yet.
        var view: NSView?
        if let layer = displayLayer, let delegate = layer.delegate as? NSView {
            view = delegate
        }
        let screen = view?.window?.screen ?? NSScreen.main
        return screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
    }

    // MARK: - Colorspace derivation

    /// Derive a short, log-friendly key describing the effective colorspace
    /// we should attach to this pixel buffer. Mirrors moonlight-qt's
    /// vt_avsamplelayer.mm:222-247 logic: read the bitstream-declared
    /// primaries + transfer from the buffer's attachments and map to one
    /// of the four CGColorSpaces it cares about. Falls back to the stream
    /// format + host HDR-mode signal when the bitstream didn't tag itself.
    nonisolated func derivedColorSpaceKey(for pixelBuffer: CVPixelBuffer)
        -> String {
        // Read what VT propagated from the bitstream's VUI / OBU into the
        // pixel buffer's attachments. These come through as CFStrings with
        // values like ITU_R_2020 / SMPTE_ST_2084_PQ. Presence of either
        // attachment means the bitstream tagged itself; absence means the
        // VUI / color_config flags were 0 (no color info) and VT had nothing
        // to propagate.
        let primariesRaw =
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
            as? String
        let transferRaw =
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
            as? String

        let primaries = primariesRaw ?? ""
        let transfer = transferRaw ?? ""
        let streamDeclaredColor = !primaries.isEmpty || !transfer.isEmpty

        let is10Bit = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT) != 0

        // OVERRIDE: when the host has signalled HDR mode AND we're decoding a
        // 10-bit stream, the content IS PQ regardless of how the bitstream's
        // VUI / OBU happens to tag itself. Sunshine's encoder ships Main10 PQ
        // content with BT.709 tags in the VUI on a number of GPU/driver combos
        // (known issue, never fixed upstream) - trusting the VUI here paints
        // PQ codes through an sRGB pipeline, which is exactly the "sandy grey,
        // washed out" look. moonlight-qt's `getFrameColorspace` consults the
        // host-HDR flag before the VUI for the same reason. When LiSetHdrMode
        // flips back to false (host returns to SDR mid-stream), the override
        // falls away and we honour the bitstream tag.
        if is10Bit && hdrEnabled {
            return "itur_2100_PQ"
        }

        // Honor the stream's own VUI / OBU color tags when present and the
        // host isn't telling us HDR is active.
        if streamDeclaredColor {
            // BT.2020 family
            if primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
                if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                    return "itur_2100_PQ"
                }
                return "itur_2020"
            }
            // BT.709
            if primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) {
                return "itur_709"
            }
            // Some other declared triple we don't have a CGColorSpace for
            // (P3, SMPTE-C, etc.). Fall through to the format-hint fallback
            // rather than guessing; sRGB-via-itur_709 is the safer default.
        }

        // Stream did NOT declare color (VUI / OBU color_description_present_flag
        // = 0) AND host hasn't engaged HDR. Use the negotiated stream format as
        // the last source of truth - same moonlight-qt fallback for
        // AVCOL_SPC_UNSPECIFIED + HDR off.
        if is10Bit {
            return "itur_2020"
        }
        // 8-bit untagged → Sunshine defaults to BT.709, prefer that.
        return "itur_709"
    }

    /// Create the CGColorSpace matching a derived-key string. Cached at the
    /// call site via `lastColorSpace` so we don't re-allocate per frame -
    /// matches moonlight-qt's `m_ColorSpace` + `m_LastColorSpace` pattern.
    nonisolated func makeCGColorSpace(forKey key: String) -> CGColorSpace? {
        switch key {
        case "itur_2100_PQ":
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case "itur_2020":
            return CGColorSpace(name: CGColorSpace.itur_2020)
        case "itur_709":
            return CGColorSpace(name: CGColorSpace.itur_709)
        case "srgb":
            return CGColorSpace(name: CGColorSpace.sRGB)
        default:
            return CGColorSpace(name: CGColorSpace.itur_709)
        }
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

    // MARK: - First-frame diagnostic probe

    /// Diagnostic: log what the first decoded CVPixelBuffer claims about its
    /// own color metadata, AND the live HDR pipeline state (host signal,
    /// stream bit depth, layer preferredDynamicRange, NSScreen EDR headroom).
    ///
    /// Read this with:
    ///   log show --predicate 'process == "Glimmer"' --info --last 1m
    ///       --style compact
    /// or while streaming:
    ///   log stream --predicate 'process == "Glimmer"' --info --style compact
    ///
    /// When the user reports "looks overbright / washed out", this single
    /// log entry is the diagnostic answer key:
    ///   * If bitstreamTransfer = SMPTE_ST_2084_PQ and derivedKey =
    ///     itur_2100_PQ → pipeline is correct.
    ///   * If derivedKey = itur_2100_PQ but EDR headroom = 1.0 → display
    ///     isn't in HDR mode. System Settings → Displays → HDR Video.
    ///   * If derivedKey = itur_2100_PQ but the layer's preferredDynamic-
    ///     Range = .standard on macOS 26+ → that property is unset and the
    ///     compositor is SDR-mapping the PQ buffer.
    ///   * If bitstreamTransfer = unknown but we're streaming Main10 with
    ///     LiSetHdrMode(true) → Sunshine is shipping untagged PQ video and
    ///     our untagged-fallback to itur_2100_PQ kicks in (this is fine).
    nonisolated func probeAndLogPixelBufferAttachments(
        _ pixelBuffer: CVPixelBuffer,
        derivedKey: String
    ) {
        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let pfStr = fourCCString(from: pf)
        // Pixel-buffer dimensions can differ from the negotiated stream
        // resolution (codec block padding, host-side virtual-display
        // mismatch upscaling the source into a different aspect, etc.).
        // The negotiated number lives in `Decoder setup:` upstream; this
        // is what we ACTUALLY got out of VideoToolbox.
        let pbWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pbHeight = CVPixelBufferGetHeight(pixelBuffer)
        let pbAspect = Double(pbWidth) / max(1.0, Double(pbHeight))

        let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any]
        let primaries =
            (attachments?[kCVImageBufferColorPrimariesKey as String] as? String) ?? "unknown"
        let transfer =
            (attachments?[kCVImageBufferTransferFunctionKey as String] as? String) ?? "unknown"
        let matrix =
            (attachments?[kCVImageBufferYCbCrMatrixKey as String] as? String) ?? "unknown"
        let hasMDCV =
            attachments?[kCVImageBufferMasteringDisplayColorVolumeKey as String] != nil
        let hasCLL =
            attachments?[kCVImageBufferContentLightLevelInfoKey as String] != nil

        // Attached CGColorSpace at this point should be the one we just set.
        // Apple returns the colorspace ref; we read its name (a CFString) so
        // we can log the actual ID - e.g. "kCGColorSpaceITUR_2100_PQ".
        var attachedCSName = "absent"
        if let csAny = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferCGColorSpaceKey, nil) {
            // CVBuffer attachment is typed as CFTypeRef; check before cast so
            // an unexpected attachment value (extremely unlikely for this key,
            // but Apple's contract allows it) logs as a diagnostic rather
            // than trapping the decode thread.
            if CFGetTypeID(csAny) == CGColorSpace.typeID {
                let cs = unsafeDowncast(csAny, to: CGColorSpace.self)
                if let name = cs.name {
                    attachedCSName = (name as String)
                } else {
                    attachedCSName = "<unnamed CGColorSpace>"
                }
            } else {
                attachedCSName = "<unexpected CFType: \(CFGetTypeID(csAny))>"
            }
        }

        let isFullRange =
            (pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            || (pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            || (pf == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
            || (pf == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)

        let is10Bit = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_MASK_10BIT) != 0
        let hostHDR = self.hdrEnabled

        // Bundle the bitstream / pixel-buffer facts gathered off-main so the
        // main-thread geometry+EDR probe can be a focused helper.
        let facts = FirstFrameProbeFacts(
            pf: pf, pfStr: pfStr,
            pbWidth: pbWidth, pbHeight: pbHeight, pbAspect: pbAspect,
            primaries: primaries, transfer: transfer, matrix: matrix,
            hasMDCV: hasMDCV, hasCLL: hasCLL,
            attachedCSName: attachedCSName, isFullRange: isFullRange,
            is10Bit: is10Bit, hostHDR: hostHDR, derivedKey: derivedKey)

        // Hop to main for layer + screen probes (NSScreen + AVSample-
        // BufferDisplayLayer.preferredDynamicRange both require main).
        Task { @MainActor [weak self] in
            self?.logFirstFrameProbe(facts)
        }

        // Re-probe the EDR headroom values at 1s, 3s, and 5s after the first
        // frame. macOS engages display HDR mode asynchronously in response
        // to PQ-tagged content arriving at the layer - the first-frame
        // probe almost always reads 1.0 because the engagement hasn't
        // happened yet. If we still read 1.0 after 5s of streaming PQ
        // content into an EDR layer, the display is in SDR mode in System
        // Settings (or macOS thinks it can't HDR) and no amount of
        // pipeline correction will give us highlights.
        for delay in [1.0, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let layer = self.displayLayer
                let view = layer?.delegate as? NSView
                let screen = view?.window?.screen ?? NSScreen.main
                let now = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
                let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                self.log.info(
                    """
                    EDR re-probe @ \(delay, privacy: .public)s: \
                    maximumEDR=\(now, privacy: .public) \
                    potentialEDR=\(potential, privacy: .public)
                    """
                )
            }
        }
    }

    /// Off-main facts about the first decoded frame: everything the probe
    /// reads from the CVPixelBuffer + negotiated stream format before hopping
    /// to the main actor for the layer/screen geometry half. Sendable so it
    /// can cross into the `@MainActor` log helper under strict concurrency.
    private struct FirstFrameProbeFacts: Sendable {
        let pf: OSType
        let pfStr: String
        let pbWidth: Int
        let pbHeight: Int
        let pbAspect: Double
        let primaries: String
        let transfer: String
        let matrix: String
        let hasMDCV: Bool
        let hasCLL: Bool
        let attachedCSName: String
        let isFullRange: Bool
        let is10Bit: Bool
        let hostHDR: Bool
        let derivedKey: String
    }

    /// Main-thread half of the first-frame probe: read the layer's dynamic-
    /// range/colorspace + the resolved NSScreen's EDR headroom and geometry,
    /// then emit the single diagnostic log entry. Split out of
    /// `probeAndLogPixelBufferAttachments` to keep each unit focused.
    @MainActor
    private func logFirstFrameProbe(_ facts: FirstFrameProbeFacts) {
        let layer = self.displayLayer
        let prefRange: String = layer?.preferredDynamicRange.rawValue ?? "n/a"
        // AVSampleBufferDisplayLayer doesn't surface `colorspace` in
        // the Swift import surface (see comment on the setter above), so
        // KVC stays. Guard with CFGetTypeID to avoid an `as!` trap when
        // the value comes back as something unexpected (would only happen
        // on an SDK regression but we don't want decode-thread crashes).
        let layerColorspaceName: String = {
            guard let csAny = layer?.value(forKey: "colorspace") as CFTypeRef?,
                  CFGetTypeID(csAny) == CGColorSpace.typeID else {
                return "n/a"
            }
            let cs = unsafeDowncast(csAny, to: CGColorSpace.self)
            return (cs.name as? String) ?? "n/a"
        }()
        // EDR headroom: 1.0 → display is in SDR; >1.0 → HDR is engaged.
        // This is the single most diagnostic line for "the panel looks
        // washed out" - if this isn't > 1.0, no amount of pipeline
        // tagging will get the user inky blacks + 1000-nit highlights.
        let screen = layer?.delegate as? NSView
        let resolvedScreen = (screen?.window?.screen ?? NSScreen.main)
        let edrHeadroom: CGFloat =
            resolvedScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        // The "potential" value is what the panel CAN do at peak HDR,
        // even when not currently engaged. If this is > 1.0 but
        // `maximumEDR` is 1.0, the display is HDR-capable but macOS
        // hasn't bumped into HDR mode yet - usually because the layer
        // hasn't been compositing HDR-tagged content long enough OR
        // System Settings has "High Dynamic Range" turned off.
        let edrPotential: CGFloat =
            resolvedScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let edrReference: CGFloat =
            resolvedScreen?.maximumReferenceExtendedDynamicRangeColorComponentValue ?? 1.0
        let screenName = resolvedScreen?.localizedName ?? "unknown"

        // Layer + window bounds so we can compare aspects to the
        // pixel-buffer aspect. resizeAspect on the AVSampleBufferDisplayLayer
        // will produce letterbox bars whenever pbAspect != layerAspect.
        let layerW = layer?.bounds.width ?? 0
        let layerH = layer?.bounds.height ?? 0
        let layerAspect = Double(layerW) / max(1.0, Double(layerH))
        let winW = (screen?.window?.frame.width) ?? 0
        let winH = (screen?.window?.frame.height) ?? 0
        let screenFrameW = resolvedScreen?.frame.width ?? 0
        let screenFrameH = resolvedScreen?.frame.height ?? 0
        let backingScale = resolvedScreen?.backingScaleFactor ?? 0
        let safeTop = resolvedScreen?.safeAreaInsets.top ?? 0
        // Panel's true physical pixel count via the active display mode.
        // For a 14" MBP in default scaled mode this should be 3024×1964;
        // anything else means the user is in a non-standard scale.
        var panelPxW: Int = 0
        var panelPxH: Int = 0
        if let displayID = resolvedScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let mode = CGDisplayCopyDisplayMode(displayID) {
            panelPxW = mode.pixelWidth
            panelPxH = mode.pixelHeight
        }

        let videoFormatHex = String(self.streamVideoFormat, radix: 16)
        let pfHex = String(facts.pf, radix: 16)
        let rangeLabel = facts.isFullRange ? "Full" : "Video"
        let is10Bit = facts.is10Bit
        let pfStr = facts.pfStr
        let pbWidth = facts.pbWidth
        let pbHeight = facts.pbHeight
        let pbAspect = facts.pbAspect
        self.log.info(
            """
            First-frame HDR probe:
              hostHDR (LiSetHdrMode) = \(facts.hostHDR, privacy: .public)
              streamFormat is10Bit   = \(is10Bit, privacy: .public) (videoFormat=0x\(videoFormatHex, privacy: .public))
              pixelFormat            = '\(pfStr, privacy: .public)' (0x\(pfHex, privacy: .public)) range=\(rangeLabel, privacy: .public)
              pixelBuffer            = \(pbWidth, privacy: .public)x\(pbHeight, privacy: .public) (aspect=\(pbAspect, privacy: .public))
              layer.bounds           = \(layerW, privacy: .public)x\(layerH, privacy: .public) (aspect=\(layerAspect, privacy: .public))
              window.frame           = \(winW, privacy: .public)x\(winH, privacy: .public)
              screen.frame           = \(screenFrameW, privacy: .public)x\(screenFrameH, privacy: .public) points
              screen.backingScale    = \(backingScale, privacy: .public)
              screen.safeAreaTop     = \(safeTop, privacy: .public)
              panel.physicalPixels   = \(panelPxW, privacy: .public)x\(panelPxH, privacy: .public)
              bitstreamPrimaries     = \(facts.primaries, privacy: .public)
              bitstreamTransfer      = \(facts.transfer, privacy: .public)
              bitstreamMatrix        = \(facts.matrix, privacy: .public)
              derivedColorSpaceKey   = \(facts.derivedKey, privacy: .public)
              attachedCGColorSpace   = \(facts.attachedCSName, privacy: .public)
              MDCV attached          = \(facts.hasMDCV, privacy: .public)
              CLL attached           = \(facts.hasCLL, privacy: .public)
              layer.preferredDynamicRange = \(prefRange, privacy: .public)
              layer.colorspace            = \(layerColorspaceName, privacy: .public)
              NSScreen                = \(screenName, privacy: .public)
              NSScreen.maximumEDR     = \(edrHeadroom, privacy: .public)
              NSScreen.potentialEDR   = \(edrPotential, privacy: .public)
              NSScreen.referenceEDR   = \(edrReference, privacy: .public)
            """)
    }

    /// FourCC encoder for diagnostic logging. e.g. `'x420'` for video-range
    /// 10-bit 4:2:0 biplanar. Prints non-printable bytes as hex escapes.
    nonisolated func fourCCString(from code: OSType) -> String {
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
