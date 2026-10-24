# Bitrate transitions

Use the session's bitrate actuator to renegotiate the current game without
issuing `/cancel` or `/launch`. The transport is replaced; the native surface,
display layer and input registrations remain owned by the same session.

## Policy contract

```swift
let admission = await session.request(rate: 30_000, reason: .congestion)
```

`rate` is the requested video bitrate in Kbps. Reasons are the closed values
`congestion`, `recovery`, `trial` and `rollback`.

- `accepted` reserves the existing session recovery owner before returning. It
  does not mean Sunshine has applied the rate or video has resumed.
- `deferred` means recovery, launch, wake verification or native availability
  prevents a transition, or this session has not owned and presented the game.
  Nothing is queued. Reconsider fresh evidence later.
- `rejected` means an invalid rate, the current applied rate, or a stopped
  session. No transport or PC request occurs.

An accepted request clears `lastBitrateChange`; read it for completion.
`appliedBitrateKbps` changes only after the replacement submits its first frame
to the renderer. It records the rate sent in ANNOUNCE, not an independently
measured encoder output rate. This API does not estimate capacity, select rungs,
or authorize automatic promotions. The caller supplies a rate already bounded by
its validated format and policy.

Native adapters call `setBitrateChangesAvailable(false)` on inactivity or sleep
and restore availability on foreground or wake. An active transition interrupted
by that boundary stops locally, preserving the game. Ordinary iOS background
grace remains unchanged when no transition is underway. A user stop during a
transition also leaves the game running; normal Mac stop semantics return after
a successful transition.

## Transport and presentation

The first attempt has no recovery backoff. Input releases precede transport
teardown. A 5 ms PCM ramp fades the old output, with a 20 ms scheduling
allowance plus the output adapter's reported latency before disposal; the new
output ramps in over 5 ms. The existing “Reconnecting…” indicator appears only
if the transition is still pending after 750 ms.

Each attempt fetches `/serverinfo`, requires the same running app, calls
`/resume`, and creates a fresh RTSP connection. `RtspClient` performs OPTIONS,
DESCRIBE, SETUP for audio/video/control, ANNOUNCE and PLAY; `SdpBuilder` writes
the requested `x-ml-video.configuredBitrateKbps`. An idle PC or a different app
ends recovery without launching anything. Resume rejection never falls back to
launch. `NativeBackend.stopConnection` closes local media/control transport;
RTSP interruption cancels its socket and sends no TEARDOWN or game-quit command.

The existing five-attempt, 30-second awake budget bounds recovery. Replacement
video has at most the existing ten-second first-frame envelope, also bounded by
the episode deadline. Failed attempts retain the frame; exhaustion uses the
existing terminal reconnect UX and leaves the game running.

## Evidence and acceptance

The privacy-safe `bitrate_change` diagnostic and `lastBitrateChange` contain old
and requested rates, reason, outcome, transition ID, attempt count, named leg
durations, video gap, audio gap and input-disabled duration. Missing media
timestamps remain unavailable. Audio may enrich the same transition ID for up to
one foreground second after video returns, without holding input. Video measures
last old renderer submission to first new submission; audio measures PCM
render-quantum timestamps. Neither proves panel scanout, speaker timing or
audible equivalence.

The deterministic fixture supplies a 120 ms video gap and a 20 ms input pause;
its transport replies are instantaneous and it has no audio device. Those are
synthetic boundary checks, not measured reconnect performance. PCM tests check
the ramp and sustained silence; fake-PC tests check resume-only legs, admission,
input release, cancellation and failure. Simulator screenshots exercise the
retained surface and delayed indicator without a PC video feed.

Real interruption is the release/fade allowance plus local teardown, HTTPS
status/resume, RTSP/control setup and first-frame delivery. For planning, allow
roughly 0.2–2 seconds on a healthy link; this is an unmeasured estimate, not an
acceptance result. Expect a visible freeze and audio/input interruption; no
subsecond guarantee is established. Sunshine may wait for its old control
session to expire after the local socket closes; that can extend the freeze into
the retry budget and must be measured. Before enabling elective promotions,
measure supported unmodified Sunshine versions and encoders, verify that
prep/undo commands and the game process do not restart, and compare
audio/video/input gaps across both clients. Include same-app takeover, failed
resume, sleep/wake and background interruption. Mac window/Space preservation
and audible pop-free output still require authorized hardware acceptance.

Use [profiling and telemetry](PROFILING.md) for the real-stream comparison.
