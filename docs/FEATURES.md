# Features

Everything Glimmer does, in more detail than the [README](../README.md).

- **Video.** Hardware-decoded H.264 and HEVC, with AV1 on supported Macs, 8- and
  10-bit, and an HDR10 pipeline. Custom modes reach 7680 × 4320 and 240 fps;
  actual playback depends on the PC, Mac and display.
- **Pacing.** Paces frames against the display clock, asks for the panel's
  maximum refresh rate, and adapts buffering to measured jitter. Tuned against
  per-frame telemetry.
- **Audio.** Stereo, 5.1 and 7.1, decoded by macOS and played through Core Audio
  with a small adaptive cushion and recovery after device switches and network
  interruptions. Spatial playback follows your audio output, with head tracking
  on compatible AirPods and no in-app setting to manage.
- **Controllers.** Xbox, DualSense and every other pad macOS supports, plus
  other USB and Bluetooth HID gamepads through SDL's controller database (those
  need Input Monitoring). Rumble, trigger rumble, gyro, touchpad, battery and
  light bar, whatever the pad has. Hold-to-stop chord. An optional raw-input
  mode (off by default, needs Input Monitoring) adds the DualSense buttons macOS
  hides and the game's adaptive-trigger effects. Support also depends on
  Sunshine's controller emulation. Hold and release Start to use the controller
  as a mouse, including the DualSense or DualShock 4 touchpad. Input settings
  can match Nintendo face buttons by label instead of position.
- **Mouse and keyboard.** Raw 1:1 aim at your Mac's tracking speed with the
  acceleration curve removed, an optional velocity-gated boost on fast flicks,
  optional ⌘-shortcut forwarding. A free pointer follows the picture, including
  fullscreen Desktop streams; the capture shortcut switches to game controls.
  macOS input methods compose text while the pointer is free.
- **Wi-Fi.** A helper parks AWDL (AirDrop's radio time-share), which can
  interrupt Wi-Fi streams. Glimmer offers it the first time it opens.
- **PCs.** mDNS discovery, PIN pairing, PCs by address or name (Tailscale
  works), Wake on LAN and a one-time import of moonlight-qt pairings.
- **Launcher.** Buttons or Covers per PC, with artwork from the PC. Controllers
  exposed by macOS GameController can choose apps and switch PCs. Stopping a
  stream leaves the PC app running; choosing it again resumes it, while Quit
  asks before closing it.
- **Mac things.** Menu bar item, mini player, display-matched quality presets,
  stats overlay, hotkeys, notarized, self-updating. Shortcuts, Siri and
  Spotlight actions stream from a PC or wake it. Shortcuts also offers Stop
  Streaming and Quit App on PC. The command line supports versioned list/status
  JSON, and `glimmer://` links can stream, wake, stop or request a confirmed
  quit.

Free, now and always. No accounts, no analytics. Glimmer talks to your own PC
and the local network for discovery and Wake on LAN, plus its update feed and
downloads when checking for updates. Performance telemetry is off by default.
When enabled, it writes local files under `~/Library/Logs/Glimmer` and names the
PC and the Mac with per-install short codes.
