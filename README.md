# Play your PC games on your Mac with Glimmer

Free, now and always. Apple Silicon, macOS 26 or later, and
[Sunshine](https://github.com/LizardByte/Sunshine) on your PC. No account or
analytics.

[Website](https://se7enbrc.github.io/glimmer/) · [Help](docs/README.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/launcher-art-dark.png">
  <img alt="Glimmer's launcher, ready to stream Desktop or Steam from a PC." src="docs/assets/launcher-art-light.png">
</picture>

## Install

1. Run in Terminal, or
   [download the DMG](https://github.com/Se7enbrc/glimmer/releases/latest):

   ```bash
   brew tap se7enbrc/glimmer
   brew trust --tap se7enbrc/glimmer
   brew install --cask glimmer
   ```

2. [Pair your PC](docs/GETTING_STARTED.md).

## Choose how you play

| Feature                                  | Guide                                                                                               |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Fullscreen, window, Mini Player, HDR     | [Display](docs/guides/STREAMING.md)                                                                 |
| Surround and AirPods                     | [Audio](docs/AUDIO.md)                                                                              |
| Gamepads, pointer and text               | [Controllers](docs/guides/CONTROLLERS.md) · [Keyboard](docs/guides/KEYBOARD_MOUSE.md)               |
| Wake, Wi-Fi and artwork                  | [PCs](docs/guides/PCS.md) · [Wi-Fi](docs/guides/WIFI.md) · [Launcher](docs/guides/LAUNCHER.md)      |
| Raycast, Stream Deck, Shortcuts, scripts | [Automation](docs/AUTOMATION.md) · [Raycast extension](https://github.com/Se7enbrc/raycast-glimmer) |

{% hint style="warning" %}

Save before stopping: ending a stream quits its PC app.

{% endhint %}

## Help and project

[FAQ](docs/FAQ.md) · [Troubleshooting](docs/guides/TROUBLESHOOTING.md) ·
[Report a problem](.github/SUPPORT.md)

[Security](docs/SECURITY.md) · [Privacy](docs/PRIVACY.md) ·
[Updates](docs/UPDATES.md)

[Contribute](docs/CONTRIBUTING.md) · [Roadmap](docs/ROADMAP.md) ·
[Sponsor](https://github.com/sponsors/Se7enbrc)

[GPLv3](LICENSE). Copyright © 2026 ugfugl.io. [Credits](CREDITS.md).

Next: [start your first stream](docs/GETTING_STARTED.md).

## Apple clients

This repository contains the Mac app, the [iPhone/iPad app](iOS/README.md), and
the shared streaming engine. See
[repository ownership](docs/APPLE_REPOSITORY.md) for development and checks. The
Homebrew tap and Raycast extension stay in their own repositories.
