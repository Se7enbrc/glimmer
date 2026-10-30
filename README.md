# Play your PC games on Mac, iPhone and iPad with Glimmer

Glimmer is a native Swift Sunshine client for Mac, iPhone and iPad. Pair with
your PC, choose a game and play with a controller, keyboard and mouse, or touch.
Free, now and always. No account or analytics.

The Mac app is generally available; iPhone and iPad are in TestFlight beta.

Use an Apple Silicon Mac with macOS 15.7 or later, an iPhone with iOS 26 or
later, or an iPad with iPadOS 26 or later.

[Website](https://se7enbrc.github.io/glimmer/) ·
[Documentation](https://ugfugl-io.gitbook.io/docs/)

<p align="center">
  <a href="https://github.com/Se7enbrc/glimmer/actions/workflows/verify.yml"><img src="https://github.com/Se7enbrc/glimmer/actions/workflows/verify.yml/badge.svg?branch=main" alt="Verification status"></a>
  <a href="https://github.com/Se7enbrc/glimmer/actions/workflows/codeql.yml"><img src="https://github.com/Se7enbrc/glimmer/actions/workflows/codeql.yml/badge.svg?branch=main" alt="CodeQL status"></a>
  <a href="https://github.com/Se7enbrc/glimmer/releases/latest"><img src="https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fse7enbrc.github.io%2Fglimmer%2Fappcast.xml&amp;query=%2F%2F%2A%5Blocal-name%28%29%3D%27item%27%5D%5Bnot%28%2A%5Blocal-name%28%29%3D%27channel%27%5D%29%5D%5B1%5D%2F%2A%5Blocal-name%28%29%3D%27shortVersionString%27%5D&amp;label=release&amp;prefix=v" alt="Latest release offered to Glimmer"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-15.7%2B%20%C2%B7%20Apple%20silicon-000000?logo=apple&amp;logoColor=white" alt="macOS 15.7 or later on Apple silicon"></a>
  <a href="https://ugfugl-io.gitbook.io/docs/introduction/getting_started/install#iphone-and-ipad"><img src="https://img.shields.io/badge/iOS%20%26%20iPadOS-26%2B%20%C2%B7%20TestFlight-000000?logo=apple&amp;logoColor=white" alt="iOS and iPadOS 26 or later, available in TestFlight"></a>
  <a href="https://github.com/Se7enbrc/homebrew-glimmer"><img src="https://img.shields.io/badge/Homebrew-se7enbrc%2Fglimmer-fbb040?logo=homebrew&amp;logoColor=white" alt="Homebrew cask in the se7enbrc/glimmer tap"></a>
  <a href="https://ugfugl-io.gitbook.io/docs/project/contributing_index/release"><img src="https://img.shields.io/badge/releases-signed%20%C2%B7%20notarized%20%C2%B7%20attested-2da44e" alt="Releases are signed, notarized and attested"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/Se7enbrc/glimmer"><img src="https://api.securityscorecards.dev/projects/github.com/Se7enbrc/glimmer/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://www.bestpractices.dev/en/projects/15346"><img src="https://www.bestpractices.dev/projects/15346/badge" alt="OpenSSF Best Practices status"></a>
  <a href="renovate.json"><img src="https://img.shields.io/badge/updates-Renovate-2da44e" alt="Dependency updates by Renovate"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Se7enbrc/glimmer" alt="GPL license"></a>
</p>

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

2. [Pair your PC](https://ugfugl-io.gitbook.io/docs/introduction/getting_started).

Mac installs update in the app through Sparkle. On iPhone or iPad, install
through the
[TestFlight beta](https://ugfugl-io.gitbook.io/docs/introduction/getting_started/install#iphone-and-ipad).
App Store availability is still ahead.

## Choose how you play

| Feature                                       | Guide                                                                                                                                                                                                   |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Picture, HDR and display choices              | [Display](https://ugfugl-io.gitbook.io/docs/guides/features/streaming)                                                                                                                                  |
| Speakers and headphones                       | [Audio](https://ugfugl-io.gitbook.io/docs/guides/features/audio)                                                                                                                                        |
| Controller layouts, touch, keyboard and mouse | [Controllers](https://ugfugl-io.gitbook.io/docs/guides/features/controllers) · [Keyboard and mouse](https://ugfugl-io.gitbook.io/docs/guides/features/keyboard_mouse)                                   |
| PCs, connection and launcher                  | [PCs](https://ugfugl-io.gitbook.io/docs/guides/features/pcs) · [Wi-Fi](https://ugfugl-io.gitbook.io/docs/guides/features/wifi) · [Launcher](https://ugfugl-io.gitbook.io/docs/guides/features/launcher) |
| Mac automation                                | [Automation](https://ugfugl-io.gitbook.io/docs/automation/automation) · [Raycast extension](https://github.com/Se7enbrc/raycast-glimmer)                                                                |

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

[FAQ](https://ugfugl-io.gitbook.io/docs/introduction/faq) ·
[Troubleshooting](https://ugfugl-io.gitbook.io/docs/guides/features/troubleshooting)
· [Report a problem](.github/SUPPORT.md)

[Security](https://ugfugl-io.gitbook.io/docs/security-and-privacy/security) ·
[Privacy](https://ugfugl-io.gitbook.io/docs/security-and-privacy/security/privacy)
· [Updates](https://ugfugl-io.gitbook.io/docs/introduction/updates)

[Contribute](https://ugfugl-io.gitbook.io/docs/project/contributing_index) ·
[Roadmap](https://ugfugl-io.gitbook.io/docs/project/roadmap) ·
[Sponsor](https://github.com/sponsors/Se7enbrc)

[GPLv3](LICENSE). Copyright © 2026 ugfugl.io. [Credits](CREDITS.md).

Next:
[start your first stream](https://ugfugl-io.gitbook.io/docs/introduction/getting_started).
