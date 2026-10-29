# Play your PC games on Mac, iPhone and iPad with Glimmer

Glimmer is a native Swift Sunshine client for Mac, iPhone and iPad. Pair with
your PC, choose a game and play with a controller, keyboard and mouse, or touch.
Free, now and always. No account or analytics.

The Mac app is generally available; iPhone and iPad are in TestFlight beta.

Use an Apple Silicon Mac with macOS 15.7 or later, an iPhone with iOS 26 or
later, or an iPad with iPadOS 26 or later.

[Website](https://se7enbrc.github.io/glimmer/) · [Help](docs/README.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/launcher-art-dark.png">
  <img alt="Glimmer's launcher, ready to stream Desktop or Steam from a PC." src="docs/assets/launcher-art-light.png">
</picture>

## Install

On Mac:

1. Run in Terminal, or
   [download the DMG](https://github.com/Se7enbrc/glimmer/releases/latest):

   ```bash
   brew tap se7enbrc/glimmer
   brew trust --tap se7enbrc/glimmer
   brew install --cask glimmer
   ```

2. [Pair your PC](docs/GETTING_STARTED.md).

Mac installs update in the app through Sparkle. On iPhone or iPad, install
through the [TestFlight beta](docs/INSTALL.md#iphone-and-ipad). App Store
availability is still ahead.

## Choose how you play

| Feature                                       | Guide                                                                                               |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Picture, HDR and display choices              | [Display](docs/guides/STREAMING.md)                                                                 |
| Speakers and headphones                       | [Audio](docs/AUDIO.md)                                                                              |
| Controller layouts, touch, keyboard and mouse | [Controllers](docs/guides/CONTROLLERS.md) · [Keyboard and mouse](docs/guides/KEYBOARD_MOUSE.md)     |
| PCs, connection and launcher                  | [PCs](docs/guides/PCS.md) · [Wi-Fi](docs/guides/WIFI.md) · [Launcher](docs/guides/LAUNCHER.md)      |
| Mac automation                                | [Automation](docs/AUTOMATION.md) · [Raycast extension](https://github.com/Se7enbrc/raycast-glimmer) |

Use a controller on any device, or touch controls on iPhone and iPad. On Mac,
use Mini Player, the menu bar, Wake on LAN and the optional Wi-Fi helper.

> Save before stopping: ending a stream quits its PC app by default. To continue
> on another device, turn on “Leave games running when you disconnect” in
> Settings › General before streaming.

## Apple clients

This repository contains the Mac app, the [iPhone/iPad app](iOS/README.md), and
the shared streaming engine. See
[repository ownership](docs/APPLE_REPOSITORY.md) for development and checks. The
Homebrew tap and Raycast extension stay in their own repositories.

## Help and project

[FAQ](docs/FAQ.md) · [Troubleshooting](docs/guides/TROUBLESHOOTING.md) ·
[Report a problem](.github/SUPPORT.md)

[Security](docs/SECURITY.md) · [Privacy](docs/PRIVACY.md) ·
[Updates](docs/UPDATES.md)

[Contribute](docs/CONTRIBUTING.md) · [Roadmap](docs/ROADMAP.md) ·
[Sponsor](https://github.com/sponsors/Se7enbrc)

[GPLv3](LICENSE). Copyright © 2026 ugfugl.io. [Credits](CREDITS.md).

Next: [start your first stream](docs/GETTING_STARTED.md).
