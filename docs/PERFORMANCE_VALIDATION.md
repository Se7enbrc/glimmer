# Performance validation for 2026.10.8

Use these measurements and outstanding checks with the
[profiling guide](PROFILING.md). Earlier captures are evidence for specific
builds, not acceptance of the new RC.

## 2026.10.8 stream CPU audit

The acceptance target is below the 2026.10.7 baseline of approximately 20% of
one core during 4K240 HDR, with main near idle and lower CPU when hidden. The
changes below remove identifiable work; they are not a measured CPU result.
Compare the same Mac, PC, scene, codec, display, audio route and controller at
both revisions. Keep telemetry and the HUD matched, warm up first, then record
at least one minute visible and one minute hidden. Repeat with each off and on.
Use process CPU and the per-thread resource fields, plus a Time Profiler trace;
check frame timing, input tails and audio underruns alongside CPU.

| Execution context             | Work retained or removed                                                                                                                                                                                                   | Expected effect                                                                                        |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Main, stats refresh           | Keep the 4 Hz history and hitch baselines; read RTT once. Skip HUD formatting, system stats, battery and layer work while occluded.                                                                                        | Less work with a hidden HUD window; fewer RTT reads in every stream.                                   |
| Main, input recovery          | Reconcile held inputs at 4 Hz with 25 ms timer tolerance. Stop the timer when releases settle; idle mouse mode creates no recovery obligation. Neutral controller samples no longer request a main-thread activity update. | No idle recovery polling or neutral-sample main hops.                                                  |
| Controller mouse queue        | Run the 20 Hz timer only while a stick produces a pointer or scroll delta.                                                                                                                                                 | Zero mouse timer wakes at rest; unchanged moving-stick cadence.                                        |
| Input sender                  | Merge deadlines remain demand-driven at 1 ms. Scheduling from the sender itself no longer wakes waiting producers.                                                                                                         | No idle ticks and fewer unnecessary condition wakeups during merged input.                             |
| Audio maintenance queue       | Keep the 10 ms render observation and recovery cadence. Query HAL running state only when the consumed-frame count fails to advance or resets.                                                                             | Avoid up to roughly 100 device queries/s during steady playback; no added render-thread work.          |
| Controller capture and motion | GameController and raw HID callbacks run off main. Motion remains event-driven, requested by the PC, rate-limited and duplicate-suppressed. Battery polling remains 30 s.                                                  | No new main-thread polling; no motion work when disabled.                                              |
| Launcher and readiness pulse  | Launcher navigation stops while streaming. The readiness pulse is a Core Animation opacity animation, removed when occluded.                                                                                               | No per-frame SwiftUI heartbeat or hidden pulse work.                                                   |
| Telemetry                     | Export, process/thread sampling and renderer sampling remain opt-in at 1 Hz off main. Display sampling is opt-in at 1 Hz on main.                                                                                          | No added default sampling cost; retain diagnostic evidence.                                            |
| Session/control safeguards    | Keep the 20 Hz present watchdog, 1 Hz frame watchdog, 2 s session tick, ENet keepalives/retransmits and 1 Hz AWDL lease renewal.                                                                                           | Preserve recovery deadlines and Wi-Fi protection. Hidden presentation takes the watchdog's early exit. |

Video receive, decode and pacing retain their dedicated execution paths. Their
normal frame flow does not dispatch a task to main for each frame; first-frame,
colour transitions and coalesced renderer recovery still publish there. No
pacing, bitrate, buffering or audio-cushion defaults changed in this audit.

## Silent output

`audio_output_silent_s` counts seconds of silent output while PCM is flowing.
Known cause, fixed in 2026.10.8: MacBook speakers report a two-channel layout
labelled `kAudioChannelLabel_Unknown`; copying it onto the final mixer rendered
exact silence. The graph keeps its own stereo layout and leaves the physical map
to the HAL. Apple's built-in speaker renderer also drops LFE at 44.1 and 48 kHz,
so built-in speakers use a stereo downmix: centre and surrounds at -3 dB, LFE at
-6 dB, with shared headroom.

## GPU power and time awake

`gpu_residency_percent` is the percentage of time the GPU is awake at any clock,
from IOReport's GPU Stats active states. It is not the percentage of GPU
capacity used: 48% awake at the lowest clock does not mean 48% of the GPU.
`gpu_power_w` is the cost in watts, from the Energy Model's “GPU Energy” rail.
Each channel's own mJ, uJ or nJ unit is converted over the measured sample
interval. `package_power_w` includes CPU, GPU and ANE compute rails.

These are whole-SoC readings, including other apps. Compare watts with the same
scene and background workload; residency alone cannot judge cost. The owner
measured an M4 Pro playing 4K HDR AV1 at about 185 fps on a 240 Hz display: the
direct path read 0 mW GPU power; composited playback read about 690 mW at P1.
This is a workload reference, not a universal threshold.

The stats overlay is what composites in that case. Any layer or window drawn
over the video makes macOS blend every frame; on the same M4 Pro the overlay
cost about 0.66 W of GPU power and 8% of a core while visible, and nothing when
hidden. A child window over the video composites the same way.

The per-second rows carry `gpu_power_w` and `gpu_residency_percent`; Prometheus
prefixes both with `glimmer_`. The session scorecard's `resources` object
carries min/avg/max for both and `package_power_w`, over all available session
samples (including startup and hidden windows). Missing rails and first samples
are omitted. A flat Energy Model window retains its baseline and emits no power
reading; zero GPU power is valid when other compute rails advance. All fields
reuse the opt-in sampler's existing one-second cadence. The stats overlay
currently shows neither GPU residency nor GPU power.

## Kernel receive timing

Video and audio enable the public `SO_TIMESTAMP_MONOTONIC` socket option.
`SCM_TIMESTAMP_MONOTONIC` carries Mach absolute ticks, converted with the Mach
timebase, not nanoseconds or wall time. The timestamp is taken in IP receive
processing before socket queuing, not at the radio or NIC. See Apple's
[`ip_savecontrol`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/ip_input.c).
Video's existing `recvmsg_x` record carries a separate ancillary buffer per
packet; its unavailable/unsupported fallback uses public `recvmsg`, retaining
timestamps. Audio uses `recvmsg`. No probe or network round trip is added.

Each per-second NDJSON row includes the following for each prefix `video` and
`audio`. Prometheus uses the same fields prefixed with `glimmer_`.

| Suffix after `<stream>_rx_`              | Meaning in the capture window                        |
| ---------------------------------------- | ---------------------------------------------------- |
| `timestamp_samples`                      | Packets with a valid kernel timestamp                |
| `timestamp_missing`                      | Packets with missing, truncated or future timestamps |
| `read_delay_max_ms`, `read_delay_p99_ms` | Kernel arrival to receive syscall return             |
| `kernel_gap_max_ms`, `kernel_gap_p99_ms` | Successive kernel arrival gaps                       |

Windows reset on capture; an idle window has zero samples and omits delay/gap
fields. Missing timestamps break the kernel-gap chain. Maxima are exact; p99 is
a nearest-rank histogram upper bound capped at the exact maximum. The 64 fixed
bins are 0.25 ms through 4 ms, 1 ms through 20 ms, 5 ms through 100 ms, then 25
ms through 475 ms; the final bin reports the maximum. All packets in one batch
share the syscall-return time, so processing earlier packets cannot inflate
later packets' measured read delay. Peer filtering precedes observation. The
existing app-read gap and RTT fields retain their meanings.

An app-read gap over 50 ms produces at most one notice per socket every five
seconds, including while telemetry export is off:

```text
Receive gap stream=video kind=late read read_ms=224 kernel_gap_ms=5 queued_ms=219 queued_count=32 reader=Glimmer.videoRecv tid=123 qos=33
```

`late read` means the current packet waited over 50 ms in the socket, or the
kernel gap was at most 50 ms while the read gap exceeded it. `late arrival`
means the kernel gap also exceeded 50 ms and this packet's queued delay did not.
Both can contribute: inspect both numbers when they are large. `unavailable`
means there is insufficient timestamp evidence; unknown values are -1.
`queued_ms` is the current packet's age at syscall return. `queued_count`
includes the unread remainder of the returned batch, including the current
packet, plus `SO_NUMRCVPKT` sampled for this notice. It is a queue snapshot, not
a reconstruction of the stall's total packets, and may include new or foreign
arrivals. `reader` identifies the receive thread; `tid` and `qos` are the actual
pthread ID and QoS class at observation.

Large read delay identifies time after kernel delivery, including receive-loop
work, queue scheduling and descheduling. Large kernel gaps with small read delay
place the delay before socket delivery. They cannot distinguish the PC/network
from Mac NIC/driver/IP-stack delays before timestamping. Compare both streams
with RTT and the existing gap counters on the next real-PC capture.

The hot path reuses ancillary storage and fixed-size histograms, reads the clock
once per syscall and takes one short histogram lock per accepted packet. Queue
counts, thread metadata and formatting occur only on a throttled notice. No
per-packet heap allocation is added by timing collection.

On 2026-10-12, an optimized Swift 6 loopback microbenchmark on macOS 27.0.1
(Xcode 27.0) compared the original receive code with timestamp parsing and
histogram observation: five paired runs, 200 warm-up iterations and 3,000
measured iterations, with 32 queued 1,392-byte packets per video call or one
packet per fallback call. Two runs gave median added costs of 14–21 ns per
batched packet and 103–138 ns per single read; histogram/classification alone
was 15 ns per packet over one million observations. These time receive syscalls
and userspace collection, excluding ingress timestamp creation, send work,
logging on a gap and scheduling before the call. They are overhead evidence, not
real-stream pacing or RTT results; repeat the stream capture on macOS 26.

## 2026.10.8 refocus investigation

The October 12 capture starting at 17:43:49Z becomes composited with stats at
17:44:10Z, hides at 17:44:40Z, resumes at 17:47:01Z, and stays composited
through 17:50:44Z. Renderer counters never reset. There was no notice because
the last observed path before hiding was already composited. That capture ran
the stats child-window implementation, which is already reverted in this
worktree.

Compared with `d15d212`, the decoder's suppression, decode gate and IDR
deduplication are unchanged. Both versions let visibility resume before the
return slide settles; both rely on a transaction completion to remove the
retained transform and restore window opacity. In .8, that completion also
restores presentation options. The resume safeguard now waits for the opaque
resting surface and has a generation-checked deadline if the completion is lost.
Reduced Motion receives the same settlement guarantee, and alpha-zero windows
count as suppressed. No display-layer rebuild, new IDR, display mode change or
steady-state sampler is added.

This fixes reproducible lifecycle gaps, but the old capture lacks the
post-resume window/layer snapshot needed to prove the compositor's cause. The
next live test must confirm optimized-frame deltas recover with stats hidden
after a long hide, rapid switching, occlusion, and Reduce Motion. Compare
HDR/EDR and GPU cost before and after refocus, with stats both shown and hidden.
Inspect the new `opaque`, `revealing`, and `collection` fields beside the
existing layer/cursor snapshot.

The same capture has 124,542 valid audio timestamps and zero missing through
17:50:44Z. The 342 samples and 95 ms p99 (101.596 ms maximum) are the first
one-second window, not session totals. Later window maxima are at most 2.026 ms.
The receiver measures every accepted-peer datagram before RTP/FEC filtering;
`recvmsg` stamps and `mach_absolute_time` share Mach ticks, converted through
`mach_timebase_info`. No measurement correction is indicated by this evidence.

## Fixed-mode variable-refresh hint: public API gap

No player hint is emitted without reliable evidence of variable-refresh support
while the display is in a fixed mode. Apple's
[Adaptive-Sync guidance](https://developer.apple.com/videos/play/wwdc2021/10147/)
uses the NSScreen minimum/maximum intervals to recognize the current
Adaptive-Sync mode. `displayUpdateGranularity` also describes the current mode.
These do not document a reliable capability query for a fixed-mode external
panel.

[CGDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaymode)
exposes a scalar refresh rate and I/O flags, not a supported refresh range. The
public IOGraphics mode flags in the installed SDK provide no variable-refresh
capability flag. Zero refresh rate is not evidence: Apple's
[refresh-rate documentation](https://developer.apple.com/documentation/coregraphics/kcgdisplayrefreshrate)
also allows zero for displays without conventional sweep timing. Inferring
support from that value, a high maximum rate, display names or undocumented flag
bits would produce guesses. The installed SDK is 27; the documented APIs are
available on 26, but fixed-versus-Variable readings on the owner's panel and
Xcode 26.6 remain unverified. No Settings row, one-time tip, preference, or
display change is shipped.

## Pacing policy and candidate checks

Variable refresh: `FramePacer+FrameRateRange.swift` reads the screen's minimum
and maximum refresh intervals and current update granularity. The maximum rate
is the reciprocal of the minimum interval, preserving fractional modes; the
integer maximum is used only when that interval is unavailable. Without either,
the link keeps the system default. A variable mode gets a floor of
`clamp(0.75 × panel max, supported minimum, panel max)`, the panel maximum and a
preferred rate from measured content, without whole-Hz rounding. For a low
enough supported minimum, floors are 180/108/90/45 Hz on 240/144/120/60 Hz
panels. A 48–60 Hz panel gets a 48 Hz floor. The preferred rate changes only
after a move greater than 10% persists for at least two seconds. A materially
different destination restarts that dwell. Decode gaps, bursts, PTS resets and
hide/show restart observation; missing frames do not count as sustained slower
content. A visible link rebuild preserves the held target within the new panel's
limits. Changes between fixed and variable modes at the same maximum also
re-evaluate the range; unchanged capability notifications do not rebind.

Only `CADisplayLink.preferredFrameRateRange` is written; Glimmer never selects a
display mode or changes the user's refresh setting. Suppression immediately
clears the hint to [the system default][display-link-range], including on a
hidden link rebuild. There is no low-rate request left over another app.
Restoring the hint requires fresh delivery and the two-second dwell, even when
the target equals the pre-hide target or the window moves during restoration.
The link remains available for presentation and liveness callbacks. A sustained
callback rate below 90% of content/preferred rate requests the full callback
grid for five seconds before retrying, through the same dwell. This fallback
pins the floor at the panel maximum. Fixed modes keep the full grid to avoid
divisor throttling.

[display-link-range]:
  https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange

The deterministic matrix in `FramePacerDisplayTests` and
`FramePacerContentRateTests` covers these capabilities. Names describe example
displays; decisions use reported intervals and granularity, never a model name.

| Reported capability                               | Expected hint and pacing                                                  | Live check                                                 |
| ------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Fixed 60/75/144/165/240/360 Hz                    | Full callback grid; variable path off; evenly spaced repeats              | Moving edges stay even below panel rate                    |
| Built-in ProMotion, about 24–120 Hz               | 90 Hz floor; content hint through 120 Hz                                  | AC and battery, quiet scene and fast motion                |
| External Adaptive-Sync, 48–240 Hz                 | 180 Hz floor; content hint through 240 Hz                                 | Brightness stable in stream and after tabbing away         |
| HDMI 2.1 VRR TV, about 40–120 Hz                  | 90 Hz floor; content hint through 120 Hz                                  | No brightness pulse, flash or blanking                     |
| Variable 48–144 and 48–60 Hz                      | 108 and 48 Hz floors, bounded by reported maximum                         | No request exceeds the panel maximum                       |
| Fractional 59.94/119.88/23.976 Hz                 | Fractional bounds/content retained at API precision; no drift retargets   | Long playback has no accumulating beat or drift            |
| Moves between different rates, variable and fixed | New capability applied, held target clamped; unchanged notices are no-ops | No flash, blanking or display mode change                  |
| Hide, occlude, background, then return            | Default range while suppressed; restore after fresh two-second dwell      | Other apps regain system-controlled refresh; prompt return |

For each available display, capture equal before/after active, suppressed and
restored spans. Correlate `present_suppressed`, the “rate hint released” and
“rate hint” breadcrumbs with `refresh_*_hz`, `pacer_ticks_per_s`,
`pacer_releases_per_s`, cadence error, late drops and output-to-present tails.
Check `gpu_power_w` and `package_power_w` for no material steady-state increase.
Include a hidden display move and a move during the restoration dwell. Callback
rates are not physical scanout measurements; watch the other app and, where
available, the display's refresh indicator. The matrix is automated policy and
cadence coverage, not evidence that these displays have been physically tested.

The owner's 2026.10.8-rc.4 Adaptive session (`2026-10-12T19:32:07Z`) reported
brightness flicker on a G-Sync-compatible 240 Hz panel: 1,229 rate-hint rows,
710 between 199 and 203 Hz, with a minimum preferred rate of 58.75 Hz and a 48
Hz floor. The hysteresis and capability-derived floor target those repeated
refresh excursions. The owner subsequently localized the flicker to tabbing
away; releasing the suppressed request addresses that reported trigger. The
regression trace has zero retargets per minute at a steady 199–203 Hz, and one
retarget after a sustained 240→190 Hz change has dwelled for two seconds. These
are deterministic test results, not new panel measurements.

Presentation follows a bounded mean of the last 64 PTS intervals rather than
assuming every configured capture slot contains a frame. Each gap contributes at
most twice the existing lower-quartile estimate; the latter still protects loss
recovery. A two-frame decode burst preserves fractional cadence within the
existing trim slack. A larger backlog retains immediate catch-up. On variable
scanouts, the tick owns presentation; submit cannot predict a future scanout
from a fixed grid. No additional buffering target is introduced.

Before-change evidence, filtering the supplied 2026-10-12 sessions to seconds
with `pacer_ticks_per_s > 230` and `fps_decoded > 150`:

| Session              | Seconds | Received fps | Rendered fps | Ticks/s | Stale repeats/s | O2P p50 / p95 / p99 (ms) |
| -------------------- | ------: | -----------: | -----------: | ------: | --------------: | -----------------------: |
| 2026.10.7, 12:55:09Z |     205 |       194.94 |       194.94 |  240.00 |           45.07 |    0.138 / 4.222 / 5.716 |
| rc.2, 12:29:07Z      |     327 |       184.97 |       184.87 |  239.99 |           55.11 |    1.193 / 5.170 / 7.833 |
| rc.3, 13:55:14Z      |      62 |       198.31 |       194.20 |  239.99 |           45.79 |   2.370 / 6.509 / 10.498 |

O2P columns are means of exported percentile fields, not pooled frame
percentiles. The rc.3 log confirms floor/preferred/maximum all at 240 Hz. These
callback counts do not measure physical panel scanout or prove repeat bunching
by themselves.

After-change live validation is still required on the same AV1 Main10 HDR 4K,
361 Mbps scene, first with the owner's Adaptive setting, then a user-selected
fixed setting. Compare equal active spans (use decoded/rendered activity, not
the old `ticks > 230` filter). Expect `refresh_avg_hz` and `pacer_ticks_per_s`
to stay near the held content target under Adaptive, bounded by the 180 Hz floor
on the 240 Hz panel, with fewer `present_stale_repeats_per_s`; `fps_rendered`
and `pacer_releases_per_s` must continue tracking decoded content. The log's
`FramePacer rate hint` records the applied changes and fallback. Expect zero
retargets per minute after settling in a steady scene, and one per sustained
change greater than 10%, after at least two seconds. Stalls and hide/resume must
not lower the target; floor/preferred must never fall below 180 Hz on this
panel. Compare `gpu_power_w` and `package_power_w` over equal active spans.
macOS may quantize or ignore hints; callback fields do not prove physical
scanout, so confirm brightness stability and motion by eye as well. No
after-change live capture has been made yet.

On a fixed screen, repeats remain necessary. The repeat gate accounts for
floating-point subtraction error at exact half-refresh boundaries, without
changing its half-refresh slack or fixed-grid policy. The matrix checks an 80%
content rate on every fixed panel for evenly spaced one/two-refresh holds.
Inspect per-frame present spacing and moving edges for evenly distributed
one/two-refresh holds. Check `present_cadence_err_ms`, `pacing_depth`,
`pacing_target_depth` and `lat_output_to_present_*_ms`: no standing extra frame,
no added wait beyond one content frame. Compare deltas of
`drops_presentation_late` and `drops_backpressure`, and verify no repeated
assist/deficit transitions, flashes or blanking. Exercise variable/fixed screen
moves, hide/resume, a quiet scene, fast motion and a delivery drought. A lower
repeat count alone is not acceptance.
