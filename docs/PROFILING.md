# Profiling Glimmer

Glimmer is a real-time game-streaming client, so “perf” means latency and frame
consistency, not throughput. This document is the playbook for profiling Glimmer
end to end with Apple's Instruments, with a focus on the OSSignpost
instrumentation already wired into the hot paths.

> Apple's “Improving your app's performance” guide is the upstream reference:
> <https://developer.apple.com/documentation/xcode/improving-your-app-s-performance>.
> Read it once; this doc is the Glimmer-specific addendum.

## TL;DR

```sh
# CPU hotspots only (installs a notarized Release build first):
make profile

# Per-frame signpost timeline, the one you usually want:
make profile-signposts
```

Both targets depend on `install`, and `install` builds Release, so what you
profile is what ships. Never profile a `make app` Debug binary.

Both targets drop a `.trace` into `~/Library/Developer/Xcode/Instruments/`.
Double-click it to open it in Instruments, drag the **os_signpost** track into
view and filter by subsystem `io.ugfugl.Glimmer` (capital G).

## Unified log

The app logs under one subsystem: **`io.ugfugl.Glimmer`**. Per-file `Logger`
categories partition the output (grep `subsystem: "io.ugfugl.Glimmer"` to
verify; some `Logger(` calls put the category on the next line):

| Category               | File                                                                              |
| ---------------------- | --------------------------------------------------------------------------------- |
| `AppModel`             | `Glimmer/AppModel.swift`                                                          |
| `AWDLHelper`           | `Glimmer/AWDLHelperManager.swift`                                                 |
| `ContainerMigration`   | `Glimmer/ContainerMigration.swift`                                                |
| `Diag.FileSink`        | `Glimmer/LogStore.swift`                                                          |
| `DualSenseHID`         | `Glimmer/Stream/DualSenseHID.swift`                                               |
| `HostsStore`           | `Glimmer/HostsStore.swift`                                                        |
| `MacSystemStats`       | `Glimmer/MacSystemStats.swift`                                                    |
| `Stream.Audio`         | `Glimmer/Stream/AudioDecoder.swift`                                               |
| `Stream.Capabilities`  | `Glimmer/Stream/Types.swift` (the VT codec probe)                                 |
| `Stream.Discovery`     | `Glimmer/Stream/Discovery.swift`                                                  |
| `Stream.Identity`      | `Glimmer/Stream/Identity.swift`                                                   |
| `Stream.Input`         | `Glimmer/Stream/InputForwarder.swift` (+ extensions)                              |
| `Stream.NativeBackend` | `Glimmer/Stream/NativeBackend.swift`                                              |
| `Stream.Network`       | `Glimmer/Stream/Network.swift`                                                    |
| `Stream.Network.TLS`   | `Glimmer/Stream/ControlTransport.swift`                                           |
| `Stream.Pacer`         | `Glimmer/Stream/FramePacer.swift`                                                 |
| `Stream.Pairing`       | `Glimmer/Stream/Pairing.swift`                                                    |
| `Stream.Session`       | `Glimmer/Stream/StreamSession.swift`                                              |
| `Stream.Telemetry`     | `TelemetryExporter`, `TelemetryFrameTrace`, `IOReportSampler`, `DisplayTelemetry` |
| `Stream.VideoDecoder`  | `Glimmer/Stream/VideoDecoder.swift` (+ extensions)                                |
| `Stream.Window`        | `Glimmer/Stream/StreamWindow.swift`                                               |

Lines written through `Diag` (the in-app log) are mirrored under their own short
categories, such as `Stream`, `NativeConnection`, `NativeVideo` and
`Controller`.

The privileged AWDL helper is a separate process and logs under its own
subsystem, `io.ugfugl.glimmer.helper` (lowercase `g`), with categories `main`
and `AWDL`.

OSSignpost categories are a separate axis on the same subsystem (see
`Glimmer/Stream/Signposts.swift`):

| Signpost category | Path                                                          |
| ----------------- | ------------------------------------------------------------- |
| `Stream.Decode`   | VT decode submit → output                                     |
| `Stream.Render`   | VT output → frame pacer submit, plus pacer and present events |
| `Stream.Network`  | connection bring-up (`startConnection`)                       |
| `Stream.Pairing`  | five-round PIN handshake                                      |
| `Stream.Audio`    | Opus decode + `AVAudioPlayerNode` schedule                    |

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

### Frame drops and backpressure

```sh
log show --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND (eventMessage CONTAINS "drop" \
         OR eventMessage CONTAINS "FAILED" \
         OR eventMessage CONTAINS "IDR")' \
    --last 1m
```

### Network handshake and pairing

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

Hot paths have OSSignpost intervals and events. The subsystem is
`io.ugfugl.Glimmer`; categories partition by area.

| Category         | Intervals                        | Events                                                                               | Wired in                                       |
| ---------------- | -------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------- |
| `Stream.Decode`  | `DecodeFrame`, `VTSessionCreate` | `FrameDropped`, `IDRRequested`, `StatsSnapshot`, `DecodeGate`, `DecodeStallRecreate` | `VideoDecoder*.swift`, `StatsCollector*.swift` |
| `Stream.Render`  | `EnqueueFrame` (per frame)       | `RendererFailed`, plus the `Pacer*` / `Present*` family                              | `VideoDecoder*.swift`, `FramePacer*`           |
| `Stream.Network` | `ConnectFlow` (per stream)       | none                                                                                 | `StreamSession+Connect.swift`                  |
| `Stream.Pairing` | `PairingFlow` (per pair)         | `PairingStep` (one per handshake round)                                              | `Pairing.swift`                                |
| `Stream.Audio`   | `AudioFrame` (per packet)        | none                                                                                 | `AudioDecoder+Decode.swift`                    |

The interval state for `DecodeFrame` threads through `StatsCollector` so submit
(on `decodeQueue`) and complete (on the VT output callback's thread) pair up
cleanly. FIFO eviction inside `StatsCollector` closes any orphan interval with
`outcome=evicted_from_fifo`. The `ConnectFlow` interval stays open across the
callback boundary and closes with `outcome=established`, `aborted` or
`reconnect`, so the Instruments timeline never shows a runaway-open interval.

Connection stages, `connectionEstablished` and `connectionTerminated` are
`StreamEvent`s on the session's `AsyncStream`, not signposts. Read them from the
unified log under `NativeConnection`, or from the telemetry NDJSON when
telemetry is on.

## Scenarios: which tool, what to look at

### “Stream feels laggy”

Start with the telemetry, not Instruments: the wait in the frame pacer is the
largest client-side stage and no signpost covers it (`EnqueueFrame` stops at the
pacer's submit; a frame that queues there waits outside any interval). Turn
telemetry on (see [Opt-in telemetry](#opt-in-telemetry)), stream for a minute,
and read `output_to_present` in the scorecard's `latency` block, then the
per-second `pacing_depth` and `pacing_target_depth`:

| Field                         | Healthy (wired, fps ≈ refresh)   | Means                                                                    |
| ----------------------------- | -------------------------------- | ------------------------------------------------------------------------ |
| `output_to_present` p50       | under one vsync (3-4 ms, 240 Hz) | how long a decoded frame waits for its vsync                             |
| `output_to_present` p95 / p99 | 7-10 ms / 8-12 ms at 240 Hz      | a p99 past two vsyncs is a standing extra frame or skipped ticks         |
| `pacing_depth`                | 0-1                              | frames queued at each tick; a steady 2 at target 1 is the standing frame |
| `pacing_target_depth`         | 1 on a clean link                | the jitter buffer the env-signal headroom level asked for                |

The full field list is under [Pacing fields](#pacing-fields). If
`output_to_present` is fine, move upstream with `make profile-signposts`. In
Instruments:

1. Filter the `os_signpost` track by category **Stream.Decode**.
2. Aggregate the `DecodeFrame` intervals (right-click → “Show in summary”).
3. Read the p50 / p95 / p99 columns.

Targets at 4K@60 AV1 HDR on high-end Apple Silicon (M-series Pro/Max):

| Metric                  | Budget (60Hz) | Target p99 |
| ----------------------- | ------------- | ---------- |
| `DecodeFrame` duration  | 16.6 ms       | < 8 ms     |
| `EnqueueFrame` duration | 16.6 ms       | < 1 ms     |

If `DecodeFrame` p99 > ~10 ms, the GPU is the bottleneck: switch to the **Metal
System Trace** template. If `EnqueueFrame` is slow, look at the sample-buffer
and format-description work in `enqueueDecodedFrame`.

### “CPU spinning / fans ramping during a stream”

`make profile`. Time Profiler shows wall-clock CPU. Look for any frame on the
call tree under `Glimmer/Stream/*` that isn't VideoToolbox, Opus decode, or the
socket receive loops. Those three are the expected heavyweights. Targets:

| Metric                           | Target                      |
| -------------------------------- | --------------------------- |
| Steady-state CPU during a stream | < 30% of one P-core (M3/M4) |

If a Swift hot path shows up unexpectedly, the input forwarder or the
stats-snapshot timer are the usual suspects.

### “Frames are dropping”

`make profile-signposts`. Filter the `os_signpost` track by category
**Stream.Decode** and look for **FrameDropped** events. Each one carries a
`reason` payload:

- `vt_status_error`: VideoToolbox failed inline (bitstream issue).
- `vt_info_dropped`: VT signalled `kVTDecodeInfo_FrameDropped` (the decoder
  threw the frame away after submit, usually queue overflow).
- `no_image_buffer`: VT returned `noErr` but no pixel buffer (rare; should
  prompt a bug report).

If `FrameDropped` events cluster near `IDRRequested` events, the PC's encoder is
the upstream cause, not us. If they cluster near `RendererFailed`,
`AVSampleBufferDisplayLayer` rejected a sample, typically a mid-stream
HDR-metadata change or a corrupt sample.

### “Decode is slow on some streams but not others”

`make profile-signposts`. Compare `DecodeFrame` interval p99 across codecs (the
begin-message payload includes `idr=true/false` and `bytes=N`). IDR frames are
always slower than P-frames; the interesting question is the P-frame p99. If
H.264 P-frames are >2× the AV1 P-frames at the same resolution, the PC's encoder
is producing pathological bitstreams.

### “Connection takes forever to establish”

The `ConnectFlow` interval (category **Stream.Network**) gives you the total:
from the connect call through to the established or aborted close. It carries no
per-stage events, so for the breakdown read the log instead (the stage lines are
info level):

```sh
log show --info --predicate 'subsystem == "io.ugfugl.Glimmer" \
    AND category == "NativeConnection"' --last 5m
```

The stage names are in `StreamStageNames.table`
(`StreamProtocolConstants.swift`): name resolution, RTSP handshake, control
stream initialization, video stream initialization, and so on. Look for an
unusually wide gap between consecutive `stage starting` and `stage complete`
lines. The most common slow stage is the RTSP handshake on PCs with slow
audio-device enumeration.

### “Pairing hangs”

`make profile-signposts`. Filter category **Stream.Pairing**. The `PairingFlow`
interval covers the entire handshake; `PairingStep` events mark each round
(`getservercert` → `clientchallenge` → `serverchallengeresp` →
`clientpairingsecret` → `pairchallenge`). Each event fires as its round starts,
so the last one that fired names the round where the PC hung.

### “Audio dropouts / crackling”

`make profile-signposts`. Filter category **Stream.Audio**. Each `AudioFrame`
interval is one Opus packet (typically 5 ms of audio at 200 Hz). If the interval
duration is consistently >5 ms the Opus decoder is the bottleneck (very unusual
on Apple Silicon). If the intervals are sparse (visible gaps) the audio receive
thread is starving; check the `Stream` log category for the audio underrun and
cushion lines.

## Opt-in telemetry

Beyond Instruments, Glimmer has an opt-in telemetry exporter. It lives in
**Settings → Diagnostics**, in a Telemetry section that is hidden until you
Option-click the version line in **Settings → About**. The pane's always-visible
half (a live controller input test and the in-app log viewer) needs no gesture.
Turning the toggle on applies to the next stream, not the running one.

When enabled, a stream writes to `~/Library/Logs/Glimmer/`:

- `telemetry-<timestamp>.ndjson`: per-second stream metrics, plus event rows
  (bookmarks, video gaps, loss episodes, key frames). Every row names the PC and
  the Mac by per-install pseudonyms (`host`, `client`);
- `telemetry-session-<timestamp>.json`: a one-shot session scorecard;
- `telemetry-frames-<timestamp>.ndjson`: the per-frame trace, segmented, plus
  the merged input Glimmer sent: mouse movement (`input_mouse`,
  `input_mouse_abs`), controller state (`input_pad`), motion sensors
  (`input_motion`, sampled at 20 Hz per sensor) and scroll (`input_scroll`).
  Keys, mouse buttons, pasted text and DualSense touchpad touches are not
  recorded;
- `glimmer-<timestamp>.log`: a richer per-session diagnostic log, with PC names,
  addresses and error text shown as `<private>`.

`audio_output_state` events in the per-second file capture mixer gains, output
format and available device volume/mute readings after audio configuration
changes or a bookmark. A bookmark-triggered snapshot names its marker number;
coalesced snapshots name the first and last markers. Device names and IDs are
omitted. If the output changes during capture, device volume/mute readings are
omitted too. To investigate a volume change, bookmark once while it sounds wrong
and again after adjusting system volume restores it.

The exporter also serves the per-second metrics on a local Prometheus endpoint,
which is what a maintainer-local dashboard rig would scrape. No such rig is in
this repository and nothing in the app depends on one; the NDJSON and the
scorecard are the portable, self-contained way to analyze a session.

Old files are pruned in two passes. At every launch, whatever the setting, any
Glimmer log or telemetry file older than 14 days is deleted. At the start of
each diagnostics session, the per-frame traces and per-second files are trimmed
to a 300 MB budget: trace segments before per-second files, oldest first, the
most recent session last. Scorecards and diagnostic logs only ever age out. The
budget is enforced before the new session's files exist, so the session being
recorded can exceed it; its trace keeps the first segment and the newest three,
up to about 384 MB.

Press **⌃B** during a stream to drop a timestamped “that felt bad” bookmark into
the telemetry. The chord is intercepted only while telemetry is on; otherwise
the keystroke passes through to the PC. All of it is local-only and carries
performance numbers, never secrets. These are the artifacts the bug-report
template asks for.

`make enable-telem` / `make disable-telem` flip the same preference from the
command line.

### Renderer performance fields

The existing opt-in exporter samples AVFoundation's renderer metrics at its
one-second cadence. No renderer sampler or polling exists when telemetry is off.
These numeric fields use the existing local files and Prometheus endpoint;
Diagnostics remains hidden by default, and LAN access still needs its separate
opt-in. Preference changes apply to the next stream.

NDJSON reports `renderer_frames_total`, `renderer_dropped_frames_total`,
`renderer_optimized_frames_total`, and `renderer_accumulated_frame_delay_s`. The
optimized count records frames using Apple's efficient compositing path.
Prometheus exposes the corresponding `glimmer_renderer_*` metrics, with times
named in seconds. These are renderer counters, not game FPS or physical scanout
measurements. Accumulated delay is relative to sample presentation timestamps,
not end-to-end latency.

`renderer_metrics_status` distinguishes unavailable, pending, baseline and ready
samples. Interval deltas are absent until two valid samples exist; a renderer
replacement or counter rollback starts a new baseline. Check sample age and the
reported interval before interpreting cached values. Only one API request may be
outstanding, and replies after teardown or renderer replacement are ignored.

### Comparing telemetry overhead

Use the same Release executable, fixed scene, display mode, stream settings and
HUD state. Alternate off/on/on/off sessions, allow startup to settle, and sample
process CPU and wakeup counters externally so the measurement does not depend on
telemetry being enabled. Compare memory footprint separately from allocation
churn; footprint cannot establish the number of allocations. Restore the prior
telemetry preference afterward. An absent telemetry file or listener in an off
session is also a useful runtime check of the opt-in boundary.

### Pacing fields

The per-second rows and the scorecard carry the frame pacer's own numbers. The
measured column is from wired 4K240 AV1 sessions on a 240 Hz panel (2026-09-28,
1.9 h; 2026-10-02, 100 s); a pacing change needs these before and after.

| Field                                                                                                    | Where                                                  | Measures                                                                                        | Measured (wired, 240 Hz)                 |
| -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `output_to_present` p50 / p95 / p99                                                                      | scorecard `latency`; rows `lat_output_to_present_*_ms` | VT output to renderer enqueue: the wait for a vsync                                             | 3.1-4.4 ms / 7.8-9.8 ms / 8.9-12.0 ms    |
| `pacing_depth`                                                                                           | rows; scorecard `peak_pacing_depth`                    | frames queued at the tick, after the trim                                                       | avg 0.6-0.8, peak 2-3                    |
| `pacing_target_depth`                                                                                    | rows                                                   | the adaptive target: 1 at rest, +1 per env-signal headroom level                                | 1                                        |
| `present_cadence_err_ms`                                                                                 | rows; scorecard `worst_windows`                        | mean distance of presents from the stream's frame grid                                          | 0.2 ms, worst window 1.1 ms              |
| `refresh_min_hz`, `refresh_avg_hz`, `refresh_max_hz`                                                     | rows                                                   | realized tick cadence that second: ProMotion ramps and skipped callbacks show as a low min      | 238-240 / 240 / 240                      |
| `pacer_ticks_per_s`, `pacer_releases_per_s`                                                              | rows                                                   | display-link ticks, and frames released to the renderer                                         | 240; releases track fps (202 at 201 fps) |
| `present_stale_repeat_total`, `present_stale_repeats_per_s`                                              | rows; scorecard `events`                               | ticks that put no new frame on screen; fps below refresh is the benign case                     | 40/s at 201 fps on 240 Hz                |
| `pacer_over_target_release_total`, `pacer_over_target_releases_per_s`, `pacer_over_target_release_ratio` | rows; scorecard `events`                               | releases forced because a backlog above target survived the trim; a spike is oscillation        | 31 in 100 s                              |
| `pacer_submit_release_total`                                                                             | rows; scorecard `events`                               | frames released straight from submit at rest, skipping a tick; read beside `drops_backpressure` | a few % of frames                        |
| `drops_presentation_late`                                                                                | rows                                                   | frames the pacer trimmed or overflowed (a standing-frame trim counts one)                       | 9 in 100 s                               |

Variable refresh: the display link asks for `preferred = maximum = panel max`
with the floor at the stream rate (`FramePacer+FrameRateRange.swift`). The
question that setting shipped to answer, whether `preferred = floor` made macOS
quantize callbacks to panel divisors (120 Hz and 80 Hz seconds on a 240 Hz
panel), is settled: every wired 240 Hz session since (2026-09-28, 1.9 h;
2026-09-29; 2026-10-02) shows `refresh_min_hz` at or above 237 and
`pacer_ticks_per_s` at 239-241 while active, so the divisor grid is gone and the
setting stays. What the recorded sessions cannot answer is whether a VRR panel
should instead be asked to pace at the content rate (`preferred` = stream fps),
so a 161 fps stream stops alternating one- and two-vsync holds on a 240 Hz grid:
they are all fixed 240 Hz or 120 Hz ProMotion with the stream at or below
refresh. Deciding it needs a session on a VRR panel with the stream below the
panel max, judged on `refresh_avg_hz` tracking `fps_received` and
`output_to_present` p99 staying under one vsync.

### “A movement or press I didn't make”

Press **⌃B** as soon as it happens. Besides the per-second file, the bookmark
lands in the frame trace as an `"event":"bookmark"` row on the same clock as the
input rows (`t_ms`, milliseconds of Mac uptime). The input rows just before it
show what Glimmer sent: a stray `input_mouse` delta, an `input_pad` button mask
that changed, or an `input_scroll` whose `sent_y` differs from what macOS
delivered (`dy`, `units_y`). Mouse movement, controller state and scroll are
traced in full, apart from the neutral controller state sent when a pad
connects; for those, no row means Glimmer didn't send it, so it came from the PC
side. Motion is sampled at 20 Hz, so a missing `input_motion` row proves
nothing. Keys, mouse buttons, pasted text and touchpad touches leave no row
either way.

```sh
cd ~/Library/Logs/Glimmer
# The newest bookmark's t_ms, then the input rows in the 2 s before it, in order:
bm=$(grep -h '"event":"bookmark"' telemetry-frames-<timestamp>*.ndjson | jq .t_ms | sort -n | tail -1)
jq -c --argjson bm "$bm" 'select((.event // "" | startswith("input_"))
    and .t_ms > $bm - 2000 and .t_ms <= $bm)' telemetry-frames-<timestamp>*.ndjson |
    jq -sc 'sort_by(.t_ms)[]'
```

### “Video freezes for a moment on Wi-Fi”

Each per-second row carries the radio (`wifi_rssi_dbm`, `wifi_tx_rate_mbps`,
`wifi_channel`, `wifi_band`), whether the Wi-Fi helper had AWDL parked
(`awdl_suppressing`), and how many datagrams the kernel dropped at a full socket
buffer (`udp_fullsock_delta`). A `video_gap` event row marks every video arrival
gap over 100 ms. If `udp_fullsock_delta` stays 0 through a gap, the packets were
lost before they reached the Mac.

To see what the radio was doing at that moment, turn on airportd's Wi-Fi debug
logging before the stream, press **⌃B** at each freeze, then read airportd's log
around the `video_gap` and bookmark times. Rows stamp `ts` in UTC, so pass the
same times with a `+0000` offset:

```sh
sudo wdutil log +wifi      # before the stream
# …stream, press ⌃B at each freeze…
log show --info --debug --timezone UTC --predicate 'process == "airportd"' \
    --start '2026-01-01 20:31:40+0000' --end '2026-01-01 20:32:20+0000'
sudo wdutil log -wifi      # afterwards; debug logging is chatty
```

Look for a scan, roam, channel switch or power-save change in the second before
each gap.

### Hidden defaults

These have no Settings row. Each lives in the app's defaults domain
(`defaults write io.ugfugl.Glimmer <key> -bool YES` or `-float N`;
`defaults delete io.ugfugl.Glimmer <key>` restores the default) and, unless its
row says otherwise, applies from the next stream. The `pacerTick*` and `cruise*`
keys are escape hatches for chasing a regression, not tuning advice.

| Key                      | Type, default | Effect                                                                                                                                      |
| ------------------------ | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `bitrateBoostWifi`       | float, 1.5    | Highest quality's multiplier on the Wi-Fi bitrate ask. The Wi-Fi cap and the radio gate still apply.                                        |
| `hidGamepadClaimAll`     | bool, NO      | The raw-HID path also takes pads GameController owns, for testing without odd hardware. Reconnect the pad or relaunch to apply.             |
| `telemetryListenLAN`     | bool, NO      | Serves the Prometheus endpoint (port 9847) on every interface instead of loopback, so anyone on your network can read it.                   |
| `diagFileLogDebug`       | bool, NO      | Debug lines in the in-app log and `glimmer-<timestamp>.log`. Same as the “Verbose session log file” toggle in the hidden Telemetry section. |
| `pacerTickOffMain`       | bool, YES     | NO moves the present tick back onto the main run loop.                                                                                      |
| `pacerTickRealtime`      | bool, YES     | NO drops the tick thread's real-time scheduling.                                                                                            |
| `cruiseTraversalEnabled` | bool, NO      | Boosts fast mouse flicks on streams wider than 1920 pixels. Off because aim and flicks overlap in speed.                                    |
| `cruiseVKnee`            | float, 1100   | Cruise: below this speed (HID counts per second) the gain is exactly 1.                                                                     |
| `cruiseVFull`            | float, 1800   | Cruise: from this speed the full gain (stream width ÷ 1920) applies.                                                                        |
| `cruiseDragDeltaScale`   | float, 1.35   | Scales dragged-mouse deltas while raw aim is on, since macOS damps them. 1.0 turns it off; clamped to 0.5 to 3.0. Applies without cruise.   |

## Other Instruments templates worth knowing

These have no Makefile target; open Instruments and pick the template.

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

For raw socket throughput. The Glimmer signposts don't measure bytes per second
directly; that goes into the stats overlay. Use the Network template if you
suspect TCP retransmissions or socket-buffer starvation.

## VideoToolbox diagnostics

- **Real-time hint.** `kVTDecompressionPropertyKey_RealTime = true` is set on
  the session so VT prefers latency over peak quality.
- **No temporal processing.** Sunshine's output has no B-frames, so VT's
  temporal-processing path is irrelevant: frames decode in arrival order.
- **Decode failures.** The `DecodeFrame` interval closes with an `outcome=`
  payload. The decode and present paths that need a fresh keyframe call
  `backend.requestIdrFrame()` and emit an `IDRRequested` event carrying a
  `trigger=`: `param_rebuild_failed`, `no_session`, `sample_build_failed`,
  `vt_decode_failed`, `decode_backlog_stall` or `present_stall`.

## Network diagnostics: packet loss or decode failure

The split between “the bits never arrived” and “the bits arrived but VT rejected
them” matters for triage:

- **Bytes received but no decoded output**: a stream issue on the PC. Either its
  encoder produced a bitstream VT can't accept (a mid-stream SPS/PPS change
  without a fresh IDR; a malformed AV1 sequence header), or the FEC layer
  recovered the bytes but their content is bad. Surfaces as `FrameDropped` with
  `reason=vt_status_error`.
- **Bytes not received**: a network issue. Surfaces as `NativeVideo` log lines
  (`unrecoverable frame`, `loss episode`) and, with telemetry on, as
  `loss_episode` and `video_gap` event rows.
- **Renderer rejection mid-stream**: the layer's
  `AVSampleBufferVideoRenderer.status` latched `.failed`. Surfaces as a
  `RendererFailed` signpost event plus a log line at `.warning`, and is
  recovered by a flush, a fresh display layer and `backend.requestIdrFrame()`.

## Frame watchdog

`StreamSession.frameWatchdogTimer` runs on the main run loop at 1 Hz
(`StreamSession+FrameWatchdog.swift`). It measures decode silence as the shorter
of `secondsSinceLastDecodedFrame()` and `secondsSinceDecodeGateLifted()`, never
longer than this connection has been armed (`watchdogDecodeIdle`), and a gated
decoder trips nothing, so a window that legitimately stopped presenting does not
trip it. Past `frameWatchdogTimeout` (10 s, moonlight-common-c's
`FIRST_FRAME_TIMEOUT_SEC`) the session tears down with
`StreamEvent.connectionTerminated` (error code -1 after video has flowed; -100
or -101 when no frame ever decoded). The log line reads:

```text
Frame watchdog tripped - no decoded frame in <N>s (last byte reception <M>s|never); tearing down
```

A connection that never produced a first frame trips too, timed from
`frameWatchdogArmedAt`; the black-screen-until-you-cancel case is the one that
path fixes. After video has flowed, a still-live control link holds instead of
tearing down. Before the hard trip, keyframe requests start at 2 s of decode
silence (`decodeStallRecoveryThreshold`) and back off to one every 16 s, and at
3 s with packets still arriving (`decodeOnlyStallThreshold`) the log gets a
“bytes received but no decoded output” line.

This fast-paths the common case where the PC crashed, the network dropped or
Sunshine restarted. The protocol's own dead-peer detection can take longer to
declare a dead connection.

## Build configuration

- **Debug** uses `-Onone` plus overflow checks. Don't profile with it: numbers
  are 2-5× worse than production.
- **Release** is what users see: `-O`, no debug asserts, dSYMs preserved.
- `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` is set on Release so Time
  Profiler symbolicates without manual dSYM linking.

`make profile` and `make profile-signposts` both depend on `install`, which
builds Release and copies the signed bundle to `/Applications/Glimmer.app`, the
path `xctrace --launch` points at. So `make profile-signposts` on its own is the
whole command.

## Common pitfalls

- **Don't trust Debug-build numbers.** They are the most common source of “why
  is decode so slow” surprises. `make app` produces a Debug binary; never time
  one.
- **Don't profile on battery.** macOS throttles ARM cores on battery, and at
  4K60 that shows up as `DecodeFrame` p99 spikes that vanish when plugged in.
- **Use Network Link Conditioner to test the network-jitter path.** System
  Settings → Developer → Network Link Conditioner. Pair it with
  `make profile-signposts` to see whether the renderer catches up after a
  transient drop.
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
// … do work …
OSSignposter.decode.endInterval("YourInterval", state, "outcome=ok")
```

Event (point-in-time):

```swift
OSSignposter.decode.emitEvent("YourEvent",
                              "reason=\(reason, privacy: .public)")
```

Pick the closest existing category rather than adding a new one: fewer
categories make Instruments simpler to filter. If the work crosses a thread
boundary, thread the `OSSignpostIntervalState` through whatever data structure
already crosses that boundary (see `StatsCollector` for the reference
implementation: a FIFO of states paired with submit timestamps).
