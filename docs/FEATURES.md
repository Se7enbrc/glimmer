# Features

Everything Glimmer does, in more detail than the [README](../README.md).

- **Video.** Hardware-decoded H.264 and HEVC, with AV1 on supported Macs, 8- and
  10-bit, and a real HDR10 pipeline. Up to 4K 240 Hz.
- **Pacing.** Locks the display to the stream cadence, runs passthrough on a
  clean link, buffers only for measured jitter. Tuned against per-frame
  telemetry.
- **Audio.** Stereo, 5.1 and 7.1, decoded by macOS and played through Core Audio
  with a small adaptive cushion and recovery after device switches and network
  interruptions. Spatial playback follows your audio output, with head tracking
  on compatible AirPods and no in-app setting to manage.
- **Controllers.** Xbox, DualSense and every other pad macOS supports, plus
  other USB and Bluetooth HID gamepads through SDL's controller database (those
  need Input Monitoring). Rumble, trigger rumble, gyro, touchpad, battery and
  light bar, whatever the pad has. Hold-to-stop chord. An optional raw-input
  mode (off by default, needs Input Monitoring) adds the DualSense buttons macOS
  hides and the game's adaptive-trigger effects.
- **Mouse and keyboard.** Raw 1:1 aim at your Mac's tracking speed with the
  acceleration curve removed, an optional velocity-gated boost on fast flicks,
  optional ⌘-shortcut forwarding.
- **Wi-Fi.** A helper parks AWDL (AirDrop's radio time-share), which can
  interrupt Wi-Fi streams. Glimmer offers it the first time it opens.
- **PCs.** mDNS discovery, PIN pairing, PCs by address or name (Tailscale
  works), Wake on LAN and a one-time import of moonlight-qt pairings.
- **Mac things.** Menu bar item, mini player, display-matched quality presets,
  stats overlay, hotkeys, notarized, self-updating. Shortcuts, Siri and
  Spotlight actions stream from a PC, wake it, or quit the app it's running.

Free, now and always. No accounts, no analytics. Glimmer talks to your own PC
and, if you leave updates on, to the update feed; nothing else. Diagnostics are
off by default, write local files under `~/Library/Logs/Glimmer`, and show your
PC's address and names as short codes.
