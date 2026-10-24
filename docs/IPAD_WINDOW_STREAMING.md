# iPad window streaming

Request the iPad window's backing pixels at stream start. Preserve its width and
height order, round down to even dimensions and use the shared 640–7680 width
and 480–4320 height bounds. Native uses that bounded size; 1080p fits the same
aspect within 1920 × 1080 or 1080 × 1920, without upscaling except to meet the
shared minimum. If that aspect cannot fit both the quality ceiling and decoder
minimum, clamp to the nearest legal dimensions rather than blocking startup. For
example, a 640 × 2752 window request becomes 640 × 1920 at 1080p; aspect fill
crops the sides. Native retains 640 × 2752. Keep the profile's FPS cap, H.264,
stereo and 20 Mbps defaults.

`StreamProfile.resolve(surface:)` uses the surface bounds and trait display
scale, not the panel's landscape bounds. iPad never requests a landscape lock.
iPhone retains its existing landscape rules. `StreamSurface` continues to use
`resizeAspectFill`; Glimmer adds no letterboxing. Rounding can cause slight edge
cropping; the minimum-size fallback can crop more. Decoder capability beyond the
shared configuration bounds still requires physical-device verification.

## Shared actuator integration

**Production resize renegotiation is not connected in this branch.**
`feat/bitrate-actuator` at `e9a5e3fc` is not an ancestor of `polish/ipad`. Its
public `StreamSession.request(rate:reason:)` API accepts bitrate only, not
width/height or a replacement format. Do not implement a second transport path
in the iOS client or call stop/start to emulate resizing.

The iOS seam is `StreamPlayback.requestFormatChange`. Wire it to the shared
actuator when format transitions are available:

1. Accept `StreamFormat` dimensions/FPS; reserve the existing shared recovery
   owner. Merge into the active configuration, preserving its current bitrate,
   codec and audio. Do not reuse the startup defaults from
   `format.configuration`. Defer while another recovery/actuator operation owns
   the session.
2. Preserve the active app, bitrate policy and session stop settings. Recheck
   the same running app and use `/resume` only. Never `/launch`, `/cancel`, quit
   the game, or fall back to a fresh launch when a resize fails.
3. Reconfigure the existing decoder, display pacing and negotiated dimensions
   through the shared transition. Retain the last frame and release held input.
   Close admission during inactivity, terminal teardown and renderer
   replacement.
4. Return `.applied` only after the first replacement-format renderer
   submission, not after admission. Return `.deferred` for temporary ownership
   conflicts and `.rejected` for terminal or unsupported requests; keep the
   existing stream on a declined request. Define failure recovery in the shared
   owner.
5. Feed completion and renewed availability to the native adapter. Never let a
   stale completion restore input or UI state after stop.

`StreamWindowResize` waits 750 ms after the last distinct size, retains the
latest target during an in-flight change, and cancels pending work on inactivity
or stop. It does not own a connection or a quit operation. The model updates its
requested-format label only on `.applied`. A deferred target waits for fresh
lifecycle evidence rather than polling. The eventual adapter must also forward
shared-owner availability after an unrelated bitrate operation completes.

Until integration, a resized window displays the initial encoder format using
aspect fill, so it can crop the previous image. Start a new stream to request
the new window size. Do not describe live resizing as shipped based on seam
tests.

## PC display modes

Sunshine's standard `/serverinfo` response does not advertise the PC's supported
display modes. The client cannot truthfully choose the nearest listed Windows
mode from that response. The closest supported **encoder request** is the
window's exact even size, scaled only when the profile/shared limits require it.
A guessed panel-mode table would turn valid window requests into incorrect
aspects and still would not describe the user's monitor or virtual display.

Source review used Sunshine
[v2026.1017.185028 `nvhttp.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/nvhttp.cpp),
[`display_device.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/display_device.cpp)
and
[`video.cpp`](https://github.com/LizardByte/Sunshine/blob/v2026.1017.185028/src/video.cpp):

- Launch/resume can request display configuration when no stream sessions are
  active. Automatic resolution uses the requested dimensions; configured mode
  remapping can substitute another display mode. Display configuration runs
  through a scheduled operation, not a returned list of supported resolutions.
- A virtual display exposes listed modes. Requesting an arbitrary encoder size
  does not add a Windows display mode. An unsuccessful switch can leave the old
  display geometry, or capture/encoder preparation can fail.
- The software conversion path scales the captured desktop proportionally and
  pads unused output space black. Thus a portrait encoder frame can contain a
  landscape desktop and large black bands. GPU/platform capture behavior and the
  game's own aspect handling need real-PC confirmation.

The
[Sunshine display settings](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)
can remap common requests to supported PC modes. Prefer the same aspect first,
then the nearest usable pixel dimensions and refresh rate. A same-aspect lower
mode costs detail; a different-aspect mode can add padding. Glimmer cannot
select among actual PC modes without a protocol capability or a supplied mode
inventory. No new client setting or private Sunshine extension is introduced
here.

### Sample budget recommendation

`docs/vdd/iphone-ipad.xml` contains 74 modes; `all-glimmer-clients.xml` already
uses all 90. Recommend adding portrait iPad modes to the mobile sample before
calling it a whole-window setup. Transposing the nine distinct iPad panel sizes
at their existing refresh rates uses 13 entries, leaving three. Three useful 60
Hz window candidates from the Simulator audit are 750 × 972 (small Stage
Manager), 1366 × 2064 (a Pro 13 tile), and 750 × 1706 (Slide Over).

That would total 90. The mini 5's Windowed Apps tile requests 1014 × 1536; the
earlier Stage Manager tile requested 1014 × 1290. Each needs another entry, so
covering both needs a replacement choice or a separate iPad sample. The set
would not cover arbitrary resizing, every 1080p profile request, or 120 Hz
versions of those windows. Window decorations and OS versions can change content
dimensions. Keep these as candidates until a PC validates switching, matching
aspect and game behavior. The combined sample needs an explicit replacement
choice or a separate iPad-focused sample; do not silently discard existing
modes. This change leaves both XML samples intact.

## Verification boundary

Simulator tests cover portrait and narrow startup, even/bounded requests,
quality caps, debounce coalescing, serialized transitions, inactivity, stop and
no playback stop/relaunch during a resize request. Layout fixtures use the real
stream controller and surface with a labeled synthetic pattern; they do not
exercise a decoder. Native UI tests exercise system window geometry separately.

Physical iPads and a PC must confirm decoder acceptance, actual negotiated size,
virtual-display switching, game aspect support, replacement-frame continuity,
input release, audio continuity and sustained power/latency. Test a failed mode
switch and an app mismatch, and prove neither invokes a quit/launch fallback.

Next: [maintain the virtual display samples](VIRTUAL_DISPLAY_MODES.md).
