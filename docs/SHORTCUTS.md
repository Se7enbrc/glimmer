---
description: Stop a stream, get the pointer back, and use copy and paste.
icon: keyboard
---

# Keyboard and controller shortcuts

These are the default bindings. Your current keyboard and controller shortcuts
are in Settings → Input, including any changes you have made.

## While streaming

The stream must have keyboard focus. If another Mac app is active, click the
stream before using its shortcuts.

| Action                               | Default shortcut | Notes                                                                                  |
| ------------------------------------ | ---------------- | -------------------------------------------------------------------------------------- |
| Stop streaming                       | Control-Q · ⌃Q   | Ends the stream and quits its app on the PC. Command-Q also quits Glimmer.             |
| Enter or leave Mini Player           | Control-M · ⌃M   | Returns to the previous presentation when leaving Mini Player.                         |
| Show or hide stream stats            | Control-I · ⌃I   | Applies to this stream; the next follows Settings → Quality.                           |
| Capture or release the pointer       | Control-P · ⌃P   | Also switches fullscreen between a free pointer and captured game controls.            |
| Paste Mac clipboard text into the PC | Control-V · ⌃V   | Command-V also works when Command shortcuts stay with the Mac.                         |
| Bookmark a rough moment              | Control-B · ⌃B   | Requires Performance telemetry in Settings → Diagnostics. Otherwise it goes to the PC. |

To leave fullscreen temporarily, use Command-Tab to switch apps or Control-M to
open Mini Player. The stream keeps running. Select Back to Stream in the
launcher to return.

Stopping with a shortcut or controller, choosing Stop Streaming, closing the
stream window, and quitting Glimmer all end the session and quit its app on the
PC. Save your progress before stopping.

## Escape and mouse capture

In a window or Mini Player, hold plain Escape for about one second to release
the pointer. A quick tap still reaches the game, and holding it sends Escape to
the game before releasing capture. Adding a modifier cancels the release
gesture. Holding Escape does not release fullscreen capture.

Mini Player captures on a click, not on hover. A normal stream window can
capture when the pointer enters its picture while the window has focus.
Controllers keep working while Mini Player is visible, even when another Mac app
is active; keyboard and mouse input follow focus.

Every app, including Desktop, starts fullscreen with captured game controls.
Control-P toggles a free pointer that follows the picture and keeps that
fullscreen choice across focus changes for this stream.

While the pointer is free, macOS input methods and the character viewer can
compose text for the PC. Capturing it sends physical keys instead. Committed
text stays ahead of later keys; pasted text first releases held input.

## Copy and paste

Control-C copies inside the PC. It does not copy that text to the Mac. Sunshine
currently has no PC-to-client clipboard channel. See the
[upstream clipboard discussion](https://github.com/LizardByte/Sunshine/issues/1539).

Glimmer's paste command types the Mac clipboard into the PC as text. It does not
synchronize clipboards or transfer files and images. Text is limited to 4,096
UTF-8 bytes per paste.

## Mac shortcuts and Game Mode

Command stays with the Mac by default, so Command-Tab switches apps and
Command-Space opens Spotlight. Settings → Input can send Command to the PC as
the Windows key in fullscreen, or while the pointer is captured in a window or
Mini Player. The Stop Streaming shortcut works either way.

In native fullscreen, Command-Escape opens macOS Game Overlay. Its Settings
contains the Game Mode switch. See
[Apple's Game Mode guide](https://support.apple.com/en-us/105118).

## Controller stop shortcut

The default is to hold both stick buttons, L3 + R3, for about half a second.
Settings → Input shows the current chord and lets you choose another one.

For Start + Select + L1 + R1, the names differ by controller:

- DualSense: Options + Create + L1 + R1. Extra DualSense buttons must be
  enabled.
- Xbox: Menu + View + LB + RB.

## Controller mouse and launcher

Hold Menu, Options or Start alone for more than 0.75 seconds, then release it to
switch that controller between game input and mouse input. Left stick moves the
pointer; right stick scrolls. The bottom, right and left face buttons click
left, right and middle; L1/R1 click back/forward, and the d-pad scrolls. On
DualSense, Start needs Extra DualSense buttons enabled.

In mouse mode, a DualSense or DualShock 4 touchpad moves with one finger and
scrolls with two. Clicking with fewer than two contacts is a left click; with
two, a right click. Nintendo button layout changes only the buttons sent to the
game, so these mouse controls stay positional. The setting is off by default and
appears in Settings → Input when a Nintendo-layout controller is connected.

In the launcher, the d-pad or left stick moves focus, the bottom face button (A
or Cross) selects, and the right face button (B or Circle) dismisses. Move to
the PC name to switch PCs. This uses macOS GameController pads; controllers
available only through raw HID do not navigate the launcher.

## When you forget

The Stream menu has Mini Player and Stop Streaming. Command-comma (⌘,) opens
Settings; Input holds the configurable bindings and Diagnostics explains
bookmarks.

Key symbols: **⌃ Control · ⌥ Option/Alt · ⇧ Shift · ⌘ Command**.
