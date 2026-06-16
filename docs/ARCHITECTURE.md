# Architecture

Glimmer is a SwiftUI launcher plus a pure-Swift streaming engine. One process.
No helper daemon, no external player, no linked C streaming library — the
GameStream/Sunshine transport is implemented in Swift under
`Glimmer/Stream/Native/` (ported from `moonlight-common-c`, GPLv3; see
[CREDITS.md](../CREDITS.md)). The only C that crosses the bridging header is
Opus (audio decode) and OpenSSL (identity / pairing / network crypto), plus a
few inline shims in `CHelpers.h`.

## Overview

The user picks a host in the SwiftUI launcher, clicks Stream, and a borderless
NSWindow takes over the screen. Decoded H.264 / HEVC / AV1 (8- or 10-bit, SDR or
HDR10) is paced by a display-link-driven `FramePacer` onto an
`AVSampleBufferDisplayLayer` for the OS to paint. Mouse / keyboard / gamepad
input is forwarded to the host through the `StreamingBackend` input methods
(coalesced by an `InputBatcher` onto the reliable control channel). When the
user hits the quit hotkey, the backend is told to disconnect and the window
comes down.

There is no helper process and no XPC service. The engine runs in the same
process as the launcher.

## Process model

Single process, single in-flight stream. `StreamSession.start()` refuses to
start a second session while one is running (`isStreaming` guard).

Top-level pieces:

| Layer                 | Type                                     | Lives where                                                 |
| --------------------- | ---------------------------------------- | ----------------------------------------------------------- |
| SwiftUI views         | views + observable state                 | `Glimmer/ContentView.swift`, `SettingsView.swift`           |
| `MoonlightManager`    | `@MainActor` `@Observable`               | `Glimmer/MoonlightManager.swift`                            |
| `StreamSession`       | `actor`                                  | `Glimmer/Stream/StreamSession.swift` (+ extensions)         |
| `StreamingBackend`    | protocol (the engine boundary)           | `Glimmer/Stream/StreamingBackend.swift`                     |
| `NativeBackend`       | `final class`, sole backend conformer    | `Glimmer/Stream/NativeBackend.swift` + `Stream/Native/`     |
| `StreamBridgeContext` | `final class`, `@unchecked Sendable`     | `Glimmer/Stream/StreamBridgeContext.swift`                  |
| `NetworkClient`       | `actor` over `URLSession`                | `Glimmer/Stream/Network.swift`                              |
| `PairingClient`       | `actor`                                  | `Glimmer/Stream/Pairing.swift`                              |
| `IdentityManager`     | `actor` (singleton)                      | `Glimmer/Stream/Identity.swift`                             |
| `VideoDecoder`        | `@MainActor final class`                 | `Glimmer/Stream/VideoDecoder.swift` (+`+HDR`, `+Bitstream`) |
| `FramePacer`          | `final class`, `@unchecked Sendable`     | `Glimmer/Stream/FramePacer.swift` (+ extensions)            |
| `AudioDecoder`        | `final class`, `@unchecked Sendable`     | `Glimmer/Stream/AudioDecoder.swift`                         |
| `InputForwarder`      | `@MainActor final class`                 | `Glimmer/Stream/InputForwarder.swift`                       |
| `ControllerForwarder` | `@MainActor` extension on InputForwarder | `Glimmer/Stream/ControllerForwarder.swift`                  |
| `StreamWindow`        | `@MainActor final class`                 | `Glimmer/Stream/StreamWindow.swift`                         |
| `StatsCollector`      | `final class`, `@unchecked Sendable`     | `Glimmer/Stream/StatsCollector.swift`                       |
| Telemetry (opt-in)    | exporter + counters                      | `Glimmer/Stream/TelemetryExporter.swift` (+ extensions)     |

## The `StreamingBackend` boundary

`Glimmer/Stream/StreamingBackend.swift` is **the** streaming-engine abstraction:
one protocol for lifecycle / telemetry / input uplink, plus sink protocols for
the inbound direction (`VideoSink`, the audio sink, `ConnectionEvents`), plus
Glimmer-owned value types (`BackendServerInfo`, `BackendStreamConfig`,
`DecodeUnit`, `OpusConfig`, `HdrMetadata`) so nothing outside the engine sees
wire-level types. `NativeBackend` is the sole conformer.

The method set deliberately mirrors the GameStream protocol surface — the
outbound input methods map 1:1 to the `LiSend*` family the protocol defines, and
doc comments keep the `Li*` names as spec citations — so the protocol itself
documents the wire contract the engine satisfies.

Protocol constants live in a Swift mirror (`StreamProtocolConstants.swift`,
`enum StreamProtocol`); nothing imports a `Limelight.h`.

## The native engine (`Glimmer/Stream/Native/`)

`NativeBackend.startConnection` drives the whole bring-up:

```
name resolution → RTSP/SDP handshake over TCP (OPTIONS, DESCRIBE,
SETUP audio/video/control, ANNOUNCE, PLAY) → ENet-subset reliable-UDP
CONTROL channel CONNECT / VERIFY_CONNECT / ACK → START_A → START_B →
connected → stream pings + RTP receive → FEC → depacketize → sinks
```

Components:

- **`RtspClient`** (+`+Handshake`) — the RTSP/SDP rounds, including Sunshine's
  encrypted-RTSP variant. `SdpCodec` builds/parses the SDP payloads.
- **`EnetControlChannel`** (+`+Handshake`, `+ControlLoop`, `+Inbound`, `+Send`)
  — a focused, single-peer, client-only ENet subset over UDP: the CONNECT
  handshake, reliable sends with ACK tracking, and the inbound control dispatch
  (rumble, HDR mode, motion enable, lightbar, termination). `EnetWire.swift`
  owns the byte layout. Ported from the enet protocol logic vendored in
  moonlight-common-c (enet is MIT, Lee Salzman — see CREDITS.md).
- **`StreamCrypto`** — control-V2 AES-GCM encryption for control messages and
  the media-stream decrypt paths.
- **Video receive** — `VideoRtpReceiver` (socket + ping loop) → `RtpVideoQueue`
  (+`+AddPacket`, `+Reconstruct`, `+ReceiveQuality`) which reorders,
  FEC-recovers, and assembles packets → `VideoDepacketizer` which emits
  `DecodeUnit`s to the `VideoSink` (the `VideoDecoder`). `ReedSolomon.swift` is
  the GF(256) erasure decoder (ported from nanors, MIT, Joseph Calderon — see
  CREDITS.md). `FecHeadroomController` adaptively deepens receive headroom under
  sustained loss with a bounded, recovering control loop.
- **Audio receive** — `RtpAudioReceiver` (+`+Socket`, `+Decrypt`, `+Fec`,
  `+Ping`, `+StartupGate`) → `RtpAudioQueue` / `AudioFecDecoder` → Opus decode
  in `AudioDecoder` (AVAudioEngine playout with an adaptive cushion).
- **Input uplink** — `InputBatcher` + `InputEncoder`: queue + merge + ~1ms flush
  (the port of `inputSendThreadProc`), coalescing high-rate mouse / controller
  deltas so the reliable channel carries ~1 packet per change per tick instead
  of 150–250/s.
- **`UdpPinger`** — stream-keepalive ping plumbing and the single steady-cadence
  dial both live receive loops ride.

Inbound callbacks fire on the engine's receive threads and are routed through
`StreamBridgeContext` (below). Stage events (`stageStarting` / `stageComplete` /
`stageFailed`) yield through the bridge's event continuation so the connection
UI lights up live.

## Stream session lifecycle

`StreamSession.start(server:config:appID:…)` returns an
`AsyncStream<StreamEvent>` that drives the launcher's UI state. The phases:

1. **Verify pairing** — `NetworkClient.fetchServerInfo()` (over HTTPS if a host
   cert is already pinned, plain HTTP otherwise). If `pairStatus != .paired`,
   throw — the launcher's pair sheet runs first, not us.
2. **Launch or cancel+launch** — `launchWithBusyRecovery()` always renegotiates:
   if the host's `currentgame` is 0 we send `/launch`, otherwise `/cancel` +
   poll-until-idle + `/launch`. The previous "auto-resume if it's our app" path
   was removed because it preserved the host's previous stream configuration
   (resolution, FPS, HDR mode) across machines — a resume from a laptop after
   starting on a desktop would carry over the desktop's 4K@240 settings. See
   `launchWithBusyRecovery()` for the polling detail (the host's per-stream Undo
   command has to finish before our next `/launch` runs, or display-resolution
   lands on whichever of Do/Undo wrote last).
3. **Build `BackendStreamConfig`** — width / height / fps / bitrate / codec
   bitmask / colorspace / colorRange / encryptionFlags. The remote-input AES
   key + IV are copied in from the launch response.
4. **Build window + decoder + input on the main actor** — `StreamWindow`,
   `VideoDecoder`, `InputForwarder` are all `@MainActor`. The decoder is
   attached to the window's `AVSampleBufferDisplayLayer` before the connection
   starts so the first decoded frame has somewhere to land.
5. **Build `StreamBridgeContext`** — holds weak references to session, decoder,
   audio decoder, input forwarder, plus the `AsyncStream.Continuation`.
   `Unmanaged.passRetained` keeps the bridge alive for the connection lifetime;
   `StreamBridgeContext.current` is a weak static for context-less callback
   paths.
6. **Build the event stream before `startConnection`** — the backend fires
   `stageStarting` / `stageComplete` synchronously while `startConnection` runs.
   The continuation has to exist before the call or those early events are
   dropped. (Regression fixed.)
7. **`backend.startConnection(server:config:)`** — blocks while the native
   engine runs the RTSP + control + media bring-up described above; throws on
   failure.
8. **Install timers** — a stats-overlay refresh and a 1 Hz frame-arrival
   watchdog on the main run loop, plus the present-path watchdog
   (`StreamSession+Watchdog.swift`). The frame watchdog (`frameWatchdogTimeout`
   = 10s, matching upstream moonlight's `FIRST_FRAME_TIMEOUT_SEC`) tears the
   session down if decode stops — the protocol's own dead-peer detection can
   take longer to declare a dead connection. The watchdogs are suppression- and
   gating-aware (a hidden window legitimately stops presenting; see
   `VideoDecoder` decode gating).

Teardown (`stop()`) is re-entrant by design — any two of {quit hotkey,
`connectionTerminated` callback, `AsyncStream.onTermination`, `startConnection`
error path} can fire back-to-back. The `isStreaming` + `stopInProgress` flag
pair both have to flip before further callers fall through.

Teardown order is load-bearing:

1. Invalidate stats-overlay + watchdog timers, hide overlay.
2. `backend.stopConnection()` — synchronous; drains the engine's receive /
   control threads. After this returns, no further backend callbacks can fire.
3. `network.cancel()` — tell the host the session is over so its `currentgame`
   clears.
4. MainActor teardowns: `input.detach()`, `videoDecoder.teardown()`,
   `window.close()`.
5. `audioDecoder.shutdown()` (AVAudioEngine drain).
6. Release the bridge's `Unmanaged.passRetained` +1, `finish()` the event
   stream, clear `StreamBridgeContext.current`.

The bridge holds weak refs to every subsystem, so a callback firing against a
torn-down subsystem just no-ops — but "no UAF" isn't "well-behaved", and the
order above keeps the engine's receive threads from racing AVAudioEngine /
AVSampleBufferDisplayLayer teardowns.

## Video pipeline

Owned by `VideoDecoder` (`Glimmer/Stream/VideoDecoder.swift`), with HDR
specifics in `+HDR.swift` and bitstream parsing in `+Bitstream.swift`.

**Packet ingest.** The native engine's depacketizer invokes
`submitDecodeUnit(_:)` on its receive thread with an Annex-B elementary-stream
`DecodeUnit`. We assemble it into a single `Data` buffer, watch for SPS/PPS/VPS
NALs (or the AV1 sequence header OBU), rebuild the `CMVideoFormatDescription` on
IDR, and submit the sample to `VTDecompressionSessionDecodeFrame`.

**VT decode.** `VTDecompressionSession` is built with hardware acceleration
required (`VTIsHardwareDecodeSupported` is checked per codec at setup).
`kVTDecompressionPropertyKey_RealTime` is set so VT prefers latency over peak
quality. The output callback fires on our `decodeQueue` (a user-interactive
`DispatchQueue`) with a `CVPixelBuffer`.

**Pacing + enqueue.** The VT output callback wraps the pixel buffer + format
description in a `CMSampleBuffer` and submits it to the `FramePacer` — a
display-clock pacer (a port of moonlight-qt's `pacer.cpp` two-queue model,
adapted to `AVSampleBufferDisplayLayer` + `CADisplayLink`). Frames land in a
bounded, hostPTS-ordered jitter/reorder FIFO; a `CADisplayLink` bound to the
stream window's screen releases at most one due frame per vsync to
`displayLayer.sampleBufferRenderer.enqueue(_:)` (`AVSampleBufferVideoRenderer`,
the macOS 15+ replacement for the deprecated `enqueueSampleBuffer`). The release
path runs on a dedicated serial queue, never the main actor. The pacer's queue
depth is adaptive: it rests at 1 frame on a clean link and grows only under
genuinely measured (RFC-3550) reorder jitter, decaying back when the link is
clean — see the rationale comments in `FramePacer.swift` and
`FramePacer+Constants.swift`. There is no Metal shader — the OS owns color/EDR
handling end-to-end.

The Metal-shader rewrite this used to be is documented in the top-of-file
comment in `VideoDecoder.swift`. Short version: with a custom MSL fragment
shader doing the YUV→RGB + PQ EOTF, HDR was visibly wrong (washed highlights,
milky blacks) on real HDR displays. moonlight-qt's macOS path also uses
`AVSampleBufferDisplayLayer`; Apple's Metal docs explicitly say "don't tone-map
in your shader, the layer applies tone mapping based on the current EDR
headroom." We do what moonlight-qt does, the OS owns the pipeline end-to-end,
and HDR works.

**HDR pipeline.** Active when all three preconditions hold:

1. Host signalled HDR via the control channel's HDR-mode message.
2. Stream is 10-bit (`streamVideoFormat & VIDEO_FORMAT_MASK_10BIT != 0`).
3. The bitstream's VUI / AV1 sequence-header `color_config` declares PQ (SMPTE
   ST 2084) — or, for untagged Sunshine bitstreams, we infer PQ from the
   10-bit + HDR-mode pair.

When active, `VideoDecoder+HDR.configureLayerColorspace` sets:

- `layer.preferredDynamicRange = .high` (macOS 26+ API; replaces the older
  `wantsExtendedDynamicRangeContent` Bool).
- `layer.setValue(CGColorSpace(name: .itur_2100_PQ), forKey: "colorspace")` —
  via KVC because the Swift overlay elides the property on the
  `AVSampleBufferDisplayLayer` subclass.

Per-frame attachments on the `CVPixelBuffer`:

- `kCVImageBufferColorPrimariesKey` = `ITU_R_2020`.
- `kCVImageBufferTransferFunctionKey` = `SMPTE_ST_2084_PQ`.
- `kCVImageBufferYCbCrMatrixKey` = `ITU_R_2020`.

HDR10 static metadata comes from the host (the native engine surfaces it via
`StreamingBackend.hdrMetadata()`, filled from the SDP mastering metadata) and is
attached as `CMFormatDescription` extensions in the exact HDR10 wire layout
(MDCV: GBR ordering, big-endian; CLL: 4 bytes big-endian). See
`VideoDecoder+HDR.refreshHDRMetadataFromHost()` for the byte-by-byte build. The
cached HDR format description is rebuilt whenever metadata changes (host
re-signals HDR with new values, e.g. a game changes EOTF or the host display is
hot-swapped).

When HDR drops back to SDR, `preferredDynamicRange` returns to `.standard`, the
layer's `colorspace` is cleared, and the next-frame fallback attaches BT.709
primaries.

**Backpressure + recovery.** `AVSampleBufferVideoRenderer.status == .failed`
latches after a bad sample (mid-stream SPS change, dirty AV1 OBU). We watch for
that on each enqueue: on failure, `renderer.flush()` and
`backend.requestIdrFrame()`. `RendererFailed` OSSignpost event fires so it shows
in Instruments. `isReadyForMoreMediaData` is also honored — when the renderer's
internal queue fills, frames drop (counted) rather than queueing unbounded
latency. A hidden/occluded stream window suppresses presentation and, after a
sustained window, gates VideoToolbox decode entirely (the host cannot pause;
audio/network/FEC keep running); resume reuses the wait-for-IDR recovery path.

**Stream-format coverage.** H.264, HEVC (Main / Main10), AV1 (Main / Main10,
plus 4:4:4 paths). Default codec set is
`[av1, av1Main10, hevcMain10, hevc, h264]`. Codec negotiation goes through
`BackendStreamConfig.supportedVideoFormats` (our preferences) and
`BackendServerInfo.serverCodecModeRaw` (raw `SCM_*` bitmask from `/serverinfo`,
passed verbatim — see the landmine note in `StreamProtocolConstants.swift` for
why we don't remap it).

## Input forwarding

`InputForwarder` (`Glimmer/Stream/InputForwarder.swift`, plus the
`ControllerForwarder` extension) hooks events at the responder level via a
custom `StreamInputView` installed as the stream window's first responder.
Earlier revisions used `NSEvent.addLocalMonitorForEvents`, but macOS 26's
responder chain consumes events for content views that accept first responder
before the local-monitor block fires.

All uplink goes through the `StreamingBackend` send methods (`sendKeyboard` /
`sendMouseMove` / `sendMultiController` / …), which the native engine batches
(`InputBatcher`, ~1ms merge+flush) onto the reliable control channel.

**Mouse.** `CGAssociateMouseAndMouseCursorPosition(false)` freezes the OS cursor
at its current position the moment the window becomes key. Raw HID deltas come
from the underlying `CGEvent`'s `kCGMouseEventDeltaX/Y` fields
(`NSEvent.deltaX/Y` goes to zero when the cursor is frozen). A sub-pixel
residual accumulator carries fractional motion forward so slow trackpad moves
don't round to zero. Cursor warp to screen center before associate-false defends
against hot corners triggering during a stream — there's no public API to
disable hot corners, so the workaround is keeping the frozen cursor away from
them.

**Keyboard.** Positional scancodes via `sendKeyboard`, with the high bit
(`0x8000`) set to ask the host to skip layout correction (GFE otherwise remaps
AZERTY → QWERTY; we want the user's physical key position to win). Every
physical key-down / key-up emits one keyboard event — no per-event modifier
reset, no "release before press" coalescing. NKRO works because AppKit delivers
each transition as its own `NSEvent` and the responder chain hands each to
`keyDown(with:)` / `keyUp(with:)` independently. Stuck modifiers are released
only in `detach()`.

The Cmd key reports as `VK_LWIN` / `VK_RWIN`. By default
(`captureSysKeys == false`) the InputForwarder drops Cmd-bearing keyDown and
`.command` `flagsChanged` events so ⌘-Tab, ⌘-Space, ⌘-Q stay local-Mac chords.
`captureSysKeys = true` forwards everything as a Win-key chord. The configured
quit / stats hotkeys are detected before the captureSysKeys gate so a
Cmd-bearing quit chord (default ⌃⌘Q) keeps working in either mode.

**Controller.** GameController framework. `GCControllerDidConnect` /
`Disconnect` are observed; per-controller state is kept in
`attachedControllers: [ObjectIdentifier: AttachedController]`. Slot assignment
is a 16-bit `gamepadMask` — bit N == 1 means slot N is in use. Arrival is
announced via `sendControllerArrival` with probed capabilities (some Sunshine
builds silently drop multi-controller events without it). State updates go
through `sendMultiController`. Host-driven feedback comes back through
`ConnectionEvents`: rumble (`0x010b`), trigger rumble (`0x5500`), motion-sensor
enable (`0x5501` — answered with `sendControllerMotion` samples), and RGB
lightbar (`0x5502`); `ControllerHaptics`, `ControllerMotion`, and
`ControllerBattery` own the actuator/sampler sides.

**Gesture suppression.** An `NSEvent.addLocalMonitorForEvents` for `.magnify` /
`.smartMagnify` / `.swipe` / `.gesture` / `.beginGesture` / `.endGesture` /
`.pressure` / `.rotate` swallows the gesture family while the stream window is
key. Scroll wheel is NOT swallowed — scrolls forward as host scroll events.
macOS Accessibility Zoom chords (⌥⌘8 / ⌥⌘= / ⌥⌘-) are intercepted
unconditionally so they never reach the OS while a stream is up.

**Input gating.** The engine refuses input until the control channel is up: the
backend's `send*` methods return -2 before then (mirroring upstream
`InputStream.c`'s `initialized` guard). `InputForwarder.isReady` flips true when
`connectionStarted` fires; until then events drop on the floor instead of
flooding the log with -2s.

## Window model

`StreamWindow` (`Glimmer/Stream/StreamWindow.swift`). One borderless
`KeyableWindow` per session. `KeyableWindow` is a thin `NSWindow` subclass that
returns true for `canBecomeKeyWindow` + `canBecomeMainWindow` — borderless
windows default to false, which silently breaks `makeKeyAndOrderFront` and the
responder chain.

**Window level.** `.normal`. We tried shielding-window level
(`CGShieldingWindowLevel()`) — AppKit marks it as key, the responder points at
our view, but `sendEvent:` silently drops keyDown/keyUp. Menu bar suppression
happens via `NSApp.presentationOptions = [.hideMenuBar, .hideDock]` instead.
(When `coversNotch == true` we temporarily raise level to
`NSWindow.Level(rawValue: CGWindowLevelForKey(.mainMenuWindow) + 1)` so the
window paints over the menu-bar zone and notch reserve; it drops back to
`.normal` on `didResignKey` so other apps surface above us when the user
Cmd-Tabs away.)

**Display layer as root.** `AVSampleBufferDisplayLayer` is installed as the
content view's root layer (`view.layer = layer` BEFORE
`view.wantsLayer = true`), not a sublayer of a default backing layer.
Compositing through an intermediate sRGB layer flattens EDR back to SDR before
the panel sees it.

**Stats overlay.** A `StatsOverlayLayer` is attached as a sublayer of the
display layer (not a sibling — root-layer status is the precondition). The OS
composites the sRGB text against the HDR content correctly.

**Dual-path fullscreen — the `coversNotch` toggle.** Two paths picked per
session config:

- **`coversNotch == true`** (default): borderless covering window at
  `.mainMenu + 1` level,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
  NO Space-based fullscreen. The window owns the full physical panel including
  the notch reserve on notched MacBooks. Bitstreams at the panel's true native
  resolution render 1:1.
- **`coversNotch == false`**: `toggleFullScreen(nil)` for Space-based
  fullscreen. AppKit handles the Space creation and reserves the menu-bar /
  notch area as safe inset. Same path SDL's
  `SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES=1` uses.

The `coversNotch == true` path is the default because borderless +
`.hideMenuBar` engages display HDR mode without needing a Space (NSScreen's
`maximumExtendedDynamicRangeColorComponentValue` lifts above 1.0 for any
layer-host that owns the panel — Space ownership isn't the gating condition we
thought it was).

**Backgrounding.** On `didResignKey`, the window is `orderOut`'d entirely and
the cursor is unhidden. The stream session keeps running — the decode pipeline
and display layer are independent of window visibility (with presentation
suppressed and decode gated while hidden; see Video pipeline). On the launcher
side, the `Back to stream` affordance calls `StreamSession.resumeWindow()` to
bring it back. We deliberately do NOT auto-reorder-front on
`NSApp.didBecomeActive` — that fired on every app activation (clicking the
launcher, Dock-clicking) and yanked the user back into the stream whenever they
tried to change a setting.

**`NSWindow.sharingType`** = `.none`. The stream window opts out of
ScreenCaptureKit and `screencapture(1)`; third-party recording / conferencing
apps see a black surface where the stream is. Threat-model rationale is in
`SECURITY.md` → Runtime hardening.

## Crossing isolation — receive threads ↔ Swift actors

The native engine delivers frames, audio, and control events on its own receive
threads — threads neither the actor system nor `@MainActor` knows about, and the
latency cost of round-tripping every frame through an actor is unacceptable. The
bridge handles this:

- **`StreamBridgeContext`** (`Glimmer/Stream/StreamBridgeContext.swift`) is the
  single instance allocated per session. It holds _weak_ references to the
  session and every subsystem, plus the `AsyncStream<StreamEvent>.Continuation`.
  A subsystem torn down before the receive threads drain just becomes nil at the
  callback site — no UAF, no order dependency.
- `Unmanaged.passRetained(bridge)` keeps the bridge alive across the
  connection's lifetime regardless of which subsystem nils out.
- **`StreamBridgeContext.current`** is a weak static, guarded by a lock, for
  context-less callback paths. Single in-flight session means a single global
  slot is correct.
- **Event yield.** Receive-thread callbacks yield directly through
  `bridge.eventContinuation?.yield(...)`. `AsyncStream.Continuation` is Sendable
  and FIFO-ordered, so ordering of consecutive callbacks is preserved on the
  consumer side. The previous `Task { await deliver(...) }` pattern lost
  ordering because unstructured Tasks land on the global concurrent executor
  without inter-Task happens-before — `stageStarting` and `stageComplete`
  arriving back-to-back from a receive thread could surface in either order on
  the consumer side.

**Swift 6 strict concurrency posture.** Strict concurrency mode is on . Where
the alternative is "synthesize an actor hop the hot path can't afford," we use
`nonisolated(unsafe)` with the invariant documented at the property and the
synchronisation justified inline. Examples:

- `StreamBridgeContext.session/videoDecoder/audioDecoder/inputForwarder` are
  weak refs; Swift's weak storage is atomic per spec, and the engine serialises
  its callbacks per-stream.
- `VideoDecoder._displayLayer` is guarded by an `NSLock` (the layer itself is
  `AVSampleBufferDisplayLayer.enqueue`-thread-safe per Apple's header, but the
  pointer load/store races against MainActor's nil-out on teardown).
- `VideoDecoder.decompressionSession` / `formatDescription` / SPS / PPS / VPS /
  stream parameters all live on `decodeQueue` and are serialised by it.

See `docs/CONTRIBUTING.md` for the rule on when `nonisolated(unsafe)` is
acceptable.

## Identity & pairing

`Identity.swift`: per-machine 32-hex `uniqueID`, an RSA-2048 keypair, and a
20-year self-signed cert (CN `NVIDIA GameStream Client` — every GameStream
client identifies as this string, including moonlight-qt). Three mode-0600 files
under
`~/Library/Containers/io.ugfugl.Glimmer/Data/Library/Application Support/Glimmer/Identity/`
(post-sandbox):

- `client-cert.pem`
- `client-key.pem`
- `client-uniqueid.txt`

Not the keychain. The top-of-file comment in `Identity.swift` explains why:
adhoc-signed builds re-derive their CDHash on every rebuild, the keychain ACL
pins to the CDHash, every rebuild trips a "Glimmer wants to use its key" prompt.
Files don't have that problem. Mode 0600 + atomic writes + stat-after-chmod
verification (some FUSE / NFS backends silently ignore the chmod).

`Pairing.swift`: the GameStream PIN handshake, five HTTP rounds plus a final
HTTPS liveness check. AES-128-ECB on raw 16-byte buffers (no padding — the
protocol pre-sizes its blocks) keyed off `SHA-256(salt || PIN)[0..16]` (or SHA-1
for pre-Gen-7 GFE, which we detect from `appversion` but don't expect to
encounter on Sunshine). RSA signatures using the long-lived client cert prove
possession of the private key.

Critically: the host cert is pinned (`NetworkClient.setPinnedHostCert`) ONLY
after the RSA signature in step 5 verifies AND the PIN-correctness check passes.
`NetworkClient.fetchServerInfo` will NOT auto-pin on first contact. Threat-model
details and the pinning lifecycle live in [SECURITY.md](SECURITY.md).

## Build pipeline

There is no separate native library and no submodule: the entire streaming
engine compiles as part of the app target. The only external link dependencies
are Homebrew `openssl@3` and `opus`.

### `Glimmer/StreamLib.xcconfig`

Tells Xcode where the OpenSSL/Opus headers and libraries live, and pulls in the
version single-source-of-truth:

```
#include "Version.xcconfig"
HEADER_SEARCH_PATHS  = $(inherited) $(GLIMMER_REPO_ROOT) \
                      $(OPENSSL_PREFIX)/include $(OPUS_PREFIX)/include
LIBRARY_SEARCH_PATHS = $(inherited) $(OPENSSL_PREFIX)/lib $(OPUS_PREFIX)/lib
OTHER_LDFLAGS        = $(inherited) -lssl -lcrypto -lz -lopus
SWIFT_OBJC_BRIDGING_HEADER = $(SRCROOT)/Glimmer-Bridging-Header.h
```

`OPENSSL_PREFIX` and `OPUS_PREFIX` are injected by the Makefile from
`brew --prefix` so the pbxproj stays portable. `Glimmer/Version.xcconfig` is the
single source of truth for `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` — the
version is NOT set in `project.pbxproj`.

### `Makefile`

| Target                   | What it does                                                             |
| ------------------------ | ------------------------------------------------------------------------ |
| `make`                   | Build `Glimmer.app` (Debug) + sign (Dev ID if found, else adhoc)         |
| `make release`           | Same with `CONFIG=Release`                                               |
| `make install`           | Build + copy to `/Applications/Glimmer.app`                              |
| `make dev`               | Fast inner loop: Release build, stable dev signature, install + relaunch |
| `make profile`           | Launch under Instruments (Time Profiler)                                 |
| `make profile-signposts` | Launch under Instruments (Logging template)                              |
| `make dist`              | Clean Release → Developer ID sign → notarize → staple → DMG              |
| `make uninstall`         | Remove `/Applications/Glimmer.app`                                       |
| `make clean`             | `rm -rf build/`                                                          |

Signing/notarization details (dedicated signing keychain, notary profile,
1Password plumbing) are documented in the Makefile itself and in
[RELEASE.md](RELEASE.md).
