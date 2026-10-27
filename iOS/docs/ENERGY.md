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

1. Note the interval's start time. Use Apple energy and profiling tools for a
   separate instrumented trial, and record their overhead and tethering effects.
   Glimmer records no diagnostics of its own in either flavour.
2. Run the fixed scene for 30 minutes. Keep controls/HUD visibility and input
   activity identical. Note visible stutter, audible gaps, unexpected reconnects
   and system thermal warnings, with elapsed times.
3. Compare the first and last five minutes for progressive degradation. Use
   available Apple reports and instruments for CPU, memory, energy and disk
   writes. Do not invent missing per-frame or per-second measurements.
4. Record battery percentage and charging state at the start and end in trial
   notes. Do not infer watts from battery percentage or GPU residency.
5. Preserve the Apple reports, build identity, start/end readings and
   deviations. Console and sysdiagnose provide logs; no Glimmer directory needs
   retrieving.

## Separate measurement overhead from normal cost

Repeat the scored interval without attached instruments. Alternate baseline and
candidate at least three times with equivalent starting conditions. Keep the
stats HUD and adaptive-quality setting matched; beta and production have
separate defaults for adaptive quality, but neither includes custom recording.

For a watts claim, use an independently measured device-energy source with known
sampling units and boundaries. Report joules, average watts (`joules / 1800`),
method, variance and any charging or tethering effect. An externally powered
meter trial is a separate condition from the unplugged battery trial. If the
instrument cannot isolate device power, report its measured scope. Battery
percentage is a coarse corroborating trend, not a power measurement.

## Check idle, background and teardown separately

1. Hold the empty launcher for five minutes, then a populated launcher for five
   minutes with artwork already cached. Check for recurring redraws, discovery
   churn and unexpected disk writes without opening a connection to a PC.
2. During an authorized stream, switch away and return after five seconds.
   Verify immediate input release, decode gating after the existing two-second
   delay, and clean recovery without stuck input. Repeat with the full 15-second
   grace, screen lock and denied/expired background execution. Preserve the PC
   game.
3. Complete ten start/stop or reconnect cycles after warmup. After final
   teardown, check that media workers, display links, watchdogs, audio
   maintenance timers stop. Explain retained framework cache plateaus rather
   than diagnosing a leak from footprint alone.

Report each build's battery change, thermal-state durations and transitions,
energy, CPU seconds per streamed minute, wakeups, footprint and media quality
with measurement method and unavailable fields. Reject a claimed saving if
cadence, latency, audio, picture fidelity or recovery regresses.
Serious/critical thermal state attributable to the workload blocks default-mode
acceptance. No numerical energy budget or battery advantage is established by
this audit.

Use the [energy audit](../../docs/IOS_ENERGY_AUDIT.md) for current findings and
[Apple diagnostics guide](DIAGNOSTICS.md) for logs and reports.
