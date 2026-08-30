<p align="center">
  <img src="docs/assets/icon-512.png" width="140" alt="Glimmer">
</p>

# Glimmer

A Mac-native client for [Sunshine](https://github.com/LizardByte/Sunshine). Pure
Swift, Apple Silicon only, built so a gaming PC in the other room feels like it
is plugged into your Mac.

![The Glimmer launcher: a paired PC ready to stream at 120 Hz HDR](docs/assets/launcher.png)

Glimmer speaks the Moonlight protocol end to end in-process: the network socket,
the decoder, the display, the audio engine, and the controllers are wired
together in one Swift process, with no external player and no C engine under the
hood.

## What you get

- **Video.** H.264, HEVC, and AV1, 8-bit and 10-bit, hardware decoded through
  VideoToolbox, with a real PQ/HLG HDR pipeline and EDR metadata. Up to 4K at
  240 Hz when the host can encode it.
- **Pacing.** A frame pacer that locks the display to the stream's cadence,
  passes frames straight through on a clean link, and buffers only for jitter it
  has measured. Tuned against per-frame telemetry; recovers on its own when the
  network gets ugly.
- **Audio.** Opus through AVAudioEngine with a small adaptive cushion, so device
  switches and rough Wi-Fi do not turn into crackle.
- **Controllers.** Xbox, DualSense, and MFi pads, with everything each pad can
  do: rumble and trigger rumble, gyro and accelerometer, touchpad, battery
  reporting, and the DualSense light bar. A hold-to-quit chord gets you back to
  the Mac without a keyboard. An optional raw-input mode (off by default, needs
  Input Monitoring) adds the DualSense buttons macOS hides - Options, Create,
  Mute - and relays the host's adaptive-trigger effects to the pad.
- **Keyboard and mouse.** Raw mouse input with the Mac's pointer acceleration
  taken out, so aim is 1:1, plus a velocity-gated boost on fast flicks that
  scales with the stream resolution. Optional forwarding of ⌘ shortcuts to the
  host.
- **Wi-Fi.** AirDrop and Continuity share the Mac's radio (AWDL) and will grab
  the channel out from under a stream. An optional helper parks AWDL while you
  play and hands it back when you stop.
- **Hosts.** mDNS discovery, PIN pairing, hosts by IP or hostname (Tailscale
  MagicDNS names work), and a one-time import of your paired hosts from
  moonlight-qt so nothing needs re-pairing.
- **Mac things.** Menu bar item, quality presets that match your display, a
  stats overlay, configurable hotkeys, notarized, and self-updating.

Nothing leaves your Mac. Diagnostics are off by default; when you turn them on
they write files under `~/Library/Logs/Glimmer` for you to read or attach to an
issue.

## Install

Requires macOS 26 or newer on Apple Silicon.

```bash
brew tap se7enbrc/glimmer
brew trust --tap se7enbrc/glimmer   # Homebrew asks this of every third-party tap
brew install --cask glimmer
```

Or grab the notarized `.dmg` from
[Releases](https://github.com/Se7enbrc/glimmer/releases) and drag Glimmer to
Applications. Either way it updates itself from then on.

Glimmer is Developer-ID signed and notarized but not sandboxed and not on the
App Store; the Wi-Fi helper needs that freedom. See
[docs/SECURITY.md](docs/SECURITY.md) for what that means in practice.

Your **host** needs Sunshine and a display that can present the exact resolution
and refresh rate you ask for: a virtual display driver on Windows, a current
Sunshine on Linux. [docs/HOST_SETUP.md](docs/HOST_SETUP.md) walks through it.

The Wi-Fi helper lives in **Settings > Quality > Wi-Fi**; macOS asks for a
one-time approval under **System Settings > General > Login Items &
Extensions**. If it ever reports `rejected by BTM` after many reinstalls, run
`sudo sfltool resetbtm` once and re-enable it.

## Build from source

Xcode 26 (Swift 6, strict concurrency) and Homebrew.

```bash
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
brew install openssl@3 opus
make
```

`make` builds the Release app the same way a shipped one is built (signed and
notarized when a Developer ID is available, ad hoc otherwise) and installs it to
`/Applications`. `make app` is a quick compile-only check, `make test` runs the
unit tests, `make uninstall` removes the app. The streaming engine lives under
`Glimmer/Stream/`, built by the app target directly, no submodules.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the map,
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) the rules.

## Why not just use Moonlight

Moonlight is excellent and Glimmer would not exist without it. On the Mac,
though, moonlight-qt is a Qt port of a cross-platform C++ app, one layer away
from the hardware. Glimmer talks to VideoToolbox, AVAudioEngine, and
GameController directly, which is where the pacing, HDR, and controller work
above comes from, and it looks and behaves like a Mac app because it is one.

## Support

Glimmer is free software written in spare time. If it makes your setup better,
[buying a coffee](https://ko-fi.com/ugfuglio) helps keep the hardware current.

## License

GPLv3. Copyright © 2026 ugfugl.io. See [LICENSE](LICENSE).

The streaming transport is a port of
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c),
with the pairing handshake, HTTP control client, and frame pacer ported from
[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt). Both are
GPLv3, so Glimmer is too. [CREDITS.md](CREDITS.md) has the full acknowledgment,
including the MIT-licensed enet and nanors code that came along with the port.
