# Profiling Glimmer

Glimmer is a real-time game-streaming client, so "perf" means latency and frame
consistency, not throughput. This document is the playbook for using Apple's
Instruments to profile Glimmer end-to-end, with a focus on the OSSignpost
instrumentation already wired into the hot paths.

> Apple's "Improving your app's performance" guide is the upstream reference:
> <https://developer.apple.com/documentation/xcode/improving-your-app-s-performance>.
> Read it once; this doc is the Glimmer-specific addendum.

## TL;DR

```sh
# CPU hotspots only (installs a notarized Release build first):
make profile

# Per-frame signpost timeline - this is the one you usually want:
make profile-signposts
```

Both targets depend on `install`, and `install` builds Release, so what you
profile is what ships. Never profile a `make app` Debug binary.

Both targets drop a `.trace` into `~/Library/Developer/Xcode/Instruments/`.
Double-click to open in Instruments.

After opening, drag the **os_signpost** track into view and filter by subsystem
`io.ugfugl.Glimmer` (capital G).

## Unified log

The app logs under one subsystem: **`io.ugfugl.Glimmer`**. Per-file categories
partition the output. The full list (grep `Logger(subsystem:` to verify):

| Category               | File                                                                              |
| ---------------------- | --------------------------------------------------------------------------------- |
| `AppModel`             | `Glimmer/AppModel.swift`                                                          |
| `AWDLHelper`           | `Glimmer/AWDLHelperManager.swift`                                                 |
| `ContainerMigration`   | `Glimmer/ContainerMigration.swift`                                                |
| `Diag.FileSink`        | `Glimmer/LogStore.swift`                                                          |
| `DualSenseHID`         | `Glimmer/Stream/DualSenseHID.swift`                                               |
| `HostsStore`           | `Glimmer/HostsStore.swift`                                                        |
| `LunaPower`            | `Glimmer/LunaPower.swift`                                                         |
| `MacSystemStats`       | `Glimmer/MacSystemStats.swift`                                                    |
| `Stream.Audio`         | `Glimmer/Stream/AudioDecoder.swift`                                               |
| `Stream.Capabilities`  | `Glimmer/Stream/Types.swift` (the VT codec probe)                                 |
| `Stream.Discovery`     | `Glimmer/Stream/Discovery.swift`                                                  |
| `Stream.Identity`      | `Glimmer/Stream/Identity.swift`                                                   |
| `Stream.Input`         | `Glimmer/Stream/InputForwarder.swift`, `StreamInputView.swift`                    |
| `Stream.NativeBackend` | `Glimmer/Stream/NativeBackend.swift`                                              |
| `Stream.Network`       | `Glimmer/Stream/Network.swift`                                                    |
| `Stream.Network.TLS`   | `Glimmer/Stream/ControlTransport.swift`                                           |
| `Stream.Pacer`         | `Glimmer/Stream/FramePacer.swift`                                                 |
| `Stream.Pairing`       | `Glimmer/Stream/Pairing.swift`                                                    |
| `Stream.Session`       | `Glimmer/Stream/StreamSession.swift`                                              |
| `Stream.Telemetry`     | `TelemetryExporter`, `TelemetryFrameTrace`, `IOReportSampler`, `DisplayTelemetry` |
| `Stream.VideoDecoder`  | `Glimmer/Stream/VideoDecoder.swift` (+ extensions)                                |
| `Stream.Window`        | `Glimmer/Stream/StreamWindow.swift`                                               |

The privileged AWDL helper is a separate process and logs under its own
subsystem, `io.ugfugl.glimmer.helper` (lowercase `g`), with categories `main`,
`AWDL`, and `XPC`.

OSSignpost categories are different (they live on the same subsystem but a
separate axis - see `Glimmer/Stream/Signposts.swift`):

| Signpost category | Path                                             |
| ----------------- | ------------------------------------------------ |
| `Stream.Decode`   | VT decode submit → output                        |
| `Stream.Render`   | VT output → `AVSampleBufferDisplayLayer` enqueue |
| `Stream.Network`  | connection bring-up (`startConnection`)          |
| `Stream.Pairing`  | five-round PIN handshake                         |
| `Stream.Audio`    | opus decode + `AVAudioPlayerNode` schedule       |

### Stream-session lifecycle

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND (category == "Stream.Session" OR category == "Stream.VideoDecoder")' \
    --last 5m
```

### HDR pipeline

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND category == "Stream.VideoDecoder" \
    AND eventMessage CONTAINS "HDR"' \
    --last 5m
```

### Frame drops + backpressure

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND (eventMessage CONTAINS "drop" \
         OR eventMessage CONTAINS "FAILED" \
         OR eventMessage CONTAINS "IDR")' \
    --last 1m
```

### Network handshake + pairing

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND (category == "Stream.Network" \
         OR category == "Stream.Network.TLS" \
         OR category == "Stream.Pairing")' \
    --last 5m
```

### Input forwarding

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND category == "Stream.Input"' \
    --last 1m
```

### Identity

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND category == "Stream.Identity"' \
    --last 24h
```

## OSSignpost instrumentation

Hot paths have OSSignpost intervals + events. Subsystem is `io.ugfugl.Glimmer`;
categories partition by area.

| Category         | Intervals                        | Events                                                                               | Wired in                                      |
| ---------------- | -------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------- |
| `Stream.Decode`  | `DecodeFrame`, `VTSessionCreate` | `FrameDropped`, `IDRRequested`, `StatsSnapshot`, `DecodeGate`, `DecodeStallRecreate` | `VideoDecoder*.swift`, `StatsCollector.swift` |
| `Stream.Render`  | `EnqueueFrame` (per frame)       | `RendererFailed`, plus the `Pacer*` / `Present*` family                              | `VideoDecoder+Session.swift`, `FramePacer*`   |
| `Stream.Network` | `ConnectFlow` (per stream)       | -                                                                                    | `StreamSession+Start.swift`                   |
| `Stream.Pairing` | `PairingFlow` (per pair)         | `PairingStep` (one per handshake round)                                              | `Pairing.swift`                               |
| `Stream.Audio`   | `AudioFrame` (per packet)        | -                                                                                    | `AudioDecoder.swift`                          |

The interval state for `DecodeFrame` threads through `StatsCollector` so submit
(on the engine's receive thread) and complete (on the VT output callback's
thread) pair up cleanly. FIFO eviction inside `StatsCollector` closes any orphan
interval with `outcome=evicted_from_fifo`. The `ConnectFlow` interval stays open
across the callback boundary and closes with `outcome=established`, `aborted`,
or `reconnect`, so the Instruments timeline never shows a runaway-open interval.

Connection stages, `connectionEstablished`, `connectionTerminated`, and
`connectionStatus` are `StreamEvent`s on the session's `AsyncStream`, not
signposts. Read them from the unified log under `Stream.Session`, or from the
telemetry NDJSON when telemetry is on.

## Scenarios - which tool, what to look at

### "Stream feels laggy"

`make profile-signposts`. In Instruments:

1. Filter `os_signpost` track by category **Stream.Decode**.
2. Aggregate the `DecodeFrame` intervals (right-click → "Show in summary").
3. Read the p50 / p95 / p99 columns.

Targets at 4K@60 AV1 HDR on high-end Apple Silicon (M-series Pro/Max):

| Metric                  | Budget (60Hz) | Target p99 |
| ----------------------- | ------------- | ---------- |
| `DecodeFrame` duration  | 16.6 ms       | < 8 ms     |
| `EnqueueFrame` duration | 16.6 ms       | < 1 ms     |

If `DecodeFrame` p99 > ~10 ms, GPU is the bottleneck - switch to the **Metal
System Trace** template. If `EnqueueFrame` is slow, the
`AVSampleBufferDisplayLayer` pipeline is doing more work than it should - look
at the format-description rebuild path in `enqueueDecodedFrame`.

### "CPU spinning / fans ramping during a stream"

`make profile`. Time Profiler shows wall-clock CPU. Look for any frame on the
call tree under `Glimmer/Stream/*` that isn't VideoToolbox, opus, or the socket
receive loops. Those three are the expected heavyweights. Targets:

| Metric                           | Target                      |
| -------------------------------- | --------------------------- |
| Steady-state CPU during a stream | < 30% of one P-core (M3/M4) |

If a Swift hot path shows up unexpectedly, the input forwarder or the
stats-snapshot timer are the usual suspects.

### "Frames are dropping"

`make profile-signposts`. Filter `os_signpost` track by category
**Stream.Decode** and look for **FrameDropped** events. Each one carries a
`reason` payload:

- `vt_status_error` - VideoToolbox failed inline (bitstream issue).
- `vt_info_dropped` - VT signalled `kVTDecodeInfo_FrameDropped` (decoder threw
  the frame away after submit, usually queue overflow).
- `no_image_buffer` - VT returned `noErr` but no pixel buffer (rare; should
  prompt a bug report).

If `FrameDropped` events cluster near `IDRRequested` events, the host encoder is
the upstream cause, not us. If they cluster near `RendererFailed`,
`AVSampleBufferDisplayLayer` rejected a sample - typically an HDR-metadata
mid-stream change or a corrupt sample.

### "Decode is slow on some streams but not others"

`make profile-signposts`. Compare `DecodeFrame` interval p99 across codecs (the
begin-message payload includes `idr=true/false` and `bytes=N`). IDR frames are
always slower than P-frames; the interesting question is the P-frame p99. If
H.264 P-frames are >2× the AV1 P-frames at the same resolution, the host encoder
is producing pathological bitstreams.

### "Connection takes forever to establish"

The `ConnectFlow` interval (category **Stream.Network**) gives you the total:
`startConnection` through to the established or aborted close. It carries no
per-stage events, so for the breakdown read the log instead:

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND category == "Stream.Session"' --last 5m
```

The stage names are in `StreamStageNames.table`
(`StreamProtocolConstants.swift`): name resolution, RTSP handshake, control
stream initialization, video stream initialization, and so on. Look for an
unusually wide gap between consecutive stage lines. The most common slow stage
is the RTSP handshake on hosts with slow audio-device enumeration.

### "Pairing hangs"

`make profile-signposts`. Filter category **Stream.Pairing**. The `PairingFlow`
interval covers the entire handshake; `PairingStep` events mark each HTTP round
(`getservercert` → `clientchallenge` → `serverchallengeresp` →
`clientpairingsecret` → `pairchallenge`). The step before the next event that
never fired is where the host hung.

### "Audio dropouts / crackling"

`make profile-signposts`. Filter category **Stream.Audio**. Each `AudioFrame`
interval is one opus packet (typically 5 ms of audio at 200 Hz). If the interval
duration is consistently >5 ms the opus decoder is the bottleneck (very unusual
on Apple Silicon). If the intervals are sparse (visible gaps) the audio receive
thread is starving; check the `Stream.Session` log for `connectionStatus` going
poor, and the `Stream.Audio` log for underrun and cushion lines.

## Opt-in telemetry

Beyond Instruments, Glimmer has an opt-in telemetry exporter. It lives in
**Settings → Diagnostics**, in a Telemetry section that is hidden until you
option-click the version line in **Settings → About**. The pane's always-visible
half (a live controller input test and the in-app log viewer) needs no gesture.
Turning the toggle on applies to the next stream, not the running one.

When enabled, a stream writes to `~/Library/Logs/Glimmer/`:

- `telemetry-<timestamp>.ndjson` - per-second stream metrics;
- `telemetry-session-<timestamp>.json` - a one-shot session scorecard;
- `telemetry-frames-<timestamp>.ndjson` - the per-frame trace, segmented;
- `glimmer-<timestamp>.log` - a richer per-session diagnostic log.

The exporter also serves the per-second metrics on a local Prometheus endpoint,
which is what a maintainer-local dashboard rig would scrape. No such rig is in
this repository and nothing in the app depends on one; the NDJSON and the
scorecard are the portable, self-contained way to analyze a session. Old files
are swept against a byte budget, so the directory does not grow without bound.

Press **⌃B** during a stream to drop a timestamped "that felt bad" bookmark into
the telemetry. The chord is intercepted only while telemetry is on; otherwise
the keystroke passes through to the host. All of it is local-only and carries
performance numbers, never secrets. These are the artifacts the bug-report
template asks for.

`make enable-telem` / `make disable-telem` flip the same preference from the
command line.

## Other Instruments templates worth knowing

Not wrapped in Makefile targets - open Instruments and pick the template.

### Metal System Trace

For GPU pacing on AV1 4K HDR. Even though we use `AVSampleBufferDisplayLayer`
(not a custom Metal renderer), VideoToolbox calls into Metal internally and the
compositor work shows up on the timeline. Use this when `DecodeFrame` p99 is
suspicious and you want to verify the GPU isn't the bottleneck.

### System Trace

For thread blocking. Surfaces lock contention, syscalls, main-thread stalls. Use
when streams feel laggy specifically during UI events (menu open, fullscreen
transition).

### Network

For raw socket throughput. The Glimmer signposts don't measure bytes/sec
directly - that goes into the stats overlay. Use the Network template if you
suspect TCP retransmissions or socket-buffer starvation.

## VideoToolbox diagnostics

- **Real-time hint.** `kVTDecompressionPropertyKey_RealTime = true` is set on
  the session so VT prefers latency over peak quality.
- **No temporal processing.** No B-frames in the GameStream / Sunshine output,
  so VT's temporal-processing path is irrelevant - frames decode in arrival
  order.
- **Decode failures.** The `DecodeFrame` interval closes with an `outcome=`
  payload. Anything that needs a fresh keyframe calls
  `backend.requestIdrFrame()` and emits an `IDRRequested` event carrying a
  `trigger=`: `param_rebuild_failed`, `no_session`, `sample_build_failed`,
  `vt_decode_rejected`, `decode_backlog_stall`, or `present_stall`.

## Network diagnostics - packet loss vs decode failure

The split between "the bits never arrived" and "the bits arrived but VT rejected
them" matters for triage:

- **Bytes received but no decoded output** - host stream issue. Either the host
  encoder produced a bitstream VT can't accept (mid-stream SPS/PPS change
  without a fresh IDR; AV1 sequence header malformed), or the FEC layer
  recovered the bytes but their content is bad. Surfaces as `FrameDropped` with
  `reason=vt_status_error`.
- **Bytes not received** - network issue. Surfaces as a
  `connectionStatus(.poor)` stream event in the `Stream.Session` log (the
  engine's poor-connection signal, typically high RTT plus packet loss).
- **Renderer rejection mid-stream** - the layer's
  `AVSampleBufferVideoRenderer.status` latched `.failed`. Surfaces as a
  `RendererFailed` signpost event plus a log line at `.warning`, and is
  recovered by a flush plus `backend.requestIdrFrame()`.

## Frame watchdog

`StreamSession.frameWatchdogTimer` runs on the main run loop at 1 Hz
(`StreamSession+Watchdog.swift`). It gates on
`min(secondsSinceLastDecodedFrame(), secondsSinceDecodeGateLifted())`, so a
window that legitimately stopped presenting does not trip it. Past
`frameWatchdogTimeout` (10s, matching upstream moonlight's
`FIRST_FRAME_TIMEOUT_SEC`) the session tears down with
`StreamEvent.connectionTerminated(errorCode: -1)`. The log line reads:

```
Frame watchdog tripped - no decoded frame in <N>s (last byte reception <M>s|never); tearing down
```

A connection that never produced a first frame trips too, timed from
`frameWatchdogArmedAt`; the black-screen-until-you-cancel case is the one that
path fixes. A still-live control link holds instead of tearing down. Before the
hard trip there is a 3s soft trip (`decodeOnlyStallThreshold`) that nudges an
IDR first.

This fast-paths the common "host crashed / network dropped / Sunshine restarted"
case. The protocol's own dead-peer detection can take longer to declare a dead
connection.

## Build configuration

- **Debug** uses `-Onone` + overflow checks. Don't profile with it - numbers are
  2-5× worse than production.
- **Release** is what users see: `-O`, no debug asserts, dSYMs preserved.
- `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` is set on Release so Time
  Profiler symbolicates without manual dSYM linking.

`make profile` and `make profile-signposts` both depend on `install`, which
builds Release and copies the freshly-signed bundle to
`/Applications/Glimmer.app`

- the path `xctrace --launch` points at. So `make profile-signposts` on its own
  is the whole command.

## Common pitfalls

- **Don't trust Debug-build numbers.** The single most common source of "wait
  why is decode so slow" surprises. `make app` produces a Debug binary; never
  time one.
- **Don't profile on battery.** macOS throttles ARM cores on battery, and at
  4K60 that shows up as `DecodeFrame` p99 spikes that vanish when plugged in.
- **Use Network Link Conditioner to test the network-jitter path.** System
  Settings → Developer → Network Link Conditioner. Pair with
  `make profile-signposts` to see how `ConnectionStatus` events flap and whether
  the renderer catches up after a transient drop.
- **OSSignpost data is sampled.** At high rates (4K@240) Instruments coalesces.
  Force the subsystem to verbose:

  ```sh
  sudo log config --mode "level:debug" \
      --subsystem io.ugfugl.Glimmer
  ```

  Reset when done:

  ```sh
  sudo log config --reset --subsystem io.ugfugl.Glimmer
  ```

- **Signpost cost is real but tiny.** `OSSignposter` calls are ~5 ns when not
  recording, ~50 ns when Instruments is active. We leave the signposts in
  production builds; do not gate them behind a debug flag.

## Adding new signposts

Shared `OSSignposter` instances live in `Glimmer/Stream/Signposts.swift`.

Interval:

```swift
let id = OSSignposter.decode.makeSignpostID()
let state = OSSignposter.decode.beginInterval("YourInterval", id: id,
                                              "key=\(value, privacy: .public)")
// ... do work ...
OSSignposter.decode.endInterval("YourInterval", state, "outcome=ok")
```

Event (point-in-time):

```swift
OSSignposter.decode.emitEvent("YourEvent",
                              "reason=\(reason, privacy: .public)")
```

Pick the closest existing category rather than adding a new one - fewer
categories means simpler filter UX in Instruments. If the work crosses a thread
boundary, thread the `OSSignpostIntervalState` through whatever data structure
already crosses that boundary (see `StatsCollector` for the reference
implementation: a FIFO of states paired with submit timestamps).
