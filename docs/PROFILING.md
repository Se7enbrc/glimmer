---
description: Use Instruments and local diagnostics to investigate a stream.
icon: gauge-high
---

# Profiling and telemetry

Compare latency, consistency and recovery on the same real stream before
changing engine defaults. For a user bug report, start with
[recording a rough moment](guides/TROUBLESHOOTING.md#record-a-rough-moment).

See [current performance validation](PERFORMANCE_VALIDATION.md) for GPU power,
kernel receive timing, audio silence, refocus and display-rate investigations.

## One diagnostic contract across clients

`GlimmerEngine/Diagnostics` owns event meanings, units, clocks, session
identity, serialization and bounded retention. Mac and iOS adapters supply
platform facts; they must not redefine engine counters or maintain another
telemetry writer. Test shared record changes in the engine boundary, including
absent probes.

Both clients use the shared recorder today. External clients still lack public
bookmark and build-identity inputs; the default configuration leaves identity
empty. Before claiming cross-client parity, expose these through the shared
session API and include app revision, resolved engine revision and record schema
in exported evidence. Do not substitute the app revision for an unknown engine
revision. Missing platform measurements remain unavailable, not healthy zeroes.

## Choose a measurement

Start with the symptom and collect only the evidence you need.

| Symptom                    | First measurement                                           |
| -------------------------- | ----------------------------------------------------------- |
| Lag or uneven frames       | Telemetry `output_to_present`, pacing depth and target.     |
| CPU or fan activity        | Time Profiler plus process/thread resource fields.          |
| Missing frames             | Decode signposts, receive gaps and renderer rejection.      |
| Slow connection or pairing | `ConnectFlow` / `PairingFlow` and stage logs.               |
| Audio gaps                 | Receive gap, worker wait, decode time and render underruns. |
| Input under load           | Capture-to-send histograms and callback-queue delay.        |

Use Release builds on AC power. Hold PC, scene, codec, display, peripherals,
network, audio cushion, Game Mode, HUD and telemetry settings constant between
builds. Unit tests do not establish playback latency or audible equivalence.

## Quick start

Use Instruments when you need call stacks or a timeline.

```sh
make profile
make profile-signposts
```

Both commands **build, sign and install** a Release app first. Run them only
when that installation is intended; otherwise attach Instruments to the
installed Release app. Do not time `make app` Debug builds.

Traces land in `~/Library/Developer/Xcode/Instruments/`. Open one and filter
`os_signpost` by `io.ugfugl.Glimmer`. See
[Apple's performance guide](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance).

## Unified log

Filter by subsystem and category to keep a log readable.

```sh
log stream --predicate 'subsystem == "io.ugfugl.Glimmer"' --level info
```

| Category                                                                 | Area                                               |
| ------------------------------------------------------------------------ | -------------------------------------------------- |
| `AppModel`, `HostsStore`, `ContainerMigration`                           | App state and persistence.                         |
| `AWDLHelper`, `MacSystemStats`, `Diag.FileSink`                          | Helper management, system stats and file logging.  |
| `DualSenseHID`, `Input`, `Stream.Input`                                  | Raw pad, input core and AppKit forwarding.         |
| `Stream.Audio`, `Stream.Capabilities`, `Stream.Discovery`                | Audio, codec probes and discovery.                 |
| `Stream.Identity`, `Stream.Pairing`                                      | Identity and PIN exchange.                         |
| `Stream.Network`, `Stream.Network.TLS`, `Stream.NativeBackend`           | Requests, TLS and protocol adapter.                |
| `Stream.Pacer`, `Stream.Session`, `Stream.VideoDecoder`, `Stream.Window` | Pacing, lifecycle, decode and presentation.        |
| `Stream.Telemetry`                                                       | Exporter, frame trace and system/display samplers. |

Diag also uses short categories such as `Stream`, `NativeConnection`,
`NativeVideo` and `Controller`. The root helper uses subsystem
`io.ugfugl.glimmer.helper`, categories `main` and `AWDL`.

### Target a log question

Replace the filter with the area or breadcrumb you need.

| Question          | Filter after the subsystem condition                                                               |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| Session lifecycle | `category == "Stream.Session" OR category == "Stream.VideoDecoder"`                                |
| HDR               | `eventMessage CONTAINS "HDR" OR eventMessage CONTAINS "Colour probe"`                              |
| Drops/recovery    | `eventMessage CONTAINS "drop" OR eventMessage CONTAINS "FAILED" OR eventMessage CONTAINS "IDR"`    |
| Pairing/TLS       | `category == "Stream.Network" OR category == "Stream.Network.TLS" OR category == "Stream.Pairing"` |
| Input             | `category == "Stream.Input"`                                                                       |
| Identity          | `category == "Stream.Identity"`                                                                    |

For example:

```sh
log show --info --predicate 'subsystem == "io.ugfugl.Glimmer" AND category == "NativeConnection"' --last 5m
```

Keep the existing stage names and Diag breadcrumbs when changing these paths.

## OSSignpost instrumentation

Read intervals for duration and events for recovery or state changes.

| Category         | Intervals                        | Events                                                                               |
| ---------------- | -------------------------------- | ------------------------------------------------------------------------------------ |
| `Stream.Decode`  | `DecodeFrame`, `VTSessionCreate` | `FrameDropped`, `IDRRequested`, `StatsSnapshot`, `DecodeGate`, `DecodeStallRecreate` |
| `Stream.Render`  | `EnqueueFrame`                   | `RendererFailed`, `Pacer*`, `Present*`                                               |
| `Stream.Network` | `ConnectFlow`                    | Connection stages are logs/telemetry, not signposts.                                 |
| `Stream.Pairing` | `PairingFlow`                    | `PairingStep`                                                                        |
| `Stream.Audio`   | `AudioFrame`                     | One interval per decoded packet.                                                     |

`EnqueueFrame` ends at pacer submission; it does not measure the pacing wait.
`StatsCollector` carries decode interval states across queues and closes evicted
ones with `outcome=evicted_from_fifo`. Connect intervals close as established,
aborted or reconnect. Preserve those closures across failures.

## Investigate video latency

Read the scorecard's `latency.output_to_present` before opening Instruments.

| Check                              | Recorded or target behavior                                                        |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| Wired 240 Hz output-to-present p50 | Roughly 3–4 ms, below one vsync.                                                   |
| Wired 240 Hz p95 / p99             | Roughly 7–10 / 8–12 ms; beyond two vsyncs suggests extra queueing or missed ticks. |
| `pacing_depth`                     | Usually 0–1; a steady 2 at target 1 suggests a standing frame.                     |
| `pacing_target_depth`              | 1 on a clean link.                                                                 |
| 4K60 AV1 HDR on high-end Pro/Max   | Target decode p99 below 8 ms and enqueue p99 below 1 ms.                           |

If pacing is normal, aggregate `DecodeFrame` in Instruments and inspect
p50/p95/p99. Compare P-frames separately from IDRs. Slow decode alone does not
prove bad PC bitstreams or GPU saturation; check scheduling and Metal System
Trace.

### Drops and stalled pictures

Separate receive loss, decode failure and renderer rejection before assigning a
cause.

| Evidence                                           | Meaning                                                                 |
| -------------------------------------------------- | ----------------------------------------------------------------------- |
| `vt_status_error`                                  | VT failed inline; inspect assembly, FEC, bitstream and decoder state.   |
| `vt_info_dropped`                                  | VT discarded a submitted frame.                                         |
| `no_image_buffer`                                  | Success without a pixel buffer; investigate as a bug.                   |
| `loss_episode`, `video_gap`, `unrecoverable frame` | Receive-side loss or delay.                                             |
| `RendererFailed`                                   | Renderer latched failure; recovery replaces the layer and requests IDR. |

`IDRRequested` carries `param_rebuild_failed`, `no_session`,
`sample_build_failed`, `vt_decode_failed`, `decode_backlog_stall` or
`present_stall`. VT uses its real-time hint; Sunshine streams have no B-frame
temporal-processing requirement.

### Frame watchdog

Check decode gating and control activity before treating silence as a dead
stream.

The 1 Hz watchdog measures silence since the latest decoded frame or gate lift,
bounded by connection age. A gated decoder does not trip it. Requests for
keyframes start at two seconds and back off to one per 16 seconds; packets
without decoded output produce a diagnostic at three seconds.

At ten seconds, teardown reports -1 after video flowed or -100/-101 before a
first frame. After video has flowed, recent control ACKs hold teardown and can
allow remote bitrate recovery. The retained breadcrumb is:

```text
Frame watchdog tripped - no decoded frame in <N>s (last byte reception <M>s|never); tearing down
```

## Investigate CPU and connection time

Use a fixed scene and compare both visible and hidden playback.

Steady CPU below 30% of one P-core on M3/M4 is a target, not a guarantee. For
the 2026.10.8 audit, compare against the approximately 20%-of-one-core 2026.10.7
baseline at 4K240 HDR. Warm up, then record at least one minute visible and one
hidden, with matched telemetry/HUD off and on. No measured improvement is
established merely by removing work.

| Context           | Work to verify                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------ |
| Main              | 4 Hz history/recovery, no hidden HUD formatting or idle recovery polling.                              |
| Controller mouse  | 20 Hz only while a stick moves or scrolls.                                                             |
| Sender            | Demand-driven 1 ms merge deadlines, no idle wakeups.                                                   |
| Audio maintenance | 10 ms observation; query HAL running state only when consumption stalls/resets.                        |
| Capture/motion    | Off-main callbacks, requested/rate-limited motion, 30 s battery polling.                               |
| Diagnostics       | Opt-in 1 Hz sampling; display sample on main, other export off main.                                   |
| Safeguards        | Preserve 20 Hz present watchdog, 1 Hz frame watchdog/AWDL renewal, 2 s session tick and ENet recovery. |

For connection delays, compare consecutive `NativeConnection` stage lines with
`ConnectFlow`. For pairing, the last `PairingStep` identifies the round:
`getservercert`, `clientchallenge`, `serverchallengeresp`,
`clientpairingsecret`, `pairchallenge`. Do not add network probes to explain a
slow launch.

## Opt-in telemetry

Enable telemetry before a new stream, then stop the stream to write its
scorecard.

1. Option-click the version in Settings › About.
2. Enable Performance telemetry in Settings › Diagnostics.
3. Start the stream and press Control-B at each rough moment.
4. Save progress, stop, and inspect `~/Library/Logs/Glimmer/`.

`make enable-telem` and `make disable-telem` change the same preference. Changes
apply to the next stream. The live controller test and log viewer need no
hidden-setting gesture.

| File                                  | Contents                                                            |
| ------------------------------------- | ------------------------------------------------------------------- |
| `telemetry-<timestamp>.ndjson`        | Per-second metrics and events: bookmarks, gaps, loss and keyframes. |
| `telemetry-session-<timestamp>.json`  | Session scorecard.                                                  |
| `telemetry-frames-<timestamp>.ndjson` | Segmented frame and merged-input trace.                             |
| `glimmer-<timestamp>.log`             | Session diagnostics with private values redacted.                   |

PC/Mac fields `host` and `client` are per-install pseudonyms. Input trace events
include `input_mouse`, `input_mouse_abs`, `input_pad`, `input_motion` at 20 Hz
per sensor and `input_scroll`. They exclude keyboard keys, mouse buttons, pasted
text and touchpad contacts. Review [privacy limits](PRIVACY.md) before sharing.

`audio_output_silent_s` counts sampled seconds with nonzero input PCM but silent
final-mixer output. Two consecutive samples log once per episode. Muted/empty
input, missing samples and route replacement reset it. It cannot detect physical
mute or acoustic faults after HAL; compare listening and `audio_output_state`.

### Retention and metrics access

Use files for portable evidence; the optional HTTP endpoint exposes the same
per-second metrics.

Telemetry enables loopback `/metrics` on port 9847. LAN access requires a
separate opt-in and has no authentication or encryption. No external dashboard
service is required.

At every launch, files older than 14 days are pruned. At diagnostics-session
start, traces then per-second files are trimmed oldest-first to 300 MB, the most
recent session last. Scorecards/logs only age out. The active session can exceed
the budget; its trace retains the first and newest three segments, about 384 MB.

### Renderer performance fields

Check status, sample age and interval before reading renderer deltas.

| Field                                | Meaning                                                      |
| ------------------------------------ | ------------------------------------------------------------ |
| `renderer_frames_total`              | Renderer frame counter.                                      |
| `renderer_dropped_frames_total`      | Renderer drop counter.                                       |
| `renderer_optimized_frames_total`    | Frames using Apple's efficient compositing path.             |
| `renderer_accumulated_frame_delay_s` | Delay relative to sample timestamps, not end-to-end latency. |
| `renderer_metrics_status`            | Unavailable, pending, baseline or ready.                     |

The opt-in sampler runs once a second with one outstanding request. Replacement
or counter rollback starts a new baseline; two valid samples are needed for
deltas. Late teardown/replacement replies are ignored. Prometheus uses
`glimmer_renderer_*`. These counters are not game FPS or physical scanout
measurements.

### Pacing fields

Compare these fields before and after pacing changes, using matched display
conditions.

Recorded wired 4K240 AV1 sessions on 2026-09-28 and 2026-10-02 supplied these
reference values; they are not targets for every display.

| Field                                                                                                    | Meaning                                                                                  | Recorded at 240 Hz                         |
| -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------ |
| `output_to_present`                                                                                      | VT output to renderer enqueue; row prefix `lat_output_to_present_`, scorecard `latency`. | p50 3.1–4.4, p95 7.8–9.8, p99 8.9–12.0 ms. |
| `pacing_depth`                                                                                           | Queue after trim; scorecard `peak_pacing_depth`.                                         | Average 0.6–0.8, peak 2–3.                 |
| `pacing_target_depth`                                                                                    | Adaptive target, one plus headroom.                                                      | 1.                                         |
| `present_cadence_err_ms`                                                                                 | Mean distance from the stream frame grid.                                                | 0.2 ms; worst window 1.1 ms.               |
| `refresh_min_hz`, `refresh_avg_hz`, `refresh_max_hz`                                                     | Realized tick cadence.                                                                   | 238–240 / 240 / 240.                       |
| `pacer_ticks_per_s`, `pacer_releases_per_s`                                                              | Ticks and released frames.                                                               | 240 ticks; releases follow FPS.            |
| `present_stale_repeat_total`, `present_stale_repeats_per_s`                                              | Ticks without a new frame.                                                               | 40/s for 201 fps on 240 Hz.                |
| `pacer_over_target_release_total`, `pacer_over_target_releases_per_s`, `pacer_over_target_release_ratio` | Releases forced by backlog surviving trim.                                               | 31 in 100 s.                               |
| `pacer_submit_release_total`                                                                             | Direct releases at rest; compare with `drops_backpressure`.                              | A few percent.                             |
| `drops_presentation_late`                                                                                | Trimmed or overflowed frames.                                                            | 9 in 100 s.                                |

Variable-refresh modes use a high supported floor and a measured-content target
that changes only after sustained evidence. Fixed-mode repeat spacing remains
bounded by the existing trim policy. Follow the
[pacing candidate checks](PERFORMANCE_VALIDATION.md#pacing-policy-and-candidate-checks)
before accepting changed cadence, latency or power. Earlier captures do not
validate this RC.

## Audio under full CPU load

Compare 120 seconds idle, 120 under load and 120 recovery on both Release
builds.

Match output, channel layout, `audio_cushion_seed_ms`, target and link class.
Repeat with telemetry and Game Mode off/on. Listen and bookmark gaps; test
output switches, unplug/reconnect, and stream reconnect while load continues.

| Field/family                                                    | Check                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `audio_receive_gap`                                             | Every datagram, including parity; compare tails and open `audio_gap_max_ms`.                |
| `audio_queue_wait`                                              | Receive to worker dequeue; tail below the cushion.                                          |
| `audio_decode_schedule`                                         | Opus/PLC through schedule/prime, including admission wait; p99 below the 5 ms frame period. |
| `audio_state_lock_wait`                                         | Graph work must not become long admission waits.                                            |
| `audio_buffer_fill_min_ms`, `audio_near_misses_window`          | Minimum accounting fill and 15/30 ms near-miss edges.                                       |
| `audio_render_cushion_min_ms`, `audio_render_underrun_total`    | Actual callback fill and missing PCM; no added underruns.                                   |
| `audio_decode_realtime`                                         | Mach request succeeded, not a guarantee against later demotion.                             |
| `audio_worker_overflow_total`, `audio_pcm_pool_exhausted_total` | No steady growth. A full packet queue drops newest.                                         |
| `audio_reconfiguration_drop_total`                              | Expected only around graph/device changes.                                                  |

`AudioFrame` normally covers a 5 ms packet; sparse intervals need receive-gap
and scheduling evidence before blaming decode. Verify the `Glimmer.audioDecode`
thread in System Trace and use Audio System Trace alongside listening.

### Interpret audio measurements

Subtract histogram buckets, counts and sums across each load window; never
subtract percentiles.

NDJSON carries `audio_timing_bounds_ms`, `_buckets`, `_count`, `_sum_ms` and
cumulative percentiles. Prometheus uses `glimmer_<family>_ms_bucket`, `_sum`,
`_count`; calculate quantiles over rates.

HAL counts missing PCM directly, excluding startup/stopped graphs. Older
player-clock polling could miss short gaps, so the counters are not identical
measurements. Keep trims, re-primes, drift/skew, engine/stall recovery and video
presentation p99 alongside them. Baselines must use the same timing boundaries.

| Gauge                      | Boundary                                                                                                                                 |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `audio_output_latency_ms`  | Device latency + safety offset + buffer duration + largest active stream latency; excludes processing-unit and acoustic/Bluetooth delay. |
| `audio_device_recovery_ms` | Device notification to first consumed PCM in the new graph, observed within the 10 ms monitor cadence.                                   |

### Audio device checks

Use listening and channel signals to verify what hostless tests cannot
establish.

1. Turn your head with compatible AirPods; check anchoring, reconnect and the
   existing personalized profile.
2. Check speakers for stereo/surround sources, loudness, mute, cracks and added
   delay.
3. Play a channel-identification signal over HDMI/USB 5.1 and 7.1; check center,
   side/rear pairs and LFE, including 48 ↔ 44.1/96 kHz changes.
4. Switch speakers → AirPods → USB/HDMI → speakers; unplug/reconnect the output.
   Require recovery without reconnecting the stream or false cushion growth.
5. Repeat sleep/wake and device changes under load, telemetry off/on.

Use physical loopback for end-to-end latency and A/V skew. Retain
`audio HAL ready`, `audio engine config change handled` and
`audio device recovery` breadcrumbs. `audio_output_state` events after
configuration/bookmarks include gains, formats and volume/mute when available,
but omit device identity and stale-route readings. Bookmark before and after a
volume adjustment to compare.

## Input under CPU load

Measure capture-to-submit and local callback delay separately from PC response.

Timing is opt-in with telemetry, for `keyboard`, `mouse`, `controller` and
`raw_hid`. Event timestamps come from AppKit, GameController or IOHID and use
Mac uptime. Invalid/future timestamps do not become zero-latency samples.

| Stage                | Boundary                                          |
| -------------------- | ------------------------------------------------- |
| `capture_handler`    | OS/device event to handler entry.                 |
| `handler_batcher`    | Handler to batcher submission.                    |
| `batcher_flush`      | Batcher to flush, including merging/scheduling.   |
| `flush_send`         | Flush to `NWConnection.send`.                     |
| `capture_send`       | Original event to that invocation.                |
| `send_completion`    | Invocation to `.contentProcessed` callback entry. |
| `capture_completion` | Original event to completion callback.            |

Submission/completion does not prove physical transmission or PC acceptance.
Local shortcuts produce no packet measurement. Coalesced input retains original
timestamps, split packets count once, and synthetic releases do not borrow event
timings. Sensor callbacks have no source timestamp and keep `input_motion`
metrics.

### Input fields and gates

Require `input_timing_dropped_total == 0` for a valid comparison.

NDJSON fields are
`input_<source>_<stage>_{p50_ms,p95_ms,p99_ms,max_ms,count,over_10ms,over_20ms,over_50ms}`.
Histograms are cumulative, with `input_latency_bounds_ms` and per-stage buckets.
Maxima and strictly-greater-than counts are exact; percentiles interpolate
buckets. Each slot retains up to 4096 samples. The scorecard's `input_latency`
includes startup.

Prometheus exposes `glimmer_input_<source>_<stage>_ms_{bucket,sum,count}`,
`_max_ms` and `_over_{10,20,50}ms_total`. Use bucket differences or rates for
windowed quantiles. Compare maxima in separate fixed-duration sessions.

The callback-queue probe is `lat_input_callback_queue_{p50,p95,p99}_ms` or
`glimmer_input_callback_queue_ms`. Submission/ACK-silence gates require local
queue progress within 2 ms. ACK silence uses `max(30 ms, 3 × RTT)` and eight
submissions; ACK-only holds end after 10 ms. Edges bypass gates. A local queue
stall can mask simultaneous network trouble; check real loss separately.

### Reproduce and compare

Collect an equal idle/load/recovery window, then compare tails and recovery.

| Evidence                                                                                | Acceptance                                                                              |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Per-source `capture_send`                                                               | Lower tails/gap rates with comparable counts.                                           |
| Controller/raw HID `capture_handler`                                                    | Lower scheduling tails; keyboard/mouse still depend on main.                            |
| `batcher_flush`, `flush_send`, `send_completion`                                        | Identify sender versus callback queue delay.                                            |
| `input_flush_backpressure_skips_total`, `input_flush_backpressure_reliable_skips_total` | No sustained holds from local stalls; real loss still gates motion, not edges/releases. |
| Video p99 and audio underruns                                                           | No material collateral regression.                                                      |

Keep the sender's exact startup line:

```text
input send thread: realtime scheduling applied
input send thread: thread_policy_set failed (kr=<code>); staying userInteractive
```

Mach scheduling is best effort. Older `lat_input_queue_to_wire` excludes OS
capture and queued submission, so it is not a `capture_send` baseline.

### Generate a controlled load

Run this only when ready: it waits ten seconds for focus, then loads each
logical CPU for 120 seconds.

```sh
python3 - <<'PYLOAD'
import os, subprocess, sys, time
worker = "import ctypes,time; assert ctypes.CDLL(None).pthread_set_qos_class_self_np(0x15,0)==0; end=time.monotonic()+120\nwhile time.monotonic()<end: pass"
time.sleep(10)
workers = [subprocess.Popen([sys.executable, "-c", worker]) for _ in range(os.cpu_count() or 1)]
try:
    for p in workers: p.wait()
finally:
    for p in workers:
        if p.poll() is None: p.terminate()
    for p in workers: p.wait()
PYLOAD
```

Workers use default QoS, not interactive or real-time priority. Use the same
trial for audio and input, and retain listening/bookmark notes.

## Inspect a rough moment

Match bookmarks to nearby input and network events using the shared `t_ms`
clock.

Press Control-B while the stream is still foreground, then switch apps to report
the problem. Mac bookmarks capture window, layer, overlay and HDR state at the
key press in the session log (`BOOKMARK context t_ms=…`). The bookmark preserves
that monotonic time and wall-clock date across the asynchronous session/file
queues. A later hidden-window sample does not describe the earlier incident.

Input traces can drop rows under disk pressure and prune old segments. Missing
rows do not prove the PC generated an event, especially for sampled motion or
input types that are never recorded.

Replace `SESSION` with your trace timestamp:

```sh
cd ~/Library/Logs/Glimmer
bm=$(grep -h '"event":"bookmark"' telemetry-frames-SESSION*.ndjson | jq .t_ms | sort -n | tail -1)
jq -c --argjson bm "$bm" 'select((.event // "" | startswith("input_"))
    and .t_ms > $bm - 2000 and .t_ms <= $bm)' telemetry-frames-SESSION*.ndjson |
    jq -sc 'sort_by(.t_ms)[]'
```

### White bands or other image artifacts

Frame trace `renderer_decision` events identify repaint submissions, failed or
backpressured submissions, and repaint-copy failures. They include `rtp`,
`t_ms`, `suppressed` and `decode_gated`. Repaints reuse an image and never count
as a new rendered frame or latency observation. Match their RTP identity to
nearby frame rows; missing rows can also mean trace overflow or segment pruning.

`t_present_ms` means the image was handed to `AVSampleBufferVideoRenderer`. It
does not prove which pixels reached the display. Healthy transport, decode and
renderer counters cannot rule out a one-frame white band. To locate that fault,
compare the PC image, decoded image and composited output from the same
incident; a physical-display-only fault also needs an external recording.
Current telemetry records timing and state, not those images.

`renderer_state` rows capture the first refusal, the next accepted enqueue, and
the boundaries of a present-recovery flush call. They carry renderer status,
readiness, `requires_flush`, attachment generation and the bookmark clock. Frame
transitions also include rejection count, raw PTS value/timescale/epoch/ flags
and the observed `display_immediately` attachment. Compare the first rejected
PTS with the preceding accepted frame in the same trace.

The first-refusal snapshot precedes the normal immediate-display marking, so
`display_immediately=false` there is expected. `backpressure_ended` means
enqueue was allowed, not that pixels reached the display. On backpressure
transitions, `ready` is the enqueue gate's result; the remaining properties are
sampled adjacently. Flush rows sample readiness directly. `flush_returned` marks
the API call returning, not asynchronous rendering completion. Missing
generation means the observed renderer was already detached; missing ending rows
may also mean teardown or trace overflow. Framework properties are adjacent
observations, not an atomic framework snapshot. Additional property reads occur
only at these transitions and only with telemetry enabled.

### Memory growth

Separate a fresh-process baseline from reconnect history and profiling runs.
Compare active-stream and post-stop footprint, then use Allocations generations
and allocation stacks to identify retained objects. A large footprint alone does
not establish a leak. Verify that Instruments actually attached and recorded
allocations; an output trace directory after an attach failure is no evidence of
a clean heap. Keep instrumented intervals out of baseline CPU and power
comparisons.

### Wired hitches and local thread stalls

Keep telemetry and frame traces enabled. A wired route does not rule out a
client stall; profiler overhead also cannot explain incidents recorded before
profiling began. Correlate the bookmark with every stage before assigning cause.

`receive_gap` rows and `ReceiveGap` signposts identify the receive thread and
the observation's monotonic `t_ms`, aligned with frame traces. The NDJSON `ts`
is the writer's time; use `t_ms` when the writer itself was delayed. Reports are
limited to one per socket per five seconds; `reports_suppressed` counts
additional qualifying gaps since the preceding report. Unreported gaps after the
final report are not flushed at stop; retain the per-second histograms too.
`kind=split delay` means the read interval exceeded 50 ms while neither the
arrival gap nor queued age individually did; it must not be labeled a local
stall.

| Evidence                      | What it establishes                                                                                                                                  |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `queued_ms`                   | Time from kernel arrival to return from receive. Large values establish local delay.                                                                 |
| `kernel_gap_ms`               | Arrival separation for these adjacent timestamped datagrams; keep it alongside local delay.                                                          |
| `receive_call_ms`             | Wall time from immediately before the current receive syscall to immediately after it. Includes waiting and descheduling, not just kernel execution. |
| `between_calls_ms`            | Wall time from the previous receive return to the current call, including packet processing and descheduling.                                        |
| `thread_id`, `StreamBookmark` | Correlation with System Trace threads and the original bookmark time.                                                                                |

Call timings describe the latest receive attempt, including a preceding failed
attempt or timeout; they do not necessarily sum to the gap between valid peer
packets. Missing/invalid clocks and failed queue probes are `null`, never zero.
The two socket paths share this implementation. One extra clock read per receive
call adds no per-packet app boundary, sampling timer or stack walk.

For the next recurrence, record scheduling history rather than infer a blocked
thread from a one-second CPU average:

1. Select the running installed Glimmer PID. Keep the candidate and its
   signature unchanged; do not use `make profile`, which installs another build.
2. Run a bounded, non-windowed System Trace. Replace `PID` below and use a fresh
   output name. Run from the repository root. This records the process; it does
   not launch it.
3. Bookmark the hitch while still foreground. Let the one-minute recording end,
   or stop it with Control-C after the event.
4. Verify successful recording and retained thread-state/scheduling data. Match
   receive, pacer and decode threads to the incident; distinguish runnable but
   unscheduled time, blocked waits and active work using available stacks.
5. Retain the trace, session log, telemetry, frame trace and exact build
   identity. Record unavailable scheduling/stacks explicitly; a failed
   attachment proves nothing about the app. Do not change signing or system
   protections to retry without separate authorization.

```sh
xcrun xctrace record --template 'System Trace' --attach PID \
  --time-limit 60s \
  --recording-options scripts/hitch-recording-options.json \
  --output "$HOME/Library/Developer/Xcode/Instruments/Glimmer-hitch.trace"
```

The options request waiting-thread, context-switch and kernel stacks alongside
Points of Interest. Verify supported options with
`xcrun xctrace record --template 'System Trace' --show-recording-options` on the
installed Xcode; defaults can omit the wait evidence this investigation needs.
Unsupported or unavailable probes remain an explicit capture limitation, not a
clean result.

Validate the exported start/end times and actual rows against the bookmark. One
Xcode 27 rolling capture saved successfully but its exported range ended before
the incident; a successful save alone does not establish coverage. Finalization
can take several minutes and use substantial CPU and memory. Exclude that
interval from uninstrumented performance comparisons. If the recorder warns that
requested and configured sampling periods differ, use the configured period when
interpreting stack coverage.

Full allocation recording answers retained-memory questions, not why a thread
was waiting. Collect it separately when needed; retain lightweight diagnostics
throughout both trials. A System Trace is also instrumented: compare the same
scene without it before claiming normal playback performance or overhead.

### Wi-Fi gaps

For failed helper registration, follow the Settings recovery message. Do not
routinely reset the whole macOS background-task database; that affects other
apps. AirDrop and other users of `awdl0` pause while the helper suppresses it.

Compare `video_gap` events over 100 ms with radio and helper state.

Read `wifi_rssi_dbm`, `wifi_tx_rate_mbps`, `wifi_channel`, `wifi_band`,
`awdl_suppressing` and `udp_fullsock_delta`. Zero full-socket drops rules out
that measured loss only, not every network delay.

For a targeted radio trial, enable Wi-Fi debug logs, bookmark, then restore
logging:

```sh
sudo wdutil log +wifi
log show --info --debug --timezone UTC --predicate 'process == "airportd"' \
  --start '2026-01-01 20:31:40+0000' --end '2026-01-01 20:32:20+0000'
sudo wdutil log -wifi
```

Replace the UTC times with the event window. Look for scans, roaming, channel
switches or power changes just before the gap.

### Hidden defaults

Use these only to investigate a regression, and restore them after the trial.

Set with `defaults write io.ugfugl.Glimmer KEY -bool YES` or `-float N`;
`defaults delete io.ugfugl.Glimmer KEY` restores the default. Changes apply to
the next stream unless noted.

| Key                          | Default          | Effect                                                                      |
| ---------------------------- | ---------------- | --------------------------------------------------------------------------- |
| `bitrateBoostWifi`           | float 1.5        | Highest quality Wi-Fi multiplier; radio gate and cap still apply.           |
| `hidGamepadClaimAll`         | bool NO          | Claim GameController pads through raw HID too; reconnect/relaunch to apply. |
| `telemetryListenLAN`         | bool NO          | Bind metrics to every interface, readable by anyone on the LAN.             |
| `diagFileLogDebug`           | bool NO          | Verbose in-app/session file log; also in the hidden Telemetry pane.         |
| `pacerTickOffMain`           | bool YES         | NO moves ticks to the main run loop.                                        |
| `pacerTickRealtime`          | bool YES         | NO removes real-time tick scheduling.                                       |
| `cruiseTraversalEnabled`     | bool NO          | Fast-flick boost above 1920 stream width.                                   |
| `cruiseVKnee`, `cruiseVFull` | float 1100, 1800 | HID counts/s at unity and full width/1920 gain.                             |
| `cruiseDragDeltaScale`       | float 1.35       | Raw dragged-delta scale, 0.5–3.0; 1 disables, independent of cruise.        |

## Other Instruments templates worth knowing

Choose a template that can test your suspected bottleneck.

| Template           | Use                                                                     |
| ------------------ | ----------------------------------------------------------------------- |
| Metal System Trace | GPU/compositor and VideoToolbox work, despite no custom Metal renderer. |
| System Trace       | Locks, syscalls and scheduling stalls.                                  |
| Network            | Socket throughput, retransmissions and starvation.                      |
| Audio System Trace | Device/render timing alongside audible checks.                          |

## Comparing telemetry overhead

Alternate off/on/on/off sessions of the same Release executable after warm-up.

Keep scene, display, settings and HUD fixed. Sample CPU/wakeups externally so
the measurement works with telemetry off. Compare footprint separately from
allocation churn. Confirm off sessions have no telemetry file/listener, and
restore the previous preference. Measure signpost overhead too; do not assume a
fixed cost or disable production evidence without measurement.

## Build configuration

Use optimized Release with its dSYM for timing; Debug uses `-Onone` and overflow
checks.

For jitter trials, use Network Link Conditioner with telemetry/signposts.
High-rate Instruments data can coalesce. Temporarily request verbose logging if
needed:

```sh
sudo log config --mode "level:debug" --subsystem io.ugfugl.Glimmer
sudo log config --reset --subsystem io.ugfugl.Glimmer
```

Run the reset after the recording, not before it.

## Adding new signposts

Reuse the closest shared signposter in
`GlimmerEngine/Diagnostics/Signposts.swift`.

```swift
let id = OSSignposter.decode.makeSignpostID()
let state = OSSignposter.decode.beginInterval("YourInterval", id: id,
                                              "key=\(value, privacy: .public)")
OSSignposter.decode.endInterval("YourInterval", state, "outcome=ok")
OSSignposter.decode.emitEvent("YourEvent", "reason=\(reason, privacy: .public)")
```

Place the measured work between begin and end. Carry interval state through an
existing cross-thread structure, as `StatsCollector` does; close every outcome.
Keep sensitive values private and never add per-frame `.info` logging.
