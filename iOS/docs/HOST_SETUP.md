# Set up the PC for iPhone and iPad

Install the [iPhone and iPad display modes](../../docs/vdd/iphone-ipad.xml) on
the PC using the [shared setup guide](../../docs/HOST_SETUP.md). Both devices
request only sizes and refresh rates from this file, including portrait and
windowed iPad play. The older mixed-client file omits the new window modes.

Choose Native, 1080p 60 or 1080p 120 in Settings → Quality. Native selects the
closest listed size to the window's pixels. Both 1080p choices request 1920 ×
1080; use them when a game needs 16:9. Listed refresh rates are capped to the
profile and display. Window modes generally use 60 fps. There is no
half-resolution or Custom choice.

The whole picture fits the window. A different aspect shows black bars, and a
lower resolution loses detail. Resizing during play keeps the initial stream
format, just like rotating iPhone; start a new stream to select for the new
window. Disconnecting quits the game on the PC unless Leave games running when
you disconnect is on.

The PC display and game must use the requested aspect. Otherwise Sunshine or the
game may put black bars inside the video. Installing modes makes them available;
it does not guarantee the PC switches successfully or the game supports them.
For fixed-aspect games, use a matching window shape to keep the whole picture.
Software with its own virtual display, such as Apollo, does not need the MTT
configuration, but must still accept the requested modes. See the
[window targets and budget](../../docs/VIRTUAL_DISPLAY_MODES.md#ipad-window-targets).

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
