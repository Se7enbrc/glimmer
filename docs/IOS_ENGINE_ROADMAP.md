# Shared engine and iOS roadmap

Maintain one streaming engine for Mac, iPhone and iPad. The engine extraction
and native iOS app are implemented in the 2026.10.8 release branch; the mobile
app is in TestFlight. This page tracks what remains, rather than restarting the
original integration project. Mac requires Apple Silicon and macOS 15.7 or
later; iPhone and iPad require iOS/iPadOS 26 or later.

## Implemented in 2026.10.8

| Area           | Current implementation                                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Shared engine  | One `GlimmerEngine` source tree for transport, pairing, decoding, pacing, audio, input policy, quality and session recovery.         |
| Native clients | Mac app and iPhone/iPad launcher, pairing, Settings and stream controls, with native lifecycle and presentation adapters.            |
| Input          | Physical controllers, per-game layouts, remappable shortcuts, controller mouse, keyboard/mouse input and an editable touch gamepad.  |
| Presentation   | iPhone landscape streaming, iPad window/orientation support, capability-based codec/HDR selection and external-display presentation. |
| Distribution   | Signed/notarized Mac candidates and separate, attested iOS archive/sign/upload workflows with beta and production flavours.          |

Implemented does not mean accepted on every device. The
[release acceptance checkpoint](release-acceptance/2026.10.8.md) names the
actual candidate, tested sources and remaining owner checks. Beta and production
iOS builds use Apple logs/reports without custom diagnostic recording; beta's
adaptive-quality default does not make it an App Store production archive.

## Keep one owner for shared behavior

Use [repository ownership](APPLE_REPOSITORY.md) and the
[architecture map](ARCHITECTURE.md#shared-engine-and-native-adapters) before
moving code. Mac consumes the engine framework; iOS references the root Swift
package. There is no copied iOS engine or independent remote pin.

- Shared code owns protocol semantics, configuration, bounded media/input
  queues, recovery and ordered session transitions.
- Native adapters own windows/scenes, display attachment, audio routes,
  permissions, storage environment and OS lifecycle notifications.
- Keep controller semantics and feedback policy shared. Consolidate remaining
  native adapter duplication only where platform ownership and teardown match.
- Keep Mac-only raw HID, IOReport and private receive-symbol paths out of iOS.
  Preserve the public iOS receive path and artifact boundary audits.
- Use existing backend and session contracts. Add no speculative service
  registry, binary framework distribution or extra modules without a consumer.

Both clients use VideoToolbox and `AVSampleBufferDisplayLayer`. No Metal
renderer, engine fork, vendor controller SDK or patched Sunshine is planned.

## Remaining validation

Record hardware results against the tested artifact and configuration. A
Simulator pass proves its assertions, not physical input latency, energy use or
colour fidelity.

| Area            | Evidence to retain                                                                                                                |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Controllers     | Backbone and another supported controller: chord capture, focus loss, detach/reconnect, held-input release and available haptics. |
| Audio/lifecycle | Speakers and headphones, interruptions, media-services recovery, background grace, lock and repeated reconnect/stop.              |
| Display         | PC mode, encoded dimensions, visible aspect and desktop restoration; HDR/codec and external-display results by device.            |
| Resources       | Sustained cadence, latency trend, memory after repeated teardown, thermal state and energy under recorded stream conditions.      |
| Accessibility   | VoiceOver, Dynamic Type and input alternatives on the affected launcher, menu and editor surfaces.                                |

These are a retained validation backlog, not a fresh full matrix for each push
or candidate. Core/security checks qualify the exact source. Comprehensive
render/UI and user journeys are one resumable feature-release pass; select
changed, failed or newly affected cases and keep other receipts at their tested
source. The owner chooses the relevant hardware follow-up. See
[verification and acceptance](CONTRIBUTING.md#hosted-verification-and-local-reproduction).

## Performance work

Use optimized builds and a repeatable PC scene. Record device/OS, codec,
resolution, frame rate, bitrate, network, brightness, audio route and
controller. Start with a 60 fps SDR stereo baseline before evaluating higher
modes. Use [profiling](PROFILING.md) on Mac and
[Apple reports and tools](../iOS/docs/DIAGNOSTICS.md) on iOS.

A performance change should compare the affected path before and after:

- Track steady-state cadence and latency, not just average FPS or successful
  launch. Separate packet arrival, decode and presentation evidence.
- Measure allocations, retained buffers and memory after teardown. API names
  alone do not prove a zero-copy path.
- Compare CPU/GPU power or energy with identical settings, including thermal
  behavior over a relevant sustained session. Record numerical budgets only
  after measuring a device tier; do not invent universal limits.
- Preserve bounded queues, release edges and stale-callback rejection. No
  per-packet tasks, growing backlog or keepalive work after stop.
- Reduce unnecessary work before reducing fidelity. Quality changes need bounded
  recovery and must not oscillate through repeated reconnects.

The former extraction plan's soak durations and proposed budgets were planning
targets, not completed measurements or mandatory repeat gates. Revisit them only
when the change or a reported problem calls for that evidence.

## Next engineering and distribution work

Keep remaining work scoped to a demonstrated gap:

1. Close reported controller, lifecycle and stream-quality issues with focused
   regression tests and the relevant hardware follow-up.
2. Consolidate duplicated native controller/feedback adapters where shared
   ownership is practical, preserving platform-specific lifetimes.
3. Improve release tooling for concurrent Mac/iOS delivery bookkeeping and
   authoritative Apple build-number selection without weakening source gates.
4. Progress TestFlight access/review and a production-flavour App Store
   candidate separately from Mac promotion. Preserve accepted Mac artifact
   bytes.
5. Explore tvOS or visionOS only when a real client project starts. Neither is
   currently supported; shared code alone is not an app port.

The broader [product roadmap](ROADMAP.md) covers priorities. Start changes with
[the contribution guide](CONTRIBUTING.md), and keep release decisions in
[the release procedure](RELEASE.md).
