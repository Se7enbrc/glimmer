//
//  VideoDecoder.swift
//
//  VideoToolbox + AVSampleBufferDisplayLayer video pipeline for Glimmer.
//
//  This file owns the `VideoDecoder` class core: lifecycle, VT session,
//  packet enqueue, and layer attachment. The HDR pipeline (MDCV/CLL parsing,
//  PQ colorspace setup, EDR engagement, first-frame probe) lives in
//  `VideoDecoder+HDR.swift`. Bitstream parsing (H.264/HEVC/AV1 NAL walking,
//  parameter-set assembly, AVCC conversion, sample buffer construction)
//  lives in `VideoDecoder+Bitstream.swift`. The per-frame stats counters
//  (`StatsCollector`) live in `StatsCollector.swift`.
//
//  Architecture overview
//  ---------------------
//  The native backend hands us Annex-B elementary stream data (H.264 / HEVC /
//  AV1) on its internal receive threads via the decoder-renderer sink. We
//  parse the bitstream into a CMSampleBuffer,
//  push it through a VTDecompressionSession (HW accelerated when the
//  capability check passes), and enqueue the resulting CVPixelBuffer onto an
//  AVSampleBufferDisplayLayer for the OS to render.
//
//  Why no Metal shader / why AVSampleBufferDisplayLayer
//  ----------------------------------------------------
//  This file used to drive a CAMetalLayer through a custom MSL fragment
//  shader doing BT.2020 NCL YUV→RGB, range scaling, chroma cositing, and
//  PQ-tagged output for HDR. Three rounds of tuning later, HDR was still
//  visibly wrong on a 4K240 HDR panel: overbright midtones, washed highlights,
//  milky blacks vs. moonlight-qt on the same host/display/content showing
//  inky blacks and full peak luminance.
//
//  The cause was architectural, not a CSC math bug. moonlight-qt's
//  HDR-correct macOS path is `vt_avsamplelayer.mm`, not `vt_metal.mm`. The
//  latter is a Metal-shader fallback (used on Linux/Windows variants of
//  their stack); the former is what runs on real macOS clients. It uses
//  AVSampleBufferDisplayLayer, which:
//
//    * Takes a CMSampleBuffer wrapping the CVPixelBuffer that VT produces.
//    * Reads the pixel buffer's `kCVImageBufferColorPrimariesKey`,
//      `kCVImageBufferTransferFunctionKey`, `kCVImageBufferYCbCrMatrixKey`
//      and `kCVImageBufferMasteringDisplayColorVolumeKey` /
//      `kCVImageBufferContentLightLevelInfoKey` attachments to know what
//      the pixels mean.
//    * Reads the CMFormatDescription's extensions for HDR metadata when
//      the pixel buffer doesn't carry it.
//    * Reads `layer.colorspace` (kCGColorSpaceITUR_2100_PQ for HDR) to know
//      how to interpret the bits at composite time.
//    * Does YUV→RGB conversion, PQ EOTF, and EDR tone-mapping in the OS's
//      own display pipeline against the panel's actual peak luminance.
//
//  There is no shader. There is no manual CSC matrix. The OS owns the
//  pipeline end-to-end, and that's the only way to get color-correct HDR
//  on macOS without re-implementing the entire macOS HDR compositor in
//  Metal - which Apple specifically does NOT want us to do, see
//  "Using Color Spaces to Display HDR Content" in the Metal docs:
//  > "Don't perform tone mapping in your shader. AVSampleBufferDisplayLayer
//  >  applies tone mapping based on the current EDR headroom."
//
//  What this file does now
//  -----------------------
//   1. Decode H.264 / HEVC / AV1 bitstreams with VTDecompressionSession.
//   2. For tagged streams: VT already attaches the right
//      primaries/transfer/matrix to the produced CVPixelBuffer.
//   3. For untagged streams (some Sunshine builds ship video without VUI
//      colour info): we attach the right CGColorSpace based on what we
//      know from the stream config (HDR mode + 10-bit → BT.2020/PQ;
//      otherwise BT.709).
//   4. When the host signals HDR via LiSetHdrMode, we pull mastering-display
//      + content-light metadata via LiGetHdrMetadata and attach it as
//      CMFormatDescription extensions (MDCV / CLL), in the exact GBR-order
//      big-endian byte layout HDR10 uses - matching moonlight-qt's
//      vt_base.mm::setHdrMode byte-for-byte.
//   5. Wrap the CVPixelBuffer + CMFormatDescription in a CMSampleBuffer
//      and enqueue it on the AVSampleBufferDisplayLayer.
//   6. Handle the layer's `AVQueuedSampleBufferRenderingStatusFailed` state
//      by flushing and rebuilding the format description - without this,
//      macOS 14+ silently stops rendering after the first decode error.
//
//  Threading model
//  ---------------
//   * setup/start/stop/cleanup/submitDecodeUnit fire on the native backend's
//     receive threads. We never block them.
//   * Bitstream → CMSampleBuffer happens inline in submitDecodeUnit.
//   * The VTDecompressionSession outputs on the decode dispatch queue.
//     That callback builds the CMSampleBuffer and enqueues it directly on
//     the AVSampleBufferDisplayLayer - no display-link, no mailbox, no
//     render queue. AVSampleBufferDisplayLayer owns the v-sync pacing.
//   * Display-layer mutations (colorspace, wantsEDR, flush) happen on the
//     main actor.

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os
@MainActor
public final class VideoDecoder {

    // MARK: Public API

    public init() {
        self.log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.VideoDecoder")
    }

    /// Safety-net teardown for the VTDecompressionSession. Normally
    /// `StreamSession.stop()` calls `teardown()` explicitly so the session
    /// dies in the right order against the backend stop - but if a
    /// VideoDecoder ever escapes that path (early-exit error in start(),
    /// orphan reference in a stalled Task, future refactor), the
    /// VTDecompressionSession would leak: it holds an Apple-side retain on
    /// the IOSurface pool that backs every decoded pixel buffer, and that
    /// pool is several MB per session. Drain it here as a backstop.
    ///
    /// Marked `isolated deinit` so we can read the MainActor-isolated
    /// `decompressionSession` slot. `VTDecompressionSessionInvalidate` is
    /// documented as callable from any thread, so the deinit invokes it
    /// without further hopping.
    ///
    /// Since the VT output callback now holds a +1 retain on self via its
    /// refcon (see `ensureDecompressionSession`), a *live* session pins the
    /// decoder alive - so reaching this deinit with a non-nil session is
    /// unreachable in normal operation (the retain keeps refcount > 0). The
    /// branch below stays as a pure defensive backstop; it deliberately does
    /// NOT release the refcon, because a non-nil refcon here would mean
    /// refcount never hit zero and we couldn't be in deinit at all.
    isolated deinit {
        if let session = self.decompressionSession {
            VTDecompressionSessionInvalidate(session)
            self.decompressionSession = nil
            log.info("VideoDecoder deinit invalidated dangling decompression session")
        }
    }

    /// Whether the host has signalled HDR mode via LiSetHdrMode. False by
    /// default - driven by `setHDR(enabled:)` from CONNECTION_LISTENER_CALLBACKS.
    ///
    /// `nonisolated(unsafe)` because the VT output callback reads this from
    /// the decode queue when deciding the untagged-bitstream fallback
    /// colorspace. Writes happen on the main actor from setHDR(); reads
    /// elsewhere are eventually-consistent, which is correct - when HDR
    /// flips on, the next-frame fallback may briefly attach BT.2020 instead
    /// of PQ before catching up, and that's visually indistinguishable.
    /// A Bool load/store is naturally atomic on every supported arch.
    nonisolated(unsafe) internal var hdrEnabled: Bool = false

    /// Whether HDR is *actually* active end-to-end: host said yes, stream is
    /// 10-bit, and the layer's colorspace is the PQ space. Surfaces upward
    /// via `onHDRActiveChanged` so the SwiftUI layer can show an HDR chip
    /// while streaming.
    public internal(set) var isHDRActive: Bool = false

    /// Fired on the main actor whenever the effective HDR-active state flips.
    /// Set by the owner (`StreamSession`) so HDR transitions can be observed
    /// without polling.
    public var onHDRActiveChanged: ((Bool) -> Void)?

    /// Whether the in-stream stats overlay (ping / fps / decode time) should
    /// be drawn on top of the next rendered frame.
    ///
    /// This value is session-scoped on purpose. `StreamSession.start` seeds
    /// it from `AppModel.showStreamStats` (the user's persisted
    /// preference) and the configured stats hotkey toggles it from inside
    /// the stream - but the toggled value never round-trips back into
    /// UserDefaults. Rationale: a user who flips stats on with the hotkey
    /// to chase a hitch shouldn't see the overlay still up the next time
    /// they start a stream a week later.
    public var statsOverlayEnabled: Bool = false {
        didSet {
            guard oldValue != statsOverlayEnabled else { return }
            log.info("Stats overlay \(self.statsOverlayEnabled ? "ON" : "OFF")")
            onStatsOverlayEnabledChanged?(statsOverlayEnabled)
        }
    }

    /// Fired on the main actor whenever `statsOverlayEnabled` flips. The
    /// session uses this to show/hide the overlay layer instantly without
    /// having to poll the decoder.
    public var onStatsOverlayEnabledChanged: ((Bool) -> Void)?

    // MARK: - Internal state
    //
    // A note on `nonisolated(unsafe)` below - read once, then trust the
    // serialization contract.
    //
    // VideoDecoder is `@MainActor`-isolated at the class level so the
    // attach/teardown path has clean main-actor semantics. But the native
    // backend hands us decode units on its own receive threads, and the
    // VideoToolbox session output callback fires on the dispatch queue we hand
    // it (decodeQueue). Those code paths can never go through the actor -
    // they're either receive-thread boundaries that can't suspend or hot paths
    // where suspending would tank latency.
    //
    // We bridge the two worlds with:
    //   * `decodeQueue.sync` for VT state (decompressionSession, format
    //     description, parameter sets, codec/stream parameters).
    //   * The native backend's per-stream callback serialization
    //     guarantee for streamWidth/Height/VideoFormat/Fps (set in
    //     handleSetup before handleStart fires, read by submit later).
    //
    // `displayLayer` is touched from the main actor on attach/teardown and
    // from the decode queue on enqueue. `enqueue` is documented as safe to
    // call from any thread in Apple's AVFoundation header, so cross-thread
    // access is by design (Apple uses an internal lock).
    //
    // `isStreaming` is the only true cross-thread atomic - set on main,
    // read on every worker thread to short-circuit teardown races. A bool
    // load is naturally atomic on every supported architecture.

    let log: Logger

    /// Negotiated bitrate (kbps) surfaced in the overlay; see setNegotiatedBitrateKbps.
    /// `nonisolated(unsafe)` - written ONCE at session start (setNegotiatedBitrateKbps,
    /// from StreamSession.start, on the main actor) and read-only thereafter, so the
    /// nonisolated `telemetryStatsSnapshot()` can surface it for the goodput-vs-ceiling
    /// signal. Same single-writer-then-trust discipline as `streamFps` above.
    nonisolated(unsafe) var negotiatedBitrateKbps: Int = 0
    /// Live audio-config display label surfaced in the overlay; see setActiveAudioConfigLabel.
    var activeAudioConfigLabel: String?
    /// Per-frame stats counters. Touched from the moonlight receive thread, the VT
    /// decode queue, and the main actor; `@unchecked Sendable` over an internal
    /// `os_unfair_lock`, so it crosses isolation boundaries safely. `nonisolated`
    /// so the static VT callback closure can record from the decode queue.
    nonisolated let statsCollector = StatsCollector()

    // The streaming engine: set at stream start and re-pointed by setBackend on a
    // silent reconnect while the decode queue (IDR) / main actor (HDR refresh) read
    // it, so the reference load/store is `backendLock`-guarded (mirrors `_displayLayer`;
    // StreamingBackend isn't Sendable, so OSAllocatedUnfairLock<T> can't hold it).
    let backendLock = NSLock()
    nonisolated(unsafe) var _backend: StreamingBackend?
    nonisolated var backend: StreamingBackend? {
        get { backendLock.lock(); defer { backendLock.unlock() }; return _backend }
        set { backendLock.lock(); defer { backendLock.unlock() }; _backend = newValue }
    }

    // Display layer. Set on the main actor before stream start, dropped on
    // teardown. The decode queue reads it from the VT output callback;
    // AVSampleBufferDisplayLayer.enqueue is thread-safe per Apple's docs
    // (the layer maintains its own internal sample queue and lock), but
    // the *reference write* itself (set/clear of the optional) races against
    // the decode-queue reader. Guard the pointer load/store with a plain
    // NSLock so the MainActor nil-out at teardown can't interleave with a
    // decode-queue snapshot. NSLock is used here instead of
    // OSAllocatedUnfairLock<T> because the latter requires its stored state to
    // be Sendable and AVSampleBufferDisplayLayer/CALayer is not - locking
    // around a plain nonisolated(unsafe) slot keeps the same race-free
    // semantics without forcing Sendable on a class we don't own.
    //
    // Read pattern at hot sites: snapshot once into a local, operate on the
    // local; the local extends the layer's lifetime past any teardown that
    // races. Writes only happen on MainActor (attach/teardown).
    let displayLayerLock = NSLock()
    nonisolated(unsafe) var _displayLayer: AVSampleBufferDisplayLayer?
    nonisolated var displayLayer: AVSampleBufferDisplayLayer? {
        get {
            displayLayerLock.lock(); defer { displayLayerLock.unlock() }
            return _displayLayer
        }
        set {
            displayLayerLock.lock(); defer { displayLayerLock.unlock() }
            _displayLayer = newValue
        }
    }

    // Decode session + format desc. Both live on the decode queue.
    nonisolated(unsafe) var decompressionSession: VTDecompressionSession?
    nonisolated(unsafe) var formatDescription: CMVideoFormatDescription?

    // The +1 self-retain handed to the VT output-callback refcon when the
    // session is created (see `ensureDecompressionSession`). Balanced by
    // `releaseOutputCallbackRefcon()` exactly once per session, at every
    // invalidation site. The retain is what guarantees the decode callback
    // can never dereference a deallocating VideoDecoder.
    nonisolated(unsafe) var outputCallbackRefcon: Unmanaged<VideoDecoder>?

    // The HDR-extended format description, built lazily by augmenting
    // `formatDescription` with kCMFormatDescriptionExtension_MasteringDisplay-
    // ColorVolume and ContentLightLevelInfo extensions. We use this for
    // enqueue when HDR is active and the host has provided metadata;
    // otherwise we enqueue with the plain `formatDescription`.
    //
    // Cached because building it is non-trivial (CMFormatDescription is
    // immutable, so we have to copy the original's extensions dict and
    // re-create the description). Invalidated whenever formatDescription
    // changes or cachedMDCV / cachedContentLightLevel changes.
    nonisolated(unsafe) var cachedHDRFormatDescription: CMVideoFormatDescription?

    // Stream parameters from setup().
    nonisolated(unsafe) var streamWidth: Int32 = 0
    nonisolated(unsafe) var streamHeight: Int32 = 0
    nonisolated(unsafe) var streamVideoFormat: Int32 = 0
    nonisolated(unsafe) var streamFps: Int32 = 0

    // Cached parameter sets so we can rebuild format descriptions if the
    // server cycles SPS/PPS mid-stream (it does after a network blip + IDR).
    nonisolated(unsafe) var spsData: Data?
    nonisolated(unsafe) var ppsData: Data?
    nonisolated(unsafe) var vpsData: Data?  // HEVC only

    // The decode queue runs everything VideoToolbox-related serially. The
    // submit callback fires on the native backend's receive thread; we hop here
    // ASYNCHRONOUSLY (decodeQueue.async) so the receive thread hands the frame
    // off and immediately loops back to recvfrom - it NEVER blocks on
    // VideoToolbox. This mirrors moonlight-common-c's separate receive /
    // decoder pthreads with a queue between them (VideoStream.c: VideoRecv +
    // VideoDec threads): in the C path recvfrom is never serialized behind VT,
    // which is what keeps 4K240 glassy. Because the queue is SERIAL, the async
    // blocks still run in strict submission order, so decode order is preserved
    // exactly as if we had called sync - param-set rebuilds and the frames that
    // follow them stay correctly sequenced.
    let decodeQueue = DispatchQueue(
        label: "io.ugfugl.Glimmer.video.decode", qos: .userInteractive)

    /// Number of frames submitted to VT for async decode but not yet retired by
    /// the VT output callback - our bound on the decode backlog. Mutated from
    /// two threads (incremented on the decode queue at submit, decremented from
    /// VT's internal output-callback thread), so it is guarded by
    /// `inFlightDecodeLock`. At 4K240 VT keeps up (the C path proves it), so
    /// this is a safety bound, not the steady path: if VT ever stalls, the
    /// queued decode work could otherwise grow unbounded in both latency and
    /// memory. When the backlog exceeds `maxInFlightDecodes` we skip submitting
    /// the new frame and request an IDR, so a transient VT stall self-recovers
    /// instead of ballooning - the same self-heal moonlight-common-c does when
    /// its bounded decodeUnitQueue overflows (VideoDepacketizer.c:513-532:
    /// flush + LiRequestIdrFrame).
    nonisolated(unsafe) var inFlightDecodes: Int = 0
    let inFlightDecodeLock = NSLock()
    /// Backlog bound - sized to ABSORB a VPN arrival burst, not to gate
    /// steady-state depth. Over a high-loss/high-jitter VPN, frames arrive
    /// bursty: pkts/s swings from ~200 to ~7800 within seconds, so the receive
    /// thread reserves slots in a burst after a jitter stall while VT is still
    /// draining the previous beat. The OLD bound of 8 was shallower than
    /// moonlight's depth-15 `decodeUnitQueue` AND measures a different thing -
    /// VT's async in-flight pipeline depth (submitted-but-not-yet-retired), not
    /// a pre-decode queue - so the same VPN burst that moonlight rides out trips
    /// us into a flush-to-IDR (a visible hitch) every ~4s. At 120fps, 30 frames
    /// = ~250ms of buffering, which covers the observed 22ms jitter spike and
    /// the burst-after-stall with wide margin while still bounding latency/memory
    /// if VT ever GENUINELY stalls (no output for 30 frames). This is the same
    /// role moonlight's depth-15 `decodeUnitQueue` plays; we need MORE than 15
    /// because our count is VT's async in-flight depth, which pipelines deeper
    /// than moonlight's one-frame-at-a-time synchronous pull thread. The
    /// flush-to-IDR self-heal is preserved - see `reserveDecodeSlot` - it now
    /// fires only on a GENUINE sustained stall (VT produces no output for
    /// `decodeStallWindowSeconds`, or the backlog hits `maxInFlightDecodeCeiling`),
    /// never on a transient burst VT is actively draining.
    ///
    /// FPS-SCALED, not a fixed frame count: the bound is a TIME budget. 30 frames
    /// was benchmarked at 120fps (= ~250ms), but a fixed count is 500ms at 60fps
    /// and 1s at 30fps - far more buffered latency than intended on a low-fps
    /// stream. Computed once `streamFps` is known (in `handleSetup`) as
    /// `max(15, 0.25 * fps)` so the buffered-latency budget stays ~250ms across
    /// frame rates, with a 15-frame floor so a very-low-fps stream still has enough
    /// slots to ride a VPN arrival burst. `nonisolated(unsafe)`: written once at
    /// setup (before any decode-path read can fire) and read-only thereafter on the
    /// receive thread - the same single-writer-then-trust discipline as `streamFps`.
    nonisolated(unsafe) var maxInFlightDecodes = 30
    /// Hard ceiling on the in-flight backlog. Between `maxInFlightDecodes` and
    /// this, the reserve path keeps absorbing a burst as long as VT is actively
    /// draining (recent output); at this ceiling we stop reserving and
    /// flush-to-IDR regardless, so a truly-stalled VT can't balloon memory or
    /// wall-clock latency. ~375ms of buffering at the stream's fps - past any
    /// plausible VPN burst, well short of a perceptible freeze. FPS-SCALED the same
    /// way as `maxInFlightDecodes`: `max(22, 0.375 * fps)`, computed in
    /// `handleSetup`. Same `nonisolated(unsafe)` single-writer discipline.
    nonisolated(unsafe) var maxInFlightDecodeCeiling = 45
    /// VT-draining window. `secondsSinceLastDecodedFrame()` under this means VT
    /// produced output recently, so a backlog at/over the bound is a transient
    /// burst VT is working through (absorb it). Past this with a full backlog is
    /// a genuine sustained stall (flush-to-IDR). 150ms ≈ 18 frames at 120fps -
    /// longer than the observed 22ms jitter spike + burst, shorter than the
    /// present-watchdog's 250ms stall trip, so the decode side resyncs before the
    /// present path notices.
    nonisolated static let decodeStallWindowSeconds = 0.150

    // True when start() has been called but stop() hasn't. We refuse to
    // touch the decode/enqueue path outside that window.
    nonisolated(unsafe) var isStreaming = false

    // One-shot guard: AVSampleBufferDisplayLayer.requiresFlushToResumeDecoding
    // can latch true after a transient decode failure (e.g. an SPS change
    // that arrives in the middle of a GOP). We watch the layer's status on
    // each enqueue and flush + request a new IDR if it goes FAILED.
    nonisolated(unsafe) var didLogFirstPixelBufferProbe = false
    nonisolated(unsafe) var didConfigureLayerOnce = false

    /// Fires exactly once per session when VT produces its first decoded
    /// pixel buffer. The session owner uses this to flip the stream window
    /// from invisible (alphaValue 0) to a smooth fade-in - without it the
    /// borderless covering window paints a black/letterboxed rectangle
    /// over the desktop during the multi-hundred-ms C-handshake gap before
    /// the first frame lands, which reads as a hard visual snap.
    ///
    /// Read from the nonisolated VT output callback, set from MainActor
    /// (StreamSession wiring). The `nonisolated(unsafe)` annotation is
    /// the same single-writer / read-on-decode-queue discipline used
    /// across this file's other VT-callback-touched closures and flags.
    /// The body is hopped onto MainActor before fire, so the closure
    /// itself doesn't need to be Sendable.
    nonisolated(unsafe) public var onFirstDecodedFrame: (() -> Void)?
    nonisolated(unsafe) var didFireFirstDecodedFrame = false

    // Tracks the last CGColorSpace we attached to a pixel buffer so we only
    // rebuild it when the bitstream-declared colorspace actually changes -
    // identical to moonlight-qt's `m_LastColorSpace` + `m_ColorSpace`
    // pattern in vt_avsamplelayer.mm. The key is a tuple of (primaries,
    // transfer) decoded from the pixel buffer's attachments at frame time;
    // changes when the host swaps from Rec.709 SDR ↔ Rec.2020/PQ HDR.
    nonisolated(unsafe) var lastColorSpaceKey: String?
    nonisolated(unsafe) var lastColorSpace: CGColorSpace?

    // Renderer-backpressure consecutive-drop counter. When the
    // AVSampleBufferVideoRenderer's internal queue fills (host bitrate spike,
    // decode hitting headroom, OS-side compositor falling behind),
    // `isReadyForMoreMediaData` flips to false; we drop the frame to keep
    // wall-clock latency bounded. We still COUNT this (the renderer's own
    // queue overflowing is a real signal) but no longer drive the IDR request
    // off it - a single late vsync can flip isReadyForMoreMediaData for one
    // frame, and asking for an IDR on transient jitter just compounds lag. We
    // still COUNT backpressure drops for the overlay, but no longer request an
    // IDR off the transient renderer-not-ready flag - a presentation-timing
    // drop of an already-decoded frame never needs a keyframe (the reference
    // chain is intact). IDR/RFI is reserved for genuine decode/reference breaks.
    nonisolated(unsafe) var consecutiveBackpressureDrops: Int = 0

    /// Consecutive decode-backlog overflows - how long the backlog has sat in
    /// the over-the-nominal-bound zone. A burst of late-then-clustered frames
    /// over the VPN can momentarily fill the in-flight bound; that burst is
    /// absorbed (we keep reserving past `maxInFlightDecodes` while VT is actively
    /// draining, up to `maxInFlightDecodeCeiling`) and only escalates to
    /// flush-to-IDR on a GENUINE sustained stall (VT produced no output for
    /// `decodeStallWindowSeconds`, or the backlog hit the ceiling - see
    /// `reserveDecodeSlot`). This counter is DIAGNOSTIC ONLY: it is logged with
    /// the stall warning so we can tell a long absorbed burst from a hard VT
    /// stop, but it is NOT itself a flush trigger (flushing a deep-but-draining
    /// burst would defeat the bound bump and reintroduce the hitch). Incremented
    /// on overflow and reset the moment a slot reserves cleanly, both inside
    /// `reserveDecodeSlot` under `inFlightDecodeLock`, so it's only ever touched
    /// on the receive thread (the reserve site) - no extra lock needed beyond
    /// the one already held there.
    nonisolated(unsafe) var consecutiveBacklogOverflow: Int = 0

    /// The display-clock frame pacer. Sits between the VT decode callback and
    /// the AVSampleBufferDisplayLayer's renderer: decoded frames are submitted
    /// into its jitter buffer and released one-per-due-vsync by a CADisplayLink
    /// bound to the stream window's screen. Created in `attach(to:)` on the
    /// main actor, started once the window is on screen, torn down in
    /// `teardown()`. `nonisolated(unsafe)` for the same single-writer-on-main /
    /// read-on-decode-queue discipline as the rest of this file's VT-callback-
    /// touched state - `submit` is called from the decode queue, the renderer
    /// reference inside the pacer is itself lock-guarded.
    nonisolated(unsafe) var framePacer: FramePacer?

    /// The view whose screen the pacer's CADisplayLink binds to, remembered from
    /// `startPacing` so the present-watchdog's give-up → re-enable path can
    /// rebuild a fresh pacer onto the same screen WITHOUT the watchdog reaching
    /// into the actor-isolated StreamWindow. Weak so it can't keep the stream
    /// view alive past teardown. MainActor-touched only (start/re-enable both run
    /// there); `@MainActor` keeps it off the nonisolated decode path.
    @MainActor weak var pacingDrivingView: NSView?

    /// Rebuild the AVSampleBufferDisplayLayer and re-point the decoder at the
    /// fresh one. Wired by StreamSession to `StreamWindow.rebuildDisplayLayer()`
    /// (+ `attach(to:)` + colorspace reconfigure). The present-path self-heal
    /// calls this as the last resort when the renderer has hard-latched
    /// `.status == .failed` and a bare `flush()` can't clear it - the only way
    /// out is a fresh layer. Returns the new layer (nil if the window is gone).
    /// MainActor-only; nil until wiring, so a pre-wire recovery degrades to a
    /// flush-only attempt rather than crashing.
    @MainActor var rebuildDisplayLayerHook: (() -> AVSampleBufferDisplayLayer?)?

    // EDR metadata cached after a successful LiGetHdrMetadata() pull.
    // The Data blobs are in the exact GBR-order big-endian byte layout that
    // moonlight-qt's vt_base.mm builds for the HDR10 MDCV + CLL SEI
    // attachments - see `refreshHDRMetadataFromHost()` for the contract.
    nonisolated(unsafe) var cachedMDCV: Data?
    nonisolated(unsafe) var cachedContentLightLevel: Data?

    /// "Presentation is intentionally suppressed" - true while the stream window
    /// is orderOut'd / occluded / minimized / nativeStreamBackgrounded, i.e. the
    /// app is deliberately streaming with nothing reaching the screen (the
    /// user Cmd-Tabbed away or moved to the launcher while the stream keeps
    /// running). It is fed by `setPresentSuppressed`, wired from the window's
    /// onBackgroundedChanged signal.
    ///
    /// Why it exists: while presentation is suppressed the present path stops
    /// retiring frames (an off-screen window's CADisplayLink stops firing, an
    /// occluded AVSampleBufferVideoRenderer stops draining), so the decode
    /// backlog and the pacer FIFO fill up even though the link is perfectly
    /// healthy. The decode side must NOT misread that intentional non-present
    /// backlog as packet loss and spam IDR/RFI - the user's "rfis/idrs and
    /// backflows happen when the window isn't focused" bug. We gate the
    /// NON-LOSS IDR source that remains (decode-backlog drop-to-IDR) on this
    /// flag; genuine on-wire loss detection (the depacketizer's gap detection →
    /// RFI/IDR) is NEVER gated by it, because that keys off wire gaps, not the
    /// sink-side backlog. (The pacing-overflow IDR is gone entirely - a
    /// presentation-timing trim of an already-decoded frame never needs a
    /// keyframe - so there is nothing left to gate there.)
    ///
    /// Lock-guarded (`presentSuppressedLock`) because it is written on the main
    /// actor (the window key/occlusion observers) and read on the receive thread
    /// (`decodeAssembledFrame`). A plain bool load would be atomic, but the
    /// lock also makes the false→true / true→false transition edges race-free
    /// against the setter's flush/drain/IDR work.
    let presentSuppressedLock = NSLock()
    nonisolated(unsafe) var _presentSuppressed = false
    /// Lock-guarded snapshot of `_presentSuppressed` for the nonisolated decode /
    /// pacer paths. Read-only accessor; the write side is `setPresentSuppressed`,
    /// which also owns the transition-edge work (drain on enter, resync on exit).
    nonisolated var presentSuppressed: Bool {
        presentSuppressedLock.lock(); defer { presentSuppressedLock.unlock() }
        return _presentSuppressed
    }

    /// "Decode is gated" - stage 2 of the hidden-window ladder, downstream of
    /// `presentSuppressed` and strictly slower:
    ///
    ///   suppress edge (0s)    → `presentSuppressed`: the pacer drops-to-newest,
    ///                           IDR escalation off (stage 1, above).
    ///   gate edge (2s hidden) → `decodeGated`: compressed AUs stop being fed
    ///                           to VideoToolbox entirely (stage 2, this flag).
    ///
    /// Why stage 2 exists: while the window is hidden the client still decodes
    /// the full 4K120 stream (~30% CPU) only for the suppressed pacer to throw
    /// every frame away. The receive/depacketize/RFI machinery MUST keep
    /// running (zero host-side changes - the stream cannot pause) and audio
    /// keeps playing, but VideoToolbox work for pixels nobody can see is pure
    /// waste. After `decodeGateDelaySeconds` of CONTINUOUS suppression the
    /// gate engages and the submit boundary (`decodeAssembledFrame`) drops AUs
    /// before any VT work happens. The delay means rapid alt-tabs never gate
    /// (and never cost a resync); the timer is cancelled on the resume edge.
    /// Gate-off is UNCONDITIONAL on resume - never a permanent give-up.
    ///
    /// Deliberately a SEPARATE flag from `_presentSuppressed`: the two stages
    /// recover independently (suppression exits do edge work even when the
    /// gate never engaged) and folding them together would re-create the
    /// pacer-flag-continuity class of bug. Guarded by `presentSuppressedLock`
    /// (same discipline: written on the main actor at the gate/resume edges,
    /// read on the receive thread at the submit boundary). Edge work lives in
    /// VideoDecoder+Suppression.swift.
    nonisolated(unsafe) var _decodeGated = false

    /// One-shot "the next fed frame must be an IDR" latch, armed at the
    /// gate-ON edge and resolved at the submit boundary after gate-off.
    /// VideoToolbox's reference chain goes stale the moment the gate starts
    /// dropping AUs, so feeding any P-frame after the gap would macroblock.
    /// `decodeGateDisposition` either clears it on a genuine IDR (feed it -
    /// the resync IDR won the race) or converts it into DR_NEED_IDR exactly
    /// once, handing the wait to the depacketizer's EXISTING wait-for-IDR
    /// recovery gate (`requestDecoderRefresh` - the same reference-
    /// invalidation flush the sustained-backlog-stall path reuses). Guarded
    /// by `presentSuppressedLock`.
    nonisolated(unsafe) var _awaitingPostGateIdr = false

    /// Monotonic stamp (uptime nanos) of the last gate-OFF edge; nil until a
    /// gate has ever lifted. The frame watchdog floors its decode-idle clock
    /// at this edge: a 60s gate leaves `secondsSinceLastDecodedFrame()` at
    /// 60s the instant the gate lifts, and without the floor the 1Hz watchdog
    /// would tear the session down before the ~12ms resync IDR can decode.
    /// Guarded by `presentSuppressedLock`.
    nonisolated(unsafe) var _decodeGateLiftedAtNanos: UInt64?

    /// The continuous-suppression gate timer: armed on the suppress edge,
    /// cancelled on resume/teardown, fires `engageDecodeGate` after
    /// `decodeGateDelaySeconds`. MainActor-touched only (suppress/resume/
    /// teardown all run there), so no lock - same pattern as the other
    /// main-actor-only slots in this file.
    @MainActor var decodeGateTimer: Task<Void, Never>?

    /// How long the window must be CONTINUOUSLY hidden before decode gates.
    /// Long enough that alt-tab flurries never gate (so a quick peek at
    /// another app never costs a resync), short enough that a stream parked
    /// in the background stops burning ~30% CPU within a couple of seconds.
    nonisolated static let decodeGateDelaySeconds: Double = 2.0

    /// NotificationCenter tokens watching the attached layer's renderer for
    /// `requiresFlushToResumeDecodingDidChangeNotification` plus the layer's
    /// `FailedToDecodeNotification`. These fire the moment an occlusion/background-
    /// triggered renderer LATCH happens - sub-frame, before the 20Hz present
    /// watchdog would notice - and route to `recoverPresentPath` immediately.
    /// Created in `attach(to:)` and torn down in `teardown()` (and rebuilt by
    /// `attach` when the layer is swapped by the rebuild hook). MainActor-touched
    /// only (attach/teardown both run there), so no extra lock (the class is
    /// `@MainActor`). The tokens are removed from NotificationCenter on teardown.
    var layerStallObservers: [NSObjectProtocol] = []
}
