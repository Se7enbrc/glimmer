# Controller and touch input

The first video frame goes straight into play. Touch game controls appear when
no supported physical controller is connected. Connecting a controller releases
and hides touch controls before hardware input begins by default; removing the
last one restores touch play. With hardware connected, touch remains a mouse.
Opening the stream menu releases PC input. Resume returns input to the PC;
connecting a controller never dismisses an explicitly opened menu. Disconnect
quits the game on the PC unless Leave games running when you disconnect is on.

## Touch game controls

For another player without a controller, open the stream's **…** menu and choose
**Show touch controls**, then **Resume**. This item appears only while a
physical controller is connected. **Hide touch controls** restores mouse-only
touch. The choice lasts for this stream, including controller reconnects, and
resets when the stream ends. It does not change Settings or the saved layout.

Use the fixed sticks, directional pad, face and shoulder buttons, triggers,
stick clicks, Options and Menu. Press a trigger fully, then drag inward to
reduce its value. Lift your finger to release. Independent fingers can hold
different controls while another finger uses the free video area as a mouse.

Choose **Show controls → Edit controls…** to move, resize or hide controls.
**Add control…** restores a hidden element. **Done** remembers deliberate
changes for this PC, app and compact or expanded layout; **Cancel** discards the
draft. Both return to the menu so you can choose when to resume. Reset layout
affects only this app and layout size. Forgetting the PC also removes its
layouts.

In Edit controls, Opacity changes every control together while previewing the
game. Done remembers it with this app's layout; Cancel discards it and Reset
layout restores the default. The range is 10% to 60%, with 20% selected
initially.

The controls follow Light and Dark appearance with quiet translucent fills over
video. Held controls become clearer until you release them. They do not animate
or poll while idle. Increase Contrast and Reduce Transparency change their
native appearance. VoiceOver offers Hold and Release, stick directions and
Center, and adjustable trigger values. The editor supports Dynamic Type and
arrow-key moves.

## Controller mouse mode

Hold Menu alone for a second and release to switch between gamepad and mouse. No
on-screen mode switch is needed. A brief confirmation appears without
interrupting input, then fades. The stream otherwise stays clear.

In Settings → Input, choose **Mouse stick** before starting a stream. Right is
the default: the right stick moves the pointer, R2 left-clicks, R1 right-clicks,
and the left stick scrolls. Left uses the left stick, L2 and L1, with the right
stick scrolling. Triggers click when pressed halfway. D-pad scroll and supported
controller touchpads keep their shared engine behavior. The stick choice applies
to the next stream. A newly attached controller starts in gamepad mode; each
controller toggles its own mode with Menu.

The shared engine owns mapping, motion, clicks and release ordering. Mouse-mode
clicks do not also reach the PC as gamepad buttons. Mac consumers retain their
existing default mapping and Menu behavior.

## Free-area touch mouse

- Drag one finger to move the relative pointer; tap to click.
- Tap with two fingers for a secondary click; drag two fingers to scroll.
- Tap with three fingers to show controls. This gesture is never a PC click.
- With VoiceOver, select the video and choose its **Show controls** action.

UIKit resolves taps against multi-finger gestures and pans before emitting click
edges. Cancellation ends the gesture without a click. Native controls receive no
PC touch input. Original event timestamps survive delayed delivery and focus
changes; screen scale converts view points to pixels, and the engine owns wire
quantization and release ordering.

## Physical controllers

The app captures extended Game Controller profiles by their actual elements,
including sticks, triggers, directional pad, face/shoulder/stick buttons and
available Menu, Options, Home, Share and controller touchpad controls. It sends
normalized snapshots to the shared engine. It does not infer capability from a
vendor name or use raw HID on iOS. Generic profiles with a complete PlayStation
face-symbol layout are announced as PlayStation controllers using their
original, unmapped glyphs. This does not advertise touchpad, motion or haptics
that the controller lacks. Sunshine's virtual-controller configuration and each
game's input support determine the glyphs ultimately displayed on the PC.
Sunshine's
[automatic controller selection](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#gamepad)
uses the reported controller type; an explicitly forced type can override it.

Hold Menu, Options and both shoulder buttons to disconnect using the shared stop
chord. It returns directly to the launcher after teardown, without a
confirmation or a second Close action, and leaves the PC game running.
Controllers that lack one of those controls can use the native player controls.
UIKit owns controller navigation while those controls are visible; the capture
adapter restores prior handlers and system gesture preferences when it releases
ownership.

Temporary inactivity, showing controls, backgrounding, screen lock and leaving
release held input. App switching preserves the stream for a maximum of 15
seconds while a finite iOS background task permits cleanup; returning within
that interval resumes input. Hidden presentation uses the engine's existing
suppression and single-keyframe resume path instead of treating the stopped
display link as a stream failure. Screen lock, recovery in progress or denied
background execution ends the stream immediately. Before input resumes, the app
reads the current controller state while still unfocused. Shared per-control
suppression waits for each held button, trigger, stick axis or touch contact to
return to neutral or release. Controller detach removes its registration; stale
callbacks cannot target a new controller that reuses the same slot.

A controller connected during gameplay immediately supplies its current state,
including held controls, without waiting for another native event. Connecting
while native controls are visible follows the same suppression on Resume.

## Feedback and sensors

The app supplies native Core Haptics engine/player operations, light/player
indicator setters, raw motion samples and actual battery readings. The engine
owns motor mapping, intensity curves, coalescing, recovery, motion conversion
and rate limits, and the existing battery cadence. A controller without a
capability remains usable; unsupported feedback is not advertised. No new app
polling timer is added.

Native feedback observes both engine stop/reset and player completion, so a
finished player can be rebuilt on the next rumble command. This recovery path
still needs sustained physical-controller validation.

Native feedback and sensor leases are invalidated on detach. Queued callbacks
cannot overwrite restored platform ownership. Capture unregisters before the
connection stops its transport; the engine closes feedback and input acceptance
before native resources are released.

## Validation limits

Simulator tests cover normalized capture, focus/registration lifetime,
recognizer cancellation and event timestamps, native actuator failure cleanup,
sensor restoration and UI rendering. They do not prove physical gesture
recognition, controller navigation, motor behavior, sensor timing, PC input or
input-to-photon latency. Validate Backbone One and a second controller against a
real PC, including reconnect, held-input focus loss, cancellation, VoiceOver and
background/lock teardown before accepting hardware behavior.

Next:
[review the touch control design and its evidence requirements](TOUCH_CONTROLS_DESIGN.md).
