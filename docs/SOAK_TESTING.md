# Long-session and input soak

Verify that a stream stays smooth and releases input after interruptions. Run
the shared deterministic checks first, then use the hardware matrix below to
accept 2026.10.8 against an unmodified Sunshine PC.

## Deterministic checks

`EnginePackageTests` contains 32-minute virtual timelines. No transport opens a
socket, no display link starts, and no audio device opens. Integer event indices
advance time without sleeping. The same sources belong to the Mac and iOS test
targets, so existing CI runs them without a new job or dependency.

| Test                                                                       | Production code exercised                                                                                    | Assertions                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SessionSoakTests.thirtyTwoMinuteCadenceRecovers`                          | Frame submission, PTS ordering/cadence estimation, trim, due gate, hidden-frame retention and queue clearing | 60/60, 120/120, 240/240 and 190/240 content/display rates; each clean 20-second window releases within two frames of expected; window counts differ by at most two; oldest clean release is at most three content periods old; queue and cadence history remain bounded |
| `AudioSoakTests.thirtyTwoMinutePCMHasNoCleanWindowUnderrunDrift`           | 48 kHz mono PCM ring, actual render callback body, enable gate and underrun accounting                       | No additional underruns in each clean window; final fill differs by at most one 10 ms packet across cycles; exact written-frame accounting; no overflows or render errors                                                                                               |
| `AudioSoakTests.thirtyTwoMinuteClockSkewDoesNotDrainTheCushion`            | Actual resampler PI loop, update rate limit and route-key invalidation                                       | +40/−80 ppm clock skew reverses after 16 minutes; fill stays between 0 and 60 ms, finishes within 3 ms of target, and final five-minute mean correction is within 20 ppm of the new clock                                                                               |
| `InputSoakTests.thirtyTwoMinuteReleaseLedgerSurvivesRepeatedInterruptions` | Release ledger, ordered release barrier, controller gating and retirement                                    | 1,920 interruption cycles; rejected releases survive retries; accepted but lost key/button releases replay after connection loss; no held or pending inputs after recovery                                                                                              |
| `InputSoakTests.sessionInputLifecycleReleasesAcrossSixteenRecoveryCycles`  | `StreamInput` focus, activation, registration, replacement and terminal stop                                 | Sixteen cycles of focus loss, background deactivation, detach and reconnect; stale registration/attempt callbacks cannot revive input                                                                                                                                   |

The fake media transport controls loss, arrival jitter and reordering
independently and has an exact replay test. Each two-minute media cycle injects
mixed loss/jitter at seconds 20–24, a one-second outage at 30, reordering at
40–44, focus suppression at 50–51, an audio route pause at 60, backgrounding at
70–72, a two-second display-tick outage at 80, and a reconnect gap at 90.
Seconds 100–119 are the recovery window. Clean-window assertions run after every
cycle, including the last, rather than accepting a healthy session average.

Run only on Simulator on machines reserved for compile-only Mac verification:

```sh
nice -n 15 taskpolicy -c utility make test-build
nice -n 15 taskpolicy -c utility make ios-test \
  TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  TEST_FLAGS='-only-testing:GlimmerTests/SessionSoakTests -only-testing:GlimmerTests/AudioSoakTests -only-testing:GlimmerTests/InputSoakTests'
```

Choose an installed Simulator runtime explicitly. The full `make ios-test` runs
these checks too. Mac execution belongs to hosted verification or a machine
where it is permitted; compiling is not evidence that Mac tests passed.

### Scope of the simulation

The media fake delivers decoded-frame timestamps and PCM availability. It does
not exercise RTP/FEC, Opus, VideoToolbox, AVSampleBufferDisplayLayer, ENet
retransmission, OS scheduling or actual device graph replacement. The queued
pacing path uses explicit tick and trim times; display-link rate hints,
adaptive-depth timing and the asynchronous direct-submit path remain covered by
their focused tests and hardware acceptance. The resampler accepts an optional
test timestamp; normal calls still read monotonic time under the existing lock.
No playback defaults change.

The audio route/background cases pause the ring's producer and render admission;
they do not claim route latency, surround or audible equivalence. The separate
resampler soak advances the production PI loop at 4 Hz with controlled clock
skew; it does not open a varispeed unit or model an acoustic output. Input
lifecycle calls are synchronous; capture stamps use current uptime only to
satisfy the native event-generation fence. Tests call reconciliation directly
rather than waiting for its timer. Keyboard ownership is injected at the shared
ledger because native keyboard capture belongs to the Mac adapter. The fake PC
retains key/button state across replacement and retires the old connection's
controller state.

## Hardware matrix for the maintainer

These are manual acceptance runs, not actions performed by the test harness. Use
an already approved Release artifact. This procedure does not authorize building
a candidate, signing, installing or connecting on the maintainer's behalf.

| Client and route    | Display cases                                                                                         | Input and audio                                                                                      |
| ------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Mac, wired Ethernet | 60, 120, and highest supported refresh; repeat high refresh with PC output capped near 80% of refresh | Keyboard, high-rate mouse, physical controller; speakers → AirPods → speakers; USB/HDMI if available |
| Mac, Wi-Fi          | Same cases with identical scene and stream settings                                                   | Same peripherals; record AWDL helper state and nearby Continuity activity                            |
| iPhone, Wi-Fi       | 60; 120 only on supported hardware as a separate trial                                                | Physical controller/Backbone, supported keyboard/mouse, touch; speakers → AirPods → speakers         |

Run each supported case for 40 minutes, twice, once on the baseline and once on
the candidate; alternate build order on the repeat. Keep resolution, codec,
bitrate, picture mode, PC frame cap, brightness, power source, room temperature,
Game Mode, HUD and diagnostics settings fixed. Keep the PC wired for both Wi-Fi
cases. Record unsupported combinations as unavailable, not passed. Repeat iPhone
on battery for thermal acceptance after the controlled powered comparison.

### Prepare evidence

1. Record app and engine revisions, OS versions, Sunshine version, device/panel,
   refresh mode, selected stream settings, audio route and controller
   connection.
2. Enable the existing diagnostic collection and verify that new per-second rows
   arrive before timing the trial. Follow [profiling](PROFILING.md); keep
   telemetry loopback-only. On iOS export the available shared session evidence
   through the approved app/container workflow and record unavailable platform
   probes.
3. Select a repeatable moving game scene with continuous audio and a visible
   response to held movement, mouse buttons and controller triggers.
4. Start a written timeline using session-relative times and bookmarks where the
   client supports them. Record each interruption's start, link restoration,
   first moving picture, first sound and confirmed neutral input.
5. Warm up for five minutes. Keep minutes 5–10 and 35–40 undisturbed for
   comparison.

### Run the interruption sequence

| Minute | Action                                                                                                                                                      | Observe                                                                                                  |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 10     | Hold movement and a mouse/controller button, then switch focus for 5 seconds and return                                                                     | PC movement stops; old held controls require release before rearming                                     |
| 13     | Switch speakers to AirPods and back; disconnect/reconnect the selected output once                                                                          | Sound returns without restarting the stream; no persistent cushion inflation or crackle                  |
| 16     | Apply 1% packet loss, up to 20 ms added jitter and 2% reordering for 60 seconds using an isolated test router/link conditioner that supports those controls | Record actual impairment settings and counters; remove the profile afterward                             |
| 20     | Hold inputs, interrupt the client network route for 3 seconds, release while offline, then restore                                                          | No held key/button after control resumes; record reconnect and recovery time                             |
| 24     | Hold controller buttons/triggers, detach the controller, release physically, then reconnect                                                                 | Neutral PC state; no stale slot or callback can restore the old press                                    |
| 27     | Mac: hide the stream for 10 seconds. iPhone: background for 5 seconds, then separately for over 15 seconds                                                  | Short return resumes cleanly; expired background grace tears down locally and leaves the PC game running |
| 31     | Disconnect and reconnect the stream three times, with held input before each disconnect                                                                     | No stuck input, retained old picture, silent audio or growing memory staircase                           |

Use only supported system network controls. If a conditioner cannot reorder,
record that trial as untested; do not substitute loss and label it reordering.
For the Mac Mini Player, background controller forwarding is intentional:
evaluate keyboard/mouse focus release separately from controller ownership.
Repeat physical input acceptance with the normal full-screen stream.

## Pass and fail gates

These are proposed acceptance thresholds for matched trials, not claims about
measured hardware or permission to change defaults. A repeatable threshold
failure blocks acceptance and needs attribution. Preserve the failing run before
retesting.

| Signal                       | Pass threshold                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Progressive cadence collapse | In each clean five-minute window, `fps_rendered` mean is at least 95% of `min(fps_decoded, display Hz)` and final-window mean is at least 98% of the first comparable window. No ten-second interval falls below 90% with sufficient decoded supply. Under-rate PC output uses its measured content rate, not nominal panel refresh.                                                   |
| Queue growth and latency     | Clean `pacing_target_depth` returns to 1 within 30 seconds of restoration; `pacing_depth > target + 1` never persists for over 2 seconds. Final mean depth rises by no more than 0.25 frame. Windowed `lat_output_to_present` p99 rises by no more than one display period and stays below three periods; investigate excess with decode/renderer counters.                            |
| Audio stability              | Zero new `audio_render_underrun_total`, `audio_worker_overflow_total`, `audio_pcm_pool_exhausted_total` or `audio_overrun_total` during both clean windows. No recurring audible clicks/gaps. Absolute change in median `av_clock_skew_ms` between comparable windows is at most 5 ms; median `audio_buffer_fill_ms` rises by at most 10 ms and stays within the reported cushion cap. |
| Recovery                     | Within 5 seconds of focus return or link/control restoration, picture and sound flow; audio route replacement has consumed PCM within 3 seconds. Within 30 seconds, rates/queues meet clean gates again. No permanent fallback, repeated unexplained IDRs, or spontaneous disconnect on a clean link.                                                                                  |
| Input correctness            | Zero stuck keys, mouse buttons, controller buttons or triggers after focus loss, background, detach or reconnect. On a healthy link, visible release within 250 ms; after link restoration, within 1 second of control becoming usable. No old press replays. Any single confirmed violation fails.                                                                                    |
| Input timing                 | `input_timing_dropped_total == 0`; per-source windowed `capture_send` p99 ≤20 ms and no more than 2 ms above the paired baseline; report counts and >50 ms events. This is enqueue/send evidence, not input-to-photon latency.                                                                                                                                                         |
| Memory and watts             | Final clean median `phys_footprint_bytes` is within max(10%, 32 MiB) of the first; reconnect cycles show no monotonic retained-memory staircase. Matched median `gpu_power_w` rises by at most max(5%, 0.2 W), and `package_power_w` by at most max(5%, 0.5 W). No sustained serious/critical thermal state.                                                                           |

Use `fps_rendered`, not tick releases alone: direct-submit releases and renderer
rejection can make `pacer_releases_per_s` differ from actual enqueues. Retain
`refresh_*_hz`, `present_cadence_err_ms`, `drops_backpressure`,
`drops_presentation_late`, `decode_backlog`, `present_suppressed` and
`decode_gated` to distinguish deliberate pauses from collapse. Inspect receive
gaps/loss and `audio_reconfiguration_drop_total` around the planned
disturbances. Audio drift, A/V skew and route latency describe different
boundaries.

Calculate windowed quantiles from histogram bucket/count differences, never by
subtracting cumulative percentiles. Split at reconnect/attempt boundaries and
counter resets. Exclude planned interruptions plus the declared recovery
interval from clean-window gates, but retain and score their recovery
separately. Missing fields, trace overflow or insufficient samples are
unverified evidence, never zero. GPU residency is not power. If watts are
unavailable on iPhone, record energy/thermal evidence with the approved
Instruments workflow and leave the watt gate unverified.

### Finish and report

1. Stop the stream and export each session's NDJSON, scorecard and relevant
   frame segments before another session can prune them.
2. Restore network conditioning and diagnostics preferences to their prior
   state.
3. Record each matrix cell as pass, fail or unverified, with duration,
   clean-window results, interruption recovery times and evidence paths.
4. For a failure, include exact revisions, timestamp/attempt, input/state
   sequence, expected versus observed behavior and the smallest reproducer. Do
   not include raw key content, credentials, certificates or private PC
   addresses.

Use [profiling and telemetry](PROFILING.md) to attribute failures before
proposing changes to pacing, bitrate, buffering, decode defaults or input
ownership.
