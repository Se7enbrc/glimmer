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
# Build a representative binary (Debug skews everything):
make release && make install

# CPU hotspots only:
make profile

# Per-frame signpost timeline - this is the one you usually want:
make profile-signposts
```

Both targets drop a `.trace` into `~/Library/Developer/Xcode/Instruments/`.
Double-click to open in Instruments.

After opening, drag the **os_signpost** track into view and filter by subsystem
`io.ugfugl.Glimmer` (capital G).

## Unified log

All Glimmer code logs under one subsystem: **`io.ugfugl.Glimmer`**. Per-file
categories partition the output. The full list (grep `Logger(subsystem:` to
verify):

| Category              | File                                                           |
| --------------------- | -------------------------------------------------------------- |
| `MoonlightManager`    | `Glimmer/MoonlightManager.swift`                               |
| `HostsStore`          | `Glimmer/HostsStore.swift`                                     |
| `Stream.Audio`        | `Glimmer/Stream/AudioDecoder.swift`                            |
| `Stream.Discovery`    | `Glimmer/Stream/Discovery.swift`                               |
| `Stream.Identity`     | `Glimmer/Stream/Identity.swift`                                |
| `Stream.Input`        | `Glimmer/Stream/InputForwarder.swift`, `StreamInputView.swift` |
| `Stream.Network`      | `Glimmer/Stream/Network.swift`                                 |
| `Stream.Network.TLS`  | `Glimmer/Stream/Network.swift` (TLSDelegate)                   |
| `Stream.Pairing`      | `Glimmer/Stream/Pairing.swift`                                 |
| `Stream.Session`      | `Glimmer/Stream/StreamSession.swift`                           |
| `Stream.VideoDecoder` | `Glimmer/Stream/VideoDecoder.swift` (+`+HDR`, `+Bitstream`)    |
| `Stream.Window`       | `Glimmer/Stream/StreamWindow.swift`                            |

OSSignpost categories are different (they live on the same subsystem but a
separate axis - see `Glimmer/Stream/Signposts.swift`):

| Signpost category | Path                                                   |
| ----------------- | ------------------------------------------------------ |
| `Stream.Decode`   | VT decode submit → output                              |
| `Stream.Render`   | VT output → `AVSampleBufferDisplayLayer` enqueue       |
| `Stream.Network`  | connection bring-up (`startConnection`) + stage events |
| `Stream.Pairing`  | five-round PIN handshake                               |
| `Stream.Audio`    | opus decode + `AVAudioPlayerNode` schedule             |

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

| Category         | Interval                   | Events                                                                                               | Wired in                                     |
| ---------------- | -------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `Stream.Decode`  | `DecodeFrame` (per frame)  | `FrameDropped`, `IDRRequested`, `StatsSnapshot`                                                      | `VideoDecoder.swift`, `StatsCollector.swift` |
| `Stream.Render`  | `EnqueueFrame` (per frame) | `RendererFailed`                                                                                     | `VideoDecoder.swift`                         |
| `Stream.Network` | `ConnectFlow` (per stream) | `StageStarting/Complete/Failed`, `ConnectionEstablished`, `ConnectionTerminated`, `ConnectionStatus` | `StreamSession.swift`                        |
| `Stream.Pairing` | `PairingFlow` (per pair)   | `PairingStep` (one per handshake round)                                                              | `Pairing.swift`                              |
| `Stream.Audio`   | `AudioFrame` (per packet)  | -                                                                                                    | `AudioDecoder.swift`                         |

The interval state for `DecodeFrame` threads through `StatsCollector` so submit
(on the engine's receive thread) and complete (on the VT output callback's
thread) pair up cleanly. The `ConnectFlow` interval stays open across the
C-callback boundary and is closed by `deliver(.connectionEstablished)` on
success or by `stop()` on failure (with `outcome=aborted` so the Instruments
timeline never shows a runaway-open interval). FIFO eviction inside
`StatsCollector` closes any orphan interval.

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
call tree under `Glimmer/Stream/*` that isn't VT, opus, or the Foundation
networking stack - those are the expected heavyweights. Targets:

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

`make profile-signposts`. Filter category **Stream.Network**. The `ConnectFlow`
interval covers the entire `startConnection` → first `connectionStarted` window.
Inside it:

- `StageStarting` / `StageComplete` for each connection stage
  (`name resolution`, `RTSP handshake`, `control stream initialization`,
  `video stream initialization`, ... - see `StreamStageNames.table` in
  `StreamProtocolConstants.swift`).
- `StageFailed` if any stage hard-fails.

Look for unusually wide gaps between consecutive `StageStarting` and
`StageComplete` events. Most common slow stage is the RTSP handshake on hosts
with slow audio-device enumeration.

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
thread is starving - switch to the **Stream.Network** category and check for
`ConnectionStatus` events showing poor RTT.

## Opt-in telemetry + the local dashboard rig

Beyond Instruments, Glimmer has an opt-in telemetry exporter (Settings → About →
option-click the version line to reveal the Diagnostics pane). When enabled, a
stream writes to `~/Library/Logs/Glimmer/`:

- `telemetry-<timestamp>.ndjson` - per-second stream metrics;
- `telemetry-session-<timestamp>.json` - a one-shot session scorecard;
- `glimmer-<timestamp>.log` - a richer per-session diagnostic log.

Press **⌃B** during a stream to drop a timestamped "that felt bad" bookmark into
the telemetry. All of it is local-only and carries performance numbers, never
secrets - these are the artifacts the bug-report template asks for.

The Diagnostics pane also surfaces a Grafana port-forward command. That points
at an **optional, maintainer-local dashboard rig** (Prometheus + Grafana + Loki
on a local k8s cluster, living in a gitignored `debug-env/` directory) - it is
deliberately **not part of this repository** and nothing in the app depends on
it. The NDJSON + scorecard files above are the portable, self-contained way to
analyze a session.

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
- **Decode failures.** `DecodeFrame` interval close payload includes outcome
  (`ok` / `dropped` / `abandoned`). A submitDecodeUnit that returns
  `DR_NEED_IDR` triggers `LiRequestIdrFrame()` and shows as an `IDRRequested`
  event with `trigger=...` (`bitstream_failed`, `renderer_failed`, etc.).

## Network diagnostics - packet loss vs decode failure

The split between "the bits never arrived" and "the bits arrived but VT rejected
them" matters for triage:

- **Bytes received but no decoded output** - host stream issue. Either the host
  encoder produced a bitstream VT can't accept (mid-stream SPS/PPS change
  without a fresh IDR; AV1 sequence header malformed), or the FEC layer
  recovered the bytes but their content is bad. Surfaces as `FrameDropped` with
  `reason=vt_status_error`.
- **Bytes not received** - network issue. Surfaces as `ConnectionStatus` events
  with `status != 0` (the engine's poor-connection signal - typically high RTT +
  packet loss).
- **Renderer rejection mid-stream** - the layer's
  `AVSampleBufferVideoRenderer.status` latched `.failed`. Surfaces as a
  `RendererFailed` signpost event + log line at `.warning`, and is recovered by
  a flush + `LiRequestIdrFrame()`.

## Frame watchdog

`StreamSession.frameWatchdogTimer` polls `VideoDecoder.secondsSinceLastFrame()`
on the main run loop at 1 Hz. If more than `frameWatchdogTimeout` (10s, matching
upstream moonlight's `FIRST_FRAME_TIMEOUT_SEC`) passes between frames AND we've
previously received at least one frame, the session tears down with
`StreamEvent.connectionTerminated(errorCode: -1)`. The log line reads:

```
Frame watchdog tripped - no frame in <N>s; tearing down
```

This fast-paths the common "host crashed / network dropped / Sunshine restarted"
case. The protocol's own dead-peer detection can take longer to declare a dead
connection.

## Build configuration

- **Debug** uses `-Onone` + overflow checks. Don't profile with it - numbers are
  2-5× worse than production.
- **Release** is what users see: `-O`, no debug asserts, dSYMs preserved.
- `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` is set on Release so Time
  Profiler symbolicates without manual dSYM linking.

Always profile with:

```sh
make release && make install && make profile-signposts
```

The `install` step copies the freshly-signed bundle to
`/Applications/Glimmer.app`, which is the path `xctrace --launch` points at.

## Common pitfalls

- **Don't trust Debug-build numbers.** The single most common source of "wait
  why is decode so slow" surprises. Always `make release` before any timing
  measurement.
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
