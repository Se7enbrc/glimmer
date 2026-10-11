---
description: Get Glimmer on your Mac with Homebrew or a download.
icon: download
layout:
  outline:
    visible: false
---

# Install Glimmer

macOS 26+, Apple Silicon.

```bash
brew tap se7enbrc/glimmer
brew trust --tap se7enbrc/glimmer   # Homebrew requires this for third-party taps
brew install --cask glimmer
```

Or the notarized `.dmg` from
[Releases](https://github.com/Se7enbrc/glimmer/releases). Either way it updates
itself. The cask also links the `glimmer` command. An existing Homebrew install
gets it with `brew upgrade --greedy glimmer` (or
`brew reinstall --cask glimmer`), because the app updates itself outside
Homebrew.

Signed and notarized, distributed outside the App Store. Glimmer runs without
App Sandbox and offers an optional administrator-approved Wi-Fi helper
([security details](SECURITY.md)). You can
[verify a download](SECURITY.md#verifying-a-download) before opening it.

Glimmer has earned the
[OpenSSF Best Practices Passing badge](https://www.bestpractices.dev/en/projects/15346).
The public assessment records the evidence and protocol limitations; the
[security roadmap](SECURITY_ROADMAP.md) tracks work toward higher levels.

Your PC needs Sunshine and a display that can present the exact mode you ask
for: a virtual display driver on Windows, a current Sunshine on Linux.
[the PC setup guide](HOST_SETUP.md) walks through it.

The Wi-Fi helper lives in Settings › Quality › Wi-Fi; macOS asks for one
approval under Login Items & Extensions. If registration fails, follow the
recovery guidance shown in Settings. Resetting macOS's entire background-task
database affects other apps too and is not a routine installation step.

If AirPods playback becomes muffled only while a voice app uses their
microphone, try selecting your Mac's microphone or a USB microphone in that app
while leaving AirPods as the output. Apple documents this
[Bluetooth microphone quality change](https://support.apple.com/en-us/102217).
See [Audio on macOS](AUDIO.md) for voice-chat and volume-recovery guidance.

The [shortcut guide](SHORTCUTS.md) covers keyboard and controller shortcuts,
getting the mouse back, and what copy and paste can do. Settings › Input shows
your current bindings.
