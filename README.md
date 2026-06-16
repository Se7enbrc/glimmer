# Glimmer

Mac-native game-streaming client. Speaks the GameStream/Sunshine protocol
end-to-end in a from-scratch native Swift engine - no linked C library. (The
transport was ported from `moonlight-common-c`; see [CREDITS.md](CREDITS.md).)

## What it does

- Pure native engine. No external player, no shelling out to other apps.
- Decodes H.264, HEVC, HEVC Main10, AV1, and AV1 Main10 through VideoToolbox
  into an `AVSampleBufferDisplayLayer`.
- 10-bit HDR pipeline: BT.2020 NCL YUV→RGB, ITU-R BT.2100 PQ/HLG color space,
  EDR metadata from the host's HDR-mode control message.
- PIN pairing, mDNS discovery (`_nvstream._tcp`, `_nvstream-tcp._tcp`),
  self-signed client identity stored as mode-0600 files inside the app's sandbox
  container (see [docs/SECURITY.md](docs/SECURITY.md) for why not the keychain).
- Configurable in-stream quit hotkey, quality presets (Smooth / Match my display
  / Maximum / Custom), menu-bar item.

## Requirements

- macOS 26 or newer
- Xcode 26 toolchain (Swift 6, strict concurrency)
- Homebrew with `openssl@3` and `opus`

## Install

### Download

Grab the latest notarized `.dmg` from the
[Releases](https://github.com/Se7enbrc/glimmer/releases) page and drag Glimmer
to Applications. From then on it updates itself (Sparkle).

### Homebrew

A Homebrew cask (`brew install --cask glimmer`) is planned - not yet available.

### From source

```bash
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
brew install openssl@3 opus
make release && make install
open /Applications/Glimmer.app
```

## Build

```bash
make            # Debug build of Glimmer.app
make release    # Release configuration
make install    # copy to /Applications, adhoc re-sign
make clean      # wipe build/
make uninstall  # remove Glimmer.app
```

The streaming engine is pure Swift under `Glimmer/Stream/`, built directly by
the app target - there is no separate native library or submodule. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the layout.

## Why this exists

[Moonlight](https://github.com/moonlight-stream/moonlight-qt) on macOS is a Qt6
port of a multi-platform C++ codebase. It works, but it lives downstream of
every Qt quirk and presents a UI that doesn't match the rest of the OS. Glimmer
is a from-scratch native Swift client - its streaming transport was ported from
`moonlight-common-c` (GPLv3; see [CREDITS.md](CREDITS.md)) and it owns its own
video / audio / input pipeline through VideoToolbox + AVAudioEngine, running
entirely in-process - no helper daemon, no external player, no linked C library.

On first launch Glimmer migrates paired hosts and the RSA client identity from a
prior moonlight-qt install (if one exists) so the user keeps their hosts without
re-pairing.

## License

GPLv3. Copyright © 2026 ugfugl.io. See [LICENSE](LICENSE).

Glimmer's Swift streaming transport is **ported from
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)**
(GPLv3). Because that port is a derivative work, Glimmer is distributed under
the GNU General Public License v3. A clean-room reimplementation from the
published GameStream/Sunshine wire protocol is planned, after which Glimmer will
become independently licensed. See [CREDITS.md](CREDITS.md) for the full
acknowledgment.
