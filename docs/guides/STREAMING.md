---
description:
  Choose stream quality, Mac presentation, iPad windows and connected displays.
icon: display
---

# Play fullscreen, windowed or in Mini Player

Play from your PC on Mac, iPhone or iPad. Fullscreen, windowed playback and Mini
Player are Mac choices; iPad also supports Split View and Stage Manager.

## Start and stop

1. Select a launcher app.

{% hint style="warning" %}

Save before stopping. On Mac, ⌃Q (Control-Q), closing the window and quitting
Glimmer quit the PC app by default. On iPhone and iPad, “Disconnect” does the
same; a stream also disconnects after its short background grace period. To keep
a game running, turn on “Leave games running when you disconnect” in Settings ›
General before streaming. Use this only with games and PCs that handle a change
in screen size.

{% endhint %}

## Continue a running game

1. Select the PC.
2. Choose “Resume” or “Continue here” beside the running game.

“Resume” appears when this device has a previous stream for that game;
otherwise, Glimmer offers “Continue here”. Continuation starts with the previous
stream size when Glimmer knows it. The Mac fits the picture to your screen;
iPhone and iPad fill the window and may crop the edges. Another device may still
be connected.

With “Leave games running when you disconnect” on, choose “Use this screen's
size…” to try a different size. Save your progress first. If that change failed
before, “Restart at this screen's size…” offers a restart instead.

Select another app, then confirm “Quit {game} and start {app}” to replace the
running game. Glimmer fills in both names. “Quit {game}…” remains available when
you only want to stop it, even with the disconnect setting on. Quitting can lose
unsaved progress and stops other streams from that PC.

## Leave the picture running

On Mac:

| Action                | Control           |
| --------------------- | ----------------- |
| Switch Mac apps       | Command-Tab.      |
| Toggle Mini Player    | Control-M.        |
| Restore hidden stream | “Back to stream”. |

{% hint style="info" %}

Mini Player keeps background controller input. Keyboard/mouse follow focus.

{% endhint %}

## Choose a display mode

On Mac:

1. Open Settings › Quality.
2. Choose your next stream's mode.

| Mode            | Picture                                |
| --------------- | -------------------------------------- |
| Sharpest        | Native Mac pixels.                     |
| Balanced        | Half-width, half-height.               |
| Custom          | Resolution, frame rate, window choice. |
| Highest quality | More detail within connection limits.  |

{% hint style="info" %}

Fullscreen fills the panel around the camera by default, without creating a
separate desktop. To swipe away and back, turn on “Keep picture below the
camera” in Settings › Quality, or “Use a full-screen Space” on a display without
a notch. The next stream opens in its own macOS Space. On a Mac with a notch,
the picture stays below the camera. Choices stay saved.

{% endhint %}

## Play on iPhone or iPad

1. Open Settings › Quality.
2. Choose “Stream format” for the next stream.

| Choice           | Picture                                                               |
| ---------------- | --------------------------------------------------------------------- |
| Native · 120 fps | Closest listed size to the window, up to the display's refresh limit. |
| 1080p · 60 fps   | 1920 × 1080, up to 60 fps.                                            |
| 1080p · 120 fps  | 1920 × 1080, up to 120 fps and the display's refresh limit.           |

iPhone streams stay in landscape. iPad streams fill portrait, Split View and
Stage Manager windows. The picture keeps its proportions and crops edges when
its shape differs from the window. Native follows the window's size; once a
resize settles, Glimmer requests the closest listed size while keeping the game
running. The 1080p choices stay 16:9, so narrow windows may crop heavily.

{% hint style="info" %}

Install the [iPhone and iPad sample](../HOST_SETUP.md#pick-your-file) on the PC.
Glimmer chooses from that sample's listed modes, rather than requesting every
possible window size. The older mixed-client sample omits the iPad window modes.
See the [mode reference](../VIRTUAL_DISPLAY_MODES.md#ipad-window-targets) for
the sizes. Some games need 16:9; choose “1080p · 60 fps” if Native looks wrong.

{% endhint %}

### Use a connected display

Connect an external display to your iPhone or iPad. When iOS makes it available
to Glimmer, the picture moves there and the controls stay on the device. The
device says “Playing on the connected display”. Disconnect the display to bring
the picture back. The mobile sample includes 1080p and 4K at 60 Hz for external
displays; it does not include 4K at 120 Hz.

## Check video support

{% hint style="info" %}

⌃Z (Control-Z) shows stream stats on Mac and with a hardware keyboard on iPhone
and iPad. On iPhone and iPad, you can also choose Show Stream Stats from the
stream menu. Settings › Quality chooses the initial visibility and overlay
detail. Change the shortcut in Settings › Input.

H.264, HEVC, supported AV1 and HDR10 require compatible hardware. Mac Custom:
640–7680 × 480–4320, 30–240 fps. PC menu: codec preference.
[Shortcuts](../SHORTCUTS.md): Game Mode.

{% endhint %}

On iPhone and iPad, Glimmer checks hardware decoding support for HEVC and AV1,
with H.264 as a fallback. It requests 10-bit HDR on an HDR-capable display when
the PC also supports it. Format selection is automatic; there is no iOS codec or
HDR switch.

In beta builds,
[adaptive stream quality](WIFI.md#adaptive-stream-quality-in-beta-builds) lowers
the bitrate when the connection struggles and raises it as it recovers. A longer
change says “Adjusting stream quality…”. The game keeps running on the PC during
the adjustment.

Next: [match the PC display](../HOST_SETUP.md) or
[automate launching](../AUTOMATION.md).
