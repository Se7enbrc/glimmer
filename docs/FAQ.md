---
description: Quick answers about setup, stopping, input, audio and automation.
icon: circle-question
---

# Find a quick answer

Glimmer is a native Swift Sunshine client for Mac, iPhone and iPad. Pair your
device with the PC, choose a game and play.

## Setup

| Question                   | Answer                                                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Intel Mac or GameStream?   | No. Use [Apple Silicon, macOS 15.7 and Sunshine](REQUIREMENTS.md).                                                                                           |
| iPhone or iPad?            | Yes: iOS 26 or later on iPhone, or iPadOS 26 or later on iPad. [Install through TestFlight](INSTALL.md#iphone-and-ipad) now, or the App Store when released. |
| Virtual display needed?    | Only for a headless PC or [unsupported display mode](HOST_SETUP.md).                                                                                         |
| Tailscale?                 | Enter the PC's address. [Wake on LAN](guides/PCS.md) stays on your home network.                                                                             |
| Why a Wi-Fi helper on Mac? | It pauses [AirDrop radio interruptions](guides/WIFI.md) during a stream.                                                                                     |

## Playing

| Question                             | Answer                                                                                                                                                                                          |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stop without quitting the game?      | Turn on “Leave games running when you disconnect” in Settings › General before streaming. Then [Resume or Continue here](guides/STREAMING.md#continue-a-running-game) on another paired device. |
| Pointer trapped on Mac?              | Press Control-P. See [mouse controls](guides/KEYBOARD_MOUSE.md).                                                                                                                                |
| Muffled AirPods on Mac?              | Use the Mac or USB microphone for [voice chat](AUDIO.md). Glimmer doesn't forward microphones.                                                                                                  |
| Copy from the PC?                    | No clipboard sync. You can [paste Mac text into the PC](guides/KEYBOARD_MOUSE.md#paste-text-into-the-pc).                                                                                       |
| Need a controller on iPhone or iPad? | No. Use [touch controls](guides/CONTROLLERS.md#play-with-touch-controls-on-iphone-and-ipad), or touch to move and click the mouse.                                                              |

## Picture and connection

| Question                       | Answer                                                                                                                                                                                                          |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| iPad picture cropped?          | The picture fills Split View and Stage Manager windows. Choose Native for the closest window size; see [iPad display modes](guides/STREAMING.md#play-on-iphone-or-ipad).                                        |
| “Adjusting stream quality…”?   | Glimmer is reconnecting at a different quality while keeping the game running. [Adaptive stream quality](guides/WIFI.md#adaptive-stream-quality-in-beta-builds) is currently enabled by default in beta builds. |
| HDR or AV1 on iPhone and iPad? | Yes, when the PC, device and display support it. See [video support](guides/STREAMING.md#check-video-support).                                                                                                  |

## More

| Question                       | Answer                                                                                                                                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Raycast or Stream Deck on Mac? | Use [automation](AUTOMATION.md).                                                                                                                                                               |
| Analytics?                     | None. [Diagnostics stay local](PRIVACY.md).                                                                                                                                                    |
| Why Glimmer over Moonlight?    | Glimmer brings native controls and a shared streaming experience to Mac, iPhone and iPad. Moonlight inspired Glimmer; see [credits](https://github.com/Se7enbrc/glimmer/blob/main/CREDITS.md). |
| What's next?                   | [Updates](UPDATES.md) and the [roadmap](ROADMAP.md), without delivery dates.                                                                                                                   |

Next: [troubleshoot a problem](guides/TROUBLESHOOTING.md) or
[find an existing report](https://github.com/Se7enbrc/glimmer/issues).
