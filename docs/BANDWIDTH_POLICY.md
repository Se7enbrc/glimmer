# Adaptive bandwidth policy

Review the shared bandwidth decisions and run the paired Mac/iPhone trials below
before enabling them in a release candidate. These numbers implement the
approved 2026.10.8 experiment; they are not measured claims about radio capacity
or image quality.

## Integration boundary

`BandwidthPolicy` is a pure value. It accepts current destination/path facts,
accepted-format demand, device state and fresh transport windows. Both clients
use the same decisions. `RouteBitratePolicy` is a compatibility alias for the
Mac launch calculations: wired/Wi-Fi boosts, codec/custom semantics, caps and
the Mac PHY gate retain their previous arithmetic.

The session owns the policy and drives the resume-only bitrate actuator from the
1 Hz frame watchdog. `BandwidthHealthSampler` turns the always-live receive
counters (pre-FEC loss, FEC recoveries, unrecoverable frames, 50/100 ms gap
events, decoder-backlog overflows, received bytes) and fresh matched-ACK RTT
samples into one-second windows. The receive path folds its counts about every
two seconds; a tick between folds reuses the last fold's fractions, and two
missed folds mark the window unavailable. No window spans a transition.

`submission(at:)` hands at most one request to `request(rate:reason:)`. Accepted
means queued; only a completed `applied` transition confirms the rate. Deferred
and failed requests retry after the minimum dwell. Rate changes made by another
owner (the watchdog downshift tier, an ordinary reconnect's route ask, a resize)
are adopted and count as changes for dwell.

`BandwidthSignals` (shared engine) supplies path facts on Mac, iPhone and iPad:
an event-driven `NWPathMonitor`, a destination route lookup that marks facts
`destination` when the kernel's route to the PC matches a current interface,
thermal and Low Power notifications, and on iPhone the data-service RAT hint.

### Switch

`AdaptiveBandwidth.defaultsKey` (`adaptiveBandwidthEnabled`) is read once per
stream. Its registered default is on for beta builds only: TestFlight and Xcode
installs on iOS, diagnostic builds and `GlimmerUpdateChannel=rc` Macs. The
Diagnostics toggle (iOS Settings, Mac Diagnostics pane) overrides it for
before/after trials. Off keeps the configured launch rate and never actuates;
decisions are still recorded when telemetry is on.

### Owner decisions

- Start rates at the reference format: Wi-Fi/wired 40, cellular/unknown 20, Low
  Data Mode at most 9 Mbps. iPhone and iPad use them as the ANNOUNCE rate when
  the switch is on. The Mac keeps its launch ask and adapts from it.
- A protective cut follows three bad seconds (or two severe episodes in ten).
- Low Data Mode caps the rate at 9 Mbps on every interface; play continues.
- Wi-Fi to cellular keeps playing; the new path reseeds from its own prior.
- iOS seeds from current conditions, never from remembered sessions.
- Low Power Mode is recorded and changes nothing.
- Every reduction stays recoverable: backoff is finite and decays.

### Flap guard

`BandwidthFlapGuard` uses session uptime, so it bounds the real change rate.

| Constant                    | Value   | Why                                                             |
| --------------------------- | ------- | --------------------------------------------------------------- |
| `minDwellSeconds`           | 10 s    | Each change freezes play ~0.2–2 s; one per 10 s caps that cost. |
| `stepUpDwellSeconds`        | 60 s    | Increases only add fidelity, so they wait longer than cuts.     |
| `failedStepUpWindowSeconds` | 300 s   | A cut this soon after an increase marks it failed.              |
| `baseBackoffSeconds`        | 300 s   | Clean time before the first retry after a cut.                  |
| `maxBackoffSeconds`         | 2,400 s | Failed step-ups double the wait up to here, never further.      |

An increase that survives the failure window, or proves itself in 120 clean busy
seconds, decays the backoff to base. Path replacement resets it. The guard state
(`lastChangeAt`, `lastIncreaseAt`, `lastAttemptAt`, `backoffSeconds`,
`failedStepUps`) is part of every `BandwidthDecision` ledger row.

## Changed files

| Area                     | Files                                                                                                                                                                                                     |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pure policy and contract | `BandwidthFacts.swift`, `BandwidthPolicy.swift`, `BandwidthPolicy+Evidence.swift`, `BandwidthTrainEvidence.swift`, `RouteBitratePolicy.swift`                                                             |
| Native facts             | `BandwidthSignals.swift`, `BandwidthInputs.swift`, shared `StreamDestinationProbe.swift`, Mac compatibility alias, `NetworkClient+Endpoints.swift`                                                        |
| Session wiring           | `StreamPlayback.swift`, `SessionAdapters.swift`, `StreamSession.swift`, `StreamSession+Public.swift`, `StreamSession+Connect.swift`, `StreamSession+FrameWatchdog.swift`, `StreamSession+Bandwidth.swift` |
| Ledger                   | `GlimmerEngine/Diagnostics/BandwidthDecision.swift` through the existing shared recorder                                                                                                                  |
| Verification             | Shared policy/actuator test files, both Xcode projects, `scripts/check-ios-boundary.py`                                                                                                                   |

## Policy table

Rates are decimal Kbps. The reference format is 1920 × 1080, 60 fps, H.264, SDR.

| Condition                               | Number                                                                                                                             | Reason                                                                                      |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Wi-Fi/wired fresh start                 | 40,000 at reference                                                                                                                | Approved current-environment prior; no remembered iOS session rate.                         |
| Cellular/unknown fresh start            | 20,000 at reference                                                                                                                | Approved cellular prior; unknown does not mean local/unmetered.                             |
| Resolution/FPS/codec                    | Existing `StreamQuality` resolution curve, 0.75 exponent above 60 fps, 0.80 for accepted HEVC/AV1                                  | Reuses shared math, normalized to mobile 1080p60 rather than desktop harness anchors.       |
| HDR                                     | Explicit format fact; no additional multiplier                                                                                     | Neither report supplies a validated HDR-only uplift. Validate separately before adding one. |
| Low Data Mode                           | At most 9,000, on every interface                                                                                                  | Within the approved 8–10 Mbps experiment; play remains allowed. Lower demand/bounds win.    |
| Custom/saver/device/encoder/data limits | Custom is exact ceiling; saver starts at 1×; all verified ceilings apply                                                           | Never add route headroom to an explicit budget or let the old floor override a lower cap.   |
| First upward trial                      | 60 clean active seconds with fresh PHY/train corroboration; otherwise 120 busy seconds                                             | Current evidence earns a small trial. No PHY is not a permanent disqualification.           |
| Subsequent trial                        | 120 clean active seconds                                                                                                           | The previous applied rung must prove itself before another increase.                        |
| Busy evidence                           | At least 30 seconds in the last 60 at ≥70% of applied ask; without PHY/train, 120 busy seconds                                     | Static scenes and encoder caps do not demonstrate spare capacity.                           |
| Trial size                              | 1.2× with corroboration; otherwise 1.1×                                                                                            | Never jump directly to a burst estimate.                                                    |
| Above-start headroom                    | Up to 2× start, only Wi-Fi/wired with all-window RTT p95 ≤5 ms, p95−p10 ≤2 ms and jitter p95 ≤1 ms                                 | Operational wired-class evidence, not an interface relabel or cellular RAT claim.           |
| Promotion health                        | ≥90% coverage; pre-FEC loss <0.1%; recovered frames <0.5%; zero unrecoverable frames/backlog; gaps ≤50 ms; local queue delay ≤2 ms | Missing, stale, reset and invalid samples do not accrue healthy time.                       |
| RTT health                              | Median rise ≤max(3 ms, 25% baseline), p95 rise ≤max(10 ms, 50% baseline)                                                           | Constant propagation delay is not congestion.                                               |
| Baseline                                | Provisional p10 after ≥10 ACKs across ≥2 seconds; then lowest healthy ten-second median in five minutes                            | TCP startup and live ENet evidence remain separate. Distress freezes baseline updates.      |
| Protective cut                          | Three bad active seconds, or two severe episodes in ten seconds, with transport corroboration                                      | Distinguish transport damage from local decode/scheduling stalls.                           |
| Cut size                                | Proven current-generation rung, otherwise 0.6× applied                                                                             | Decisive protection calculated from the real request. No recursive launch gate.             |
| Change dwell                            | See the flap guard: 10 s between any changes, 60 s before an increase                                                              | Bounds disruption in real time without delaying a protective cut for long.                  |
| Recovery                                | 300 clean active seconds; failed trials double to a finite maximum of 2,400                                                        | No permanent disablement. A successful 120-second trial clears the penalty.                 |
| Thermal                                 | Inhibit increases while serious/critical; 300 clean seconds after thermal stress. Low Power Mode changes nothing                   | Bitrate is not a substitute for reducing pixel decode work.                                 |
| Foreground                              | No learning in background; discard evidence and requalify on return                                                                | Background grace is owned by the existing lifecycle, not a second timer.                    |

A default-path hint cannot authorize promotion. Fresh train corroboration needs
three distinct accepted frames across at least one second, newest at most five
seconds old, maximum/minimum rate ≤1.5, and uses 0.7× p20 IP delivery only as a
trial budget. Comparison uses matching measured IP/encoded byte layers. No train
or PHY observation establishes downlink capacity by itself.

## Inputs and recording

The shared `BandwidthSignals` adapter owns an event-driven `NWPathMonitor`,
current data-service RAT classification, thermal and Low Power notifications. It
stops observation in the background and at final disposal. It uses no SSID,
carrier/subscriber identity, location permission, radio scan, throughput test or
background polling. RAT and link quality remain qualitative facts, not Mbps
multipliers or permanent caps.

The destination route/MTU lookup and TCP sampler are shared with Mac. The UDP
route lookup sends no traffic. iOS now supplies the existing bounded prelaunch
sampler; its extra wait is at most 400 ms. Only a qualifying prelaunch window is
recorded as prelaunch evidence. The existing Mac launch/RTT and PHY gates
remain. The public iOS session uses the destination route for remote packet-size
policy without adopting the Mac absolute-RTT bitrate discount. Unknown, cellular
and other-interface hints retain conservative packet sizes until destination
evidence is available.

A monitor update is `defaultPath` provenance until the destination route lookup
(the kernel's choice for the PC's address, which the media sockets share) names
one of its interfaces; then it is `destination`. Every monitor event bumps the
generation, so a same-interface route replacement invalidates evidence. A
tunnel's underlay stays unknown.

`BandwidthDecision` and `BandwidthLedger` serialize through the existing shared
recorder. They separate display demand, base, every supplied ceiling, target,
applied/proven rates, generation, monotonic health windows, confidence, retry
eligibility and actuator outcome. Optional fields remain absent. The context has
slots for distinct app/engine revisions, Sunshine/encoder configuration,
connect/media clocks, interruption lengths and byte/transition totals.
Integration must supply those actual values; an unknown engine revision is not
the app revision.

Live windows come from `BandwidthHealthSampler` (see the integration boundary).
Local queue delay, rising-queue trend, jitter percentiles and packet trains are
not produced yet; absent values never block health, so the 2× Wi-Fi headroom
(which needs jitter p95) stays unearned until a producer exists.

## Deterministic verification

The same `BandwidthPolicyTests.swift` and `BandwidthActuatorTests.swift` sources
are explicitly registered in the Mac and iOS targets. Both public-client
fixtures feed identical immutable facts and compare complete decision values.
Tests use numeric clock advancement and explicit continuation barriers, with no
sleeps. The iOS boundary audit requires these exact shared files, rather than
allowing arbitrary outside sources.

Coverage includes reference starts, codec fallback and bounds, null PHY earning
2×, qualification equality, static traffic, NaN/missing/stale/reset evidence,
rollover/reorder credit, frozen RTT baseline, severe FEC/gaps, local overload,
below-base and Low Data recovery, 40-minute retry eligibility, path replacement,
thermal/foreground/Low Power recovery, and deferred/rejected/stale actuator
work. Mac execution remains required in hosted verification: this task compiles
Mac tests but deliberately does not run them.

Local verification on Xcode 27.1 passed the compile-only Mac gate,
`nice -n 15 taskpolicy -c utility make test-build`, without compiler warnings.
Mac unit tests were not executed. Simulator verification passed the full iOS
suite (179 tests in 20 suites), then the affected boundary suite (10 tests) and
actuator suite (4 tests) after the final regression additions. Commands used
`nice -n 15 taskpolicy -c utility make ios-test` with the explicit iPhone 17 Pro
iOS 26.0 Simulator destination. No real-device, radio, image-quality or energy
claim follows from these results.

`make check` passed Actionlint, SPDX, strict SwiftLint and both source-boundary
audits, but the script gate did not pass under the heavily loaded local machine.
A complete run executed 394 tests: 37 subprocess timeouts and one temporary
fixture cleanup error, with no assertion failures. The errors were in release,
signed-commit and signing fixtures; the changed iOS boundary tests passed. A
focused rerun reproduced `test_ci_release` timing out after ten seconds in its
mocked `checks` phase; neither that fixture nor its release script changed here.
Rerun the complete unchanged gate on an unloaded machine before approval. Do not
raise timeouts or treat the successful compile and Simulator runs as a
substitute.

## Required before/after trials

1. Record exact baseline/candidate app and engine revisions, Sunshine version,
   encoder/configuration, codec/chroma/HDR, output dimensions/FPS, FEC,
   peripherals, helper state and telemetry state. Use unmodified supported
   Sunshine. Begin with shadow-only observations; do not enable elective
   renegotiation yet.
2. Alternate baseline/candidate order for at least three matched 15-minute runs
   per scenario. Replay static text, grain/foliage, rapid pans and action. Match
   brightness and thermal starting state. Compare blinded pictures as well as
   timing; a higher requested rate is not evidence of better output.
3. Test wired Mac, strong and weak/congested Wi-Fi Mac, iPhone 17 Pro 1080p60
   SDR Wi-Fi, and cellular through known direct/relay tunnel setups. Compare
   iPhone's current 20 Mbps with 40/20 startup and 9 Mbps Low Data candidates.
   Separately validate 120 fps/native resolution, HDR, codec alternatives and
   iPad hardware.
4. Add controlled capacity cuts/removal, isolated/burst loss, FEC-recovered
   loss, pure added RTT, local receive starvation, decoder overload, static
   scenes and encoder caps. Exercise Ethernet undock, AP roam,
   Wi-Fi→cellular→Wi-Fi, same-type route replacement, constrained toggles,
   dual-SIM data-service changes and tunnel restarts. Confirm current cost facts
   and over-budget handoff duration.
5. After safe-resume acceptance, run 60–90 minute recovery soaks through
   repeated failed trials and the 40-minute retry cap. Verify fresh ANNOUNCE
   rate, same PC app, no cancel, no duplicate recovery, released input and
   recovery after every temporary reduction. Include stop/takeover/path
   replacement during negotiation.

Score total disturbed time including renegotiation freezes, >50/100 ms arrival
and presentation gaps, post-FEC loss, decode/presentation drops, audio
underruns, input-disabled intervals and time at each rate. Report decision
latency separately from application latency, with connect-start and first-media
anchors. Seed acceptance guards are no material clean-path image regression, no
additional clean-path stalls, p95/p99 latency increase ≤max(1 ms, 10%), and
controller overhead below 1% of a CPU core and power measurement noise. The
proposed safe-resume p95 <2 seconds remains a trial goal, not an established
capability.

On Mac compare `gpu_power_w` and `package_power_w`, CPU, wakeups and memory. On
phone compare energy, battery drain and thermal duration at fixed brightness;
leave unavailable watts absent. Measure actual interface bytes, handoff overage
and Low Data usage; an ANNOUNCE ask is not a carrier spending cap. Repeat
telemetry off/on/on/off and verify identical decisions. Simulator cannot
establish radio throughput, energy, picture quality, timestamp accuracy or safe
PC resume.

Continue with [the profiling procedure](PROFILING.md) and record the acceptance
results before any release candidate.
