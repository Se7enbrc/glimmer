# External display validation

Validate external stream output without changing the stream's quality defaults.
This page records the adapter's contract and the hardware checks still required
before accepting playback. See [profiling](../../docs/PROFILING.md) for the
measurement procedure.

## Output ownership

The noninteractive external scene receives the existing stream surface. The
application window keeps controls and relative touch input. Connecting or
removing a display moves the same surface, decoder and session; it does not quit
the game, start a second stream or restart negotiation. Removing the display
returns video to the application window.

An interactive Stage Manager window remains an application scene. iPad streaming
follows its window orientation; only iPhone streaming requests landscape. Its
drawable size determines native stream dimensions at connection time. Resizing
fits the existing picture without cropping. To request new dimensions,
disconnect and start again after resizing or moving the window.

A dedicated external scene selects the display's preferred mode while streaming
and restores its previous mode and overscan compensation afterward. A subsequent
system mode change takes precedence over restoration. The renderer uses
aspect-fit, and UIKit's overscan scaling protects the edges on TVs.

## Capabilities and input

Native dimensions, refresh limits and EDR headroom come from the output
surface's screen. The stream's selected profile still limits its frame rate. The
display link follows that screen, including when the window moves between
displays. Resolution, rate and codec remain fixed for the running connection.

The current mobile profiles negotiate H.264 SDR. Reading an external display's
EDR headroom does not enable HDR or establish HDR playback support. Enabling a
10-bit profile needs codec negotiation and sustained hardware evidence in a
separate change. No bitrate, pacing, buffering or decode defaults change here.

Relative touch motion maps control-window points to negotiated stream pixels
using the aspect-fitted picture's scale. It does not use the external monitor's
point scale. Controller mouse motion continues through the shared input path.
Absolute touch, external keyboard capture and remapping are separate work.

## Simulator checks

Use an isolated iOS 26 iPad Simulator and injected playback. Never contact a PC
from display tests. Cover role filtering, portrait external modes, native window
sizes, 60/120 Hz caps, letterboxed input scaling, attach/detach and mode
restoration ownership. Verify one surface and one playback survive each handoff,
and that controls stay in the application window.

The iOS 26 iPad Simulator accepted a 1920 × 1080 TV-out geometry and power
changes, but delivered only an application scene. Dedicated external-scene
delivery still needs a connected device. Injected window tests cover routing,
restoration and focus; rendered corner patterns verify letterboxing and
pillarboxing without cropping. Simulator results cannot prove cable modes, HDR
output, actual display-link cadence, hardware decoding or power.

## Hardware acceptance still required

1. Connect an iPhone and a Stage Manager capable iPad to 1080p, 4K and portrait
   displays. Record selected mode, requested stream size, actual refresh and
   display scaling. Repeat through a dock and a TV with overscan.
2. Attach and detach during connection, playback, reconnect and disconnection.
   Verify input release, uninterrupted audio, restored mode, a complete picture
   and immediate return to the device screen. Repeat while holding input.
3. Move the application window between displays and resize it in Stage Manager.
   Check picture edges, relative pointer motion, controls, focus, background
   grace, lock, and foreground return. Do not treat an active external scene as
   permission to keep a background application streaming.
4. Compare SDR black, near-black and colour patterns. Check reported current and
   potential EDR against the output display; do not claim HDR playback from SDR
   frames or simulator screenshots.
5. Run matched sustained sessions and report latency percentiles, drops, decode
   format, thermal state, memory, wakeups, `gpu_power_w` and `package_power_w`
   where available. Unavailable power measurements stay unavailable, not zero.

Record results and artifacts alongside
[performance validation](../../docs/PERFORMANCE_VALIDATION.md).
