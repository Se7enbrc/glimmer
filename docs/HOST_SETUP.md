# Host setup: display modes (Sunshine + VDD)

Glimmer asks the host for an **exact** `width × height @ refresh` (whatever you
pick in **Settings ▸ Quality**, including _Match this Mac's display_). The host
can only honor a mode it can actually present, so the host's display has to be
able to produce every mode you might request. On Windows that means a **Virtual
Display Driver**; on Linux a current Sunshine that resizes the session. Without
this the stream either falls back to a wrong size or fails to start — there's no
way to guarantee a clean result otherwise.

## Windows — Virtual Display Driver

A headless gaming PC (or one whose real monitor can't do your Mac's exact mode)
needs a virtual display that _can_.

1. **Sunshine** — install a current release (it manages the VDD per session):
   <https://github.com/LizardByte/Sunshine>
2. **Virtual Display Driver** — install from
   <https://github.com/VirtualDrivers/Virtual-Display-Driver> (follow its
   README; it's a signed IDD driver + a companion app).
3. **Configure the modes.** Copy [`vddsettings.xml`](vddsettings.xml) to the
   path your VDD build reads (the companion app shows it — commonly
   `C:\IddSampleDriver\vdd_settings.xml` or `C:\VirtualDisplayDriver\`). Then:
   - set `<gpu><friendlyname>` to your GPU exactly as Device Manager ▸ Display
     adapters shows it;
   - make sure every resolution/refresh you'll pick in Glimmer has a
     `<resolution>` entry. The sample already covers the common Mac panels +
     720p/1080p/1440p/4K at 60/120/240; **add a block for anything missing.**
4. **Let Sunshine drive it.** On a current Sunshine, point it at the virtual
   display and it enables the VDD on stream start, sets it to the resolution the
   client asked for, and tears it down on disconnect. (If your build doesn't do
   this automatically, use the VDD project's enable/disable scripts as Sunshine
   **Prep Commands** — Do on connect, Undo on disconnect.)
5. In Glimmer, pick a resolution/refresh that exists in the config above.

## Linux — Sunshine dynamic resize

No VDD needed: a current Sunshine resizes the session to the requested mode on
connect and restores it on disconnect. Make sure the requested modes are
actually available to the display server:

- **X11**: the mode must exist in `xrandr`. Add any custom Mac mode with
  `xrandr --newmode` + `--addmode` (or a modeline in your X config) so Sunshine
  can switch to it.
- **Wayland**: resize support depends on the compositor; current Sunshine drives
  it where the compositor exposes mode-setting.

Prefer this over manually scripting `xrandr` per stream — let Sunshine own the
resize/restore so a crashed session doesn't strand your desktop at the streaming
resolution.

## The one rule

Whatever Glimmer requests must exist on the host. Glimmer accepts any
`640–7680 × 480–4320 @ 30–240`, so if you stream an unusual mode, add it to the
VDD config (Windows) or the display server's mode list (Linux) first.
