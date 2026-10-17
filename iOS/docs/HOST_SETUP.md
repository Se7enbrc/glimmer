# Set up the PC for iPhone

Glimmer requests an exact resolution and refresh rate, just like the Mac app.
**Native · 120 fps** is the default: it uses the iPhone display's landscape
pixel size and caps the requested frame rate to the display's supported maximum.
For iPhone 17 Pro, the native request is **2622 × 1206 at 120 Hz**. Settings
also offers **1920 × 1080 at 120 or 60 Hz**. Your choice is saved for the next
stream.

The PC's physical or virtual display must offer the requested mode. Glimmer
requests that mode; it does not install drivers or guarantee Sunshine changes
the PC's display. The video fills the iPhone edge to edge. A 16:9 stream may be
cropped on the wider iPhone screen; Native matches its aspect ratio.

## Windows and MTT Virtual Display Driver

1. Install a current [Sunshine release](https://github.com/LizardByte/Sunshine).
2. If the physical monitor cannot offer the iPhone's mode, install
   [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
   following the instructions for that release.
3. Back up the driver's existing settings XML. Find its actual settings path;
   filename and schema depend on the installed release. This test PC uses
   `C:\VirtualDisplayDriver\vdd_settings.xml`, not `C:\VDD\settings.xml`.
4. Add the missing modes inside the existing `<resolutions>` element. Preserve
   the other modes, GPU selection and driver settings. For the installed MTT
   schema, the native entry is:

   ```xml
   <resolution>
     <width>2622</width>
     <height>1206</height>
     <refresh_rate>60</refresh_rate>
     <refresh_rate>120</refresh_rate>
   </resolution>
   ```

   Also keep a `1920` × `1080` entry with `60` and `120` refresh rates. Compare
   this with the driver's
   [configuration guide](https://github.com/VirtualDrivers/Virtual-Display-Driver/wiki/How-to-configure-the-driver)
   before editing a different release. Reload or restart the virtual display
   driver as that release directs, while no stream is active.

5. In Sunshine, select the intended display (`output_name`) and enable display
   configuration. Use automatic resolution and refresh selection. The tested PC
   uses `dd_configuration_option = ensure_only_display`; that disables other
   displays during streaming, so choose a different supported policy if you need
   them. See
   [Sunshine's display settings](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_configuration_option).
6. Pair in Glimmer's Settings → PCs, choose **Native · 120 fps** in Settings →
   Quality, and start a stream from the launcher. Confirm Windows Advanced
   display or Sunshine's log reports **2622 × 1206** and **120 Hz**. A 120 fps
   request alone does not prove sustained delivery.

The tested PC already has the native 60/120 modes and 1080p120 configured.
Sunshine has reported capture at 2622 × 1206 and a 120 fps request.

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

Sunshine's built-in `dd_` controls are Windows-only. On Linux, configure the
physical or virtual display and preparation commands for its desktop system. See
Sunshine's
[resolution examples](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2app__examples.html#changing-resolution-and-refresh-rate).
