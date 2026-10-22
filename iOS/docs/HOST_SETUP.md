# Set up the PC for iPhone and iPad

Follow the [shared PC setup guide](../../docs/HOST_SETUP.md) to install
Sunshine, copy the [ready-made display modes](../../docs/vddsettings.xml), and
let Sunshine select the right size and refresh rate. The same file serves Mac,
iPhone and iPad. The guide also includes an optional Apollo path without an XML
file.

In Settings → Quality, **Native · 120 fps** requests this display's landscape
pixel size rounded down to even dimensions, capped to its maximum frame rate.
**1080p · 60 fps** and **1080p · 120 fps** request 1920 × 1080, also capped to
the display. There is no half-resolution or Custom choice.

## Audio and controllers

Glimmer requests stereo audio and plays through the iPhone's selected output. In
Sunshine, keep audio streaming enabled. On Windows, Sunshine can use its virtual
audio device to capture sound without playing it through the PC's speakers.
Verify the game is producing sound into the device Sunshine captures; an
application pinned to another Windows output can be silent in the stream. Use
Sunshine's supplied `tools\audio-info.exe` to identify devices before changing
`audio_sink` or `virtual_sink`. Follow its
[audio configuration reference](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#audio_sink).
Do not change sinks merely because the client is silent; capture can initialize
successfully while the client output graph still needs diagnosis.

Sunshine also needs a supported virtual gamepad backend for controller input and
rumble. A controller appearing in Glimmer proves local detection, not that the
PC game accepts its virtual controller. See [input controls](INPUT.md).

## Disconnect and other PC platforms

Disconnecting or locking the iPhone stops local streaming. Switching apps keeps
the connection for up to 15 seconds before disconnecting; iOS can expire that
grace earlier. Each of these actions leaves the PC game running. Do not rely on
an app-exit Undo command running when you disconnect. Sunshine's display restore
behavior depends on its session configuration; verify it for the installed
version.

For Linux display switching and restoration, follow the
[shared Linux instructions](../../docs/HOST_SETUP.md#linux-switch-modes).

Next: [pair the PC and start a stream](../README.md).
