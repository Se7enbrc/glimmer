# Touch game controls: design for 2026.10.8

Review this design before implementing touch gameplay. The recommendation is a
small UIKit overlay feeding the existing `StreamInput` controller path. The
system virtual controller cannot provide the requested editor or complete PC
controller layout. This is Phase 1: no shipping input, UI, protocol, release
version or changelog changes. The native Simulator fixture is a visual proposal,
not a working gamepad or a latency result.

## Decision: native controls, shared input

Base reviewed: `1400f6ca` on `feat/ios-touch-controls`, already based on the
current `feat/2026.10.8` worktree. The shared brief's older `c16bba10` snapshot
is not the current checkout.

The review covered AGENTS.md, DESIGN.md, PRODUCT.md, iOS/docs/INPUT.md,
architecture and profiling guidance, controller capture, touch recognizers,
stream focus and controller mouse mode. Public Apple documentation and the
installed SDK's `GameController.framework/Headers/GCVirtualController.h` were
checked together.

| Need             | Apple's GCVirtualController                                                                                                                                                            | Decision                                                                                                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Elements         | A/B/X/Y, shoulders, triggers, two sticks or d-pad. Including left stick and d-pad selects only the stick. Menu, Options and stick clicks are absent from the documented supported set. | PC games need both navigation and movement, plus Menu/Options/L3/R3. Keep them available.                                                                                   |
| Layout           | System arranges each side for its configured elements. Manual placement is explicitly unsupported.                                                                                     | Cannot implement the requested move editor.                                                                                                                                 |
| Size and opacity | No public frame, scale or opacity property on the element configuration.                                                                                                               | Do not transform or inspect Apple's private overlay views.                                                                                                                  |
| Customization    | Button image paths, hiding elements, and stick-as-touchpad behavior. Changing the element set requires another controller.                                                             | A custom glyph is not an arbitrary new input element or layout editor.                                                                                                      |
| Haptics          | Apple describes feedback on system buttons and sticks.                                                                                                                                 | Valuable, but not enough to offset the layout limits.                                                                                                                       |
| Integration      | Connecting creates a GCController and connection notification. Its extended profile can reach existing capture callbacks.                                                              | Track the virtual controller's identity separately from physical presence or it can hide itself.                                                                            |
| Hidden interface | Since iOS 17, hide the system UI and set button values or stick/d-pad vectors from app controls.                                                                                       | Still needs our UI and touch routing; documented element limits remain, and the setters accept no original touch timestamp. Use the existing normalized input API directly. |

Sources: Apple's
[supported elements](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller/configuration/elements),
[element customization](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller/elementconfiguration),
[virtual controller class](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller),
[hidden-interface configuration](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller/configuration),
and
[integration guide](https://developer.apple.com/documentation/gamecontroller/adding-virtual-controls-to-games-that-support-game-controllers-in-ios).
Apple's
[WWDC controller session](https://developer.apple.com/videos/play/wwdc2021/10081/)
explicitly covers placement limits and system haptics. These are public API
conclusions, not a claim that undocumented combinations were exhaustively
tested. `setPosition` sets an input vector, not the control's screen position.
The local header clamps button values to 0…1 and vectors to −1…1; use those
ranges.

Apple also offers
[Touch Controller](https://developer.apple.com/documentation/touchcontroller)
with more flexible controls. Its
[central controller](https://developer.apple.com/documentation/touchcontroller/tctouchcontroller)
renders using Metal. Adding a second renderer for control chrome is not
justified for Glimmer's AVSampleBufferDisplayLayer stream or its energy budget.

Use UIButton for digital controls, a UISlider-based trigger, and UIControl for
the two-dimensional stick, which UIKit does not otherwise provide. Style real
controls; do not make tappable drawings. Editing uses native buttons, menus,
sliders and sheets/popovers. The custom work is layout, continuous-axis tracking
and touch ownership. Encoding, coalescing, focus suppression, release recovery,
controller mouse mapping and transport remain in the existing engine.

## Per-session override

The approved Phase 2 refinement keeps physical-controller play clear by default:
touch is the mouse and the gamepad overlay is absent. The stream's **…** menu
shows **Show touch controls** only while a supported physical controller is
connected. It enables a separate touch player; **Hide touch controls** restores
the default. The choice survives reconnects within this stream and resets at
stream end. It is not a Settings preference or a saved-layout property.

The custom overlay registers directly with StreamInput, never with
GameController discovery. Engine controller activity must not be used as
physical presence, because it includes this touch player.

## First frame and physical handoff

- At the first usable frame, show touch game controls and enable input when no
  supported physical controller is present. Do not require Resume on every
  controller-free launch. Desktop starts the same way; touch mouse remains
  available in the unoccupied center.
- Unless the per-session override is selected, when a supported physical
  controller connects, synchronously reject new touch game input, release the
  touch registration, remove its hit targets and visual controls, then accept
  physical input. No fade or deliberate debounce. The next rendered frame should
  be clear. The OS notification itself has delivery latency.
- When the last supported physical controller disconnects, restore the saved
  touch layout immediately. Existing fingers must lift before controlling it. A
  controller without a usable extended gamepad must not strand the player.
- An explicitly opened stream menu or editor stays open during handoff. Input
  remains released until Resume; a hardware connection must not dismiss an
  intentional pause. Connecting during editing preserves the draft and explicit
  pause. Editor previews remain editable, but no live touch gameplay overlay is
  active. Done/Cancel returns to the menu; Resume then uses the physical
  controller.
- Background, interruption, reconnection, scene resize, rotation and teardown
  release owned contacts before changing geometry or registration. Returning
  never replays a held touch. Disconnect still leaves the game running on the
  PC.

One quiet 44pt ellipsis button opens the existing stream controls. Keep the
three-finger tap and VoiceOver “Show controls” action as alternatives. Add “Edit
controls…” there. No launch onboarding, persistent instructions, mode picker or
new global Settings section.

## Default layout and reach

Use current safe bounds and size classes, never a device-name lookup. The video
continues behind cutouts; interactive frames remain inside safe regions. Left
and right clusters anchor to their respective safe edges. Preserve left/right
controller meaning in right-to-left locales. No control or hidden hit region
covers the center just because its container does.

| Available space        | Starting geometry in points                                                      | Reach policy                                                                                                                                                                                               |
| ---------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Small iPhone landscape | 96pt stick bases, 46pt face buttons, 44pt d-pad directions; 132pt d-pad envelope | Outer stick/face centers 72pt from safe edges; inner d-pad/right stick centers 214pt from edges. Keep all hit targets at least 44pt.                                                                       |
| Pro Max landscape      | Same starting control sizes; grow empty separation, not the d-pad                | Keep thumb travel bounded instead of scaling everything with screen width. User can enlarge selected controls.                                                                                             |
| iPad regular window    | 112pt stick bases, 52pt face buttons; same 132pt d-pad                           | Outer centers 100pt from safe edges; inner centers 254pt. Groups sit near lower side grips, not in the screen center.                                                                                      |
| Narrow iPad window     | Compact layout when safe geometry requires it                                    | Reflow and clamp before reducing targets; never scale targets below 44pt.                                                                                                                                  |
| Duo outer              | Compact, safe-area-driven layout                                                 | Reflow shoulders above their thumb groups; shorter height must not put Menu or sticks in system gestures.                                                                                                  |
| Duo inner flat         | Expanded side groups, same physical control sizes                                | Keep the center clear; opening must not stretch a stick across the inner display.                                                                                                                          |
| Duo partly folded      | Separate reachable groups around active reserved regions                         | No hit target crosses a fold or camera exclusion. For a horizontal fold, place groups on the usable lower region if it fits; otherwise use a native message and Resume after unfolding, not tiny controls. |

Layout numbers are starting proposals for the boards, not ergonomics evidence.
If a compact window cannot fit the complete layout at minimum targets, suspend
input and show “Make this window larger to use touch controls.” Never silently
hide a necessary button. Leave the platform's edge gestures operational.

Duo behavior must use `GeometryProxy.reservedRegions(kind:)` on iOS 27.1,
checking active division and occlusion frames, with safe-area layout on iOS 26.
The installed Xcode 27.1 SwiftUICore interface confirms this API. Code using it
needs a compiler/SDK guard as well as runtime availability because hosted builds
currently use Xcode 26.6; the toolchain change needs its own approval before
claiming full Duo support. Do not infer fold angle from aspect ratio or
introduce a sensor polling loop. Actual Duo posture acceptance is a Phase 2
gate; ordinary iPhone or iPad screenshots are not substitutes.

The full default exposes both sticks, d-pad, A/B/X/Y, L1/R1, L2/R2, L3/R3,
Options and Menu. There is no Home/Share button. Keep L3/R3 as separate 44pt
buttons so sprint/crouch can be held without guessing a pressure or double-tap
gesture. Each element can be hidden in the editor; a game should never force
players to hide half a giant pad before they can see it.

## Stick, trigger and button behavior

Fixed sticks win for the first version. A fixed base gives a repeatable neutral
point and a predictable excluded mouse region. A contact begins only inside its
base, owns that stick until up/cancel, and can move beyond the base with its
vector clamped to the unit circle. One owner per stick; a second finger cannot
steal it. Use a small radial neutral zone, initially 8% of travel with
continuous rescaling outside it, verified against drift and fine movement before
acceptance. No acceleration, smoothing, per-frame sampling or release animation
delays input. Floating sticks are deliberately omitted because their expanding
claim area conflicts with the existing touch mouse and makes grip placement less
predictable.

Buttons send down on touch-down and up on release/cancel, not after tap
recognition. Leaving the original button cancels its hold; do not transfer a
contact to another action. Independent fingers can hold independent buttons. The
d-pad permits diagonals and resolves opposite directions to neutral. A d-pad
contact can slide between directions within that control; releases precede new
presses when it crosses sectors.

L2/R2 look like compact capsules. A normal touch presses fully immediately, as
most games expect. Dragging inward while held reduces the analog value linearly
across 72pt; returning to the original point restores full travel. Release is
always zero. The tracking implementation retains UISlider accessibility and
keyboard semantics, with a value readout in editing and VoiceOver. The editor's
trigger hint explains the gesture. Use a full-travel press for VoiceOver
activation; adjustable actions provide partial values and an explicit release.
This analog interaction needs usability validation; do not claim racing
precision from the boards.

Hold Menu alone for the existing one-second interval and release to enter
controller mouse mode. Preserve the saved left/right mouse-stick mapping and
existing engine threshold, curve and cadence. Show the existing brief mode
notice for a touch registration too. Mouse-mode control labels/accessibility
values identify pointer, scroll and clicks; do not emit simultaneous gamepad
clicks. Direct center touch mouse remains independently available according to
the player's existing Touch mouse preference. Add no second mode setting.

## Edit in context, remember only deliberate changes

1. Open stream controls and choose “Edit controls…”. Release all PC input first.
   The game keeps running; do not claim to pause it or send a guessed Menu key.
2. Select a control, then drag it. A violet selection ring identifies it. A
   native inspector offers Size and Hide; show its current name and a brief
   usage hint. Collapse the inspector while dragging so it cannot block a
   destination. Keep the selected control visible when the inspector reappears.
3. Resize through the slider or accessible increment/decrement. Clamp the whole
   hit frame inside safe bounds and keep distinct targets separated by 8pt.
   Moving to an invalid position previews the last valid location.
4. Use “Add control…” to restore hidden elements from a native list. “Reset
   layout…” resets this app and geometry family after confirmation. Done saves
   atomically and returns to the stream menu; Cancel discards all preview edits.
5. Resume when ready. The editor's touches cannot become gameplay presses.

No jiggle loop, save-on-every-drag, arbitrary transparency slider, layout
gallery, presets picker, cloud sync or numerical coordinate form. Controls are
neutral by default; violet belongs to selection and editor actions.

Per-PC-app memory earns its keep: a platformer and a driving game need different
visible controls. Save only deviations after Done, keyed by the persisted PC
UUID, Sunshine app ID and compact/expanded geometry family, locally on this
installation. Do not key by PC address or display name. Store edge-relative
positions within each reachable region, element size and visibility plus a
schema version. Rotation reuses and clamps the layout; opening Duo uses the
other family without destroying the saved one. Revalidate on every geometry
change; temporary clamping must not overwrite the original layout. Missing,
corrupt or incompatible data returns to defaults. Forgetting the PC deletes its
layouts. Do not auto-create records for every game launch.

## Appearance, accessibility and haptics

During play, use static translucent system neutral fills, semantic labels and a
fine contrasting edge. Starting visual values are 26% dark or 34% light fill,
with labels at about 85%; increase contrast for the accessibility preference.
These are design tokens, not user settings. Pressed controls become more opaque
immediately. Avoid live background blur, refraction and shadows over moving
video. Use native material only in the editor/stream menu. No scene luminance
sampling, timed fade, idle animation, haptic keepalive or display link.

The fixture shows light and dark alternatives over the same illustrative frame.
The existing stream menu is deliberately dark. Recommended play chrome also
stays dark in both system appearances, with accessibility contrast overrides;
keep the menu policy. Light chrome is an explicit review alternative. The
comparison boards evaluate the alternative, not an unapproved appearance change
to the rest of the app.

Editor text uses system text styles, Dynamic Type and scrollable native
presentation when space is tight. Gameplay glyphs identify stable controls;
never shrink touch targets to accommodate text. Give each control a spoken name,
role and value. Buttons support activation and explicit Hold/Release
accessibility actions; loss of focus clears holds. Sticks expose directional and
Center actions, triggers adjustable values. Keep “Show controls” reachable
through the video accessibility action and ellipsis. Do not claim full
simultaneous action-game accessibility from those fallbacks. Test VoiceOver,
Switch Control, keyboard focus, largest accessibility text, Increase Contrast,
Reduce Transparency and Reduce Motion before approval of the built interaction.

Use one soft
[UIKit feedback](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator)
impulse on a digital down edge and one selection impulse when an edit snaps into
a valid position, only where hardware supports it and system preferences permit.
No feedback per analog sample, no vibration while holding a stick, and no
synthetic PC rumble capability. Unsupported hardware stays silent. Haptic calls
follow input submission so they cannot gate it. iPad haptics and actual feel
cannot be established in Simulator.

## Touch ownership and release invariants

At touch-down, assign the contact to a visible enabled control or to the free
video surface, and retain that ownership until up/cancel. The overlay container
passes through empty areas. Real UIControl descendants are excluded from all
mouse/reveal recognizers. A touch that starts on video never becomes a button
press merely by crossing it, and a stick drag never turns into pointer motion.

Allow multiple game-control contacts plus independent center mouse contacts. The
three-finger tap counts only contacts that started on the free surface; three
fingers holding controls must never open the menu. Keep current failure ordering
among free-surface taps and pans, so a successful three-finger tap produces no
PC click. Do not make gamepad presses wait for that recognizer. Opening the menu
releases gamepad, pointer buttons and scroll before showing UI. Cancellation and
visibility/geometry changes reset every owned contact once.

Physical takeover invalidates the touch registration before hardware admission,
so held touches cannot occupy a second player slot or leave a stuck action. If
physical registration fails, preserve the touch fallback and report the failure
through existing UI. Never infer a successful handoff from a notification alone.
Session focus belongs to one coordinator; a touch adapter must not fight
`IOSControllerCapture` by independently toggling global focus.

## Integration evidence and risks

These are confirmed integration constraints, not claims of existing defects.

| Location                                                    | Concrete consequence                                                                                                          | Required change and regression coverage                                                                                                                                      |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iOS/Glimmer/StreamSessionModel.swift:158` and `:207`       | Last-controller detach opens stream controls; first frame without hardware remains unfocused.                                 | Separate physical presence, touch availability and explicit menu intent. Test first frame, last detach and explicit pause during connect.                                    |
| `iOS/Glimmer/StreamSessionModel.swift:183`                  | Mouse-mode notice is gated on physical presence.                                                                              | Include the active touch registration; test both mouse stick mappings and reentry after detach.                                                                              |
| `iOS/Glimmer/StreamTouchCapture.swift:47` and `:75`         | Recognizer failure ordering protects multi-finger taps, and UIControl ancestry already excludes native controls.              | Preserve it for free contacts, add stable ownership and pass-through hit testing. Test stick + face + mouse together and three free fingers versus three control contacts.   |
| `iOS/Glimmer/IOSControllerCapture.swift:80`, `:100`, `:138` | Registration happens before the current connection callback; focus sampling and queued callbacks are guarded by generations.  | Coordinate takeover before attach can emit physical state; retain stale callback rejection and held-control suppression. Test same-slot reuse and failed physical admission. |
| `iOS/Glimmer/StreamPlayback.swift:90`                       | NativeInputLifetime currently owns only physical capture.                                                                     | Own the touch adapter at the same session boundary; quiesce before disposing either adapter.                                                                                 |
| `GlimmerEngine/Input/StreamInput.swift:92` and `:111`       | Unregister releases controller state; submit accepts normalized samples and original timestamps and begins controller timing. | Reuse this API. No second packet path or synthetic GCController is required.                                                                                                 |
| `iOS/Glimmer/StreamView.swift:109`                          | Touch mouse goes straight to StreamInput with event timestamps and scale.                                                     | Preserve center mouse path and the existing preference. Game axes use normalized points, not screen pixel scaling.                                                           |

The adapter should emit one complete snapshot per changed touch event with the
original UITouch/UIEvent uptime timestamp, directly into synchronous
`submitController`. Do not first mutate SwiftUI state, create a Task, wait for a
frame or queue through an artificial GCController callback. Visual updates
follow submission. Unchanged analog values and stationary held contacts produce
no new snapshots. Registration advertises only implemented inputs and analog
triggers, not motion, battery, touchpad, light or rumble.

## Phase 2 proof required after design approval

| Evidence                  | Method and acceptance                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Input correctness         | Swift Testing on Simulator: ownership, simultaneous axes/buttons, cancel, diagonals, trigger range, geometry clamp, layout persistence, handoff ordering, stale generation, focus and mouse-mode transitions. Deterministic clocks and injected submissions. Assert each release and timestamp.                                                                              |
| Latency                   | Use existing `input_controller_capture_handler`, `handler_batcher`, `batcher_flush`, `flush_send` and `capture_send` p50/p95/p99/max and counts. Compare the touch adapter to direct normalized submission with the same recorded event trace, including idle, drag/button load and main-thread load. Keep original timestamps at the capture boundary.                      |
| Timing validity           | `input_timing_dropped_total == 0`; equal event counts and capture windows; report bucket precision and run variability. At least three paired runs. No added timer, tap delay or frame boundary. Reject a repeatable tail increase beyond baseline variability; investigate any added >1ms p95 processing before acceptance. This is a proposed gate, not a measured result. |
| Idle cost                 | Compare controls hidden, visible untouched, held stationary and actively moving. Instruments should show no added recurring overlay callback, redraw, timer or allocation while untouched/held. Measure compositor cost over moving video separately; alpha composition is not free.                                                                                         |
| Energy and stream quality | Match scene, codec, resolution, fps, network, brightness and diagnostic mode. Compare process CPU, wakeups, allocation, frame pacing and available GPU/energy evidence. Mac `gpu_power_w`/`package_power_w` cannot be assumed available or representative on iOS Simulator. No decode/pacing/bitrate changes are authorized.                                                 |
| Visual and access         | Before/after boards on small iPhone, Pro Max, iPad mini/large/resized and Duo outer/inner/partial-fold, both rotations and appearances. Include editor, physical connected, disconnect, mouse mode, no PC, many apps, background/recovery and accessibility sizes where relevant. Verify labels, keyboard navigation and actual hit frames.                                  |

The existing timing contract is in `docs/PROFILING.md:484` and `:508`.
`capture_send` ends at NWConnection submission; it is not physical transmission,
PC receipt or input-to-photon latency. Simulator measurements can validate
adapter overhead and scheduling only. Real thumb reach, haptic feel, sustained
iOS watts and touch-to-photon performance remain unverified under this task's
Simulator-only restriction. Do not run a real iPhone to close those gaps.

## Deliberately left out

- Floating sticks, pressure gestures, macros/turbo, arbitrary remapping, gyro
  aiming and simulated PC rumble. They add ambiguity or new input policy.
- Cloud profiles, exported layouts, layout marketplaces, automatic game genre
  detection and a settings page. Remember explicit local edits only.
- Live blur during play, repeating animation, idle fades and continuously armed
  haptics. The stream keeps the rendering and energy budget.
- A second renderer, a second input transport, patched Sunshine, version changes
  and Phase 2 implementation before approval.

## Simulator boards and validation record

| Board                                                           | Captured states                                                      |
| --------------------------------------------------------------- | -------------------------------------------------------------------- |
| [iPhone 16e](assets/touch-controls/board-iphone-small.jpg)      | Dark recommendation, light alternative, clear sample, revised editor |
| [iPhone 17 Pro Max](assets/touch-controls/board-iphone-max.jpg) | Same four states at the larger phone geometry                        |
| [iPad Pro 11-inch (M5)](assets/touch-controls/board-ipad.jpg)   | Same four states, cropped to the rendered landscape scene            |

Captured on iOS 26.0 Simulator with Xcode 27.1 (27A9275), SDK 27.1, Swift 6
language mode and deployment target 26.0. The separate fixture built with
warnings treated as errors; the final build had no warnings. An initial sandbox
macro failure and linker SDK warning were resolved by permitting the compiler
helper and supplying the Simulator SDK explicitly to the linker.

The sample scene is an original static illustration, not footage from a
connected PC. Buttons and editor controls are native, but joysticks are visual
stand-ins and none sends game input. The clear image is the same sample without
proposed chrome, not a shipping-app screenshot. No application source or Xcode
project file was changed.

The iPad runtime kept the landscape scene letterboxed inside a portrait surface,
even with a public scene geometry request. Device Hub UI access was denied;
manual device rotation was unavailable. The iPad board removes only black rows
outside the scene and labels that crop. Full raw PNGs are retained. This proves
the proposed landscape composition, not full-screen rotation or touch geometry
on a physically rotated iPad. Duo postures, iPad resizing, VoiceOver operation,
Dynamic Type extremes, analog tracking, physical handoff and real-game input
remain Phase 2 work. Do not treat these boards as product acceptance
screenshots.

Reproduction files are in `shots-48/fixture/`: `Mockup.swift`, the app's
`Info.plist`, `build.sh`, `capture.py` and `Boards.swift`. `build.sh` builds
only the isolated Simulator fixture at low priority. `capture.py` installs that
fixture on the three named Simulators, captures each state, terminates it and
returns those devices to shutdown. It neither installs Glimmer nor contacts a
PC. Board composition preserves the raw screenshots, apart from the explicitly
labelled iPad crop. Review copies of the boards are committed with this design;
fixture source and raw evidence remain in the requested output directory.

Verification: Actionlint, SPDX, engine/iOS boundary audits and strict SwiftLint
passed in `make check`. Its release-tool tests did not pass: existing
`HostedReleaseTests.test_build_retry_accepts_successful_verification_from_earlier_attempts`
times out in the mocked `scripts/ci-release.sh verify-checks` subprocess after
10 seconds. A fail-fast rerun reproduced it
(`scripts/tests/test_ci_release.py:154` and `:531`). The isolated release-tool
file finished with 26 errors in 29 tests; the full `make check` run was
interrupted after the repeated timeouts were confirmed. Logs are retained in
`shots-48/make-check.log` and `shots-48/ci-release-first-failure.log`. No
release script or test threshold was changed. This is an incomplete repository
gate, not a clean verification claim.

No Mac unit tests, real-device commands, signing operations, push or
Version.xcconfig changes were performed. The local documentation commit uses
normal hooks, without bypassing checks. Full `make verify` is excluded because
this task expressly prohibits Mac unit tests.

Next:
[review the implementation and remaining acceptance evidence](TOUCH_CONTROLS_VALIDATION.md).
