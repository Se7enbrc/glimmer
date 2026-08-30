# Glimmer

A Mac-native client for [Sunshine](https://github.com/LizardByte/Sunshine). Pure
Swift, Apple Silicon only, built so a gaming PC in the other room feels like it
is plugged into your Mac.

![The Glimmer launcher: a paired PC ready to stream at 120 Hz HDR](docs/assets/launcher.png)

Glimmer speaks the Moonlight protocol end to end in-process. There is no
external player, no helper daemon, and no C runtime under the hood: the network
socket, the decoder, the display, the audio engine, and the controllers are all
wired together in one Swift process.

## What you get

- **Video.** H.264, HEVC, and AV1, 8-bit and 10-bit, decoded in hardware through
  VideoToolbox. HDR streams get a real PQ/HLG pipeline with EDR metadata rather
  than a tone-mapped approximation. Up to 4K at 240 Hz when the host can encode
  it.
- **Pacing.** A frame pacer that locks the display to the stream's cadence,
  passes frames straight through on a clean link, and buffers only for jitter it
  has actually measured. It was tuned against per-frame telemetry, not by feel,
  and it recovers on its own when the network gets ugly.
- **Audio.** Opus through AVAudioEngine with a small adaptive cushion, so
  swapping to AirPods mid-session or a rough patch of Wi-Fi does not turn into
  crackle.
- **Controllers.** Xbox, DualSense, and MFi pads with rumble. On a DualSense you
  also get adaptive triggers, the light bar, gyro and accelerometer, the
  touchpad, and battery reporting. A hold-to-quit chord gets you back to the Mac
  without a keyboard.
- **Keyboard and mouse.** Raw mouse input with the Mac's pointer acceleration
  taken out, so aim is 1:1, plus a velocity-gated boost on fast flicks that
  scales with the stream resolution, so a 4K desktop still crosses in one swipe.
  Optional forwarding of ⌘ shortcuts to the host.
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

### Your host

The gaming PC needs Sunshine and a display that can present the exact resolution
and refresh rate you ask for. On Windows that is a virtual display driver; on
Linux a current Sunshine resizes the session itself.
[docs/HOST_SETUP.md](docs/HOST_SETUP.md) walks through it.

### Wi-Fi helper

Turn it on in **Settings > Quality > Wi-Fi**. It runs as a privileged background
service, so macOS asks for a one-time approval under **System Settings >
General > Login Items & Extensions**. If it ever reports
`operation not permitted` or `rejected by BTM` after a lot of reinstalls, reset
the Background Task Management database once and re-enable:

```bash
sudo sfltool resetbtm
```

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
`Glimmer/Stream/` and is built by the app target directly, no submodules.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the map,
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) the rules.

## Why not just use Moonlight

Moonlight is excellent and Glimmer would not exist without it. On the Mac,
though, moonlight-qt is a Qt port of a cross-platform C++ app, and it lives one
layer away from the hardware. Glimmer talks to VideoToolbox, AVAudioEngine, and
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
