---
description: Stop a stream, get the pointer back, and use copy and paste.
icon: keyboard
---

# Control your stream with shortcuts

Stop and Stats work on Mac and with a hardware keyboard on iPhone and iPad. Mini
Player, pointer capture, paste and Mac system shortcuts below apply to Mac. On
iPhone and iPad, the stream menu also offers “Show Stream Stats” or “Hide Stream
Stats”.

| Reference                      | Location                                        |
| ------------------------------ | ----------------------------------------------- |
| Saved bindings                 | Settings › Input; defaults below.               |
| Shortcuts app, Siri, Spotlight | [Automation](AUTOMATION.md).                    |
| Key symbols                    | ⌃ Control · ⌥ Option/Alt · ⇧ Shift · ⌘ Command. |

## While streaming

| Action in the focused stream | Default        | Result                                                                                    |
| ---------------------------- | -------------- | ----------------------------------------------------------------------------------------- |
| Stop                         | ⌃Q (Control-Q) | Ends the stream; quits the PC app unless “Leave games running when you disconnect” is on. |
| Mini Player                  | Control-M      | Toggles presentation.                                                                     |
| Stats                        | Control-Z      | Toggles for this stream; next uses Settings › Quality.                                    |
| Pointer                      | Control-P      | Toggles captured/free; keeps choice across focus changes.                                 |

| Text and diagnostics | Default   | Result                                        |
| -------------------- | --------- | --------------------------------------------- |
| Paste                | Control-V | Types Mac text into PC.                       |
| Bookmark             | Control-B | With telemetry enabled; otherwise sent to PC. |

⌃Z (Control-Z) is the default for “Show or Hide Stream Stats”; ⌃Q is the default
for “Stop Streaming”. Change either in Settings › Input. Saved custom bindings
stay yours. The old stats default moves to ⌃Z once; choosing ⌃I afterward keeps
it.

Stats changes apply to this stream. Settings › Quality chooses the initial
visibility and overlay detail for future streams, including on iPhone and iPad.

{% hint style="warning" %}

Closing the stream window or quitting Glimmer follows “Leave games running when
you disconnect” in Settings › General. It is off by default, so save first.
Command-Q quits Glimmer. An explicit “Quit” action quits the PC app even when
the setting is on.

{% endhint %}

## Escape and mouse capture

| Gesture                                          | Result                                                                           |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| Hold plain Escape ~1 second                      | Frees pointer in window/Mini Player; also sends Escape.                          |
| Tap Escape / add modifier                        | Sends Escape / cancels release gesture.                                          |
| Enter fullscreen                                 | Captured controls, including Desktop; Escape won't free pointer.                 |
| Click Mini Player / enter focused window picture | Captures pointer.                                                                |
| Aim                                              | Mac tracking speed without acceleration; optional fast-flick boost defaults off. |

## Copy and paste

| Action    | Result                                       |
| --------- | -------------------------------------------- |
| Control-V | Up to 4,096 UTF-8 bytes; no files or images. |
| Command-V | Same, when Command stays with Mac.           |
| Control-C | Copies within PC; no clipboard sync.         |

## Mac shortcuts and Game Mode

| Shortcut                             | Default action                                                                             |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| Command-Tab / Command-Space          | Switch Mac apps / Spotlight; stream continues.                                             |
| Command-comma                        | Settings.                                                                                  |
| Command-1 through Command-9          | Switch PC in Stream menu; stream continues.                                                |
| Command-Escape                       | Game Overlay in native fullscreen; Settings holds Game Mode.                               |
| Command forwarding, Settings › Input | Sends Windows key fullscreen or captured in window/Mini Player; stop shortcut still works. |

## Controller shortcuts

Hold the complete shortcut for about half a second, then release every button.
The defaults on Mac, iPhone and iPad are:

- **Stop:** L1 + R1 + Create/Select + Options/Start.
- **Stats:** L1 + R1 + L3 + R3, using both stick buttons.

Change either in Settings › Input › Controller layouts. Choose Stop streaming or
Stats, record at least three buttons, then release. Shortcuts use physical
buttons independently of the game's mapping. Existing saved choices stay yours.

| Controller        | Button names                |
| ----------------- | --------------------------- |
| PlayStation       | L1 + R1 + Create + Options. |
| Xbox              | LB + RB + Menu + View.      |
| Other controllers | L1 + R1 + Start + Select.   |

On a Mac, a DualSense connection that hides Options or Create needs **Extra
DualSense buttons** enabled in Settings › Input.

## Controller options

| Settings › Input                      | Effect                                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Extra DualSense buttons               | Options, Create, mute and adaptive triggers; needs Input Monitoring.                                    |
| Nintendo button layout                | Recognized Nintendo pads only, not individual Joy-Con sides; defaults off, swaps game buttons by label. |
| Nintendo layout with controller mouse | Mouse controls stay positional.                                                                         |
| Feedback and motion                   | Rumble, trigger rumble, gyro, touchpad, battery and light bar need controller and Sunshine support.     |

## Controller mouse and launcher

| Control                              | Result                                                                                 |
| ------------------------------------ | -------------------------------------------------------------------------------------- |
| Hold mouse-mode toggle, then release | Switch modes. Change the binding in Settings › Input › Controller mouse.               |
| D-pad / left stick in launcher       | Move focus; macOS-supported controllers only.                                          |
| Bottom / right face button           | Select / dismiss.                                                                      |
| Mouse controls                       | [Click, scroll and touchpad map](guides/CONTROLLERS.md#use-the-controller-as-a-mouse). |

## When you forget

| Need                         | Open              |
| ---------------------------- | ----------------- |
| Mini Player / Stop streaming | Stream menu.      |
| Bindings                     | Settings › Input. |

Next: [use keyboard and mouse controls](guides/KEYBOARD_MOUSE.md).
