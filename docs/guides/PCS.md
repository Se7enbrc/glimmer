---
description: Pair several PCs and wake a sleeping PC before streaming.
icon: desktop
---

# Add, switch or wake a PC

1. Choose “Pair a PC…” in Settings.
2. Select the PC or enter its address; Tailscale works.
3. Enter Glimmer's PIN in Sunshine.

| Task                    | Control                                                     |
| ----------------------- | ----------------------------------------------------------- |
| Switch                  | Launcher PC name; Stream menu; Command-1 through Command-9. |
| Rename, re-pair, unpair | PC context menu.                                            |
| Default                 | Settings PC controls; yellow star.                          |

{% hint style="info" %}

Switching keeps your single stream running. First launch can import Moonlight
pairings without changing Moonlight's data.

{% endhint %}

## Enable Wake on LAN

1. Enable wake in PC firmware.
2. Enable wake in network adapter settings.
3. Select the awake PC in Glimmer.

{% hint style="info" %}

Wake defaults on after learning the wake address; check the PC menu. It works on
your home network, not Tailscale.

{% endhint %}

Next: [wake then stream](../AUTOMATION.md#wake-then-stream).
