---
description: Pair several PCs and wake a sleeping PC before streaming.
icon: desktop
---

# Add, switch or wake a PC

1. On Mac, choose “Pair a PC…” in Settings. On iPhone or iPad, open Settings ›
   PCs.
2. Select the PC or enter its address; Tailscale works.
3. Enter Glimmer's PIN in Sunshine.

On iPhone or iPad, choose “Add PC by address…” if the PC isn't listed. Pair each
device with the PC separately, then use the launcher's PC name to choose a saved
PC. Settings › PCs › “Forget…” removes that device's saved pairing.

On Mac:

| Task                    | Control                                                     |
| ----------------------- | ----------------------------------------------------------- |
| Switch                  | Launcher PC name; Stream menu; Command-1 through Command-9. |
| Rename, re-pair, unpair | PC context menu.                                            |
| Default                 | Settings PC controls; yellow star.                          |

{% hint style="info" %}

Switching keeps your single stream running. First launch can import Moonlight
pairings without changing Moonlight's data.

{% endhint %}

## Continue on another device

1. Turn on “Leave games running when you disconnect” in Settings › General on
   the device you are leaving, before streaming.
2. Disconnect from the stream.
3. Select the same PC on the next paired Mac, iPhone or iPad.
4. Choose “Resume” or “Continue here”.

Disconnecting quits the PC app by default. Keep the setting on only for games
and PCs that handle screen-size changes. A running-game label does not mean
another device has disconnected; see
[continuation](STREAMING.md#continue-a-running-game).

## Enable Wake on LAN

On Mac:

1. Enable wake in PC firmware.
2. Enable wake in network adapter settings.
3. Select the awake PC in Glimmer.

{% hint style="info" %}

Wake defaults on after learning the wake address; check the PC menu. It works on
your home network, not Tailscale.

{% endhint %}

Next: [wake then stream](../AUTOMATION.md#wake-then-stream).
