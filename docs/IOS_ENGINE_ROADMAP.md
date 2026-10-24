# Shared engine and iOS roadmap

Prepare Glimmer's reusable streaming engine for the iOS app, while keeping macOS
on the same implementation. The result must let an iPhone with a Backbone or
another supported controller feel like a dedicated, premium game-streaming
device: immediate input, consistent frames, clean audio, full-display video, and
sustained play without unnecessary heat or battery drain.

This is an implementation brief for the Glimmer agent. The immediate deliverable
is a shared framework consumed by the existing Mac app and a small iOS
integration app. A finished iOS launcher and public release follow separately.
The integration app must stream on hardware; a library that merely compiles is
not a completed handoff.

Maintainer direction: maximize shared implementation and behavior across Apple
platforms, preserve Glimmer's native feel, make physical controllers the
baseline, provide simple touch input, fill the iPhone display, and treat
resource usage as a primary design constraint. This extends the Mac-only product
scope; it does not relax [AGENTS.md](../AGENTS.md), the renderer decision, or
the requirement to work with unmodified Sunshine.

## Scope and defaults

- Deliver macOS and iOS consumers of one engine. Include iPadOS in iOS layout
  and capability tests. Keep future tvOS adoption possible without implementing
  a tvOS client or adding speculative abstractions now.
- Use iOS/iPadOS 26 as the initial deployment-target assumption, alongside the
  existing macOS 26 minimum. Phase 0 confirms SDK availability and device
  coverage. Any higher API requirement needs an availability path or a
  documented product decision.
- Start with landscape, SDR, 60 fps, stereo, hardware decoding, a physical
  controller, and an aspect-matched stream. Enable higher refresh, HDR, and
  higher pixel counts only as capabilities and sustained measurements justify.
- Preserve Mac preferences and behavior during extraction. Do not silently
  change existing Mac quality defaults to mobile defaults.
- Scope simple touch to pointer interaction and essential player controls. A
  full virtual gamepad, remapping editor, macros, and gesture customization are
  separate product work.
- No cloud accounts, telemetry service, engine fork, new streaming dependency,
  Metal renderer, or background streaming feature.

## Shared behavior and native presentation

Homogeneity means a fix to pairing, transport, decoding, pacing, recovery, input
encoding, or quality selection reaches every applicable platform through the
same source. It also means the same setting has the same meaning, failures
explain the same condition, and session states behave consistently.

The native shells own navigation, windows/scenes, focus, safe areas, permission
prompts, and OS lifecycle integration. macOS uses AppKit and SwiftUI; iOS uses
UIKit and SwiftUI. Both use system controls, SF Symbols, the existing icon and
violet accent, accessible labels, and restrained motion. Adapt layout and text
sizes to the platform instead of copying Mac point sizes onto an iPhone. Follow
[DESIGN.md](../DESIGN.md) and [PRODUCT.md](../PRODUCT.md) for the brand; their
Mac window rules remain Mac-specific.

One shared policy accepts measured capabilities and current conditions. A Mac
and iPhone can consequently choose different stream modes without having
different quality algorithms. Platform branches belong at API boundaries, not
throughout transport, recovery, and session decisions.

## Current extraction map

Use this map to start the work, then recheck the current checkout before moving
code. It describes source reviewed at `bf2cb8a`.

| Existing area                                                                 | Destination and required work                                                                                                                                                   |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Stream/Native/`, `NativeBackend+*`, `StreamingBackend.swift`                 | Shared transport, protocol, crypto, FEC, and input encoding. Preserve the existing backend and sink contracts. Audit Darwin calls and dynamic symbol use.                       |
| `Network*`, `ControlTransport*`, `Pairing*`, `Identity*`, `PEM*`, discovery   | Shared PC communication and pairing. Separate storage locations, protected-data availability, and permission presentation from protocol logic.                                  |
| `StreamSession+*`, `StreamBridgeContext`                                      | Shared connection lifecycle and recovery. Remove ownership of `StreamWindow` and Mac UI operations from the shared session. Preserve callback ordering and teardown invariants. |
| `VideoDecoder+*`, `FramePacer+*`                                              | Shared VideoToolbox decode and pacing decisions. Isolate `NSView`, `NSScreen`, display-link attachment, display capabilities, and wake notifications.                           |
| `AudioDecoder+*`, `OpusDecoder+*`, `SpatialAudio`                             | Share decoding, buffering, drift correction, and recovery. Split Mac HAL device observation from iOS audio-session and route handling.                                          |
| `InputForwarder+*`, `ControllerForwarder+*`, `ControllerHaptics+*`            | Share controller semantics, capability reporting, state normalization, feedback routing, and encoding. Isolate event capture, raw HID, cursor handling, and UI gestures.        |
| `Models/Host.swift`, `StreamDisplayMode.swift`, bitrate and recovery policies | Share stream configuration and quality semantics. Separate Mac labels, display queries, and window preferences from engine values.                                              |
| Stats, telemetry, logging, `IOReportSampler`                                  | Share bounded counters and snapshot schema. Keep OS probes and presentation outside the shared core; omit unsupported metrics rather than reporting fabricated zeroes.          |
| App model, `StreamWindow+*`, CLI, AWDL helper, login item, Sparkle            | Mac shell. None is a dependency of the reusable engine or iOS app.                                                                                                              |

The protocol directory currently has no AppKit imports, but the surrounding
stream directory has substantial AppKit coupling. In particular, the existing
`StreamSession` creates a window and owns Mac-specific presentation actions.
Extracting only `NativeBackend` would leave too much duplicated work for iOS.

## Framework structure

Create one in-repository `GlimmerEngine` framework target, initially built from
source by Xcode for macOS, iOS, and iOS Simulator. The consumer now lives in
`iOS/` and references the root Swift package; see
[repository ownership](APPLE_REPOSITORY.md). Keep one source owner for every
shared file; do not copy a directory into another repository. The Mac app must
consume this target before the extraction is considered complete.

Use a source framework first. A Swift package or binary XCFramework can follow
an actual distribution need; packaging must not delay proving the shared engine.
Keep the small Objective-C exception guard in a supported private framework
module arrangement. Do not assume the app's bridging-header configuration can be
copied unchanged into a framework target.

The dependency direction is:

```text
Mac app and Mac adapters       iOS app and iOS adapters
             \                 /
                  GlimmerEngine
        Session, quality policy, controller semantics
        Apple media pipeline, pacing, bounded telemetry
        Sunshine protocol, transport, crypto, FEC
```

Keep these as internal areas of one module initially. Add another module only
when a real build or dependency boundary requires it. No universal platform
service registry, plugin architecture, or protocol for every type.

The public boundary must support:

- PC discovery, pairing, app listing, launch, and connection state without
  exposing raw identity material to views.
- Validated stream requests and capability snapshots: render dimensions, display
  cadence, supported hardware codec/profile combinations, HDR, audio, input
  capabilities, and power/thermal constraints. Probe capabilities rather than
  maintaining a device-name whitelist.
- Start, cancel, stop, and reconnect with typed failures and ordered, bounded
  state delivery. Preserve one active stream and make stop idempotent. Coalesce
  replaceable stats, but never lose terminal state or required lifecycle
  ordering when a consumer is slow.
- Native presentation attachment with explicit ownership and readiness. Keep
  `NSWindow`, `NSView`, `UIViewController`, and SwiftUI out of engine-facing
  configuration and session state.
- Canonical input submission, controller arrival/removal, and feedback. Keep raw
  OS events and device objects in the input adapters.
- Low-frequency stats snapshots and opt-in diagnostics with the same field
  meanings across platforms.

Reuse `StreamingBackend`, `StreamConfig`, `StreamEvent`, and existing test seams
before inventing equivalents. Introduce small interfaces only at demonstrated
Mac/iOS differences. Keep packet and frame buffers on the current direct media
path: no per-packet Task, actor hop, observable UI update, or serialized message
bus added for architectural uniformity.

Platform adapters own display-link creation and attachment, native input
capture, audio route observation, lifecycle notifications, storage environment,
and platform-only probes. Shared code owns the meaning of those events and the
resulting recovery decisions. Do not create parallel Mac and iOS pacers, audio
queues, or reconnect state machines.

## iOS integration requirements

### Video and the full display

Use the existing VideoToolbox pipeline and `AVSampleBufferDisplayLayer` in a
native view. The video surface extends to every display edge in landscape,
including behind cutouts and the home-indicator area. Interactive controls and
essential status stay inside usable safe areas. Respect system navigation and
use supported APIs for indicator behavior.

Determine the active presentation area's pixel dimensions and orientation at
runtime. The shared selector chooses an encoder-compatible mode with that aspect
ratio, plus fps and bitrate within the device's measured budget. Physical panel
pixels are the upper bound for a native-quality choice, not an obligation to
spend that many pixels at the default quality. A lower-resolution mode with the
same aspect ratio can still fill the display correctly.

Use the selected dimensions consistently in launch parameters, SDP, decoder
validation, presentation geometry, and pointer coordinates. Keep requested and
observed dimensions distinct in diagnostics. Decoder dimensions alone cannot
prove that the PC rendered the desktop at that size instead of scaling it.

Do not stretch a 16:9 image to disguise a missing phone-shaped mode. If the PC
cannot provide the requested mode, explain the setup action and offer a
supported aspect-fit mode. Cropping is not the default fallback. Game-generated
letterboxing remains possible even when the desktop resolution matches.

Support both landscape orientations without reconnecting when dimensions stay
the same. Coalesce geometry changes; do not restart a stream for transient
layout updates. Dimension changes requiring a new PC mode use the existing
launch/reconfiguration flow, with stale callbacks invalidated.

### Controllers and simple touch

A compatible Backbone is the baseline physical-device acceptance case, with
another supported wired or wireless controller as a second case. Use Apple's
[Game Controller discovery and profiles](https://developer.apple.com/documentation/gamecontroller/discovering-game-controllers).
Match available controls and capabilities, not vendor names. No Backbone SDK or
vendor service is required.

- Support sticks, triggers, face buttons, shoulders, directional pad, and
  available menu/options controls. Preserve shared slot allocation and wire
  semantics. Advertise only capabilities actually available through public APIs.
- Connection and removal work during a stream. Removal, loss of focus,
  interruption, cancellation, and teardown release all held input and stop
  feedback. Reconnection must not duplicate slots or observers.
- Route supported haptics through the shared feedback path. A controller with no
  haptics remains fully usable. Keep raw-HID Mac enhancements isolated.
- The eventual launcher and player controls support controller focus and
  activation. The integration app must already demonstrate entering a stream and
  leaving it with a controller after pairing.
- Initial touch support is a simple relative pointer surface: drag to move, tap
  to click, two-finger tap for secondary click, and two-finger scroll. Resolve
  gestures before emitting clicks; cancellation must release input. Keep the
  mapping fixed and document it in the client handoff.
- Provide a discoverable, safe-area player control for leaving the stream and a
  way to reveal player controls without forwarding that gesture to the PC.
  Native controls retain accessibility semantics. No permanent control overlay
  is visible during controller play.

Reuse mouse/button/scroll input encoding for this touch baseline. Do not confuse
phone touchscreen input with the existing controller-touchpad protocol. Direct
PC touch injection and a full on-screen gamepad are later capabilities.

### Audio and lifecycle

Keep the shared decode, playout, and drift-correction path. The iOS adapter owns
`AVAudioSession` configuration, actual route format and latency observation,
interruptions, route changes, and media-services resets. Preferred sample rate
and buffer duration are requests; validate the actual values before building the
graph. Begin with stereo and test speakers plus Bluetooth or wired audio.

Represent foreground, temporary inactivity, background, route loss, and
protected-data unavailability explicitly. Temporary inactivity immediately
releases input; returning must not replay held state. On background or screen
lock, stop local streaming work and release resources. Returning offers a
controlled resume/reconnect. Local disconnect and quitting the PC application
are distinct actions; backgrounding must not silently quit the player's game.
Document the existing Sunshine cancellation semantics before changing them.

Use structured cancellation and a session generation to reject old callbacks.
Stop receive work before releasing its sinks and bridge. Remove display links,
timers, observers, and controller handlers; release media buffers and deactivate
the audio session when appropriate. No keepalive loop should survive a stopped
session. Mac window deactivation keeps its existing platform semantics.

Preserve certificate pinning, identity validation, and privacy-safe logging. Use
app-container storage with appropriate protection and lifecycle handling; never
share the Mac's paths or assume identity files remain accessible while locked.
Local-network permissions and Bonjour declarations belong in the iOS app target.
Explain denied permission instead of retrying indefinitely.

## PC resolution preparation

The current launch request already sends `width x height x fps` in `mode`, and
SDP carries viewport dimensions. Extend that shared path rather than adding an
iOS protocol. Check the client's launch flags as well as its dimensions.

For an already-configured Windows virtual display, preparation may be adding the
missing resolutions and refresh rates to its mode list. That is not enough if
Sunshine is not configured to select and switch that display. Sunshine's
[display configuration](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_resolution_option)
documents automatic resolution selection and its client-side optimization
condition; these display options are Windows-specific. Validate other PC
platforms against their actual display tooling rather than promising universal
automatic resizing.

After the selector is implemented, extend [HOST_SETUP.md](HOST_SETUP.md) and
[iPhone/iPad sample](vdd/iphone-ipad.xml) with the tested phone/tablet modes and
their efficient alternatives. Record the exact width, height, refresh,
device/aspect coverage, and encoder alignment. Generate examples from the same
selection fixtures or validate them against those fixtures so client and PC
instructions cannot drift. Do not publish a guessed list of iPhone resolutions
now.

Verify PC mode selection, encoded dimensions, visible aspect ratio, and desktop
restoration on normal stop and interrupted sessions. Test switching between a
Mac and iPhone so the previous client's resolution cannot leak into the new
session. Use stock Sunshine and supported display configuration only; adding a
patched-host dependency is outside this roadmap.

## Resource and latency contract

Resource usage is a delivery gate alongside fidelity. Measure optimized builds
on physical devices, with the same PC scene, codec, dimensions, fps, bitrate,
network conditions, brightness, audio route, controller, and diagnostic setting.
Simulator timing and a short successful stream are not performance evidence. Use
[PROFILING.md](PROFILING.md) and extend its existing measurement vocabulary.

The engine must:

- Keep hardware decode and the existing pixel-buffer display path. Avoid a CPU
  pixel conversion, full-frame readback, new frame copy, or second render pass.
  Measure actual allocations and copies rather than claiming zero-copy from the
  API names alone. Do not silently fall back to software video decoding.
- Bound encoded queues, decoded frames, audio buffers, input batches, and event
  delivery. Document each limit and overflow/recovery policy. Recovery must not
  grow latency indefinitely or discard reference frames without recovery.
- Reuse packet and audio storage where it is safe. Do not allocate a Task,
  timer, or UI state object per packet/frame. Preserve input transitions when
  coalescing continuous motion; never drop a release edge.
- Make discovery, telemetry, motion sensors, haptics, and UI updates demand-led.
  An invisible HUD does not redraw or collect expensive diagnostic samples.
  Diagnostics off must disable capture/export work while retaining cheap
  operational counters needed for recovery.
- Reduce unnecessary work before reducing fidelity. When device pressure still
  requires a lower mode, use the shared policy, bounded hysteresis, and
  recovery. Bitrate reduction alone is not a guarantee of lower decode/display
  cost. Resolution or fps changes that need relaunch follow explicit session
  policy; never oscillate through repeated reconnects.

`DatagramBatch` dynamically resolves `recvmsg_x`; the receive loop documents it
as private SPI and already has a `recvfrom` fallback. The iOS build must exclude
the private-symbol path, not merely wait for lookup to fail. Benchmark the
public fallback early. If it is too expensive, evaluate public receive APIs
behind the existing transport boundary using the same packet-loss and latency
tests. Keep Mac-only IOReport and private input hooks out of iOS too. This does
not authorize changing the Mac receive implementation without measurements.

### Required measurement gates

These are initial acceptance gates, not claims about current performance. Phase
0 records the Mac baseline; Phase 2 records the first device baseline and sets
absolute budgets per supported device tier before adding higher modes.

| Measure                   | Gate and evidence                                                                                                                                                                                                                                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Mac extraction overhead   | Same workload before/after, three paired runs. Investigate and resolve any reproducible increase above 5% in process CPU, physical footprint, or wakeups, and any p95/p99 media-latency regression outside baseline variability. A performance tradeoff needs an explicit maintainer decision.                           |
| Sustained mobile workload | At least 30 minutes after warmup on the oldest supported test device and a representative higher-refresh device. Record CPU seconds per streamed minute, physical footprint and peak, wakeups, energy evidence, thermal state, actual fps, decode/pacing latency, drops, audio underruns, and observed bitrate.          |
| Memory and teardown       | Ten start/stop or reconnect cycles after warmup, plus the sustained run. No live per-session object/resource accumulation or monotonic retained-memory growth; explain allocator/framework cache plateaus using allocation evidence. No active session workers, links, or timers after stop.                             |
| Input and media quality   | No stuck input, no client-caused audio underruns, and no sustained missed cadence on the clean-network baseline. Report p50/p95/p99 input enqueue-to-send and media-stage latency. Do not label these measurements end-to-end input-to-photon latency.                                                                   |
| Battery and heat          | Record ambient conditions, brightness, charging state, controller power draw context, Low Power Mode, and starting thermal state. Default quality must sustain the baseline without serious/critical thermal state attributable to the workload. Prefer energy instruments; battery percentage alone is coarse evidence. |
| Diagnostic overhead       | Compare diagnostics off, counters/HUD, and full capture under the same conditions. Report the incremental cost. Heavy capture is opt-in and cannot be required for normal operation.                                                                                                                                     |

The device-budget table must name exact devices/OS builds and numerical CPU,
memory, wakeup, and energy ceilings with measurement method and run variance. Do
not invent one universal CPU percentage or memory ceiling. The framework handoff
remains incomplete until this table and the measurements exist. Failed sustained
tests constrain the default mode or supported device set; they are not deferred
as UI polish.

## Phased implementation and acceptance

Each phase is a reviewable change or small series. Keep mechanical extraction
separate from behavior tuning so regressions can be attributed. Do not leave
duplicate implementations between phases as the final architecture.

| Phase                                | Deliverable                                                                                                                                                                                                              | Acceptance                                                                                                                                                                                                                            |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. Inventory and baseline            | Map build dependencies, API availability, source ownership, existing lifetime invariants, controller coupling, and Mac measurements. Define the initial device matrix and measurement protocol.                          | A concrete extraction list and test commands; known private APIs and Mac-only symbols identified; no invented performance claims.                                                                                                     |
| 1. Shared framework used by Mac      | Extract protocol, pairing, configuration, media logic, session policy, and bounded stats into `GlimmerEngine`. Supply native Mac adapters and rewire the existing app/CLI.                                               | Mac uses the framework with no parallel engine source. Existing tests, `make verify`, required hosted checks, strict concurrency, and zero-warning gate pass. Mac behavior and measured performance are preserved.                    |
| 2. iOS stream on hardware            | Add a minimal integration app using the same framework, native video surface, iOS audio/lifecycle adapters, public networking, controller support, and simple touch. Exercise pairing, launch, stream, stop, and return. | Real iPhone streams video/audio and accepts Backbone input; iPad also builds/runs. Both landscape orientations, hot-plug, permission failure, route interruption, and lock/background teardown work. Record initial resource budgets. |
| 3. Shared selection and full display | Implement capability-based mode selection and mobile condition inputs without duplicating policy. Add validated PC modes and host setup guidance.                                                                        | Aspect-matched edge-to-edge play on test phones, truthful unsupported-mode fallback, deterministic geometry/input tests, and correct Mac-to-phone resolution transitions. Efficient defaults pass sustained gates.                    |
| 4. Framework handoff                 | Stabilize the minimal API, sample integration, build matrix, ownership documentation, and resource evidence. Complete lifecycle and failure testing.                                                                     | Both consumers build from one engine; the handoff checklist below is complete. This is the end of the engine-preparation project.                                                                                                     |
| 5. iOS product                       | Build the native launcher, pairing/setup experience, controller navigation, accessibility, polished player controls, and broader device validation using the framework.                                                  | Premium product review on devices and existing performance gates. App distribution/release is a separate task.                                                                                                                        |

Engine extraction and iOS bring-up may expose issues requiring an earlier phase
to be revisited. Keep each change narrow; do not combine extraction with a new
renderer, new audio architecture, or wholesale tuning of existing recovery.

## Verification matrix

Run shared deterministic tests on macOS and iOS Simulator, and real networking
and media tests on devices. Reuse the existing fake Sunshine, UDP loopback,
protocol, crypto, FEC, input, pacing, and lifecycle tests. Move tests with their
shared source; keep platform presentation tests with their shell. Preserve
current test scheduling constraints and sanitizer coverage.

Add meaningful tests for new boundaries and failure paths:

- Identical inputs and capability snapshots produce identical configuration,
  recovery decisions, wire input, and error categories on each platform.
- Start/cancel races, reconnect generations, partial startup failure, repeated
  stop, controller removal with held buttons, and callbacks arriving at
  teardown.
- Dimensions and alignment, aspect-fit mapping, both landscape orientations,
  cutout-safe controls, unsupported modes, and delayed display readiness.
- Denied local-network access, unavailable identity storage, packet loss, route
  changes, Bluetooth audio changes, media-services reset, background/lock,
  return, memory pressure, and thermal/Low Power Mode transitions.

Build Debug and Release for Mac, iOS device, and Simulator with Swift 6 strict
concurrency and no warnings. Add a dependency/API audit that prevents Mac UI,
helpers, Sparkle, raw HID, IOReport, and private receive symbols entering the
iOS binary. Update CI and documented commands to exercise both consumers. A
compile check cannot substitute for hardware decode, energy, controller, or
audio tests.

## Framework handoff checklist

- [ ] `GlimmerEngine` has one source tree and is consumed by the shipping Mac
      architecture and the iOS integration app.
- [ ] Public API and sample show discovery/pairing, launch, attachment, ordered
      events, input, stats, cancellation, teardown, and reconnect.
- [ ] Ownership and isolation are documented for buffers, sinks, sessions,
      display links, audio callbacks, and controller handlers.
- [ ] iOS private-API exclusions and SDK availability checks are verified in the
      built artifact, with no unsupported placeholder paths hidden by stubs.
- [ ] Backbone and another controller pass real-device acceptance; simple touch
      and leaving the stream are usable without a keyboard.
- [ ] Full-display mode selection and PC configuration examples agree and have
      been tested against unmodified Sunshine.
- [ ] The Mac comparison and mobile sustained, teardown, and diagnostic-cost
      reports exist with per-device numerical budgets and reproducible
      conditions.
- [ ] Shared tests and the build matrix run in CI; required Mac verification
      remains intact. Hardware-only checks have recorded results.
- [ ] Architecture, profiling, host setup, and contribution guidance describe
      the new target and adapter boundaries. Record remaining iOS product work
      separately from completed engine work.

## First task for the Glimmer agent

Start with Phase 0 and a narrow framework extraction plan. Read
[ARCHITECTURE.md](ARCHITECTURE.md), [PROFILING.md](PROFILING.md), and the actual
session, pacing, audio, and input ownership paths. Capture a reproducible Mac
baseline. Then make the existing Mac app consume the first shared slice, expand
that boundary incrementally, and prove the iOS media path early. Do not begin by
copying the Mac app into `iOS/` or redesigning the launcher.
