# Touch controls implementation and proof

Review the native touch controls against the approved
[design](TOUCH_CONTROLS_DESIGN.md). The implementation is ready for code review,
but the complete Phase 2 acceptance evidence is not available: actual iPad
rotation, Duo inner/partial-fold postures, assistive interaction and device
energy still have gaps.

## Overlay-wide opacity follow-up

The editor starts with no selection. All controls contains the global Opacity
slider above a divider; selecting an element adds its own Size row and Hide
button below. Reset and hiding the selected element return to no selection. The
inspector remains a native material surface at normal opacity.

Previously every gamepad element shared the value, but the editor preview
omitted “…” and play rendered that button separately. The gamepad view now owns
a native menu button, including in the editor preview. One synchronous,
non-animated UIKit pass applies an opacity change to every element, including
the d-pad's shape, stick thumbs, shoulders and bottom utility buttons. The
standalone mouse-only menu button also loads the saved layout opacity through
the shared palette.

168 correctness tests pass. The all-control test checks colors immediately after
configuration, without forcing a later layout pass, preserves held input and hit
frames, and checks the ellipsis palette and frame. Native slider tests run with
no selection and a selected right stick, verify both endpoints update every
control live, leave Size unchanged, and do not save until Done. Menu activation,
its accessibility label and touch-mouse exclusion are also covered.

The repeated idle fixture records zero recurring root layouts, draws or input
submissions at 10%, 60% and stationary-held states in both appearances, over
static and moving video. Static visible process CPU ranges from 0.15% to 0.20%
of one Simulator host core. Median paired touch-minus-direct capture-to-network
p95 differences are -0.003 ms idle, +0.001 ms under input load and approximately
0 ms with main-thread work. Stage counts match; dropped timing records are zero.
These are Simulator process/input counters, not child-layer GPU or device watts.

The new strings are “All controls” and “Select a control to move or resize it.”
Size is reused as a visible label. Both section names have accessibility heading
traits; the slider retains its Opacity label and locale-formatted percentage.
Physical VoiceOver interaction and device power remain unverified.

Before/after panels, selected/unselected panels and 10%/20%/60% light/dark
boards for iPhone Max and iPad mini are under `shots-48/phase2/opacity-global/`.
The viewport fixtures do not establish actual iPad rotation or fold posture
behavior. The existing simulator-only, no-Mac-tests, no-push and no-version-bump
limits remain in force. No stream-session or quality-indicator files changed.

## Original opacity editor follow-up

Edit controls now includes a native Opacity slider beside Size, with a vertical
fallback for narrow or large-text inspectors. The range is 10% to 60% in five
percentage-point steps; 20% retains the approved translucent look. The same
bounded value styles every gamepad element and the stream-menu button without
changing hit frames. Glyph edges retain a readability floor and held controls
keep their contrast boost. Accessibility palette overrides still take
precedence.

Done saves opacity with explicit per-PC/app/family edits, including opacity-only
changes. Cancel leaves the stored record alone. Reset layout restores 20%;
saving a fully default layout removes its record. Existing layouts without the
field load at 20%. The only new string is “Opacity”; its visible and accessible
values use locale-formatted percentages.

The warning-as-error Simulator build and 167 correctness tests pass. Coverage
includes bounds/non-finite values, legacy decoding, persistence/scope, discarded
drafts, reset, every native control type, held-input/geometry preservation,
contrast over neutral luminance levels, and glyph raster reuse independent of
background fill. Native editor captures also assert matching slider and preview
values at 10%, 20% and 60%.

Boards, raw xcresults, CSVs and reproduction scripts are under
`shots-48/phase2/opacity/` in the task evidence directory. The board index
includes before/after editors, both appearances over bright/dark frames, eight
viewport geometries, and actual small-iPhone/Max/Duo-primary scenes in both
landscape orientations. iPad/fold fixtures do not resolve the physical posture
gaps above.

Opacity invalidates appearance only on a value change; gameplay adds no timer,
continuous animation, blur or polling. Values are quantized before rendering,
and glyph cache keys contain only foreground/edge colors. The updated idle
fixture measures 10% and 60% over static and moving video; existing input timing
uses the unchanged capture-to-network submission path. See the evidence folder's
`measurements.md` for results and limits, including unmeasured child-layer GPU
composition, device watts and physical input latency.

Idle measurements at both bounds record zero recurring root layouts, draws or
input submissions in light/dark, static/video and stationary-held intervals.
Static visible CPU is 0.14% to 0.22% of one Simulator host core; moving-video
visible CPU is 6.55% to 6.94%. These are process counters, not device power.
Existing capture-to-network p95 timing has median paired touch-minus-direct
differences of -0.003 ms idle, -0.024 ms under input load and -0.008 ms with
main thread work. All timing stage counts match and dropped records are zero.

The native slider regression and maximum-value captures caught fractional steps
truncating the final endpoint to 55%. Using whole percentage points fixes it;
the regression sends native value-change events at both endpoints and verifies
live preview without saving. VoiceOver label/value are supplied by the Slider.
In-process enumeration did not expose SwiftUI's accessibility nodes; physical
VoiceOver gestures remain an acceptance gap. No stream-session,
disconnect-default or quality-indicator policy files changed; no Mac tests,
physical-device run, version bump or push is included.

## Implemented behavior

- Touch gameplay starts with the first usable frame without a physical
  controller. Physical admission retires touch input before registering the
  controller unless the stream-only override was explicitly selected. Explicit
  stream menus remain paused through handoff.
- Native UIButton, UIControl and UISlider controls submit complete normalized
  samples synchronously with original touch timestamps. Ownership survives
  movement and rejects stale contacts after cancellation. Fixed sticks, diagonal
  d-pad, analog triggers and the existing controller mouse mode share the engine
  input path.
- Editing moves, resizes, hides and restores elements in context. Done stores
  deliberate per-PC/app/geometry-family changes; Cancel discards them.
  Forgetting a PC removes its layouts. Targets stay at least 44 points, with
  separation and a reserved stream-menu target.
- Geometry changes release contacts. An unusably small region suspends touch
  play and explains how to recover. Stream notices overlay the clear center
  during touch play so they cannot move controls during a hold. Stream
  instructions scroll below their toolbar; toolbar actions adapt to
  accessibility text sizes.
- Gameplay uses static fills, no live blur, timer, display link, repeating
  animation or haptic keepalive. Native material appears in the editor. Haptic
  generators are reused and invoked after input submission.

The full inventory of new user-facing text is in
[touch control strings](TOUCH_CONTROLS_STRINGS.md). Floating sticks, macros,
remapping, genre detection, cloud layouts, Settings-page opacity controls and a
second renderer remain excluded.

## Correctness and build

The Simulator warning-as-error build succeeds with Swift 6 strict concurrency.
The preceding light appearance correctness run passes 161 tests in 18 suites,
including ownership, timestamps, unchanged-sample suppression, stale
generations, physical admission ordering, focus rearming, native accessibility
activation/release, geometry, persistence and session behavior. Eleven existing
native UI tests also pass, covering launcher, settings, recovery and stream
states. The final scene capture tests also assert identical control frames
before and after entering mouse mode.

The first-frame regression was observed failing against the original policy
before the fix. A later test caught editor state surviving teardown; the final
run passes it. Hit testing verifies free-area pass-through and exclusion of
native controls and their descendants from touch-mouse/reveal recognizers.
Actual multi-finger injection, VoiceOver gestures and Switch Control operation
are not established by these unit tests.

Static repository checks pass: Actionlint, SPDX, engine/iOS boundaries and
strict SwiftLint. `make check` completes its 393 release-tool tests with four
errors and one failure: three malformed verification-record subcases and one
publication fixture time out, and a retry test expects no sleep. These failures
are outside the touched area. No test, threshold or release script was changed
to hide them. The full repository gate is not green.

## Input timing

Three paired runs per workload use the existing `FrameTimingTracker`,
`InputTimingContext`, `InputBatcher`, encryption and `NWConnection` submission
path. Each pair replays identical scheduled timestamps and values. Idle has 240
samples over 1,195 ms; button/drag and main-thread loads have 480 over 239 ms.
All five stage counts match, and dropped timing records are zero.

| Load                  | Direct capture-to-send p95 | Touch p95 | Median difference |
| --------------------- | -------------------------- | --------- | ----------------- |
| Idle trace            | 1.933 ms                   | 1.933 ms  | −0.001 ms         |
| Drag and button edges | 1.834 ms                   | 1.829 ms  | −0.006 ms         |
| Main-thread work      | 1.905 ms                   | 1.891 ms  | −0.014 ms         |

These are medians of three histogram estimates, not raw-sample percentiles. The
evidence CSV includes p50/p95/p99, exact maxima, counts and all five stages. The
smallest bucket boundaries are 0.1, 0.25, 0.5, 1, 2 and 4 ms. Interpolation can
put a quantile above the exact maximum within a bucket. Earlier working-tree
runs have Simulator scheduler outliers: main-thread capture-to-send maxima reach
51.114 ms direct and 26.923 ms touch. The approved-source run has maxima below
2.7 ms; both datasets are retained. There is no repeatable added p95 processing
tail above the proposed 1 ms investigation gate; these results do not establish
zero physical touch latency.

The fixture uses loopback without a PC handshake, backpressure or video decode.
Capture timestamps include scheduled-dispatch lateness. The endpoint is
submission to NWConnection, not transmission, PC receipt or input-to-photon
latency. No engine batching, pacing or network policy changed.

## Idle and video composition

The unprofiled fixture compares hidden, visible untouched, stationary held and
moving controls, first over a static surface and then a production
AVSampleBufferDisplayLayer receiving two preallocated 1280×720 BGRA frames at 60
Hz. This is a compositor exercise, not a decoded PC stream.

| State             | Static process CPU | Moving-video process CPU | Recurring root layouts / draws / input submissions |
| ----------------- | ------------------ | ------------------------ | -------------------------------------------------- |
| Hidden            | 5.22%              | 4.22%                    | 0 / 0 / 0                                          |
| Visible untouched | 0.19%              | 4.95%                    | 0 / 0 / 0                                          |
| Stationary held   | 0.17%              | 5.27%                    | 0 / 0 / 0                                          |
| Moving            | 4.11%              | 7.58%                    | 0 / 0 / 479                                        |

Each interval is approximately eight seconds. CPU is user plus system CPU time
divided by elapsed time, as a percentage of one host core. The first hidden
static interval includes startup work and is not a fair energy baseline. Moving
video submits 480–481 frames per interval. Root draw/layout counters do not
count child-layer composition; moving a thumb updates its child layer. Static
and held results support absence of recurring overlay input work, not a claim of
zero GPU cost. The test-only display link belongs to the video fixture, never
the shipping controls.

Power Profiler explicitly reports that it is unsupported on Simulator. The
combined Time Profiler/Allocations recording and the Allocations-only retry both
fail to acquire the global kperf lock. The Simulator idle suite passes three
further repetitions, but the failed recorder provides no allocation or CPU stack
proof. Raw trace attempts and counters are retained. Do not treat failed
recordings, host watts or these short CPU intervals as sustained iOS energy
acceptance.

## Visual evidence and gaps

The requested review output contains the `shots-48/phase2/` evidence bundle. Its
README identifies final results, raw manifests, superseded captures, board
composition sources and failed gates.

Actual iPhone 16e, iPhone 17 Pro Max and Duo primary-display captures pass both
landscape orientations and appearances. Viewport boards cover small phone, Max,
iPad mini/large/resized and Duo outer/inner/partial-fold geometry, including
editing and largest accessibility text. Increase Contrast captures pass on the
small phone; the Simulator preference was restored afterward. The before image
is the same original illustrative frame without the overlay, not an old
executable or a PC game. Play chrome now follows system appearance: light
surfaces with dark glyphs in Light, and the existing dark palette in Dark. The
appearance follow-up boards are in `shots-48/phase2/light/`. No screenshots are
cropped or retouched.

The iPad runtime rejects programmatic orientation changes in its current
windowing mode. Both actual-iPad capture runs fail with that system error;
viewport fixtures do not replace them. Public Simulator display geometry
controls do not provide fold-angle state, so inner and partial-fold fixtures are
not actual Duo posture proof. The code guards the reserved-region API for
SDK/compiler and runtime availability; hosted Xcode 26.6 and real posture
behavior still need verification.

Real thumb reach, haptic feel, VoiceOver/Switch Control interaction, physical
keyboard navigation, Reduce Transparency/Reduce Motion behavior, physical
touch-to-photon latency and sustained iOS watts remain unverified under
Simulator-only work. These are explicit acceptance gaps.

## Light appearance refinement

The stream host no longer pins dark appearance. Gameplay uses static colors
resolved from system background, label and fill colors. The ellipsis shares the
palette and retains its exact layout code. Native materials in the editor and
stream menu follow the current appearance. A regular system material backs the
light pause/status surface so dark text stays readable over the game; it is
absent during gameplay. Gameplay adds no backdrop blur.

Tests check light glyph contrast of at least 4.5:1 over composited pure black
and white frames, including stick thumbs, pressed controls, Increase Contrast
and Reduce Transparency. They also preserve the dark palette's existing color
values and check that a live appearance change retains held input and all hit
frames without sending input. The final scene captures assert the actual native
control traits and title colors, not just the fixture's requested theme.

All six dark gameplay captures, covering small iPhone, Max and Duo primary
display in both landscape orientations, are byte-identical to the preceding
override captures. Nineteen comparison boards include gameplay, editing and the
per-session controller override menu in both appearances.

Bright and dim sample frames are native fixture illustrations. They are not PC
footage, HDR measurements or proof of every game's legibility. No product
strings are added. The input submission path, frame geometry and previous
latency/idle measurements are unchanged; no new timing or sustained-energy claim
is made.

## Translucency refinement

The later maintainer review asks both appearances to recede. Resting fills now
use 22% light and 18% dark alpha, with 20% outlines and quieter glyphs. Active
controls gain contrast only while held. Glyph edges use cached text and SF
Symbol rasters, preserving bright-frame legibility without live blur, layer
shadows or an additional visible glyph layer. Geometry, input and menu policy
are unchanged. The earlier light-palette screenshots and contrast claims above
are historical; the new boards live in `shots-48/phase2/translucent/`.

The new regression fails on the preceding palettes. The final correctness run
passes 163 tests in 18 suites. Tests cover resting/active alpha, accessibility
overrides, glyph-to-edge contrast over 21 neutral frame levels, native label
edges, raster reuse and held-input continuity. This contrast check describes the
glyph edge, not the control fill or every game's legibility. The small-phone,
Max, iPad and Duo boards include bright and dim sample frames. Actual
device/posture gaps remain as listed above.

The updated idle fixture passes both appearances over static and 60 Hz video
surfaces. Untouched and held controls record zero recurring root layouts, draws
and input submissions. Static visible/held CPU is 0.21–0.26% of one host core;
video visible/held CPU is 6.36–6.66%. These short Simulator intervals do not
prove sustained GPU or device power. The glyphs use cached images and no layer
shadow.

Three paired input-timing runs per load retain matched stage counts and zero
dropped records. Median capture-to-send p95 differences are −0.001 ms idle,
−0.016 ms for input and +0.028 ms under main-thread work. This fixture measures
submission, not UIKit rendering or physical touch latency. Full CSVs and the 22
comparison boards are retained in the translucency evidence folder.

No product strings are added or changed. The native controls retain their
accessibility names and actions. No setting, animation, timer, display link,
engine policy or Version.xcconfig change is introduced.

## Integration ownership

Overlap with concurrent stream work is limited to `StreamPlayback.swift` input
lifetime, `StreamSessionModel.swift` focus/touch state, and `StreamView.swift`
overlay/menu composition. The disconnect disposition and adjusting-quality
policy are unchanged. A quality notice must use overlay placement to avoid
moving held touch targets. The disconnect documentation retains the branch's
existing behavior and will need reconciliation with that separate change.

The per-session override is now approved and committed. Its stream-menu item
appears only while streaming with a physical controller. It enables a separate
touch registration and clears on local stop and remote stream end. Physical
presence comes only from native discovery, never the engine's aggregate activity
flag or the overlay's registration. Tests cover two controllers, partial and
last detach, reconnect, distinct player slots, local/remote teardown and
lifetime reuse.

The earlier source-overlay build and preserved manual patch remain historical
evidence. Final override builds use the working sources directly, without a file
overlay. The reset regression was recorded failing before the fix. Updated
Simulator captures show default mouse-only play, Show/Hide menu items,
concurrent touch play and restoration after the last physical controller
disconnects.

No Mac unit tests, real-device runs, signing changes, push or Version.xcconfig
changes were performed. Normal commit hooks remain enabled.

Next: inspect the boards and measurements, then close the outstanding device,
accessibility and energy evidence before accepting the feature.
