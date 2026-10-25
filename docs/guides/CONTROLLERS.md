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

With a custom layout, hold Menu + Options for one second, then release to show
controller layouts. Controllers without that pair use Menu + left stick button,
or both stick buttons. The editor shows the available pair. This shortcut always
uses physical controls and cannot be remapped.

Hold **L1 + R1 + Start + Select** together for half a second to stop streaming.
This chord is fixed on every device and cannot be remapped. Game layouts never
change mouse mode or turn a PC button into a Glimmer shortcut.

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

1. Hold Menu, Options or Start alone for over 0.75 seconds.
2. Release to toggle modes.

On Mac:

| Control                          | Mouse action                                                                  |
| -------------------------------- | ----------------------------------------------------------------------------- |
| Left stick                       | Move.                                                                         |
| Right stick / d-pad              | Scroll.                                                                       |
| Bottom / right / left button     | Left / right / middle click.                                                  |
| L1 / R1                          | Back / forward.                                                               |
| DualSense / DualShock 4 touchpad | One finger moves, two scroll; two-contact click right-clicks, otherwise left. |

On iPhone and iPad, Settings › Input › “Mouse stick” chooses Right or Left for
the next stream. Right is the default: the right stick moves, R2 clicks, R1
right-clicks and the left stick scrolls. Left swaps those roles to the left
stick, L2 and L1, with the right stick scrolling.

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

Save first. Hold L1 + R1 + Start + Select together for half a second to stop
streaming. Disconnecting quits the PC app by default. To keep it running, enable
“Leave games running when you disconnect” in Settings › General before
streaming.

{% endhint %}

Next:
[controller button names and DualSense requirements](../SHORTCUTS.md#controller-stop-shortcut).
