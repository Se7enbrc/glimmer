<p align="center">
  <img src="docs/assets/icon-512.png" width="140" alt="Glimmer">
</p>

# Glimmer

A Mac-native client for [Sunshine](https://github.com/LizardByte/Sunshine). Pure
Swift, Apple Silicon only, built so a gaming PC in the other room feels plugged
into your Mac.

![The Glimmer launcher](docs/assets/launcher.png)

The whole pipeline - socket, decoder, display, audio, input - runs in one Swift
process. No external player, no C engine.

## What you get

- **Video.** Hardware-decoded H.264, HEVC, and AV1, 8- and 10-bit, with a real
  PQ/HLG HDR pipeline. Up to 4K 240 Hz.
- **Pacing.** Locks the display to the stream cadence, runs passthrough on a
  clean link, buffers only for measured jitter. Tuned against per-frame
  telemetry.
- **Audio.** Opus through AVAudioEngine with a small adaptive cushion, so device
  switches and rough Wi-Fi don't crackle.
- **Controllers.** Xbox and DualSense: rumble, trigger rumble, gyro, touchpad,
  battery, light bar - whatever the pad has. Hold-to-quit chord. An optional
  raw-input mode (off by default, needs Input Monitoring) adds the DualSense
  buttons macOS hides and the host's adaptive-trigger effects.
- **Mouse and keyboard.** Raw 1:1 aim with the Mac's pointer acceleration
  removed, a velocity-gated boost on fast flicks, optional ⌘-shortcut
  forwarding.
- **Wi-Fi.** An optional helper parks AWDL (AirDrop's radio time-share) during a
  stream - the usual cause of multi-second Wi-Fi freezes.
- **Hosts.** mDNS discovery, PIN pairing, hosts by IP or name (Tailscale works),
  one-time import of moonlight-qt pairings.
- **Mac things.** Menu bar item, display-matched quality presets, stats overlay,
  hotkeys, notarized, self-updating.

Nothing leaves your Mac. Diagnostics are off by default and write local files
under `~/Library/Logs/Glimmer`.

## Install

macOS 26+, Apple Silicon.

```bash
brew tap se7enbrc/glimmer
brew trust --tap se7enbrc/glimmer   # Homebrew requires this for third-party taps
brew install --cask glimmer
```

Or the notarized `.dmg` from
[Releases](https://github.com/Se7enbrc/glimmer/releases). Either way it updates
itself.

Signed and notarized, not sandboxed, not on the App Store - the Wi-Fi helper
needs that freedom ([docs/SECURITY.md](docs/SECURITY.md)).

Your host needs Sunshine and a display that can present the exact mode you ask
for: a virtual display driver on Windows, a current Sunshine on Linux.
[docs/HOST_SETUP.md](docs/HOST_SETUP.md).

The Wi-Fi helper lives in Settings > Quality > Wi-Fi; macOS asks for one
approval under Login Items & Extensions. If it reports `rejected by BTM`, run
`sudo sfltool resetbtm` once.

## Build

Xcode 26 (Swift 6) and Homebrew.

```bash
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
brew install openssl@3 opus
make
```

`make` builds and installs to /Applications the same way a release ships.
`make app` compile-checks, `make test` runs the unit tests, `make uninstall`
removes it. The engine is under `Glimmer/Stream/`, no submodules.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## Why not Moonlight

Moonlight is excellent and Glimmer would not exist without it. But moonlight-qt
is a Qt port of cross-platform C++, one layer from the hardware. Glimmer talks
to VideoToolbox, AVAudioEngine, and GameController directly - that is where the
pacing, HDR, and controller work comes from - and it behaves like a Mac app
because it is one.

## Support

Free software, spare time. [Buy a coffee](https://ko-fi.com/ugfuglio) if it
makes your setup better.

## License

GPLv3. Copyright © 2026 ugfugl.io. See [LICENSE](LICENSE).

The transport is ported from
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and
[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt), both GPLv3, so
Glimmer is too. Full acknowledgment in [CREDITS.md](CREDITS.md).
