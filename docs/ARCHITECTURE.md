# Architecture

Glimmer is a SwiftUI launcher plus a pure-Swift streaming engine, in one
process. No external player, no linked C streaming library: Sunshine's streaming
protocol is implemented in Swift under `Glimmer/Stream/Native/` (ported from
`moonlight-common-c`, GPLv3; see [CREDITS.md](../CREDITS.md)). The only code
that crosses the bridging header is an Objective-C exception guard in
`CHelpers.h`, which Swift can't express; crypto, TLS and audio decode run on
CryptoKit, CommonCrypto, Security, Network.framework and AudioToolbox.

Two helpers sit outside the stream path. The opt-in root LaunchDaemon under
`helper/` parks the AirDrop radio (`awdl0`) for the duration of a stream. It is
loaded through `SMAppService.daemon` and talks XPC. The login item under
`LoginHelper/` opens Glimmer in the menu bar at login when requested. See
[SECURITY.md](SECURITY.md) for the root helper's purpose and limits.

The network helper is an app-like bundle under `Contents/Library/LaunchServices`
with its own Developer ID profile. Its Network Topology Observation entitlement
authorizes routing-socket observation under macOS 27's privacy rules; it does
not replace administrator approval or grant network-interface mutation rights.

The root helper associates suppression with the XPC peer that last claimed it;
an older connection's invalidation cannot release the current owner's claim. An
explicit release from a replacement connection remains valid for recovery. Its
`ifconfig` runner owns and reaps each child before another mutation can proceed.
After two seconds it sends TERM, then KILL after a 250 ms grace period, while
draining and capping output. A child stuck in the kernel still blocks later
mutations until it exits.

Login-item reconciliation probes launchd off the main actor with a two-second
deadline. Only a confirmed missing-service response triggers re-registration;
unknown responses preserve it. Saved intent, service status and registration
revision are rechecked after the await so a stale probe cannot undo a new
choice.

## Overview

The user picks a PC in the SwiftUI launcher and clicks Stream. A native
full-screen Space is the default; saved window and screen-covering preferences
are preserved. Decoded H.264, HEVC or AV1 (8- or 10-bit, SDR or HDR10) is paced
by a display-link-driven `FramePacer` onto an `AVSampleBufferDisplayLayer` for
the OS to paint. Mouse, keyboard and gamepad input goes to the PC through the
`StreamingBackend` input methods (coalesced by an `InputBatcher` onto the
reliable control channel). When the user hits the quit hotkey, the backend is
told to disconnect and the window comes down.

## Process model

Single process, single in-flight stream. `StreamSession.start()`
(`StreamSession+Start.swift`) refuses to start a second session while one is
running (`isStreaming` guard).

Top-level pieces:

| Layer                 | Type                                                     | Lives where                                             |
| --------------------- | -------------------------------------------------------- | ------------------------------------------------------- |
| SwiftUI views         | views + observable state                                 | `Glimmer/ContentView.swift`, `SettingsView.swift`       |
| `AppModel`            | `@MainActor` `@Observable`                               | `Glimmer/AppModel.swift` (+ extensions)                 |
| `StreamSession`       | `actor`                                                  | `Glimmer/Stream/StreamSession.swift` (+ extensions)     |
| `StreamingBackend`    | protocol (the engine boundary)                           | `Glimmer/Stream/StreamingBackend.swift`                 |
| `NativeBackend`       | `final class`, sole backend conformer                    | `Glimmer/Stream/NativeBackend.swift` + `Stream/Native/` |
| `StreamBridgeContext` | `final class`, `@unchecked Sendable`                     | `Glimmer/Stream/StreamBridgeContext.swift`              |
| `NetworkClient`       | `actor` over `ControlTransport` (Network.framework mTLS) | `Glimmer/Stream/Network.swift`                          |
| `PairingClient`       | `actor`                                                  | `Glimmer/Stream/Pairing.swift`                          |
| `IdentityManager`     | `actor` (singleton)                                      | `Glimmer/Stream/Identity.swift`                         |
| `VideoDecoder`        | `@MainActor final class`                                 | `Glimmer/Stream/VideoDecoder.swift` (+ extensions)      |
| `FramePacer`          | `final class`, `@unchecked Sendable`                     | `Glimmer/Stream/FramePacer.swift` (+ extensions)        |
| `AudioDecoder`        | `final class`, `@unchecked Sendable`                     | `Glimmer/Stream/AudioDecoder.swift`                     |
| `InputForwarder`      | `@MainActor final class`                                 | `Glimmer/Stream/InputForwarder.swift`                   |
| `ControllerForwarder` | `@MainActor` extension on InputForwarder                 | `Glimmer/Stream/ControllerForwarder.swift`              |
| `HIDGamepadManager`   | `@MainActor final class` (singleton)                     | `Glimmer/Stream/HIDGamepad/`                            |
| `DualSenseHID`        | `final class`, `@unchecked Sendable` (singleton)         | `Glimmer/Stream/DualSenseHID.swift` (+ extensions)      |
| `StreamWindow`        | `@MainActor final class`                                 | `Glimmer/Stream/StreamWindow.swift`                     |
| `StatsCollector`      | `final class`, `@unchecked Sendable`                     | `Glimmer/Stream/StatsCollector.swift`                   |
| Telemetry (opt-in)    | exporter + counters                                      | `Glimmer/Stream/TelemetryExporter.swift` (+ extensions) |

> The control and HTTP path runs over `ControlTransport`
> (`ControlTransport.swift`): mutual TLS on Network.framework, deliberately
> **not** `URLSession`. The client identity is built in memory from its PEM
> files (`SecIdentityCreate`), so the keychain, which locks on sleep, is never
> in the path, and the PC's self-signed cert is pinned by exact DER in the TLS
> verify block instead of CA-validated.

**Command line.** The same binary is the `glimmer` command. `GlimmerMain`
(`Glimmer/CLI/`) is the entry point: run as `glimmer` (the cask's link), or with
a bare word or `-h`/`--help` as the first argument, it runs `GlimmerCLI`;
anything else (no arguments, `--launched-at-login`, `-psn_*`, `-NS*`, Xcode and
test arguments) starts the app. Login, Launch Services, Sparkle and test
launches depend on that, so any new launch argument the app takes must start
with a dash. Verbs run headless through the app's own `AppModel`, pairing and
`NetworkClient` code. `glimmer stream` opens the app if needed and hands it the
launch over distributed notifications (`CommandChannel`,
`AppModel+Commands.swift`), so no stream ever runs in the terminal's process;
`glimmer quit` ends the app's own stream from that PC the same way. Run through
a symlink, the binary re-execs through its real path so `Bundle.main` and the
defaults domain resolve.

**Shortcuts, Siri and Spotlight.** `GlimmerIntents.swift` declares three App
Intents: Stream from PC, Wake PC and Quit App on PC, with the paired PCs as a
`PCEntity` query. They run inside the app, once `AppModel.forIntent()` has
loaded the PCs, and call the launcher's own entry points (`requestStream`,
`sendWakeAndWait`, `quitRunningApp`), so they share its rules and its wording.
`GlimmerShortcuts` refreshes the PC names Siri knows whenever one is paired,
renamed or removed.

## The `StreamingBackend` boundary

`Glimmer/Stream/StreamingBackend.swift` is **the** streaming-engine abstraction:
one protocol for lifecycle, telemetry and input uplink, plus sink protocols for
the inbound direction (`VideoSink`, `AudioSink`, `ConnectionEvents`), plus
Glimmer-owned value types (`BackendServerInfo`, `BackendStreamConfig`,
`DecodeUnit`, `DecodeBuffer`, `OpusConfig`, `HdrMetadata`, `GamepadAnalog`) so
nothing outside the engine sees wire-level types. `NativeBackend` is the sole
conformer.

The method set deliberately mirrors the protocol's own surface: the outbound
input methods map 1:1 to its `LiSend*` family, and doc comments keep the `Li*`
names as spec citations, so the protocol itself documents the wire contract the
engine satisfies.

Protocol constants live in a Swift mirror (`StreamProtocolConstants.swift`,
`enum StreamProtocol`); nothing imports a `Limelight.h`.

## The native engine (`Glimmer/Stream/Native/`)

`NativeBackend` runs the whole bring-up on a dedicated connect thread:

```text
name resolution → RTSP/SDP handshake over TCP (OPTIONS, DESCRIBE,
SETUP audio/video/control, ANNOUNCE, PLAY) → ENet-subset reliable-UDP
CONTROL channel CONNECT / VERIFY_CONNECT / ACK → START_A → START_B →
connected → stream pings + RTP receive → FEC → depacketize → sinks
```

Components:

- **`RtspClient`** (+`+Handshake`): the RTSP/SDP rounds, including Sunshine's
  encrypted-RTSP variant. `SdpCodec` builds and parses the SDP payloads.
- **`EnetControlChannel`** (+`+Handshake`, `+ControlLoop`, `+Inbound`,
  `+ControlMessages`, `+Send`): a focused, single-peer, client-only ENet subset
  over UDP. It runs the CONNECT handshake, reliable sends with ACK tracking, and
  the inbound control dispatch (rumble, HDR mode, motion enable, lightbar,
  termination). `EnetWire.swift` owns the byte layout (ENet wire format; see
  [CREDITS.md](../CREDITS.md)).
- **`StreamCrypto`**: AES-GCM for the control-V2 envelope and for video the PC
  requires encrypted.
- **Video receive**: `VideoRtpReceiver` (socket and ping loop) → `RtpVideoQueue`
  (+`+AddPacket`, `+Reconstruct`, `+ReceiveQuality`, `+ReorderStats`), which
  reorders, FEC-recovers and assembles packets → `VideoDepacketizer`, which
  emits `DecodeUnit`s to the `VideoSink` (the `VideoDecoder`).
  `ReedSolomon.swift` is the GF(256) erasure decoder (see
  [CREDITS.md](../CREDITS.md)). Once a link has shown reordering, the queue may
  hold back one datagram of the next frame while the current frame is incomplete
  and FEC can still recover it, and only within 24 ms of that frame's first
  packet. It is replayed as soon as the frame completes, a datagram for another
  frame arrives, or the 24 ms window runs out, so the hold is one datagram deep
  and adds no buffer depth.
- **Audio receive**: `RtpAudioReceiver` (+`+Socket`, `+Receive`, `+Decrypt`,
  `+Ping`, `+StartupGate`, `+Events`, `+Telemetry`) → `RtpAudioQueue` (+`+Fec`)
  / `AudioFecDecoder` → `OpusDecoder` (Opus on AudioToolbox) → `AudioDecoder`
  (AVAudioEngine playout with an adaptive cushion). When that cushion trims a
  decoded packet, `AudioPacketSplice` retains the first skipped block and blends
  its first millisecond into the next scheduled block. The blend preserves the
  original join without adding frames; uninterrupted audio is unchanged. A
  drained player or a new session discards the pending join.
- **Spatial audio**: the default stream requests 7.1 from Sunshine so a stereo
  speaker-to-headphone switch retains a surround source without reconnecting.
  `AudioOutputRoute` uses CoreAudio stream terminal types, not device names or
  Bluetooth alone, to identify suitable outputs. `AudioDecoder+Spatial` inserts
  an `AVAudioEnvironmentNode` after varispeed and renders an ambience bed to
  stereo, without reverb. macOS handles head tracking on compatible headphones.
  External stereo speakers use Apple's external-speaker renderer, which keeps
  the LFE channel that the ordinary stereo mixer omits. Physical surround
  outputs keep native multichannel playback; stereo sources need no spatial
  node. A change in spatial renderer rebuilds the graph even when the sample
  rate and channel count are unchanged. There is no app preference to manage.
  The app carries Apple's Head Pose and Spatial Audio Profile entitlements;
  AVAudioEngine applies orientation and any personalized profile within its
  renderer. Glimmer does not read, store or log raw head-pose or profile data.
- **`StreamPathMTU`**: a connect-time egress path-MTU probe. It resolves
  `StreamConfig.remoteness == .auto` from the real route, so the SDP packet-size
  clamp (1392 down to 1024 on a tunnelled path) fires on the paths that need it.
- **Input uplink**: `InputBatcher` + `InputEncoder`. High-rate mouse and
  controller state merges between sends at least 1 ms apart, on a one-shot flush
  timer armed only while input is pending, so an idle stream costs no wakeups;
  edge events pass through in order.
- **`UdpPinger`**: the keepalive ping plumbing and cadences the video and audio
  receivers share; each pings from its own socket.

Inbound callbacks fire on the engine's receive threads and are routed through
`StreamBridgeContext` (below). Stage events (`stageStarting`, `stageComplete`,
`stageFailed`) yield through the bridge's event continuation so the connection
UI lights up live.

## Stream session lifecycle

`StreamSession.start(server:config:appID:…)` returns an
`AsyncStream<StreamEvent>` that drives the launcher's UI state. The phases:

1. **Verify pairing**: `NetworkClient.fetchServerInfo()` (over HTTPS if the PC's
   cert is already pinned, plain HTTP otherwise). If `pairStatus != .paired`,
   throw: the launcher's pair sheet runs first, not us.
2. **Launch, or cancel and launch**: `launchWithBusyRecovery()` always
   renegotiates. If the PC is idle we send `/launch`; otherwise `/cancel`, then
   poll `/serverinfo` until idle (`waitForHostIdle`, up to 5 s), then `/launch`.
   The old “auto-resume if it's our app” path was removed because it preserved
   the PC's previous stream configuration (resolution, FPS, HDR mode) across
   machines: a resume from a laptop after starting on a desktop would carry over
   the desktop's 4K@240 settings. The poll matters because the PC's per-stream
   Undo command has to finish before our `/launch` runs, or display resolution
   lands on whichever of Do and Undo wrote last.
3. **Build `BackendStreamConfig`**: `width`, `height`, `fps`, `bitrate`, the
   `supportedVideoFormats` codec bitmask, `colorSpace`, `colorRange`,
   `encryptionFlags`. The remote-input AES key and IV are copied in from the
   launch response.
4. **Build window, decoder and input on the main actor**: `StreamWindow`,
   `VideoDecoder` and `InputForwarder` are all `@MainActor`. The decoder is
   attached to the window's `AVSampleBufferDisplayLayer` before the connection
   starts so the first decoded frame has somewhere to land.
5. **Build `StreamBridgeContext`**: holds weak references to the session,
   decoder, audio decoder and input forwarder, plus the
   `AsyncStream.Continuation`. `Unmanaged.passRetained` keeps the bridge alive
   for the connection lifetime; `StreamBridgeContext.current` is a weak static
   for context-less callback paths.
6. **Build the event stream before connecting**: the backend fires
   `stageStarting` and `stageComplete` while the connect runs, so the
   continuation has to exist before the call or those early events are dropped.
7. **`backend.startConnectionAsync(server:config:)`**: awaits the RTSP, control
   and media bring-up described above, which runs on the engine's own connect
   thread; throws on failure.
8. **Install timers**: four on the main run loop (the stats-overlay refresh, the
   1 Hz frame watchdog, the present-path watchdog, and the 2 s session tick that
   also feeds the pacer's depth; see `StreamSession+FrameWatchdog.swift`,
   `+Watchdog.swift` and `+PresentMetric.swift`). The frame watchdog asks for
   keyframes from 2 s of decode silence. At `frameWatchdogTimeout` (10 s,
   moonlight-common-c's `FIRST_FRAME_TIMEOUT_SEC`) it tears down, unless video
   has already flowed and ENet ACKs are recent: then it holds, and a remote path
   may downshift the bitrate instead. The watchdogs are suppression- and
   gating-aware: a hidden window legitimately stops presenting, so they read the
   decode gate too (see `VideoDecoder` decode gating).

Teardown (`stop()`) is re-entrant by design: any two of {quit hotkey,
`connectionTerminated` callback, `AsyncStream.onTermination`, connect error
path} can fire back-to-back. `stop()` flips `isStreaming` and `stopInProgress`
before its first await, and later callers wait on the same `SharedTeardown`
instead of running it again.

Stopping cancels the initial server-info task as well as a pending launch.
Native connection events carry their originating backend and preserve arrival
order, so delayed callbacks cannot revive input or stop a replacement
connection. Per-PC launch epochs serialize late cleanup against the next launch:
a new launch waits for an already-sending cancel, while cleanup from an older
epoch cannot cancel a newer session. Different PCs remain independent.

Teardown order is load-bearing:

1. Invalidate the four main-run-loop timers, hide the overlay, and release held
   input while the uplink is still live.
2. `backend.stopConnection()`: synchronous; drains the engine's receive and
   control threads. After this returns, no further backend callbacks can fire.
3. Main-actor teardowns: `input.detach()`, `videoDecoder.teardown()`,
   `window.close()`, so a dead link can't hold a frozen full-screen frame while
   `/cancel` waits.
4. `audioDecoder.shutdown()` (AVAudioEngine drain).
5. `network.cancel()`: tell the PC the session is over so its `currentgame`
   clears.
6. Clear `StreamBridgeContext.current`, release the bridge's
   `Unmanaged.passRetained` +1, then `finish()` the event stream.
7. Release the `beginActivity` power assertion.

The bridge holds weak refs to every subsystem, so a callback firing against a
torn-down subsystem just no-ops. But “no use-after-free” isn't “well-behaved”,
and the order above keeps the engine's receive threads from racing the
AVAudioEngine and AVSampleBufferDisplayLayer teardowns.

## Video pipeline

Owned by `VideoDecoder` (`Glimmer/Stream/VideoDecoder.swift`), with HDR
specifics in `+HDR.swift` and bitstream parsing in `+Bitstream.swift`.

**Packet ingest.** The native engine's depacketizer calls `submitDecodeUnit(_:)`
on its receive thread with an Annex-B elementary-stream `DecodeUnit`, which hops
asynchronously to `decodeQueue` (a serial, user-interactive `DispatchQueue`) so
the receive thread never blocks on VideoToolbox. There we assemble it into a
single `Data` buffer, watch for SPS/PPS/VPS NALs (or the AV1 sequence header
OBU), rebuild the `CMVideoFormatDescription` on IDR, and submit the sample to
`VTDecompressionSessionDecodeFrame`.

**VT decode.** `VTDecompressionSession` is built with hardware acceleration
required (`VTIsHardwareDecodeSupported` is checked per codec at setup).
`kVTDecompressionPropertyKey_RealTime` is set so VT prefers latency over peak
quality. Frames decode asynchronously, and the output callback fires on a
VideoToolbox thread with a `CVPixelBuffer`.

**Pacing and enqueue.** The VT output callback wraps the pixel buffer and format
description in a `CMSampleBuffer` and submits it to the `FramePacer`, a
display-clock pacer (a two-queue model on `AVSampleBufferDisplayLayer` and
`CADisplayLink`). Frames land in a bounded, hostPTS-ordered jitter and reorder
FIFO; a `CADisplayLink` bound to the stream window's screen releases at most one
due frame per vsync to `displayLayer.sampleBufferRenderer.enqueue(_:)`
(`AVSampleBufferVideoRenderer`, the macOS 15+ replacement for the deprecated
`enqueueSampleBuffer`). The tick fires on a private real-time thread and the
release runs on a dedicated serial queue, never the main actor; at rest, a frame
that is already due is released straight from the submit. The target depth rests
at 1 frame and grows one frame per 2 s session tick toward the headroom level
`EnvSignalController` publishes from sustained receive jitter, then decays back
once the level drops (`FramePacer+AdaptiveDepth.swift`). There is no Metal
shader: the OS owns color and EDR handling end to end.

At enqueue, decoded images carry `kCMSampleAttachmentKey_DisplayImmediately`:
the pacer has already decided when to release them. Their RTP timestamps remain
intact for ordering and telemetry. The layer has no custom control timebase;
without this attachment, AVFoundation would interpret those PC timestamps on the
Mac's host clock.

Glimmer supplies the decoded pixel buffers and their color and HDR metadata to
AVFoundation rather than implementing its own color-conversion shader. The
display-layer choice is a product decision, not an Apple restriction on Metal:
Apple also documents
[system tone mapping for Metal video layers](https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content).

**HDR pipeline.** Active when all three preconditions hold:

1. The PC signalled HDR via the control channel's HDR-mode message.
2. The stream is 10-bit (`streamVideoFormat & VIDEO_FORMAT_MASK_10BIT != 0`).
3. The bitstream's VUI or AV1 sequence-header `color_config` declares PQ (SMPTE
   ST 2084), or, for untagged Sunshine bitstreams, we infer PQ from the 10-bit
   and HDR-mode pair.

When active, `VideoDecoder+HDR.configureLayerColorspace` sets:

- `layer.preferredDynamicRange = .high` (macOS 26+ API; replaces the older
  `wantsExtendedDynamicRangeContent` Bool).
- `layer.setValue(CGColorSpace(name: .itur_2100_PQ), forKey: "colorspace")`, via
  KVC because the Swift overlay elides the property on the
  `AVSampleBufferDisplayLayer` subclass.

Per-frame attachments on the `CVPixelBuffer`:

- `kCVImageBufferColorPrimariesKey` = `ITU_R_2020`.
- `kCVImageBufferTransferFunctionKey` = `SMPTE_ST_2084_PQ`.
- `kCVImageBufferYCbCrMatrixKey` = `ITU_R_2020`.

HDR10 static metadata comes from the PC (the native engine surfaces it via
`StreamingBackend.hdrMetadata()`, parsed from the control channel's HDR message)
and is attached as `CMFormatDescription` extensions in the exact HDR10 wire
layout (MDCV: GBR ordering, big-endian; CLL: 4 bytes big-endian). See
`VideoDecoder+HDR.refreshHDRMetadataFromHost()` for the byte-by-byte build. The
cached HDR format description is rebuilt whenever metadata changes (the PC
re-signals HDR with new values, e.g. a game changes EOTF or the PC's display is
hot-swapped).

When HDR drops back to SDR, `preferredDynamicRange` returns to `.standard`, the
layer's `colorspace` is cleared, and the next-frame fallback attaches BT.709
primaries.

**Backpressure and recovery.** `AVSampleBufferVideoRenderer.status == .failed`
latches after a bad sample (mid-stream SPS change, dirty AV1 OBU). The present
path checks it on every frame: on failure the main actor flushes the renderer,
swaps in a fresh display layer (a flush can't clear the latch), and calls
`backend.requestIdrFrame()`. A `RendererFailed` OSSignpost event fires so it
shows in Instruments. `isReadyForMoreMediaData` is also honored: when the
renderer's internal queue fills, frames drop (counted) rather than queueing
unbounded latency. A hidden or occluded stream window suppresses presentation
and, after a sustained window, gates VideoToolbox decode entirely (the PC can't
pause; audio, network and FEC keep running); resume reuses the wait-for-IDR
recovery path.

The present watchdog recognizes a continuous renderer-refusal window longer than
250 ms even if every rejected frame empties the pacing queue. It measures time
between actual attempts, restarts after a 250 ms delivery gap, and requires a
recent refusal, so a network drought cannot age a brief rejection into a
renderer freeze. The existing 90-rejection fallback remains for deep bursts.
Recovery flushes the renderer and requests a keyframe; this limits a freeze's
duration but does not identify why macOS initially stopped accepting frames.

**Stream-format coverage.** H.264 (8-bit and 4:4:4), HEVC (Main / Main10 / RExt
4:4:4), AV1 (Main / Main10 / High 4:4:4). The default set is not a hardcoded
list: `VideoFormats.probedSupported` (`Types.swift`) asks
`VTIsHardwareDecodeSupported` per codec at runtime, with an Apple Silicon gate
on the 4:4:4 profiles, and the per-PC `HostCodecPreference` narrows it further.
Codec negotiation then goes through `BackendStreamConfig.supportedVideoFormats`
(our preferences) and `BackendServerInfo.serverCodecModeRaw` (the raw `SCM_*`
bitmask from `/serverinfo`, passed verbatim; see the landmine note in
`StreamProtocolConstants.swift` for why we don't remap it).

## Input forwarding

`InputForwarder` (`Glimmer/Stream/InputForwarder.swift`, plus the
`ControllerForwarder` extension) hooks events at the responder level via a
custom `StreamInputView` installed as the stream window's first responder.
Earlier revisions used `NSEvent.addLocalMonitorForEvents`, but macOS 26's
responder chain consumes events for content views that accept first responder
before the local-monitor block fires.

All uplink goes through the `StreamingBackend` send methods (`sendKeyboard`,
`sendMouseMove`, `sendMultiController`, …), which the native engine merges
(`InputBatcher`, sends at least 1 ms apart) onto the reliable control channel.

**Mouse.** `CGAssociateMouseAndMouseCursorPosition(false)` freezes the OS cursor
at its current position the moment the window becomes key. Raw HID deltas come
from the underlying `CGEvent`'s `kCGMouseEventDeltaX/Y` fields
(`NSEvent.deltaX/Y` goes to zero when the cursor is frozen). A sub-pixel
residual accumulator carries fractional motion forward so slow trackpad moves
don't round to zero. A cursor warp to screen center before associate-false keeps
the pointer away from hot corners on every supported OS. On macOS 27, the
fullscreen presentation options also disable screen-corner interactions. The
option uses the public SDK 27 enum value so Xcode 26 builds retain this
behavior.

`StreamWindow` owns the counted display hide and transparent cursor image
together. A new input view starts with the pointer visible. Capture enables
both; release disables the transparent image before balancing the hide count.
Detach also retires the view's cursor image, so a late tracking event during the
fullscreen exit animation cannot hide the pointer over the launcher. Closing
windows immediately pass mouse clicks through while their fade and fullscreen
exit finish.

**Keyboard.** Positional scancodes via `sendKeyboard`, with the high bit
(`0x8000`) set to ask the PC to skip layout correction (it otherwise remaps
AZERTY → QWERTY; we want the user's physical key position to win). Every
physical key-down and key-up emits one keyboard event: no per-event modifier
reset, no “release before press” coalescing. NKRO works because AppKit delivers
each transition as its own `NSEvent` and the responder chain hands each to
`keyDown(with:)` / `keyUp(with:)` independently. Held keys, mouse buttons and
modifiers are released on focus loss, a paste, a reconnect and `detach()`. Key
events also release tracked modifiers absent from their current flags,
recovering a lost modifier-up without pressing additional modifiers.

The Cmd key reports as `VK_LWIN` / `VK_RWIN`. By default
(`captureSysKeys == false`) the InputForwarder drops Cmd-bearing keyDown and
`.command` `flagsChanged` events so ⌘-Tab, ⌘-Space and ⌘-Q stay local-Mac
chords. `captureSysKeys = true` forwards everything as a Win-key chord. The
configured quit and stats hotkeys are detected before the `captureSysKeys` gate
so a Cmd-bearing custom quit chord keeps working in either mode.

**Controller.** GameController framework. `GCControllerDidConnect` /
`Disconnect` are observed; per-controller state is kept in
`attachedControllers: [ObjectIdentifier: AttachedController]`. Slot assignment
is a 16-bit `gamepadMask`: bit N == 1 means slot N is in use. Arrival is
announced via `sendControllerArrival` with probed capabilities (some Sunshine
builds silently drop multi-controller events without it). Sunshine keeps a
paired client's virtual pads across a reconnect and ignores an arrival for a
slot it holds, so the forwarder remembers each slot's last arrival
(`announcedControllers`) and, when input is ready again, removes every slot
whose pad left or changed before it replays the arrivals. An entry is cleared
only there, since a removal sent into a link that has already died is lost.
State updates go through `sendMultiController`. Feedback from the PC comes back
through `ConnectionEvents`: rumble (`0x010b`), trigger rumble (`0x5500`),
motion-sensor enable (`0x5501`, answered with `sendControllerMotion` samples),
and RGB lightbar (`0x5502`); `ControllerHaptics`, `ControllerMotion` and
`ControllerBattery` own the actuator and sampler sides.

Mini Player keeps controller input active when another Mac app has focus.
Keyboard and mouse still release on focus loss. A shared ownership set manages
`GCController.shouldMonitorBackgroundEvents` for Mini Player, Diagnostics and
the shortcut recorder, restoring its previous value after the last owner leaves.
Leaving Mini Player in the background releases held controller input; returning
to the stream resynchronizes the pad's current state.

**Raw-HID gamepads.** Pads GameController doesn't own reach the PC through
`HIDGamepadManager` (`Glimmer/Stream/HIDGamepad/`). It enumerates joysticks,
gamepads and multi-axis controllers with `IOHIDManager` and skips any device
GameController owns: `GCController.supportsHIDDevice` on macOS 27, a
platform-vendor and product-name check before that, and a recheck whenever a
GameController pad connects. The hidden `hidGamepadClaimAll` default takes those
pads too, for testing (see [PROFILING.md](PROFILING.md#hidden-defaults)). Each
pad is mapped from the macOS section of SDL's GameControllerDB
(`GameControllerDB+Data.swift`, generated by `scripts/gen-gamecontrollerdb.py`),
with a heuristic layout as the fallback; a keyboard's gamepad interface with no
known mapping is ignored. The forwarder gives each pad a free bit in the same
`gamepadMask` (`ControllerForwarder+HID.swift`), and the manager keeps its own
slot map so rumble from the PC reaches the right pad through ForceFeedback,
never one that took the slot after the PC sent it. Input Monitoring is asked for
only once such a pad is present, never at stream start.

**DualSense side channel.** GameController never delivers a DualSense's Options,
Create or mute buttons. With raw input on (`rawHIDControllerEnabled`, Settings →
Input), `DualSenseHID` opens the pad non-exclusively next to gamecontrollerd,
which keeps sticks, face buttons, triggers, touchpad, rumble and light. It reads
those buttons and the battery from the input report, and writes the PC's
adaptive-trigger effects in one merged output report that re-emits rumble and
light bar with them. `DualSenseRouting` pairs each raw device with its
`GCController` by matching face-button presses (`DualSenseBinder`), so with two
DualSenses each keeps its own buttons and feedback.

**Gesture suppression.** An `NSEvent.addLocalMonitorForEvents` for the narrow
mask `[.magnify, .smartMagnify, .swipe, .rotate]` swallows that gesture family
while the stream window is key. The broader gesture and pressure types
(`.gesture` / `.beginGesture` / `.endGesture` / `.pressure`) are deliberately
excluded: they carry the trackpad pan and scroll the OS synthesizes `mouseMoved`
from, so swallowing them would kill cursor and scroll on trackpad-only Macs. The
scroll wheel is not swallowed either; it forwards to the PC as scroll events.

**Input gating.** The engine refuses input until the control channel is up: the
backend's `send*` methods return -2 before then (mirroring upstream
`InputStream.c`'s `initialized` guard). `InputForwarder.isReady` flips true when
`connectionStarted` fires; until then events drop on the floor instead of
flooding the log with -2s.

## Window model

`StreamWindow` (`Glimmer/Stream/StreamWindow.swift`). One `KeyableWindow` per
session, borderless in full screen. `KeyableWindow` is a thin `NSWindow`
subclass that returns true for `canBecomeKeyWindow` and `canBecomeMainWindow`:
borderless windows default to false, which silently breaks
`makeKeyAndOrderFront` and the responder chain.

**Window level.** `.normal`. We tried the shielding-window level
(`CGShieldingWindowLevel()`): AppKit marks the window key and the responder
points at our view, but `sendEvent:` silently drops keyDown and keyUp. Menu bar
suppression happens via `NSApp.presentationOptions = [.hideMenuBar, .hideDock]`
instead. (When `coversNotch == true`, `show()` raises the level to
`NSWindow.Level(rawValue: CGWindowLevelForKey(.mainMenuWindow) + 1)` so the
window paints over the menu-bar zone and notch reserve; when the user Cmd-Tabs
away, the window is ordered out, as Backgrounding describes.)

**Display layer as root.** `AVSampleBufferDisplayLayer` is installed as the
content view's root layer (`view.layer = layer` before
`view.wantsLayer = true`), not a sublayer of a default backing layer.
Compositing through an intermediate sRGB layer flattens EDR back to SDR before
the panel sees it.

**Stats overlay.** A `StatsOverlayLayer` is attached as a sublayer of the
display layer (not a sibling: root-layer status is the precondition). The OS
composites the sRGB text against the HDR content correctly.

**Dual-path fullscreen: the `coversNotch` toggle.** Two paths, picked per
session config:

- **`coversNotch == true`**: a borderless covering window at the
  `mainMenuWindow + 1` level,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
  No Space-based fullscreen. The window owns the full physical panel, including
  the notch reserve on notched MacBooks. Bitstreams at the panel's true native
  resolution render 1:1.
- **`coversNotch == false`** (default): `toggleFullScreen(nil)` for Space-based
  fullscreen. AppKit handles the Space creation and reserves the menu-bar and
  notch area as safe inset. Same path SDL's
  `SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES=1` uses.

Both paths support HDR: EDR follows the layer's PQ content, not the window's
Space membership.

On displays without a notch, “Use a full-screen Space” defaults on. On notched
displays, “Keep picture below the camera” defaults off: a Space can't draw
beside the camera, so the borderless cover fills the whole panel. Each display
type keeps its own saved preference, and changes apply to the next stream.

**Game Mode.** `LSSupportsGameMode = true` and the Games application category
make Glimmer eligible. macOS may activate Game Mode in native fullscreen; the
persistent per-app on/off control is Game Overlay → Settings → Game Mode. There
is no app-local runtime setter. The borderless cover qualifies too: gamepolicyd
starts a full-screen gaming session for it. See
[Apple's Game Mode guide](https://support.apple.com/en-us/105118) and
[`LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode).

**Backgrounding.** A resign is debounced 200 ms so transient controller-connect
focus changes do not hide the cover. The borderless cover is ordered out when
the app deactivates; a native fullscreen Space stays with the window manager.
Both release the pointer and update the launcher's “Back to Stream” affordance,
including when another Glimmer window takes focus from a native Space.
`onBackgroundedChanged` drives launcher state; the separate
`onPresentationSuppressedChanged` follows actual visibility, occlusion, and
minimization. A visible unfocused Space continues presenting. A hidden window
suppresses presentation and eventually gates decode while audio and receive
continue. Uncovering it resumes through the existing decoder resynchronization.

“Back to Stream” calls `StreamSession.resumeWindow()` to bring the window back.
App activation alone does not order it front: clicking the launcher to change a
setting must not pull the player back into the stream.

**`NSWindow.sharingType`** = `.none` is a best-effort hint for legacy capture
clients. Modern ScreenCaptureKit ignores it, so the stream can appear in screen
recordings and shares. It is not a privacy boundary; see
[SECURITY.md](SECURITY.md#runtime-hardening).

## Crossing isolation: receive threads ↔ Swift actors

The native engine delivers frames, audio and control events on its own receive
threads, which neither the actor system nor `@MainActor` knows about, and
round-tripping every frame through an actor costs too much latency. The bridge
handles this:

- **`StreamBridgeContext`** (`Glimmer/Stream/StreamBridgeContext.swift`) is the
  single instance allocated per session. It holds _weak_ references to the
  session and every subsystem, plus the `AsyncStream<StreamEvent>.Continuation`.
  A subsystem torn down before the receive threads drain just becomes nil at the
  callback site: no use-after-free, no order dependency.
- `Unmanaged.passRetained(bridge)` keeps the bridge alive across the
  connection's lifetime regardless of which subsystem nils out.
- **`StreamBridgeContext.current`** is a weak static, guarded by a lock, for
  context-less callback paths. A single in-flight session means a single global
  slot is correct.
- **Event yield.** Receive-thread callbacks yield directly through
  `bridge.eventContinuation?.yield(...)`. `AsyncStream.Continuation` is Sendable
  and FIFO-ordered, so consecutive callbacks keep their order on the consumer
  side. The previous `Task { await deliver(...) }` pattern lost ordering because
  unstructured Tasks land on the global concurrent executor without inter-Task
  happens-before: `stageStarting` and `stageComplete` arriving back-to-back from
  a receive thread could surface in either order on the consumer side.

**Swift 6 strict concurrency posture.** `SWIFT_STRICT_CONCURRENCY = complete` on
every configuration. Where the alternative is “synthesize an actor hop the hot
path can't afford”, we use `nonisolated(unsafe)` with the invariant documented
at the property and the synchronisation justified inline. Examples:

- `StreamBridgeContext.session/videoDecoder/audioDecoder/inputForwarder` are
  weak refs; Swift's weak storage is atomic, and the engine serialises its
  callbacks per stream.
- `VideoDecoder._displayLayer` is guarded by an `NSLock` (the renderer's
  `enqueue` is thread-safe, but the pointer load and store race the main actor's
  nil-out at teardown).
- `VideoDecoder.decompressionSession` / `formatDescription` / SPS / PPS / VPS /
  stream parameters all live on `decodeQueue` and are serialised by it.

See [CONTRIBUTING.md](CONTRIBUTING.md#nonisolatedunsafe) for the rule on when
`nonisolated(unsafe)` is acceptable.

## Identity & pairing

`Identity.swift`: a per-machine 32-hex `uniqueID`, an RSA-2048 keypair, and a
20-year self-signed cert (CN `NVIDIA GameStream Client`, the string every client
of this protocol identifies as). Three mode-0600 files under
`~/Library/Application Support/Glimmer/Identity/`:

- `client-cert.pem`
- `client-key.pem`
- `client-uniqueid.txt`

The pairing identity remains file-backed. Provisioned capabilities now remove
one historical obstacle to evaluating the data-protection keychain, but no
identity migration is part of that signing change. Files get mode 0600, atomic
writes and a stat-after-chmod check (some FUSE and NFS backends silently ignore
the chmod). See SECURITY.md for the remaining same-user exposure.

`Pairing.swift`: the PIN handshake, four HTTP rounds plus a final HTTPS
`pairchallenge`. AES-128-ECB on raw 16-byte buffers (no padding; the protocol
pre-sizes its blocks) keyed off `SHA-256(salt || PIN)[0..16]`, with SHA-256 for
the challenge hashes too; a PC running NVIDIA GameStream is refused before the
handshake starts. RSA signatures using the long-lived client cert prove
possession of the private key.

Critically: the PC's cert is pinned (`NetworkClient.setPinnedHostCert`) only
after the RSA signature in step 5 verifies and the PIN-correctness check passes.
`NetworkClient.fetchServerInfo` will not auto-pin on first contact. Threat-model
details and the pinning lifecycle live in [SECURITY.md](SECURITY.md).

## Build pipeline

There is no separate native library and no submodule: the entire streaming
engine compiles as part of the app target. Apart from Sparkle, embedded for
updates, Glimmer links no third-party library, so the shipped app needs nothing
installed to run.

### `Glimmer/StreamLib.xcconfig`

Points Xcode at the bridging header and pulls in the version's single source of
truth:

```text
#include "Version.xcconfig"
GLIMMER_REPO_ROOT          = $(SRCROOT)
HEADER_SEARCH_PATHS        = $(inherited) $(GLIMMER_REPO_ROOT)
ARCHS                      = arm64
SWIFT_OBJC_BRIDGING_HEADER = $(SRCROOT)/Glimmer-Bridging-Header.h
```

`ARCHS = arm64` is pinned so the Release build stays Apple Silicon only, the
platform Glimmer ships for. `Glimmer/Version.xcconfig` is the single source of
truth for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the version is not
set in `project.pbxproj`.

### `Makefile`

Every build that gets installed goes through the same pipeline the shipped build
does, so there is no ad hoc or Debug divergence in signing, notarization or
library validation to chase. Developer ID signing and explicit app and helper
profiles are required for installation. `make app` and `make test` build Debug
and never sign; they need no profiles.

| Target                   | What it does                                                                 |
| ------------------------ | ---------------------------------------------------------------------------- |
| `make app`               | Compile-only check, no signing or notarization                               |
| `make test`              | Build + run the `GlimmerTests` bundle                                        |
| `make verify`            | Strict SwiftLint, release-tool tests and Swift tests; the gate `dist` runs   |
| `make release`           | Notarized Release build, no install                                          |
| `make` / `make install`  | `release` + copy to `/Applications/Glimmer.app`                              |
| `make reinstall`         | `install` + quit and relaunch the running app                                |
| `make dev`               | Inner loop: `test`, then `reinstall`                                         |
| `make profile`           | Launch under Instruments (Time Profiler)                                     |
| `make profile-signposts` | Launch under Instruments (Logging template)                                  |
| `make dist`              | `verify`, then clean Release → Developer ID sign → notarize → staple → DMG   |
| `make release-publish`   | `dist` + EdDSA-signed ZIP → GitHub release + Sparkle appcast → Homebrew cask |
| `make uninstall`         | Remove `/Applications/Glimmer.app`                                           |
| `make clean`             | `rm -rf build/`                                                              |

Signing and notarization details (the dedicated signing keychain, the notary
profile, the credentials file) are documented in the Makefile itself and in
[RELEASE.md](RELEASE.md).
