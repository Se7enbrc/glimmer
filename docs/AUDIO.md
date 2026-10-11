# Audio on macOS

Glimmer follows the Mac's selected audio output during a stream. Compatible
AirPods use spatial playback and head tracking automatically. Change outputs
through macOS; there is no separate spatial-audio switch in Glimmer.

## Bluetooth headphones and voice chat

Using a Bluetooth headset's microphone can change its playback quality and
volume. A game that sounds clear with the microphone idle can sound muffled when
Discord or another voice app starts using it. Apple describes this
[Bluetooth audio behavior](https://support.apple.com/en-us/102217).

When possible, select a separate microphone in your voice app: the Mac's
built-in microphone, a webcam microphone, or a USB microphone. Keep the AirPods
selected as the output. In our testing, switching Discord's input from AirPods
to a Logitech C920 microphone substantially improved playback quality.

The result depends on the headphones, macOS version and voice app. Game Mode
does not guarantee that simultaneous Bluetooth playback and microphone use will
sound the same as playback alone. Glimmer does not capture microphone audio or
change Discord's input selection.

## Volume after a microphone or output change

During testing, changing the microphone sometimes left playback quieter even
though the Mac's volume control still showed its previous level. A small
adjustment with the system volume control restored the expected loudness.

If this happens, make a small system-volume adjustment and return it to your
preferred listening level. This is an observed workaround; the cause of the
retained low volume has not been confirmed. It is separate from the Bluetooth
quality change above.

Glimmer does not normalize loudness or boost its gain to compensate for a quiet
device transition. A compensating boost could become too loud when the device
recovers. When reporting a volume problem, note whether other Mac apps are also
quieter, which input and output are selected, and whether adjusting system
volume restores the sound.

## Core Audio output

Glimmer controls the HAL output unit directly from Swift. The decode worker
copies pooled PCM into a preallocated single-producer/single-consumer ring; the
render callback reads only raw pointers and lock-free atomics. It never
allocates, acquires a lock, formats diagnostics or calls into decoder state. A
stopped graph owns its callback memory until its units have been disposed.
Device setup, property listeners, retries and diagnostics run off the render
thread. An unavailable output leaves receive/decode alive for recovery.

The processing chain is PCM ring → AUVarispeed → optional AUSpatialMixer →
AUMultiChannelMixer → HAL output. Varispeed retains the existing drift PI
controller and all cushion constants. Ring consumption replaces player
completions. Cold startup waits for the learned cushion; a mid-stream drain
keeps pulling while the existing 250 ms catch-up grace and bounded silence
backfill rebuild it. Trimming keeps its 15 ms hysteresis and 100 ms spacing. The
30 ms base, 10 ms growth steps and link-aware caps are unchanged. Teardown and
route replacement cannot teach a synthetic underrun or carry stale drain
evidence to a new device.

Spatial setup follows Apple's
[Generating spatial audio from a multichannel audio stream](https://developer.apple.com/documentation/audiotoolbox/generating-spatial-audio-from-a-multichannel-audio-stream):
AUSpatialMixer renders an ambience bed using the selected output type, with head
tracking enabled for headphones and personalized HRTF mode set to automatic.
That mode requests an available profile; it does not prove one was used. Stereo
sources bypass the spatial mixer. Native multichannel outputs also bypass it;
channel layouts, including LFE and Sunshine's 7.1 side/rear permutation, are
preserved through format conversion. No head-pose or profile data is collected.

## Verification on a Mac and PC

Hostless tests cover the ring, real audio-unit impulse rendering, channel
identity, LFE, drift math, retry generations, decode admission and teardown.
They cannot establish acoustic latency, physical speaker wiring, AirPods pose
response or personalization. Before accepting this migration, compare the
previous build and this build with the same PC, game scene, output and learned
cushion, using the idle/load/recovery procedure in [PROFILING.md](PROFILING.md).

- AirPods: turn your head during a fixed-position sound; check stable anchoring,
  automatic reconnection and personalization with the existing profile.
- Built-in speakers: check stereo and surround-source playback, loudness, mute
  and absence of cracks or added delay.
- HDMI/USB 5.1 and 7.1: use a channel-identification signal. Verify every
  speaker, center, side/rear pair and LFE separately, including 48 ↔ 44.1/96 kHz
  changes.
- Switch speakers → AirPods → USB/HDMI → speakers during a stream; unplug the
  selected device, then reconnect it. Playback must recover without reconnecting
  the stream, with no false cushion growth or channel swap.
- Sleep/wake repeatedly during playback, including while headphones disconnect.
  Repeat under CPU load and with telemetry disabled/enabled.

Compare `audio_render_underrun_total`, `audio_render_cushion_min_ms`,
`audio_buffer_fill_min_ms`, `audio_near_misses_window`, `audio_underrun_total`,
trims, re-primes, drift/skew and engine/stall-recovery counts. Keep
`audio_decode_schedule_p99_ms`, `audio_queue_wait_p99_ms` and video presentation
p99 alongside them. The HAL path verifies missing PCM inside the render
callback; the old path polled a player clock, so short-gap counts are more
sensitive now. `audio_output_latency_ms` reports device latency + safety offset

- buffer duration; it excludes acoustic/Bluetooth delay and processing-unit
  latency. `audio_device_recovery_ms` reports a device-change notification to
  the first consumed PCM in the replacement graph, observed within the 10 ms
  monitor cadence. Logs carry `audio HAL ready`,
  `audio engine config change handled` and `audio device recovery`. Use physical
  loopback/listening for end-to-end latency and A/V skew; neither unit tests nor
  these gauges prove audible equivalence.
