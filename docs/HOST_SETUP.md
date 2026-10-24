---
description: Set up one PC display for your Mac, iPhone and iPad.
icon: desktop
---

# Give your PC a display to stream

Set up Sunshine and one virtual display for your Mac, iPhone and iPad. The
[default sample](vdd/all-glimmer-clients.xml) includes their display sizes, so
changing devices does not mean editing the PC's modes again.

## Windows: install Sunshine and the display

1. Install a current
   [Sunshine release](https://github.com/LizardByte/Sunshine/releases).
2. Open Sunshine's web interface on the PC at `https://localhost:47990`.
3. Create your Sunshine sign-in when prompted.
4. Download and extract
   [MTT Virtual Driver Control 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23).
5. Open Virtual Driver Control and install its **Virtual Display Driver**.

{% hint style="info" %}

This guide targets the driver bundled with **25.7.23**, the current release. Its
title says “Beta”. Use its supplied installation instructions; Windows on ARM
needs the manual installation path. Stock Sunshine works with this setup.
[Apollo](#or-use-apollo) is an optional alternative.

{% endhint %}

### Pick your file

Use **all-glimmer-clients.xml** if unsure. Each file is a complete replacement
for the same driver settings file, with automatic GPU selection.

| Device type                                           | File                                                   | Modes |
| ----------------------------------------------------- | ------------------------------------------------------ | ----- |
| Mixed Mac, iPhone and iPad                            | [all-glimmer-clients.xml](vdd/all-glimmer-clients.xml) | 90    |
| MacBook or iMac built-in display                      | [mac-builtin.xml](vdd/mac-builtin.xml)                 | 26    |
| Studio Display, Studio Display XDR or Pro Display XDR | [mac-apple-displays.xml](vdd/mac-apple-displays.xml)   | 10    |
| Standard external display                             | [standard-external.xml](vdd/standard-external.xml)     | 90    |
| iPhone or iPad, including iPhone Duo                  | [iphone-ipad.xml](vdd/iphone-ipad.xml)                 | 75    |

### Copy the ready-made modes

1. Stop any active streams.
2. Back up `C:\VirtualDisplayDriver\vdd_settings.xml`.
3. Open your chosen file above and copy the entire file.
4. Replace the contents of `C:\VirtualDisplayDriver\vdd_settings.xml` with the
   sample, saving as UTF-8. Keep the underscore in the PC's filename and make
   sure the editor has not added `.txt`.
5. Use **Reload Driver** in Virtual Driver Control's context menu.

{% hint style="info" %}

Keep `<friendlyname>default</friendlyname>`. The driver chooses the GPU
automatically, using the one with the most dedicated video memory unless an
existing `C:\VirtualDisplayDriver\adapter.txt` selects another. No GPU edit is
needed for a new installation. To choose a different GPU, replace `default` with
its exact name from Device Manager → Display adapters, then reload.

A previous installation can override the folder through `VDDPATH` under
`HKEY_LOCAL_MACHINE\SOFTWARE\MikeTheTech\VirtualDisplayDriver`. If you changed
that location, save the file there. Older releases use different settings;
update to 25.7.23 before using this file. If Windows still shows the old modes
after Reload Driver, restart the PC before continuing.

{% endhint %}

### Combine two files

To add a single device to an existing file, search for its name and copy the
blocks directly below its matching comments into your `<resolutions>` section.

1. Copy the `<resolution>` blocks from one file into the other's `<resolutions>`
   section, before `</resolutions>`.
2. Merge blocks with the same width and height, keeping each `<refresh_rate>`
   only once for that size.
3. Count every `<refresh_rate>` as one mode. Remove modes you do not need until
   the total is **90 or fewer**, then update the header count. Keep `<global />`
   empty; global rates multiply across every resolution.
4. Save the combined file as `vdd_settings.xml` and use **Reload Driver**.

### Let Sunshine switch the display

1. Restart Sunshine so its log lists the new display.
2. In Sunshine → Configuration → Audio/Video, set **Output Name**
   (`output_name`) to the virtual display's `device_id` from Troubleshooting →
   Logs. Copy the value including its braces; do not copy a physical monitor's
   ID.
3. Set **Device configuration** (`dd_configuration_option`) to
   `ensure_only_display`.
4. Set **Resolution** (`dd_resolution_option`) to `auto`.
5. Set **Refresh rate** (`dd_refresh_rate_option`) to `auto`, then save and
   restart Sunshine.

{% hint style="warning" %}

`ensure_only_display` turns off the PC's other displays during streaming. Use
`ensure_primary` instead if they must stay on. If Windows initially mirrors the
virtual display, choose **Extend these displays** in Windows Settings → System →
Display before streaming.

These are Sunshine's
[Windows display settings](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_configuration_option).
Glimmer already sends the request needed for automatic resolution selection.
Leave mode remapping empty to keep the requested size and frame rate. To restore
the PC displays when an iPhone or iPad disconnects without quitting the game,
set `dd_config_revert_on_disconnect` to `enabled`.

{% endhint %}

## Start a stream

1. Pair the PC in Glimmer: [Mac](GETTING_STARTED.md#3-pair-the-pc) or
   [iPhone and iPad](../iOS/README.md).
2. In Settings → Quality, choose a mode from the table below.
3. Start Desktop or a game from Glimmer's launcher.
4. Check Windows Settings → System → Display → Advanced display for the virtual
   display's resolution and refresh rate.

| Client         | Quality choice                    | What the PC receives                                                                            |
| -------------- | --------------------------------- | ----------------------------------------------------------------------------------------------- |
| Mac            | Sharpest                          | Native display pixels at the display's maximum frame rate.                                      |
| Mac            | Balanced                          | Half the width and height, rounded down to even pixels, at the same frame rate.                 |
| Mac            | Custom                            | Your saved size and frame rate. The menu offers 720p, 1080p, 1440p and 4K.                      |
| iPhone or iPad | Native · 120 fps                  | Landscape native pixels rounded down to even, capped to the display's maximum of 60 or 120 fps. |
| iPhone or iPad | 1080p · 60 fps or 1080p · 120 fps | 1920 × 1080, capped to the display's maximum.                                                   |

{% hint style="info" %}

MacBook Neo's Balanced choice keeps its native size because half would be too
small. On a 16-inch MacBook Pro, Balanced sends **1728 × 1116**, not 1728
× 1117. On Mac, Custom in a window caps the frame rate to the display; full
screen keeps your chosen rate.

The files cover the
[listed Apple displays and selected custom modes](VIRTUAL_DISPLAY_MODES.md).
Each stays within 90 modes because larger lists can stop the display from
starting. Arbitrary Custom values and other external displays may need
replacement modes or Apollo. The iPhone/iPad sample includes half sizes, but
Glimmer on iPhone and iPad has no half-resolution or Custom choice. A listed
mode does not promise that the PC can encode it fast enough.

{% endhint %}

### If the picture does not start

1. Check that Sunshine's `output_name` still identifies the virtual display.
2. Check the saved XML file and use **Reload Driver**.
3. Start a new stream. If it still fails, check Sunshine's Troubleshooting →
   Logs for the display or encoder error.

## Or use Apollo

[Apollo](https://github.com/ClassicOldSong/Apollo) is a Sunshine fork for
Windows. Its bundled SudoVDA display matches the client's requested size and
refresh rate at stream start, without a mode list. Glimmer is built and tested
against stock Sunshine; Apollo is a separate project that was last updated in
May 2026 and does not track Sunshine's current releases.

1. Stop Sunshine's service before installing
   [Apollo](https://github.com/ClassicOldSong/Apollo/releases).
2. Install Apollo with its SudoVDA driver.
3. In Apollo's application settings, enable **Always use Virtual Display** for
   the game or Desktop entry you want to stream.
4. Pair the PC in Glimmer and start that entry.

{% hint style="info" %}

The built-in **Virtual Display** entry is another way to try it immediately. To
use a virtual display for every application, enable **Headless Mode** under
Audio/Video instead. Keep Apollo's advanced display configuration disabled for
this path. If Windows mirrors the display on first use, press Windows-P on the
PC and choose **Extend**, then quit and reopen the streamed application. See
[Apollo's setup answers](https://github.com/ClassicOldSong/Apollo/wiki/FAQ).

For each additional paired device, grant **Launch Apps** and the input
permissions it needs in Apollo; only the first client gets full permissions
automatically. You do not need MTT VDD or the XML sample for Apollo.

{% endhint %}

## Linux: switch modes

1. Add the mode to your display system.
2. Add
   [Sunshine preparation commands](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2app__examples.html#changing-resolution-and-refresh-rate).
3. Add an Undo command to restore the previous mode.

{% hint style="info" %}

Sunshine's `dd_` controls are Windows-only. On Mac, stopping the stream also
quits the PC app, allowing app-exit Undo commands to run. On iPhone and iPad,
disconnecting leaves the game running; do not rely on an app-exit Undo command
for display restoration.

{% endhint %}

Next: [pair the PC on Mac](GETTING_STARTED.md#3-pair-the-pc) or
[connect from iPhone or iPad](../iOS/README.md).
