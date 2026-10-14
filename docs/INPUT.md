# Controller and touch input

The player starts with native Resume and Disconnect controls. Resume gives the
PC ownership of controller and touch input and hides the overlay. Showing the
controls releases PC input before UIKit handles their buttons. Disconnect stops
the local stream without quitting the game on the PC.

## Fixed touch mapping

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
vendor name or use raw HID on iOS.

Hold Menu, Options and both shoulder buttons to disconnect using the shared stop
chord. Controllers that lack one of those controls can use the native player
controls. UIKit owns controller navigation while those controls are visible; the
capture adapter restores prior handlers and system gesture preferences when it
releases ownership.

Temporary inactivity, showing controls, backgrounding, screen lock and leaving
release held input. Before input resumes, the app reads the current controller
state while still unfocused. Shared per-control suppression waits for each held
button, trigger, stick axis or touch contact to return to neutral or release.
Controller detach removes its registration; stale callbacks cannot target a new
controller that reuses the same slot.

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
