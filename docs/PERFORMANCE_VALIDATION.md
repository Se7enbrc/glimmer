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
