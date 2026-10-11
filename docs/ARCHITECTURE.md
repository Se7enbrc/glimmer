# Architecture

Find the subsystem you need to change, then preserve its ownership and recovery
rules. For setup and checks, use the [developer guide](CONTRIBUTING.md).

## Overview

Follow one stream through one Swift process: network → decode → pacing →
display, with audio and input alongside it.

Glimmer implements Sunshine's RTSP-based protocol in `Glimmer/Stream/Native/`,
ported from moonlight-common-c. It uses system video, audio and cryptography
frameworks, with no external player, linked C streaming engine or Objective-C
shim. Sparkle handles updates. See
[credits](https://github.com/Se7enbrc/glimmer/blob/main/CREDITS.md).

| Outside the stream process | Responsibility                                                                |
| -------------------------- | ----------------------------------------------------------------------------- |
| `helper/`                  | Optional root LaunchDaemon pauses `awdl0`; XPC through `SMAppService.daemon`. |
| `LoginHelper/`             | Opens Glimmer in the menu bar at login when enabled.                          |

The network helper has its own profile and Network Topology Observation grant.
Its current XPC peer owns suppression; old invalidation cannot release a newer
claim. The `ifconfig` runner reaps each child before another mutation: TERM at
two seconds, KILL after 250 ms. A kernel-stuck child blocks later mutations.

Login reconciliation probes launchd off main with a two-second deadline. Only
confirmed absence triggers registration; saved intent, status and revision are
rechecked after awaiting. Unknown results preserve the existing registration.

## Process model

Keep one in-flight stream; `StreamSession.start()` refuses a second.

| Layer                      | Ownership and source                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------- |
| Views and app model        | Main actor; `ContentView.swift`, `SettingsView.swift`, `AppModel.swift` and extensions. |
| Stream lifecycle           | `StreamSession` actor in `Stream/StreamSession*.swift`.                                 |
| Protocol                   | `StreamingBackend`, `NativeBackend`, `Stream/Native/`.                                  |
| Callback bridge            | `StreamBridgeContext`, weak subsystem references and ordered events.                    |
| Network, pairing, identity | `NetworkClient`, `PairingClient`, `IdentityManager` actors.                             |
| Video                      | Main-actor `VideoDecoder` lifecycle, serial decode queue, locked display-layer access.  |
| Pacing                     | `FramePacer`, dedicated display tick and serial release queue.                          |
| Audio                      | `AudioDecoder`, packet worker, SPSC PCM ring and HAL callbacks.                         |
| Keyboard and mouse         | Main-actor `InputForwarder` and `StreamInputView`.                                      |
| Controllers                | Main-actor lifecycle, locked `InputCore`, dedicated capture queues.                     |
| Raw controllers            | `HIDGamepadManager`, `DualSenseHID`, owned HID run loop.                                |
| Window                     | Main-actor `StreamWindow`.                                                              |
| Metrics                    | Locked `StatsCollector`; optional `TelemetryExporter`.                                  |

### Commands and App Intents

Route every entry point through the app's existing model and session code.

`GlimmerMain` runs CLI verbs when invoked as `glimmer`, with a bare command, or
with `-h`/`--help`. App launch arguments must start with a dash. A symlink
invocation re-execs the real binary so bundle/defaults lookup stays correct.

Pair/list/wake/quit run headlessly. Stream hands off to the app over
`CommandChannel` distributed notifications; status queries it without opening
the app or contacting the PC. URLs parse into the same command type, with
mandatory quit confirmation. See [command reference](COMMAND_LINE.md).

`GlimmerIntents.swift` provides Stream from PC, Wake PC and Quit App on PC.
`PCEntity` exposes saved PCs; `GlimmerShortcuts` refreshes names after pairing,
rename or removal. These actions use the launcher's own entry points.

## The `StreamingBackend` boundary

Keep wire types inside the engine and use Glimmer-owned values at its boundary.

`StreamingBackend` owns lifecycle, telemetry and input uplink; `NativeBackend`
is its existing sole conformer. `VideoSink`, `AudioSink` and `ConnectionEvents`
carry inbound work. Do not add speculative abstractions or single-conformer
protocols.

`BackendServerInfo`, `BackendStreamConfig`, `DecodeUnit`, `DecodeBuffer`,
`OpusConfig`, `HdrMetadata` and `GamepadAnalog` describe the boundary. Input
methods mirror the upstream `LiSend*` contract. Constants in
`StreamProtocolConstants.swift` preserve upstream C names for searching.

## The native engine (`Glimmer/Stream/Native/`)

Use the connect thread for bring-up and dedicated receive paths for media.

```text
Resolve → RTSP/SDP → ENet connect/verify/ack → START_A → START_B
        → connected → pings and RTP receive → FEC → depacketize → sinks
```

| Component                                              | Responsibility                                                                               |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `RtspClient`, `SdpCodec`                               | OPTIONS, DESCRIBE, SETUP, ANNOUNCE, PLAY and encrypted RTSP.                                 |
| `EnetControlChannel`, `EnetWire`                       | Single-peer client ENet subset, reliable ACKs, rumble/HDR/motion/light/termination messages. |
| `StreamCrypto`                                         | Control-V2 and required video AES-GCM.                                                       |
| `VideoRtpReceiver`, `RtpVideoQueue`                    | Socket batches, reorder, FEC and assembly.                                                   |
| `VideoDepacketizer`, `ReedSolomon`                     | Decode units and portable SIMD GF(256) recovery.                                             |
| `RtpAudioReceiver`, `RtpAudioQueue`, `AudioFecDecoder` | Audio receive, reorder, decrypt and FEC.                                                     |
| `StreamPathMTU`                                        | Egress route/MTU probe; tunnel packet clamp from 1392 to 1024 when needed.                   |
| `InputBatcher`, `InputEncoder`, `InputSendThread`      | Merge state and send ordered edges on reliable control.                                      |
| `UdpPinger`                                            | Keepalives from each media receiver's own socket.                                            |

After observed reordering, video may retain one next-frame datagram while the
current frame is recoverable, within 24 ms of its first packet. Completion,
another frame or timeout replays it; this does not add a frame of buffer depth.

### Audio output

Keep decode work away from HAL callbacks and preserve the adaptive cushion.

```text
64-slot packet ring → AudioPacketWorker → Opus/PLC → AudioPCMQueue
→ AUVarispeed → optional AUSpatialMixer → AUMultiChannelMixer → HAL
```

The user-interactive worker requests a best-effort 5 ms Mach deadline. PCM,
ciphertext and FEC storage are preallocated. HAL reads raw pointers and
lock-free atomics only. Decode admission closes under `stateLock` before graph
changes; HAL work runs after releasing that lock. Packets during reconfiguration
are counted and discarded. Shutdown joins the worker, stops HAL and disposes
units before freeing callback memory.

Preserve PI gains, slew and bounds, the 30 ms base cushion, 10 ms growth steps,
link-aware caps, 250 ms catch-up grace, bounded silence backfill, and trim
hysteresis/spacing of 15/100 ms. `AudioPacketSplice` blends the first
millisecond after a trim. Teardown/device replacement cannot teach a false
underrun.

### Spatial playback and recovery

Follow the output route automatically, with no app-local spatial toggle.

Request 7.1 so output switches retain the surround source. `AudioOutputRoute`
uses Core Audio terminal types. Multichannel sources on stereo outputs use
AUSpatialMixer's ambience bed, output-type rendering and no reverb. Compatible
headphones request head tracking and automatic personalized HRTF; that request
does not prove a profile was used. Native surround outputs and stereo sources
bypass it.

Preserve channel labels, LFE and Sunshine's 7.1 side/rear mapping through rate
conversion. Default-output, device-alive, rate and stream-format listeners drive
OSStatus recovery off the render thread. An unavailable output leaves receive
and decode alive. No raw head-pose/profile data is collected. See
[audio verification](PROFILING.md#audio-device-checks).

## Stream session lifecycle

Create the event stream and display target before starting the connection.

1. Fetch PC status and require pairing.
2. Launch if idle; otherwise confirm takeover when needed, cancel and wait up to
   five seconds for idle before launching. Let Sunshine finish Undo commands.
3. Build `BackendStreamConfig`, including formats, colour, bitrate and session
   keys.
4. Build the window, decoder and input on main; attach the display layer.
5. Retain `StreamBridgeContext` for the connection lifetime and create the event
   continuation.
6. Await native bring-up; callbacks yield stage events during connection.
7. Install stats, frame, present and two-second session timers.

A new launch always renegotiates; a stopped session is not resumed on another
link. The frame watchdog requests keyframes after two seconds of decode silence.
At ten seconds it tears down unless video previously flowed and control ACKs
remain recent; a remote route may reduce bitrate instead. Hidden decode gates
suppress inappropriate watchdog recovery.

### Teardown

Release input while the uplink is alive, then drain callbacks before destroying
their targets.

1. Mark stopping before awaiting; repeated callers share `SharedTeardown`.
2. Cancel status/launch work, invalidate timers, hide stats and release held
   input.
3. Stop the backend and drain receive/control threads.
4. Detach input, tear down video, close the window and shut down audio.
5. Settle pending launch work, cancel this session's PC app and close control.
6. Clear/release the bridge, finish events and release the power assertion.

Every stop path uses this order. Cancellation is bounded and best-effort when
the PC is unreachable. A PC-side quit or another client's takeover clears
ownership. Per-PC launch epochs keep late cleanup from cancelling a newer
session; different PCs remain independent. Events retain their originating
backend so delayed callbacks cannot revive a retired connection.

## Video pipeline

Keep receive, decode and presentation independent so one slow stage cannot block
the others.

| Stage   | Contract                                                                                       |
| ------- | ---------------------------------------------------------------------------------------------- |
| Receive | `submitDecodeUnit` queues Annex-B or AV1 work asynchronously onto serial `decodeQueue`.        |
| Format  | Watch SPS/PPS/VPS or sequence OBUs, rebuild on IDR, submit a sample to VideoToolbox.           |
| Decode  | Require hardware support and set the real-time hint; VT returns pixel buffers asynchronously.  |
| Pace    | Bounded timestamp-ordered FIFO; display link releases at most one due frame per tick off main. |
| Present | Enqueue on `AVSampleBufferDisplayLayer`; no custom Metal renderer or timebase.                 |

Depth rests at one frame, rises one per two-second session tick toward measured
jitter headroom and recovers afterward. Due frames at rest can release on
submit. `DisplayImmediately` is required because the pacer already chose the
release time; RTP timestamps stay intact for order and telemetry.

### Colour and HDR

Resolve declared colour tags before using negotiated fallbacks.

Use VT pixel-buffer tags, then compressed-format extensions, then negotiated SDR
colour (BT.709 by default). Output pixel format owns range. HEVC parameter sets
and AV1 sequence headers supply compressed colour metadata.

Declared tags survive independently. Missing primaries/transfer can use
BT.2020/PQ for control-channel HDR with 10-bit input. Declared PQ/HLG fills
missing primaries/matrix with BT.2020; explicit SDR transfer stays SDR. Cache
attachments and range; do not force a colour triple or use a KVC override.

PQ/HLG requests high dynamic range; actual HDR output also needs display EDR
headroom above one. HDR10 MDCV uses GBR big-endian order and CLL four big-endian
bytes. Metadata changes invalidate sample formats; SDR removes HDR metadata.
Keep colour-probe breadcrumbs and the current-transition EDR checks at 1, 3 and
5 seconds.

### Backpressure and format support

Drop bounded work under pressure and recover when the renderer or decoder fails.

A failed renderer needs a fresh layer, not only a flush, plus an IDR request.
Honor `isReadyForMoreMediaData`. A continuous refusal over 250 ms can trigger
recovery; gaps over 250 ms reset that evidence. The 90-rejection fallback
remains. Hidden windows suppress presentation and later decode;
audio/network/FEC continue. Uncovering uses wait-for-IDR recovery.

Probe hardware support at runtime for H.264, HEVC and AV1, including supported
8/10-bit and 4:4:4 profiles. Apply the per-PC codec preference afterward. Pass
Sunshine's raw `SCM_*` bitmask through unchanged; do not remap it.

## Input forwarding

Use `StreamInputView` responders and the shared backend send path.

`InputBatcher` merges replaceable mouse/controller state at least 1 ms apart.
Edges bypass the merge delay and return local channel acceptance in order. The
sender owns encoding, sealing and submission and sleeps when idle. No input
waits for an ACK or adds a launch round trip.

### Mouse and keyboard

Preserve physical key ownership and pending releases across focus and connection
changes.

Fullscreen starts relative/captured for every app, including Desktop. Control-P
switches to absolute mapping over the aspect-fitted picture. Use raw CGEvent
deltas and fractional accumulation; frozen-cursor NSEvent deltas can be zero.
Warp away from hot corners before capture. macOS 27 also uses its public
screen-corner suppression option.

Capture owns both the counted cursor hide and transparent cursor. Release
retires transparency before balancing hides; closing windows pass clicks
through. Physical keys use positional scancodes with `0x8000`. Command stays
local by default; forwarding applies only fullscreen or captured. Hotkeys
precede that gate.

### Release ledger and text

Keep failed releases pending before allowing new presses or text.

Focus loss, sleep, readiness loss, paste and detach release held input.
Reconciliation runs after event gaps and on the recovery timer; keyboard checks
need Input Monitoring and two missing samples, mouse checks cover buttons 0–4. A
replacement connection repeats possibly unacknowledged releases, never old
presses.

Free-pointer mode retains AppKit IME composition; captured mode sends physical
keys. Text commits preserve held game keys while releasing modifiers. Paste
releases held input; commits and later keys wait behind pending releases in
order.

### Controllers

Keep capture off main and UI/lifecycle publications on main.

GameController callbacks use a serial user-interactive queue and locked
`InputCore`. Arrival announces capabilities; reconnect removes stale slots
before replaying arrivals and current state. Old callbacks cannot reach retired
slots. Rumble, trigger rumble, motion, battery and light feedback use the shared
routing.

Mini Player retains background controller input, while keyboard/mouse follow
focus. Background monitoring has shared ownership with diagnostics and shortcut
recording and restores its original value after the last owner leaves.

Start held over 750 ms then released toggles per-slot controller mouse. Stop
chords cancel toggles. Mouse buttons share the release ledger; stick polling
runs only while moving/scrolling. Touchpad coordinates come from GameController.
Nintendo layout swaps only outgoing A/B and X/Y after positional mouse/chord
handling.

### Raw HID and gestures

Avoid duplicate pads and preserve normal trackpad movement.

`HIDGamepadManager` skips devices GameController owns, using its public check on
macOS 27 and vendor/product checks earlier. SDL's macOS database supplies
mappings; a heuristic handles unknown pads, excluding unmapped keyboard gamepad
interfaces. Input Monitoring is requested when needed, not at stream start.

`DualSenseHID` adds Options/Create/mute, battery and adaptive-trigger reports
without taking over sticks and ordinary feedback. `DualSenseBinder` matches
face-button presses to route multiple pads correctly. Merged reports retain
rumble/light.

Suppress only magnify, smart magnify, swipe and rotate while streaming. Broader
gesture/pressure masks would swallow trackpad pointer/scroll events. Input
remains gated until the control channel is ready.

## Window model

Keep the display layer as the root layer and preserve each display type's
fullscreen preference.

| Presentation              | Behavior                                                                                |
| ------------------------- | --------------------------------------------------------------------------------------- |
| Borderless cover, default | Whole physical panel at main-menu level + 1, including the notch area; no native Space. |
| Native full-screen Space  | AppKit owns the Space and safe inset below the camera.                                  |
| Window/Mini Player        | Keyboard/mouse follow focus; Mini Player can retain background controllers.             |

`KeyableWindow` allows key/main status. Do not use shielding-window level, which
loses keyboard delivery. The stats layer is a child of the display layer so
macOS composites it against HDR. Game Mode eligibility is declared, but macOS
owns its switch; no private API or signed-plist edits.

Borderless deactivation waits 200 ms before hiding to ignore transient focus
changes. Actual visibility separately drives presentation/decode suppression.
“Back to stream” restores the window; app activation alone must not pull it
forward. The legacy `.none` sharing hint does not block ScreenCaptureKit.

## Crossing isolation: receive threads ↔ Swift actors

Retain the bridge through callback drainage and keep event delivery ordered.

`StreamBridgeContext` holds weak subsystem references and a Sendable FIFO event
continuation. A retained unmanaged reference owns its connection lifetime; the
locked weak `current` slot serves callbacks without context. Do not wrap
consecutive events in unstructured tasks.

Complete strict concurrency applies everywhere. Unsafe isolation and unchecked
sendability require documented invariants: serialized callback refs,
decode-queue state, locked display-layer loads/stores and the locked shared
format box. See [concurrency rules](CONTRIBUTING.md#concurrency).

## Identity & pairing

Use the shared file-backed identity and authenticated pinning flow.

Identity is RSA-2048 with owner-only files. Pairing performs four HTTP rounds
and HTTPS liveness, using PIN-derived AES-ECB challenges and RSA proofs. Only a
verified signature and PIN proof permit pinning. First contact never pins. See
[protocol security](#protocol-security) for storage, limits and migration rules.

## Build pipeline

Compile the engine into the app target and keep version fields in one place.

`Glimmer/StreamLib.xcconfig` includes `Version.xcconfig`, pins arm64 and enables
compiler protections. Release strips path-bearing debug maps for
reproducibility. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` belong in
`Version.xcconfig`, not the project file.

Unsigned compile checks/tests need no signing profiles. Installed builds use the
same Developer ID signing, notarization and explicit-profile path as releases.
Use the [build command table](CONTRIBUTING.md#build) and
[release process](RELEASE.md) for operations.

## Protocol security

Review these boundaries when changing pairing, transport or local commands.

### Threat model

Treat Glimmer as a client for your own PC, not an isolation boundary against a
compromised Mac or PC.

| Threat                                       | Protection or limit                                                                                                      |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Someone observing the network                | Input is encrypted; video is plaintext unless Sunshine requires encryption. Audio encryption has protocol limits below.  |
| Someone intercepting connections             | PIN-verified pairing establishes a certificate pin; later certificate mismatches fail. First contact is unauthenticated. |
| Malicious paired PC                          | Pairing proves identity, not safe data. Protocol-parser bugs belong to Glimmer and should be reported here.              |
| Software running as your Mac user            | Can read identity files, replace pins and send local commands. Owner-only permissions do not stop it.                    |
| Root, a compromised macOS or build toolchain | Outside the protection model. Nation-state attacks are also outside scope.                                               |

Sunshine protocol-design limits are documented below. Bugs in
[Sunshine itself](https://github.com/LizardByte/Sunshine) belong upstream.

### Local commands and links

Distinguish local automation from links that can arrive through a browser.

| Entry point           | Boundary                                                                                                                                                                           |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local command channel | Distributed notifications are unauthenticated. Software running as you can start or end streams, quit PC apps and authorize takeover. CLI/UI confirmation happens before dispatch. |
| `glimmer://` links    | Only stream, wake and quit for saved PCs. Quit always asks; stream uses normal takeover checks.                                                                                    |
| Malformed links       | Unknown or duplicate parameters, empty/control-character values, paths, credentials, ports and fragments are rejected without logging their contents.                              |

See [URL commands](COMMAND_LINE.md#url-commands). There is no stop or pair URL
action.

### Identity

Protect your Mac account and the files under
`~/Library/Application Support/Glimmer/Identity/`.

| File                  | Contents                                                     |
| --------------------- | ------------------------------------------------------------ |
| `client-cert.pem`     | Self-signed RSA-2048 client certificate, valid for 20 years. |
| `client-key.pem`      | Unencrypted PKCS#8 private key.                              |
| `client-uniqueid.txt` | 32-character hexadecimal client ID.                          |

Files use mode 0600 in a mode-0700 directory. Writes are atomic and verify
permissions; failures remove the partial file. The identity is file-backed, not
in the keychain, and software running as you can read it.

On first launch, Glimmer can import moonlight-qt's identity and pairings. It
never changes Moonlight's preferences or their permissions. The one-time import
does not create a stronger boundary around Moonlight's original copy.

### Pairing

Enter Glimmer's four-digit PIN in Sunshine only on a trusted network or
authenticated encrypted tunnel.

Do not expose Sunshine's pairing or streaming ports directly to the internet.
Four-digit PINs have about 13 bits of entropy; retry handling does not establish
resistance to offline guessing of a captured handshake.

Glimmer checks the PC's RSA signature and PIN proof before sending its own
pairing secret and committing the pin. Imported identities, pairing certificates
and pinned peers need RSA keys of at least 2048 bits. Rejected keys and
certificates are not silently replaced; fix them at the source and re-pair.

#### Protocol limits

Use Sunshine's mandatory encryption mode for video, while recognizing what it
cannot fix.

| Mechanism           | Limit                                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Pairing AES-128-ECB | Protocol-required, unauthenticated cipher; signatures and challenge checks supplement it.                                               |
| Audio AES-128-CBC   | No authentication tag; IVs derived from the session value and 16-bit sequence repeat on wrap. Padding checks do not authenticate audio. |
| TLS 1.2 minimum     | Glimmer does not require an ephemeral key agreement suite, so forward secrecy is not guaranteed.                                        |
| GCM counters        | Direction/channel-specific deterministic IVs must stay unique under each fresh session key.                                             |

CryptoKit, CommonCrypto and Security provide the cryptography. Random keys,
salts and challenges use system cryptographic generators. See
[NIST's GCM IV guidance](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf#page=28).
These constraints are not a claim of a newly demonstrated Glimmer exploit.

### Pinning

Choose “Pair again…” after confirming a legitimate certificate change on the PC.

A mismatch fails the connection and shows “Trust needed”. Glimmer does not
silently replace a pin. TLS compares the PC's exact certificate bytes, with
session resumption disabled; the system certificate authorities are not the
trust anchor.

Pins live in `~/Library/Application Support/Glimmer/PinnedHosts/<hostID>.pem` at
mode 0600. IDs are sanitized to `[A-Za-z0-9-_.]`. The file wins; a missing or
unreadable file falls back to the legacy defaults pin and attempts migration. A
conflicting or unmigratable PC-record pin requires re-pairing.

Plain-HTTP discovery data cannot establish trust: `<PlainCert>` and
`<PairStatus>` from `/serverinfo` are ignored before pairing, and HTTPS without
a pin is refused.

### Transport

Use the table to see which parts of a session are encrypted.

| Path              | Protection                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------------ |
| Before pairing    | HTTP on 47989; four pairing rounds, then a final HTTPS liveness check.                                 |
| Paired requests   | Mutual TLS on 47984 for status, app lists, artwork, launch and cancellation; session keys travel here. |
| RTSP setup        | AES-128-GCM over TCP with `rtspenc://`; unencrypted replies are rejected.                              |
| Control and input | AES-128-GCM over ENet/UDP in both directions.                                                          |
| Video             | UDP, plaintext by default; AES-128-GCM when Sunshine requires encryption.                              |
| Audio             | UDP, AES-128-CBC whenever offered, as current Sunshine does.                                           |

Video and audio check the resolved PC's source IP, allowing varying source
ports. This rejects unrelated senders but does not authenticate plaintext
packets or prevent IP spoofing. Encryption cannot stop packets being dropped or
delayed.

#### Network paths

Use this list for the connections outside the media stream.

| Path                      | Exposure and check                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Bonjour discovery         | Unauthenticated `_nvstream._tcp` and `_nvstream-tcp._tcp`; a discovered address is saved only after pinned HTTPS confirms the PC's ID. |
| Reachability probe        | TCP connect to the PC's HTTP port, no payload; status can be forged, trust cannot.                                                     |
| Stream keepalives         | Unencrypted UDP ping identifiers, no keys or input.                                                                                    |
| Wake on LAN               | Unauthenticated UDP magic packets, including ports 9 and 47009 and Sunshine ports; the PC's MAC address is visible.                    |
| Updates                   | HTTPS feed and GitHub downloads; each ZIP has an Ed25519 signature. The feed is unsigned.                                              |
| Optional metrics listener | HTTP port 9847 on loopback; a separate LAN opt-in allows anyone on the network to read metrics.                                        |

Glimmer makes no analytics or tracking calls. See [Privacy](PRIVACY.md).

### Runtime hardening

Approve the optional root helper knowing that Glimmer itself runs without App
Sandbox.

| Boundary             | What it does                                                                                                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Wi-Fi helper         | Root LaunchDaemon through `SMAppService.daemon`; pauses `awdl0` during a stream.                                         |
| Helper authorization | Requires the signed `io.ugfugl.Glimmer` app from Apple team `5T7M4RH3F8`, not just a claimed bundle ID.                  |
| Helper API           | Only `setAWDLDown(_:reason:)` changes state; status, ping and suppression count are read-only. No arbitrary-command API. |
| Release runtime      | Hardened Runtime, no JIT or library injection, library validation enabled.                                               |
| Distribution         | Developer ID signing, Apple notarization and a stapled ticket on the app.                                                |
| Parser checks        | Deterministic fuzz tests and coverage-guided fuzzing under AddressSanitizer; neither contains a successful exploit.      |

The current helper architecture is unsandboxed. USB access alone does not
require that choice; a sandboxed distribution would need a separate architecture
review. Debug builds relax library validation for unsigned instrumentation;
Release does not.

#### Capabilities and capture

Check the separate app and helper grants when reviewing a signed build.

| Bundle       | Capabilities                                                                                                                  |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| App          | Head Pose and Spatial Audio Profile for system spatial playback; Enhanced Security for heap, platform and loader protections. |
| Root helper  | Network Topology Observation for routing-socket observation under macOS 27; does not grant root or replace approval.          |
| Login helper | Neither audio capability.                                                                                                     |

Enhanced Security version 1 remains selected while version 2's streaming costs
are unmeasured. Profiles are validated and embedded separately; see
[Release](RELEASE.md). Glimmer never reads or exports raw head-pose or profile
data.

The stream window's legacy capture hint does not block ScreenCaptureKit. Your
stream can appear in screen recordings or shares; Glimmer provides no DRM
boundary.
