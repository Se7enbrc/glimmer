# iOS production diagnostics audit

Build `production` for the App Store candidate and `beta` for local diagnostic
recording. This audit implements the October 24, 2026 maintainer handoff against
integration commit `2088675b88757e7e4b1896acc90daed1018bace1`.

## Distribution contract

| Build                             | Compiled diagnostics | Fresh preference | Saved false | Saved true  |
| --------------------------------- | -------------------- | ---------------- | ----------- | ----------- |
| Beta                              | Included             | On               | Off         | On          |
| Production                        | Excluded             | Unavailable      | Unavailable | Unavailable |
| Missing local flavour             | Production           | Unavailable      | Unavailable | Unavailable |
| Unknown workflow/Makefile flavour | Build rejected       | No artifact      | No artifact | No artifact |

`GLIMMER_DIAGNOSTICS` is set only by the explicit beta build. Shared engine
conditions also admit macOS, preserving the Mac's existing behavior. Neither
`DEBUG`, StoreKit, receipt environment, launch arguments nor preferences can
provide the missing capability. There is no asynchronous environment lookup or
resolution interval. A production candidate installed through TestFlight stays
production.

Diagnostic types and their companion extensions are excluded as units. Mixed
streaming paths use empty instrumentation seams or conditional sampling blocks;
the streaming engine and its control policies stay shared. Production's
`StatsCollector` holds only the two watchdog clocks, and diagnostic counter and
gauge storage is absent.

Production never opens the old Diagnostics directory, removes old files or
exposes them. The preference itself is left untouched. Beta's default is
registered, not written over an explicit choice. Neither flavour adds automatic
uploads. Beta's telemetry listener remains loopback-only.

## Writers and surfaces

Locations identify the implementation or the shared seam. Companion extensions
of a compile-excluded type are excluded together.

| Location                                                                                          | Classification and production result                                                                                                                                          |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iOS/Glimmer/DiagnosticsDefaults.swift:9`                                                         | Diagnostic default and directory. No StoreKit import, registration or directory in production.                                                                                |
| `iOS/Glimmer/ControllerMouseSettings.swift:35`                                                    | Diagnostics destination, toggle and footer excluded, including the preference wrapper.                                                                                        |
| `iOS/Glimmer/StreamPlayback.swift:8`                                                              | Session construction uses the compile-selected optional directory.                                                                                                            |
| `GlimmerEngine/Session/SessionAdapters.swift:45`                                                  | Recording factory cannot construct a sink/exporter in production, even with `enabled: true`.                                                                                  |
| `iOS/Glimmer/IOSControllerCapture.swift:169`                                                      | Controller capability JSON writer and call excluded. Beta honors the recording preference.                                                                                    |
| `GlimmerEngine/Diagnostics/LogStore.swift:12`                                                     | In-app ring, pinned records and snapshots excluded. No production log viewer/export surface.                                                                                  |
| `GlimmerEngine/Diagnostics/LogStore.swift:304`                                                    | Session file handle, flush timer and retention cleanup excluded.                                                                                                              |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:105`                                           | NWListener, connection handlers, exporter state and startup excluded. No loopback or LAN metrics listener in production.                                                      |
| `GlimmerEngine/Diagnostics/TelemetryExporter+Capture.swift:15`                                    | Periodic capture timer and all Capture extensions excluded.                                                                                                                   |
| `GlimmerEngine/Diagnostics/TelemetryExporter+Sinks.swift:86`                                      | Summary JSON, NDJSON, evidence JSON and bookmark events excluded. Render extensions and snapshot/aggregate/report types excluded.                                             |
| `GlimmerEngine/Diagnostics/DiagnosticEvidence+Files.swift:28`                                     | Evidence copying, file validation and analysis/export implementations excluded.                                                                                               |
| `GlimmerEngine/Diagnostics/TelemetryFrameTrace.swift:148`                                         | Frame trace writer, flush timer, chunks, manifest and retention excluded.                                                                                                     |
| `GlimmerEngine/Diagnostics/TelemetryLatency.swift:19`                                             | Per-frame timing table, histograms, trace stages, renderer and input timing recording excluded. Empty instrumentation seams retain only shared call signatures/reason values. |
| `GlimmerEngine/Diagnostics/InputLatency.swift:28`                                                 | Thread-local timing allocation, sample arrays and latency histograms excluded. Production capture returns no samples.                                                         |
| `GlimmerEngine/Diagnostics/ReceiveTimingTelemetry.swift:4`                                        | Receive-gap histogram collector excluded.                                                                                                                                     |
| `GlimmerEngine/Network/DatagramBatch.swift:9` and `GlimmerEngine/Network/SocketTimestamp.swift:4` | Ancillary timestamp allocation, socket timestamp option, kernel-arrival decoding and diagnostic receive clock reads excluded. Datagram batching and source validation remain. |
| `GlimmerEngine/Network/RtpAudioReceiver+Telemetry.swift:30`                                       | Periodic audio quality fold and packet-statistics increments excluded. Audio packet parsing, FEC, loss concealment and sequencing remain.                                     |
| `GlimmerEngine/Network/RtpAudioReceiver+Events.swift:32`                                          | Pending-audio diagnostic timer/event recording excluded.                                                                                                                      |
| `GlimmerEngine/Network/VideoRtpReceiver+Recovery.swift:8`                                         | Loss episode aggregation and IDR timing rows excluded. Reference invalidation and IDR recovery remain.                                                                        |
| `GlimmerEngine/Network/RtpVideoQueue+ReceiveQuality.swift:10`                                     | Diagnostic loss/duplicate tallies, quantiles/buckets, reorder distribution and FEC summary storage/publication excluded; operational measurements below remain.               |
| `GlimmerEngine/Diagnostics/StatsCollector.swift:510`                                              | Production implementation contains only two watchdog clocks. No FPS windows, sample arrays, decode spans or cadence histograms.                                               |
| `GlimmerEngine/Diagnostics/DisplayTelemetry.swift:82`                                             | Display polling timer and collector excluded. Plain platform snapshot values are not samplers.                                                                                |
| `GlimmerEngine/Diagnostics/RendererTelemetry.swift:104`                                           | Renderer/compositing collectors excluded. Platform renderer ownership remains.                                                                                                |
| `GlimmerEngine/Video/VideoDecoder+ColorProbe.swift:4`                                             | Pixel/content color probe and its task excluded. HDR/color metadata needed for rendering remains.                                                                             |
| `GlimmerEngine/Video/VideoDecoder+Backdrop.swift:14`                                              | HUD backdrop state and pixel-luminance sampling excluded. No iOS diagnostic overlay is constructed.                                                                           |
| `GlimmerEngine/Video/VideoDecoder+Configuration.swift:9`                                          | Diagnostic VT property discovery/readback excluded. Same realtime and power-efficiency property requests retained.                                                            |
| `GlimmerEngine/Diagnostics/AudioPipelineTelemetry.swift:13`                                       | Audio stage histograms, output probes and window snapshots excluded.                                                                                                          |
| `GlimmerEngine/Audio/AudioOutput+Silence.swift:4` and `GlimmerEngine/Audio/AudioPCMQueue.swift:9` | PCM content probe, render observer and silence classifier excluded, including observer installation in `iOS/Glimmer/IOSAudioOutput.swift:9`.                                  |
| `GlimmerEngine/Diagnostics/TelemetryCounters+AudioSkew.swift:60`                                  | Diagnostic A/V RTP correlation store excluded; audio resampling control remains independent.                                                                                  |
| `GlimmerEngine/Diagnostics/TelemetryCounters+AudioGauges.swift:125`                               | Arrival histogram, first-audio timing and cushion diagnostic collectors excluded.                                                                                             |
| `GlimmerEngine/Diagnostics/TelemetrySessionEvents.swift:67`                                       | Disconnect totals, connect-leg timing, input-delivery stamps and P2 event storage excluded. Disconnect reason classification remains.                                         |
| `GlimmerEngine/Diagnostics/TelemetryCounters+Types.swift:27`                                      | Diagnostic totals and gauges have no backing storage in production. Explicit operational counters, input activity and receive jitter retain synchronized storage.             |
| `GlimmerEngine/Diagnostics/Signposts.swift:11`                                                    | Signpost handles, intervals and emission excluded at compile time, including pairing, audio, decoder and presentation paths.                                                  |
| `GlimmerEngine/Pacing/FramePacer+Tick.swift:57`                                                   | Refresh diagnostic windows and missed-tick attribution excluded. Tick liveness and deficit recovery remain.                                                                   |
| `GlimmerEngine/Pacing/FramePacer+DueGate.swift:26`                                                | Cadence reporting and over-target diagnostic streak recording excluded. Frame selection/release policy remains.                                                               |
| `GlimmerEngine/Session/StreamSession+Telemetry.swift:11`                                          | Exporter creation, bookmark capture and termination rows excluded.                                                                                                            |
| `GlimmerEngine/Session/StreamSession+PresentMetric.swift:47`                                      | Periodic metric formatting/snapshots excluded. The shared two-second operational adaptation tick remains.                                                                     |
| `iOS/Glimmer/IOSAudioSession.swift:11` and `iOS/Glimmer/IOSAudioSession+Notifications.swift:9`    | Diagnostic session descriptions excluded. Activation, interruption and route recovery remain.                                                                                 |

## Retained operational measurements

These are inputs to streaming behavior, not diagnostic recording. No pacing,
bitrate, buffering, decode or recovery thresholds are retuned.

| Location                                                                                                                                     | Measurement and reason                                                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GlimmerEngine/Session/EnvSignalController+Evidence.swift:76`                                                                                | Video/audio gaps over 50/100 ms, video reorder count, ENet retransmits and live receive jitter drive link degradation/recovery and buffer headroom.                                                |
| `GlimmerEngine/Network/RtpVideoQueue+ReceiveQuality.swift:10`                                                                                | Sequence/reorder classification, packet totals, arrival times and receive jitter support stream adaptation and stall error context. Diagnostic loss totals and quantile sampling are excluded.     |
| `GlimmerEngine/Network/EnetControlChannel+ControlLoop.swift:21`                                                                              | RTT, ACK age, reliable backlog and retransmission timing govern transport reliability and input backpressure.                                                                                      |
| `GlimmerEngine/Network/StreamPathMTU.swift:359` and `GlimmerEngine/Session/StreamSession+Connect.swift:46`                                   | Path probing, RTT and link-quality ceilings determine negotiated packet size and bitrate. These control inputs remain independent of exported RTT/quality gauges.                                  |
| `GlimmerEngine/Diagnostics/StatsCollector.swift:510`                                                                                         | Decoded/presented timestamps feed stall watchdogs. Reconnect resets these clocks. Byte totals and FPS windows are excluded.                                                                        |
| `GlimmerEngine/Session/StreamSession+PresentMetric.swift:15`                                                                                 | Two-second route/environment observation and gradual pacing-depth growth are required independent of the exporter.                                                                                 |
| `GlimmerEngine/Pacing/FramePacer+Tick.swift:57` and `GlimmerEngine/Pacing/FramePacer+TickDeficit.swift:158`                                  | Tick/release timestamps, realized tick rate, queue depth and starvation state govern frame release and display-link recovery.                                                                      |
| `GlimmerEngine/Audio/AudioDecoder+Meter.swift:99` and `GlimmerEngine/Audio/AudioDecoder+Resampler.swift:20`                                  | Scheduled/played frames, buffer fill, underrun evidence and clock drift control priming, cushion adaptation and varispeed. Learned audio seeds remain operational preferences.                     |
| `GlimmerEngine/Audio/AudioDecoder+Worker.swift:10`                                                                                           | Render-clock observation detects stalled output and updates played-frame accounting. The maintenance timer serves audio recovery, not recording.                                                   |
| `GlimmerEngine/Network/InputCallbackProbe.swift:24`                                                                                          | Callback freshness distinguishes ACK backpressure from a starved completion queue. Its diagnostic latency histogram is excluded.                                                                   |
| `GlimmerEngine/Diagnostics/TelemetryCounters+InputActivity.swift:26`                                                                         | Last-input time controls idle behavior; diagnostic idle-edge and delivery samples are excluded.                                                                                                    |
| `GlimmerEngine/Diagnostics/LogStore.swift:175`                                                                                               | Redacted system Logger messages retain normal connection, transport and recovery/error handling. Production has no in-app ring, session file or diagnostic export. Private values remain redacted. |
| `GlimmerEngine/Diagnostics/AudioDiagnostics.swift:7`                                                                                         | Off-render-thread queue still serves operational audio recovery and learned-seed persistence. It is not itself a recorder.                                                                         |
| `GlimmerEngine/Input/ControllerBattery.swift:114`                                                                                            | Battery polling sends controller state to the PC through the input protocol. Controller motion and feedback capabilities remain functional inputs, separate from the excluded capability report.   |
| `GlimmerEngine/Network/Identity.swift:87`, `GlimmerEngine/Network/Types+Cert.swift:183` and `GlimmerEngine/Models/LauncherArtCache.swift:77` | Pairing identity/certificate persistence and PC artwork caching are normal application data, not diagnostic files.                                                                                 |

## Release controls and landing order

1. Land `c823ba52` on `main`: workflows, Makefiles, archive and delivery
   validation, inspection script/tests and release procedure docs.
2. Land `ef346fd6` on the feature/integration stack: compiled capability,
   UI/services, instrumentation seams, bundle flavour, tests and public copy.
   Keep the tooling commit in that source branch's ancestry so its candidate
   workflow and Makefile also select the correct flavour.
3. Land the audit and screenshots with the app change. Keep the existing
   `2026.10.8 - Unreleased` version; no version/build bump is part of this work.

The archive manifest and attested receipt bind `IOS_FLAVOUR`. Bundle metadata
and compiled-content checks must agree before export and upload. The receipt's
`app_store_source_eligible` value is true only for production. This does not
make an internal-only TestFlight IPA eligible for App Store submission. A later
submission path must use the accepted production archive and preserve all
existing signing, approval, exact-commit verification and immutable-artifact
controls. This change dispatches no workflow and publishes nothing.

## Copy changes

Beta Settings retains “Diagnostics” and “Record diagnostics”. Its footer says
“Saves performance and troubleshooting files on this device for the next stream.
Nothing is uploaded. Beta builds turn this on by default.” Production contains
none of that diagnostic UI. Privacy/support text distinguishes the compiled
flavours, including a production candidate tested through TestFlight. The
production listing removes the optional diagnostic-recording sentence.

The local App Store Connect pack's `paste/description.txt`, `PRIVACY-POLICY.md`
and `SUPPORT.md` were reconciled after both flavour tests and compiled-content
inspections passed. They remain unpublished drafts.

There are no promised translations, languages or dates. The existing English and
Base resources remain the supported localization state.

## Settings review

The original UI rendering suite passed all 13 tests on the isolated iPhone 17
Pro Simulator, iOS 26.0. Production rendering includes light/dark and standard/
accessibility text sizes. The native Settings rows and support links fit without
clipping after removing Diagnostics. No keyboard or VoiceOver session was run.

| Appearance               | Before (`2088675b`)                                                               | Production                                                                           |
| ------------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Light, standard text     | [Before](../iOS/docs/diagnostics-evidence/before-settings-light.png)              | [After](../iOS/docs/diagnostics-evidence/production-settings-light.png)              |
| Dark, accessibility text | [Before](../iOS/docs/diagnostics-evidence/before-settings-accessibility-dark.png) | [After](../iOS/docs/diagnostics-evidence/production-settings-accessibility-dark.png) |

Beta's toggle and complete footer fit in
[landscape light](../iOS/docs/diagnostics-evidence/beta-diagnostics-landscape-light.png)
and
[portrait dark](../iOS/docs/diagnostics-evidence/beta-diagnostics-portrait-dark.png).

## Acceptance evidence

The verified application and engine source is commit `ef346fd6`; its source diff
matches the fingerprint captured for both Simulator runs and the Mac compile.
Release tooling is `c823ba52`.

Local verification uses Xcode 27.1, an iPhone 17 Pro Simulator on iOS 26.0,
version `2026.10.8` / iOS build `3`, and unsigned Debug test hosts. The final
runs use an isolated Simulator (`3C2C197C-8265-493D-8D79-58CCE39CC093`). Earlier
shared-Simulator launch timeouts and interrupted builds are not acceptance
evidence. Mac verification compiles test targets without executing them.

The baseline regression test `productionRejectsSavedTrue` failed at line 22 on
`2088675b` with a saved true preference, proving the prior default was not a
production restriction. The test ran in an isolated checkout on the iPhone 17
Pro Simulator (iOS 26.0), Debug, with Xcode 27.1.

Production passed all 157 tests in 17 suites. This includes saved nil/false/true
preferences, ignored enable/unknown environment overrides, unchanged existing
files despite a forced recording request, Settings capability and retained
operational counters/watchdog clocks. Strict SwiftLint passed without warnings.

Beta passed all 157 tests in 17 suites, including default-on and explicit-off
preferences. Its compiled app contains all 12 required diagnostic components (15
total type/control markers). All 49 iOS release-tooling tests pass. Unknown
Makefile flavour input is rejected before building.

The unsigned Mac `make test-build` passed without compiler warnings. No Mac unit
tests, device builds, signing, workflow dispatches or uploads were run.

The production Debug Simulator app passed executable, defined-symbol,
debug-dylib and resource inspection with zero diagnostic markers. The scanner
recognizes Swift types rather than source-map filenames or empty shared method
names. Archive and signed-export validation apply the same scanner to the actual
distribution app before delivery. No device archive or signed build was made
locally.

Production Simulator SHA-256 values:

App path:
`iOS/build/production-tests/DerivedData/Build/Products/Debug-iphonesimulator/Glimmer.app`.

| File                  | SHA-256                                                            |
| --------------------- | ------------------------------------------------------------------ |
| `Glimmer`             | `46cf792c40c5a1a7a01147751f295439ae8f41e603e2cc84fa1fa05b110e5ad8` |
| `Glimmer.debug.dylib` | `bf677de8347951ee78b7326e3a093f95e2fd659aecc59b99c715cf8fb8a7e03e` |

Beta Simulator SHA-256 values:

App path:
`iOS/build/beta/DerivedData/Build/Products/Debug-iphonesimulator/Glimmer.app`.

| File                  | SHA-256                                                            |
| --------------------- | ------------------------------------------------------------------ |
| `Glimmer`             | `b5fb977c3d07047d0324f322fa23d1ebf7c33491d13c79a2133cac99be52dd4e` |
| `Glimmer.debug.dylib` | `dbdebc9ee3873a6179fe808eee58eb3824a7c5f4e6dadf930e6af745e3a86f37` |

The first full production Simulator run reached 157 tests. Its sole failure was
the existing scene-visibility fixture: it returned an invalid background grant,
which correctly disconnected before the asserted foreground event. That test now
supplies a valid grant and deterministic clock/sleep calls. Its shared launch
fixture moved to `LauncherTests.swift` because the integration version of
`StreamSessionTests.swift` already exceeded the 600-line lint limit.

`make check` passed workflow lint, SPDX, both source-boundary audits and strict
SwiftLint, then failed its Python gate: 404 tests, 13 ten-second subprocess
timeouts in the existing `test_ci_release.HostedReleaseTests` fixtures, and one
temporary-directory cleanup error following a timeout. There were no assertion
failures. An earlier full run also hit fixture timeouts, and an isolated fixture
reproduced the timeout with Python 3.15 and 3.14. The machine was under heavy
concurrent build load. No timeout was raised and no test was skipped.

The full gate requires a clean rerun on a quieter machine before landing.
Simulator evidence cannot establish a real TestFlight installation, physical
controller/audio/display behavior or Sunshine streaming quality.

| Handoff requirement                            | Verified here                                                                                                                   | Remaining acceptance                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Production/unknown cannot enable diagnostics   | Three saved-preference cases, ignored environment overrides, rejected unknown build inputs, no asynchronous environment lookup  | Inspect the accepted signed production artifact                                    |
| Beta records locally and honors off            | Beta preference tests and audio/export integration tests pass; compiled recorders are present                                   | Real TestFlight installation and expected session/controller files                 |
| Production has no controls, files or listeners | Settings tests/screenshots, forced recording factory leaves a sentinel file unchanged, recorder/listener implementations absent | Pair, stream, disconnect, recover and relaunch the production TestFlight candidate |
| Upgrade preserves old data without exposure    | Saved true cannot grant capability; existing file remains unchanged                                                             | Install production over a diagnostic beta with actual old files                    |
| Streaming measurements remain functional       | Both iOS suites pass, including audio pipeline and operational counter/watchdog checks                                          | Sunshine streaming, controller/audio/display and power on physical hardware        |
| Exact artifact is identified                   | Source commit, flavour, iOS version/build and Simulator binary hashes recorded                                                  | Signed archive/IPA digests, device/OS and TestFlight processing record             |

The remaining release acceptance requires:

1. Install the diagnostic beta through TestFlight and verify expected local
   session, telemetry and controller capability files; verify explicit off.
2. Install the exact production candidate through TestFlight over that beta,
   retaining a true preference and old files. Confirm no Diagnostics UI and no
   new/modified diagnostic files or listeners across pairing, streaming,
   disconnect, failure recovery and relaunch.
3. Stream on physical iPhone/iPad hardware with Sunshine, controller and audio;
   compare stream-control behavior and power using the established protocol.
4. Record source SHA, flavour, version/build, archive/IPA digest, device/OS and
   TestFlight processing evidence for each accepted artifact.

Next: [build and test the exact candidate](../iOS/docs/TESTFLIGHT.md).
