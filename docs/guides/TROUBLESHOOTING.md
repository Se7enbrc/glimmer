---
description: Find a fix or collect useful local diagnostics for a report.
icon: wrench
---

# Find your next fix

## Connection

| Problem           | Try this                                                            |
| ----------------- | ------------------------------------------------------------------- |
| Missing PC        | Enter its address in “Pair a PC…”.                                  |
| Unreachable PC    | Check Sunshine is running, then Glimmer's Local Network permission. |
| Pairing timed out | Retry with the new PIN.                                             |
| Pairing busy      | Cancel the other request on Sunshine's PIN page.                    |
| Trust needed      | Confirm the certificate change before “Pair again…”.                |

## Playback

| Problem                          | Try this                                                                                                                                     |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Wrong size                       | [Match the PC display](../HOST_SETUP.md).                                                                                                    |
| Stutters                         | On Mac, [enable the Wi-Fi helper](WIFI.md). In beta builds, check [Adaptive stream quality](WIFI.md#adaptive-stream-quality-in-beta-builds). |
| Quiet or muffled sound           | [Audio fixes](../AUDIO.md).                                                                                                                  |
| Trapped pointer or paste trouble | [Keyboard and mouse](KEYBOARD_MOUSE.md#paste-text-into-the-pc).                                                                              |
| Missing buttons                  | [Controller setup](CONTROLLERS.md).                                                                                                          |

## iPhone and iPad

| Problem                          | Try this                                                                                                                                                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Touch gamepad disappeared        | Connecting a controller hides it. Open the stream menu with a three-finger tap, choose “Show touch controls”, then “Resume”.                                                         |
| Touch controls won't fit         | Enlarge the iPad window or connect a controller. Use [Edit controls…](CONTROLLERS.md#edit-the-touch-layout) to adjust Size and Opacity.                                              |
| Picture cropped or wrong size    | Choose Native for windowed play and install the [mobile display modes](../HOST_SETUP.md#pick-your-file). Some games need “1080p · 60 fps”.                                           |
| Lower quality in Low Data Mode   | Adaptive quality limits new streams to 9 Mbps, up to 1080p and 60 fps. See [Low Data Mode](WIFI.md#low-data-mode-on-iphone-and-ipad).                                                |
| Game closed after switching apps | After the background grace period, Glimmer disconnects and quits the game by default. Enable “Leave games running when you disconnect” in Settings › General before the next stream. |

“Adjusting stream quality…” means Glimmer is reconnecting at a different
quality, keeping the game running. If it keeps appearing, check the network
connection to the PC. See
[adaptive quality](WIFI.md#adaptive-stream-quality-in-beta-builds).

## Record a rough moment

{% hint style="info" %}

On Mac, [collect local diagnostics](../PROFILING.md#opt-in-telemetry). On iPhone
and iPad, note the time and what happened; both beta and production builds use
Apple's system logs and crash reports without custom recording.
[Review reports before sharing](../PRIVACY.md); never attach keys, PINs or
certificates.

{% endhint %}

## Report a problem

1. Search [existing issues](https://github.com/Se7enbrc/glimmer/issues).
2. Report versions, steps to reproduce, devices and connection type.

{% hint style="warning" %}

Use the
[private security form](https://github.com/Se7enbrc/glimmer/security/advisories/new)
for suspected vulnerabilities.

{% endhint %}

Next: [open or find a report](https://github.com/Se7enbrc/glimmer/issues).
