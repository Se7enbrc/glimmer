# iOS battery and thermal audit, 2026.10.8

Static review of the same-checkout iOS launcher, lifecycle, shared video/audio,
pacing, input, transport and diagnostics found an avoidable encoded-video copy
before decode admission. Simulator regression tests check that boundary without
a PC connection. No physical device, live stream, Instruments session or energy
measurement was used. Quality defaults and AVSampleBufferDisplayLayer remain
unchanged. Follow the [30-minute device procedure](../iOS/docs/ENERGY.md) for
physical acceptance; eliminated work is not a measured battery saving.

Reviewed baseline: `1400f6ca51cb`, on `perf/ios-energy-audit`, 2026-10-24.

## Findings

### Mobile resource and battery measurements are unavailable

**Medium severity as an acceptance gap, confirmed; needs diagnostic integration
and hardware.**
[SessionAdapters.swift:44](../GlimmerEngine/Session/SessionAdapters.swift#L44)
builds recording services without native capture probes;
[TelemetryCapture.swift:86](../GlimmerEngine/Diagnostics/TelemetryCapture.swift#L86)
defaults resource, process and cluster readers to `nil`.
[Thermal state](../GlimmerEngine/Diagnostics/TelemetryExporter+CaptureSections.swift#L415)
and Low Power Mode are sampled through the shared recorder, but this iOS path
supplies no battery percentage, CPU, footprint, wakeup or watt measurements.
[TelemetryExporter+Capture.swift:269](../GlimmerEngine/Diagnostics/TelemetryExporter+Capture.swift#L269)
also defaults the legacy `onBattery` value to false without a resource sample.
That value cannot establish that an iPhone is on external power.

The device procedure retains battery readings separately and marks absent fields
unavailable. Full battery-via-telemetry acceptance requires a native probe
through the existing recorder, coordinated with production-diagnostics
ownership. No second writer or fabricated healthy zero is an acceptable
substitute. A test must distinguish a missing probe from
discharging/charging/unknown readings.

### Deferred picture assembly after decode admission

**Low severity, confirmed; fixed in `f84013c3`.**
[VideoDecoder+Sink.swift:70](../GlimmerEngine/Video/VideoDecoder+Sink.swift#L70)
concatenated `.picData` buffers before
[VideoDecoder+Decode.swift:139](../GlimmerEngine/Video/VideoDecoder+Decode.swift#L139)
consulted the hidden decode gate. With two or more picture buffers, every gated
frame could allocate/copy its encoded payload only to discard it. The same work
preceded a resync rejection or saturated decode admission. One picture buffer
already shares `Data` storage; this is not a claim that every frame copied.

The fix evaluates picture assembly synchronously only after the existing gate
and slot reservation accept it. Parameter-set selection, frame-receive counters,
IDR epochs, queue bounds and recovery verdicts remain in their existing order.
`VideoDecodeEnergyTests.gatedFramesDoNotAssemblePictureData` covers IDR and
P-frames; `resyncDoesNotAssembleRejectedPictureData` covers reference recovery.
They fail on eager evaluation and require no VideoToolbox session or connection.
The existing gate delay and 15-second grace are unchanged.

### Diagnostic file timers wake when their buffers are empty

**Low severity, confirmed work; deferred to diagnostic ownership.**
[LogStore.swift:356](../GlimmerEngine/Diagnostics/LogStore.swift#L356) and
[TelemetryFrameTrace.swift:146](../GlimmerEngine/Diagnostics/TelemetryFrameTrace.swift#L146)
arm repeating 250 ms flush sources for an enabled session. The log sink drains
an empty buffer on quiet ticks, including hidden playback; its timer is armed
before opening the destination succeeds. These are scheduled callbacks, up to
four per second per source, not measured independent hardware wakeups or watts.
They do not run in an ordinary diagnostics-off launcher.

A demand-led, coalesced flush after the first queued record is the smallest
follow-up. It must retain bounded buffers, final synchronous drain and close,
overflow/privacy behavior and retry/failure evidence. Test empty periods,
bursts, concurrent append/drain, file-open failure and final stop with an
injected scheduler. The production-diagnostics effort owns these files and
compile-time gates; this audit leaves them untouched to avoid competing writer
changes.

## Costs retained pending hardware evidence

| Path                 | Static evidence and disposition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Media keepalives     | [VideoRtpReceiver.swift:385](../GlimmerEngine/Network/VideoRtpReceiver.swift#L385) and [RtpAudioReceiver+Ping.swift:37](../GlimmerEngine/Network/RtpAudioReceiver+Ping.swift#L37) each wake on the 75 ms quantum even for relaxed sends. [TransportPlatform.swift:12](../GlimmerEngine/Session/TransportPlatform.swift#L12) uses the shared route policy; mobile supplies no environment observations, so unknown-route protection stays fast. Preserve the validated anti-doze policy. Measure paired Wi-Fi gaps, cadence, input-idle behavior and energy before changing scheduling or sends. |
| Control and recovery | [ControlLoop.swift:40](../GlimmerEngine/Network/EnetControlChannel+ControlLoop.swift#L40) has a 20 ms wait, early recovery wake and 100 ms periodic ping. Present watchdog is 20 Hz, decode watchdog 1 Hz, session tick 0.5 Hz. These remain alive during finite background grace to preserve recovery; final teardown cancels them. No cadence or timeout was changed.                                                                                                                                                                                                                         |
| Audio maintenance    | [AudioDecoder+Worker.swift:68](../GlimmerEngine/Audio/AudioDecoder+Worker.swift#L68) observes render progress at 100 Hz, including diagnostics off. It drives adaptive cushion, underrun accounting and stall recovery, not only instrumentation. Do not lower it without before/after audible, latency and energy evidence.                                                                                                                                                                                                                                                                    |
| Display link         | [StreamSurface.swift:49](../iOS/Glimmer/StreamSurface.swift#L49) creates one link for the stream's shared pacer on its private run loop. [FramePacer+Tick.swift:201](../GlimmerEngine/Pacing/FramePacer+Tick.swift#L201) rate-limits main-actor hint checks to 10 Hz; ticks also hand work to the pacing queue. Suppression clears fallback-timer episodes via [TickDeficit.swift:399](../GlimmerEngine/Pacing/FramePacer+TickDeficit.swift#L399). Confirm actual callback cessation/coalescing during iOS inactive/background transitions on hardware before adding link-pause policy.         |
| Encoded/audio copies | [VideoRtpReceiver.swift:343](../GlimmerEngine/Network/VideoRtpReceiver.swift#L343) copies reusable socket storage into owned packets needed by reorder/FEC. [AudioPacketWorker.swift:58](../GlimmerEngine/Network/AudioPacketWorker.swift#L58) copies into a bounded cross-thread ring and reusable consumer packet. Opus interleaved-to-planar conversion feeds the existing PCM output format. No unnecessary full-frame pixel readback or CPU pixel conversion was found. Copy-removal proposals need allocation and lifetime evidence, not an assumption of zero-copy.                      |

## Areas reviewed with no additional confirmed waste

- [LauncherModel.swift:91](../iOS/Glimmer/LauncherModel.swift#L91) stops
  discovery when inactive and before streaming. Discovery uses event delivery,
  not a launcher readiness timer. Artwork is requested by visible lazy-grid
  tasks; [artworkRevision](../iOS/Glimmer/LauncherModel.swift#L216) disables
  fetching while inactive or streaming. No continuous animation, TimelineView or
  hidden HUD formatting loop was found in the iOS shell. Development builds
  intentionally prevent foreground auto-lock even in the launcher; production
  does so only during a stream
  ([GlimmerApp.swift:51](../iOS/Glimmer/GlimmerApp.swift#L51)).
- [StreamBackgroundGrace.swift:39](../iOS/Glimmer/StreamBackgroundGrace.swift#L39)
  owns one cancellable 15-second deadline, not a poll. Input releases
  immediately; presentation suppresses and the shared two-second decode gate
  engages. Audio, transport and essential recovery continue until return,
  expiration, lock or teardown. Background scheduling and actual suspension
  still need hardware.
- [InputReconciliation.swift:17](../GlimmerEngine/Input/InputReconciliation.swift#L17)
  arms only for pending releases/announcements and invalidates when settled.
  Controller mouse polling is movement-led, motion is request/focus-led and
  controller battery polling is shared at 30 seconds. No new input policy was
  introduced.
- VideoToolbox requires hardware decode; decoded `CVPixelBuffer` images are
  wrapped for AVSampleBufferDisplayLayer. Format descriptions and colour
  metadata are cached; colour probe formatting occurs on changes, not every
  stable frame. This static path inspection does not prove internal framework
  allocations or physical scanout efficiency.
- Telemetry export, display sampling, frame traces and file logging are gated by
  recording services. Diagnostics off retains operational counters, signposts
  and error reporting. Their residual cost needs matched optimized runs; no
  diagnostics-off zero-overhead claim is made.

## Verification and handoff

Completed build and test invocations used `nice -n 15 taskpolicy -c utility`.

- Regression-first run: eager assembly failed for gated IDR, gated P-frame and
  resync rejection (three issues); the admitted-frame preservation test passed.
- Final isolated iOS 26 Simulator run: **154 tests in 17 suites passed**,
  including all three `VideoDecodeEnergyTests` methods, with no compiler
  warnings. The Simulator reported its missing system haptics pattern asset
  during rendering; this does not establish physical haptics or power behavior.
- `make test-build`: Mac app and test bundle compiled successfully with no
  compiler warnings. No Mac unit tests were executed.
- `make check`: Actionlint, SPDX, strict SwiftLint and both boundary audits
  passed. The 393 release-tool tests ended with 44 `subprocess.TimeoutExpired`
  errors across `test_ci_release`, `test_github_signed_commit`,
  `test_release_candidates` and `test_sign_bundle`. An isolated
  `test_fresh_signer_requires_verified_handoff_before_credentials` reproduced
  the 10-second `ci-release.sh verify-checks` fixture timeout. These files are
  unchanged; no timeout or gate was relaxed. Full check acceptance is
  outstanding.

The test record and final commit identifiers accompany this audit's delivery.
Only Simulator tests and a Mac `build-for-testing` compile are authorized here;
Mac unit tests, real-device execution and calls to the maintainer PC are
excluded. The generic `make verify` instruction is therefore replaced locally
with `make check`, `make ios-test` and `make test-build`. Hosted full
verification remains outstanding.

The initial full run on a shared Simulator restarted and emitted test suites
absent from this checkout, so it is not acceptance evidence. A fresh, dedicated
iPhone 17 Pro Simulator on iOS 26 isolates the rerun. Concurrent verification
must use separate Simulator IDs to avoid replacing another run's app/test bundle
or sharing saved-PC data.

Changes are limited to the video decode boundary, its Simulator regressions,
release note and these documents. Potential merge overlap is shared video decode
work and the iOS engine-link test file. No iOS polish, touch controls,
remapping, adaptive-bandwidth policy or production-diagnostics source was
edited.

Run the [physical-device procedure](../iOS/docs/ENERGY.md), fill the missing
native resource probes, and publish paired variance before claiming an energy,
battery or sustained-thermal improvement.
