# iPhone and iPad window streaming

Install `docs/vdd/iphone-ipad.xml` on the PC. The iOS app bundles that exact
file and selects only its width, height and refresh combinations. iPhone and
iPad use one `StreamProfile.resolve` path, with the window playing the role of
the screen. No request invents a Windows display mode.

## Shared profile rules

Settings orders the choices Native, 1080p 60, 1080p 120 and uses the same copy
on both devices. Native targets the stream surface's bounds multiplied by its
screen's physical `nativeScale`, in the current width/height order, rounded down
to even pixels. Both 1080p choices target 1920 × 1080 regardless of window
shape. iPhone still waits for landscape before starting; iPad accepts any window
orientation.

`StreamDisplayModes` reads the bundled XML once. Its modes must have even widths
in 640–7680 and heights in 480–4320 and listed 60/120 Hz refresh rates. The
selector filters out rates above the profile/display maximum, then ranks:

1. Smallest worst-axis proportional size error: the maximum of the absolute
   logarithms of width/target-width and height/target-height. This treats
   doubling and halving equally and avoids an oversized decode request for a
   tiny aspect improvement.
2. Least area cropped by proportional aspect fill.
3. Highest listed FPS within the cap. XML order breaks any remaining tie.

Exact listed sizes therefore win. A 750 × 1000 target selects 750 × 972, with
2.8% horizontal cropping after scaling to fill, rather than a full panel.
Full-panel ProMotion modes retain 120 fps; most window modes have only 60 Hz. A
90 Hz display report selects a listed 60 Hz mode, never an invented 90 Hz mode.
Requests retain the same 20 Mbps, stereo, codec and HDR negotiation as every
other stream. This changes no decoder, bitrate, pacing or HDR defaults. The
catalog is local, not a PC discovery response.

## Filling and resizing

`StreamSurface` uses `AVSampleBufferDisplayLayer.resizeAspectFill` across the
whole window. A same-aspect lower mode loses detail through upscaling; a higher
mode downsamples. A different aspect crops equal amounts from opposite edges,
without stretching or adding Glimmer letterboxing. This can hide game HUD
elements. The requested-format label reports the selected mode, not the window
target.

Rotation keeps the stream running and the surface follows every layout change.
After a window resize settles for 750 ms, `StreamWindowResize` asks the session
to move to the window's listed mode through the resume-only
[size seam](BITRATE_ACTUATOR.md#format-seam-for-window-resizing): same app,
`/resume` only, the running frame rate and the stop policy preserved. It counts
the change only when the session reports a `resize` applied at that exact size;
a deferred or failed change keeps the current size and retries on the next
lifecycle edge. A continued game that resumes at an earlier size moves to the
window's mode the same way. Until then the picture fills the window, cropping
edges after an aspect change. Nothing quits or relaunches the game.

## PC behavior and sample budget

The mobile sample uses exactly 90 resolution × refresh combinations. It retains
all 36 native landscape combinations and both 1080p rates, replaces 36 unused
optional half-size combinations, and adds 52 window combinations. The
[mode reference](VIRTUAL_DISPLAY_MODES.md#ipad-window-targets) gives each
geometry and the trade-offs. Every iPad pixel geometry has portrait, half,
two-thirds, one-third and Dock-visible half-width Stage Manager targets. Shared
minimum/medium Stage Manager and Slide Over targets cover additional audited
windows.

Sunshine's standard `/serverinfo` does not advertise Windows display modes.
Selecting from the bundled sample guarantees membership in that file, not that
the PC installed it, enabled the virtual display or switched successfully. The
older combined sample lacks the new window modes; use the mobile sample for this
client. Do not merge both complete files and exceed the driver budget.

Source review used Sunshine
[v2026.1017.185028 `nvhttp.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/nvhttp.cpp),
[`display_device.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/display_device.cpp)
and
[`video.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/video.cpp):

- Launch/resume can request display configuration when no stream sessions are
  active. Automatic resolution uses the requested size; configured remapping can
  substitute another mode. An encoder request does not add a Windows mode.
- If switching fails, the PC may retain its old geometry or capture preparation
  can fail. A game may also keep a fixed aspect independently of the desktop.
- The software conversion path proportionally scales the captured desktop and
  pads unused output space black. Glimmer's aspect fill cannot guarantee removal
  of padding already encoded inside a frame. GPU paths need real-PC validation.

## Verification boundary

Simulator tests cover catalog membership, exact native sizes, odd dimensions,
invalid targets, caps, profile order, identical phone/pad selection, and resized
surface geometry with no playback stop/relaunch. Layout boards use a labeled
synthetic source pattern at the selected aspect, beneath real stream controls;
they do not exercise a decoder. Native UI tests separately cover system windows.

Physical devices and a PC must confirm mode installation/switching, encoder and
decoder acceptance, actual FPS, game HUD visibility, hardware input and
sustained power/latency. Test a failed mode switch and a fixed-aspect game. No
Simulator image establishes those results.

Next: [install the matching PC display modes](HOST_SETUP.md#pick-your-file).
