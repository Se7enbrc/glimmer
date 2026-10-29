# Validate iPhone and iPad video fidelity

Use these checks before accepting mobile HDR or codec performance for release.
Simulator results cover negotiation and colour plumbing, not hardware decode,
panel luminance, latency, battery life or thermal stability.

## Capability and presentation contract

Both apps use `VideoFormats.hardwareSupported`, which caches VideoToolbox's
H.264, HEVC and AV1 hardware queries once per process. HEVC and AV1 offer their
8-bit and 10-bit Main paths. iOS offers 4:2:0 only; the Mac's existing separate
4:4:4 policy is unchanged. A positive codec query is not a reservation of
decoder resources or proof of sustained performance at a particular size and
frame rate. The decompression session still requires hardware and never falls
back to software decoding.

The stream's actual presentation screen supplies potential EDR headroom. A
finite value above one allows 10-bit offers and the existing Sunshine HDR launch
parameters. An SDR screen removes 10-bit offers. Temporary reductions in current
headroom do not trigger reconnects or lower quality. Sunshine's DESCRIBE offer
and capability mask select AV1, then HEVC, then H.264; unsupported advanced
codecs remain absent. H.264 remains the SDR compatibility path. A decoder
resource failure still follows shared session recovery, without a software
fallback. Offers are fixed at launch: moving an HDR stream to an SDR display
uses system tone mapping; starting a new stream reevaluates the presentation
screen.

The shared decoder preserves pixel-buffer colour tags, then compressed-format
tags, then negotiated SDR defaults. Untagged 10-bit frames can use the PC's HDR
signal as PQ/BT.2020 fallback; an explicit SDR transfer wins. Declared PQ and
HLG both request high dynamic range on `AVSampleBufferDisplayLayer`. HLG is
supported when declared by the stream; no separate HLG mode is invented in
Sunshine's SDP. Output pixel format determines range. SDR removes HDR metadata
and colour changes invalidate the sample-format cache. The OS maps the tagged
source to the current display, including when EDR headroom temporarily drops to
one.

Resolution, frame rate, bitrate, pacing, buffering and VideoToolbox tuning are
unchanged. New codec offers and HDR presentation still require the acceptance
runs below before claiming parity with the Mac.

## Simulator checks

1. Run `make ios-test` at low priority with an explicit Simulator destination if
   the default name is ambiguous.
2. Check `StreamVideoTests` for hardware combinations, SDR display filtering,
   common PC/client codec selection, 10-bit SDP and 4:2:0 negotiation.
3. Check `VideoColorPatternTests`, compiled by both clients, for 10-bit ramp
   preservation, PQ/HLG/SDR attachments, compressed colour fallback, layer range
   transitions and separate input HDR versus actual EDR output.
4. Compile Mac tests with `nice -n 15 taskpolicy -c utility make test-build`. Do
   not run Mac unit tests on the development machine used for this change.

The ramp checks video-range codes 64, 65, 66, 128, 256, 512, 939 and 940 with
neutral chroma. They verify storage and tags without tone mapping or a pixel
copy; they do not verify decoded compressed pictures or the compositor's visible
output.

## Device and PC matrix

Use current, unmodified Sunshine on a separately authorized test PC. Record its
version, GPU and driver, Windows HDR state, display mode and advertised codec
mask. Never infer hardware capabilities from a model name alone.

| Device/display case                             | Required checks                                                       |
| ----------------------------------------------- | --------------------------------------------------------------------- |
| HDR iPhone with AV1 hardware                    | AV1 8/10-bit, HEVC 8/10-bit, H.264 fallback, PQ and HLG tags          |
| Older supported iPhone without AV1 hardware     | No AV1 offer; HEVC Main10 on an HDR panel; H.264 fallback             |
| HDR iPad                                        | Same tests, both landscape orientations and screen replacement        |
| SDR iPad or SDR external display                | No 10-bit offer at launch; correct SDR blacks and colour              |
| HDR external display where supported by the app | Capabilities from the presentation screen; attach/detach and EDR loss |

Select codec cases through the test PC's encoder capabilities, without adding
client tuning controls. Test a PC without HDR and one that lacks AV1 encoding. A
stock Sunshine capture path may not produce HLG; mark live HLG acceptance
unavailable in that case and retain the deterministic tag tests separately.

## Reference pictures and transitions

1. Display known SDR BT.709 and HDR10 PQ patterns on the PC: black and
   near-black steps, smooth greyscale ramps, saturated primaries and small text.
   Record the source range, bit depth and mastering luminance with the captures.
2. Compare the source, decoded sample tags and physical display. Inspect black
   level, shadow detail, banding, clipped highlights and hue. A screenshot alone
   cannot establish HDR luminance or physical scanout correctness.
3. Toggle SDR to HDR and back repeatedly during play, then disconnect and start
   an SDR session. Check for stale PQ, stale mastering metadata, washed-out
   frames, blank output and incorrect range after every transition.
4. Vary brightness and Low Power Mode, temporarily background and return, and
   replace the presentation display where supported. Distinguish HDR input from
   EDR output; current headroom of one must not be reported as visible HDR.
5. Repeat with HLG reference input if the capture path can preserve its declared
   tags. Record a missing live HLG source as a gap, not a passed test.

## Sustained power and thermal acceptance

Run each candidate mode for at least 30 uninterrupted minutes after warm-up.
Compare against H.264 SDR and HEVC SDR at identical dimensions, frame rate,
bitrate, scene and audio route. Alternate run order and repeat each pair. Hold
brightness, ambient temperature, case, charge state, Wi-Fi route, peripherals,
HUD and Apple profiling tools constant. Use an optimized build with exact app
and engine revision recorded. Test 60 fps first, then existing 120 fps/native
modes; do not change defaults from a Simulator result.

| Evidence                                                         | Review requirement                                                                                             |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Decoder configuration in system logs                             | Hardware decode readback, requested hints and failed/unsupported properties recorded                           |
| Decode/present latency, cadence, drops, backlog and pacing depth | Compare early and final five-minute windows; no progressive collapse, unbounded growth or new recurring stalls |
| Apple thermal evidence, Low Power Mode and display observations  | No sustained serious/critical thermal state; explain any brightness/headroom reduction                         |
| Apple energy reports or external whole-device measurements       | Compare watts and variance, never GPU residency as a substitute                                                |
| Battery/charging state and external energy measurement           | Record unavailable probes explicitly; battery percentage is not a wattmeter                                    |

The current iOS adapter does not provide Mac IOReport package/GPU watt probes.
Those fields remain unavailable. Use a calibrated external meter with controlled
charging state for whole-device watts, or supported device energy tooling, and
label its scope separately from package/GPU power. Do not fill absent telemetry
with zeroes or introduce private iOS probes. Both flavours use Apple logs and
reports; Glimmer records no diagnostic files or frame traces on iOS.

Risks to measure are 10-bit memory bandwidth, codec-specific decoder load,
compositor tone mapping and the HDR panel's brightness power. Native resolution
and 120 fps can amplify all of them. The existing decoder hint
`MaximizePowerEfficiency=false` remains; record its readback and measure its
cost with the other unchanged latency hints. The change adds no per-frame
capability probe, new timer, software conversion, pixel copy or custom renderer.
That is a static cost assessment, not evidence of equal watts. Reject acceptance
if colour is wrong, decode falls back to software, cadence degrades over the
run, or power increases materially without an agreed fidelity benefit; retain
measured baselines before any tuning change.

Continue with the shared [profiling guide](../../docs/PROFILING.md) to collect
and interpret session evidence.
