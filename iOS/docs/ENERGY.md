# Measure sustained iPhone and iPad energy use

Compare two optimized builds over the same 30-minute game scene before changing
quality defaults. This is a physical-device procedure for an authorized tester;
Simulator results establish behavior, not battery life or watts.

Repeat on the oldest supported test device and a representative higher-refresh
device. Record results separately for each device and OS build.

## Prepare a matched pair

1. Record each build's app and engine revisions, version, flavour, device model,
   OS build, battery health, ambient temperature and case. Use the same device
   and unmodified Sunshine PC for both builds.
2. Set brightness to 50% and turn off automatic brightness, True Tone and Night
   Shift. Keep the same room lighting and display orientation. Record Low Power
   Mode, Game Mode and accessibility display settings; keep them fixed.
3. Choose the same repeatable game benchmark or replay. Fix H.264 SDR, stereo,
   1920 × 1080 at 60 fps, and record the negotiated bitrate. Test the current
   native/120 profile separately at its exact dimensions. These are test cases,
   not new defaults. Reject a pair with different negotiated settings.
4. Fix Wi-Fi access point, band, channel, distance, PC Ethernet connection,
   output volume, audio route and controller. Record whether the controller
   draws device power. Keep external displays and unrelated accessories absent
   for the baseline; test them as separate pairs.
5. Start each trial unplugged at the same battery level, preferably 70–80%, and
   nominal thermal state. Let the device cool between trials. Warm up the scene
   for five minutes before the scored interval. Do not charge, attach a
   debugger, record the screen or retrieve files during the interval.

## Record 30 uninterrupted minutes

1. For an evidence trial, enable **Record diagnostics** before connecting using
   [the existing recorder](DIAGNOSTICS.md). Keep verbose logging off. Record the
   interval's start wall time and monotonic `t_ms` from the shared telemetry.
2. Run the fixed scene for 30 minutes. Keep controls/HUD visibility and input
   activity identical. Note visible stutter, audible gaps, unexpected reconnects
   and any system thermal warning, with elapsed times.
3. Retain the per-second `thermal_state` (0 nominal, 1 fair, 2 serious, 3
   critical), `low_power_mode`, actual frame/decode/pacer rates, stage latency,
   discard causes, audio underruns, loss and bitrate. Compare minutes 0–5, 10–15
   and 25–30 for progressive degradation as well as the whole interval.
4. Record battery percentage and charging state at the start and end. **This
   revision does not export iOS battery percentage or a native resource/power
   probe.** Preserve these readings in the trial notes and mark telemetry
   battery/CPU/wakeups/watts unavailable. `on_battery=false` alone is not proof
   of charging here. Do not infer watts from percentage or GPU residency.
5. Disconnect, then retrieve only the diagnostic directory as described in
   [Record an iPhone test](DIAGNOSTICS.md). Preserve raw files, session
   identity, build identity, start/end readings and deviations together before
   another session can prune evidence.

Full battery telemetry acceptance needs the native diagnostic adapter to supply
battery readings through the shared recorder. Keep that follow-up with
diagnostic ownership; do not create a second telemetry writer. Verify the actual
field names and availability in the tested build before recording the run as
complete.

## Separate diagnostics from normal cost

Repeat the scored interval with diagnostics off using the same executable.
Alternate off/on/on/off, then repeat the baseline/candidate pairs at least three
times with equivalent starting conditions. Production and beta must be
identified separately when diagnostics are compiled out. Never enable beta
recording by modifying production settings or treating a missing measurement as
zero.

For a watts claim, use an independently measured device-energy source with known
sampling units and boundaries. Report joules, average watts (`joules / 1800`),
method, variance and any charging or tethering effect. An externally powered
meter trial is a separate condition from the unplugged battery trial. If the
instrument cannot isolate device power, report its measured scope. Battery
percentage is a coarse corroborating trend, not a power measurement.

## Check idle, background and teardown separately

1. Hold the empty launcher for five minutes, then a populated launcher for five
   minutes with artwork already cached. Check for recurring redraws, discovery
   churn and diagnostic writes without opening a connection to a PC.
2. During an authorized stream, switch away and return after five seconds.
   Verify immediate input release, decode gating after the existing two-second
   delay, and clean recovery without stuck input. Repeat with the full 15-second
   grace, screen lock and denied/expired background execution. Preserve the PC
   game.
3. Complete ten start/stop or reconnect cycles after warmup. After final
   teardown, check that media workers, display links, watchdogs, audio
   maintenance and diagnostic timers stop. Explain retained framework cache
   plateaus rather than diagnosing a leak from footprint alone.

Report each build's battery change, thermal-state durations and transitions,
energy, CPU seconds per streamed minute, wakeups, footprint and media quality
with measurement method and unavailable fields. Reject a claimed saving if
cadence, latency, audio, picture fidelity or recovery regresses.
Serious/critical thermal state attributable to the workload blocks default-mode
acceptance. No numerical energy budget or battery advantage is established by
this audit.

Use the [energy audit](../../docs/IOS_ENERGY_AUDIT.md) for current findings and
[profiling guide](../../docs/PROFILING.md) for shared field meanings.
