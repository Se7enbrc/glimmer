# Touch controls implementation and proof

Review the native touch controls against the approved
[design](TOUCH_CONTROLS_DESIGN.md). The implementation is ready for code review,
but the complete Phase 2 acceptance evidence is not available: actual iPad
rotation, Duo inner/partial-fold postures, assistive interaction and device
energy still have gaps.

## Implemented behavior

- Touch gameplay starts with the first usable frame without a physical
  controller. Physical admission retires touch input before registering the
  controller. Explicit stream menus remain paused through handoff.
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
remapping, genre detection, cloud layouts, opacity settings and a second
renderer remain excluded.

## Correctness and build

The Simulator warning-as-error build succeeds with Swift 6 strict concurrency.
The approved-source correctness run passes 155 tests in 18 suites, including
ownership, timestamps, unchanged-sample suppression, stale generations, physical
admission ordering, focus rearming, native accessibility activation/release,
geometry, persistence and session behavior. Eleven existing native UI tests also
pass, covering launcher, settings, recovery and stream states. The final scene
capture tests also assert identical control frames before and after entering
mouse mode.

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
executable or a PC game. Play chrome stays dark in both system appearances as
approved. No screenshots are cropped or retouched.

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

## Integration ownership

Overlap with concurrent stream work is limited to `StreamPlayback.swift` input
lifetime, `StreamSessionModel.swift` focus/touch state, and `StreamView.swift`
overlay/menu composition. The disconnect disposition and adjusting-quality
policy are unchanged. A quality notice must use overlay placement to avoid
moving held touch targets. The disconnect documentation retains the branch's
existing behavior and will need reconciliation with that separate change.

Concurrent manual Show/Hide touch controls and simultaneous physical/touch
registration edits are preserved unstaged in four files. They are not part of
the approved automatic-handoff commits. Earlier native-UI captures reflect that
working-tree variant where a physical controller is selected. The final
approved-source build uses Swift's file overlay for the four affected sources,
matching their committed contents without changing the working tree. Binary
symbol inspection confirms the manual toggle is absent; the approved native-UI
suite passes separately. `manual-override-review.patch` isolates the retained
difference.

No Mac unit tests, real-device runs, signing changes, push or Version.xcconfig
changes were performed. Normal commit hooks remain enabled.

Next: inspect the boards and measurements, then close the outstanding device,
accessibility and energy evidence before accepting the feature.
