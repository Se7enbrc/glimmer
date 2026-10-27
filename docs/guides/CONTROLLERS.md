---
description:
  Use controllers, per-game layouts and iPhone or iPad touch controls.
icon: gamepad
---

# Play with a controller

## Connect and test

1. Connect by USB or Bluetooth.
2. On Mac, try Settings › Diagnostics › “Controller input test”.
3. Open Settings › Input for controller options on Mac, iPhone or iPad.

PlayStation controllers, including the PlayStation edition of Backbone One, use
PlayStation button symbols in their layout diagrams. Glimmer also identifies
them to the PC so compatible games can show PlayStation button prompts.

## Change a controller layout

1. Open Settings › Input › Controller layouts.
2. Choose a controller and **All games**, or a game on a particular PC.
3. Choose **Change a button…**, then press and release the control.
4. Choose what it sends to the PC, then choose **Save**.

You can also choose a control from the diagram or list. Sticks can swap axes or
reverse direction; triggers and extra buttons appear when the connection exposes
them. **No action** disables a control for the PC.

The diagrams show DualSense, DualSense Edge, DualShock 4, Xbox Series, Xbox
Elite Series 2 and both Backbone One editions, with a general diagram for other
MFi controllers. Choose **Back** for exposed rear buttons and paddles. If a
connection doesn't report a button's position, use the list or press the button
to capture it.

A game layout starts as a copy of All games. Later changes to All games leave
that copy alone. **Use All games…** removes the game's override. **Use system
layout…** restores Apple's mapping for All games and keeps custom game layouts.
**Reset to standard…** keeps a custom layout with standard button positions.

Custom layouts replace Apple's button and stick remapping for the selected
games. Glimmer's menus still use Apple's mapping. A controller's own saved
firmware profile still applies. If physical controls aren't available, Glimmer
keeps the system layout active and explains why.

Layouts stay on this device. Controllers without a stable individual identity
share a layout with others of the same type; the editor says when this applies.

During a Mac stream, choose Stream › “Controller layout…”. On iPhone or iPad,
open the stream menu and choose “Controller layouts”.

## Keep Glimmer's controls available

Stop streaming and Stats use remappable physical-button shortcuts on Mac, iPhone
and iPad. Hold the complete shortcut for about half a second. It acts once and
waits for every button to release before it can act again.

| Action             | Default                                  |
| ------------------ | ---------------------------------------- |
| Stop streaming     | L1 + R1 + Create/Select + Options/Start. |
| Show or hide Stats | L1 + R1 + L3 + R3.                       |

1. Open Settings › Input › Controller layouts.
2. Choose Stop streaming or Stats.
3. Hold at least three buttons, then release to record the shortcut.

Saved shortcuts remain independent of game button mappings. Ordinary presses
reach the PC immediately. Use the stream menu to open controller layouts;
keyboard Stop and the touch menu remain available.

## Reset settings

1. End the current stream.
2. Open Settings › General and choose “Reset to defaults…”.
3. Choose whether to include per-game controller layouts, then confirm.

Reset restores settings and controller shortcuts. Paired PCs, your app library
and diagnostic captures stay on the device.

## Navigate the launcher

| Control               | Action                             |
| --------------------- | ---------------------------------- |
| D-pad / left stick    | Move focus, including PC switcher. |
| Bottom / right button | Select / dismiss.                  |

{% hint style="info" %}

Needs a macOS-supported controller and launcher focus; pauses during
streams/tests. Other pads and Extra DualSense buttons need Input Monitoring.

{% endhint %}

## Use the controller as a mouse

Hold the mouse-mode toggle for a second, then release to switch modes. The
default is Menu (Options or Start on some controllers). On iPhone and iPad, the
hold opens stream controls; choose “Use mouse mode” there.

Settings › Input › Controller mouse offers the same presets on Mac, iPhone and
iPad:

| Function                  | Right-handed (default) | Left-handed        |
| ------------------------- | ---------------------- | ------------------ |
| Move / scroll             | Right / left stick     | Left / right stick |
| Primary / secondary click | R2 / R1                | L2 / L1            |
| Middle click              | Right stick press      | Left stick press   |
| Back / forward            | L2 / L1                | R2 / R1            |

Select any function to change its binding. Choose controls in the diagram or
record buttons on your controller. A binding already in use must be changed
first. Your custom bindings stay when you choose another preset; choose “Reset
to preset” to replace them. Reset to defaults in General restores Right-handed.

A DualSense or DualShock 4 touchpad also moves the pointer with one finger and
scrolls with two. A two-finger click right-clicks; a one-finger click clicks.

## Play with touch controls on iPhone and iPad

On-screen controls appear when no controller is connected. Use “Show controls”
or tap with three fingers to open the stream menu. Choose “Resume” to play
again. With VoiceOver, choose the video's “Show controls” action.

Connecting a controller hides the touch gamepad. To add a touch player during
that stream, open the menu, choose “Show touch controls”, then “Resume”. “Hide
touch controls” hides the gamepad again. This choice lasts for the session.
Touch can still
[move and click the mouse](KEYBOARD_MOUSE.md#use-touch-as-a-mouse-on-iphone-and-ipad).

### Edit the touch layout

1. Open the stream menu.
2. Choose “Edit controls…”.
3. Select a control.
4. Drag it, adjust “Size” or choose “Hide”.
5. Choose “Done” to save the layout for this PC app on this device.

Under “All controls”, adjust “Opacity” for the whole overlay, even with no
control selected. “Done” saves opacity with the layout.

“Add control…” restores a hidden control. “Reset layout…” restores the default
layout. “Cancel” leaves your saved layout unchanged. If the window is too small
for touch controls, enlarge it or connect a controller.

## Stop playing

{% hint style="warning" %}

Save first. Hold your Stop shortcut for about half a second to stop streaming.
Disconnecting quits the PC app by default. To keep it running, enable “Leave
games running when you disconnect” in Settings › General before streaming.

{% endhint %}

Next:
[controller button names and DualSense requirements](../SHORTCUTS.md#controller-shortcuts).
