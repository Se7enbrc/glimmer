---
description: Set up Sunshine and a display that matches your Mac.
icon: desktop
---

# Set up the PC

Glimmer asks the PC for an **exact** `width × height @ refresh`, whatever you
pick in **Settings ▸ Quality**. The presets there are _Sharpest_ (your panel's
own pixel grid), _Balanced_ (half that in each direction), and _Custom_. For
matching capture and stream dimensions, the PC's physical or virtual display
must support the requested mode and be configured to use it. Glimmer sends the
request; it does not install a display driver or guarantee a mode change on the
PC.

## Windows: Virtual Display Driver

A headless gaming PC, or one whose real monitor cannot do your Mac's exact mode,
needs a virtual display that can. Use stock Sunshine with a compatible VDD;
Glimmer does not require a modified Sunshine.

1. **Sunshine.** Install a current release:
   <https://github.com/LizardByte/Sunshine>
2. **Virtual Display Driver.** Install from
   <https://github.com/VirtualDrivers/Virtual-Display-Driver> (follow its
   installation instructions for your driver release).
3. **Configure the modes.** Copy [`vddsettings.xml`](vddsettings.xml) to the
   settings location documented by your VDD release; filenames and schema vary.
   Check the sample against that release before replacing its settings. Then:
   - set `<gpu><friendlyname>` to your GPU exactly as Device Manager ▸ Display
     adapters shows it;
   - make sure every resolution and refresh rate you'll pick in Glimmer has a
     `<resolution>` entry. The sample already covers the common Mac panels plus
     720p, 1080p, 1440p and 4K at 60, 120 and 240 Hz. **Add a block for anything
     missing.**
4. **Configure Sunshine's display controls.** Select the display with
   `output_name`, enable a suitable `dd_configuration_option` (disabled by
   default), and use automatic resolution and refresh-rate selection. Glimmer
   sends `sops=1`, which enables Sunshine's requested-mode handling. These
   controls configure an installed display; they do not install a VDD. See
   [Sunshine's display configuration](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_configuration_option).
5. In Glimmer, pick a resolution and refresh rate that exist in the config
   above.

## Linux: configure mode switching

Sunshine's built-in `dd_` display configuration is Windows-only. On Linux,
configure preparation commands for your display system if you need the mode to
change automatically. Sunshine's
[resolution and refresh-rate examples](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2app__examples.html#changing-resolution-and-refresh-rate)
use `xrandr` on X11 and compositor-specific tools on Wayland. The requested mode
must be supported; use an Undo command to restore your previous mode when the PC
app ends. Disconnecting Glimmer leaves that app running, so do not assume an
app's Undo command runs on every disconnect.

## The one rule

Whatever Glimmer requests must exist on the PC. Glimmer accepts any
`640-7680 × 480-4320 @ 30-240`, so if you stream an unusual mode, add it to the
VDD config (Windows) or the display server's mode list (Linux) first.
