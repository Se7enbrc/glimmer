---
description: Set up Sunshine and a display that matches your Mac.
icon: desktop
---

# Give your PC a display to stream

1. Install [Sunshine](https://github.com/LizardByte/Sunshine).
2. Try streaming with your current display.

| Settings › Quality | Requested size                        |
| ------------------ | ------------------------------------- |
| Sharpest           | Mac panel's native pixels.            |
| Balanced           | Half the width and height.            |
| Custom             | Your saved resolution and frame rate. |

{% hint style="info" %}

The PC display must support the mode. Glimmer requests it; Sunshine selects it.
Glimmer does not install display drivers.

{% endhint %}

## Windows: virtual display

1. Install
   [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).
2. Adapt [vddsettings.xml](vddsettings.xml) to your driver's schema.
3. Set `<gpu><friendlyname>` to the GPU name in Device Manager.
4. Add your resolution and refresh rate.
5. Save to the driver's documented settings location.

### Switch modes automatically

1. Select the display in Sunshine's `output_name`.
2. Enable a suitable
   [`dd_configuration_option`](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_configuration_option).
3. Select automatic resolution and refresh rate in Sunshine.
4. Start a new stream with a matching Glimmer mode.

## Linux: switch modes

1. Add the mode to your display system.
2. Add
   [Sunshine preparation commands](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2app__examples.html#changing-resolution-and-refresh-rate).
3. Add an Undo command to restore the previous mode.

{% hint style="info" %}

Sunshine's `dd_` controls are Windows-only and disabled by default. Stopping
quits the PC app, allowing Undo commands to run.

{% endhint %}

Next: [pair the PC](GETTING_STARTED.md#3-pair-the-pc).
