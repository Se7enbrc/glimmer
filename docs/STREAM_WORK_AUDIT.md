# Work performed during streaming

This audit covers the rc.17 (`cb2562a4`) to rc.19 (`591dbe68`) controller
regression and the recurring work reachable from the iOS and Mac stream
lifecycles. It follows callback installation, input delivery, timers,
notification/KVO subscriptions and UI refreshes in `Glimmer`, `iOS/Glimmer` and
`GlimmerEngine`. It is a source audit with deterministic input tests, not a
physical-device power measurement.

## Confirmed failures and changes

| Finding                                                                  | Evidence                                                                                                                                                                                                                                                                                                                                            | Change                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| High, confirmed: the stream used the layout editor's input lease.        | At rc.19, `ControllerLayoutCapture.swift:211` cleared the extended-gamepad callback; `IOSControllerLayouts.swift:50` and `MacControllerLayouts.swift:100` installed the lease. Its physical callback read legacy system-mapped values, whose publication can follow that callback. The physical-first regression ended with X = 16384 instead of 0. | The stream forwarders install their own callbacks. Layout configuration only prepares readers and mapping/chord policy. Recording leases are exclusive to the editing UI.                                                |
| High, confirmed: build 8 trapped off the main actor.                     | The owner's two Organizer reports, iPhone OS 27.0.1, build 8, 18:27–18:28, identify `closure #1 in closure #1 in ControllerLayoutInputLease.init` from `_GCDevicePhysicalInput handleGamepadEvent:`. This is the nested-closure isolation defect corrected by `d7096a71`.                                                                           | Keep the rc.19 explicit Sendable callback boundary. New stream callbacks are also explicitly Sendable and call only synchronous, nonisolated readers and locked input state.                                             |
| Medium, confirmed: launcher callbacks could return during an iOS stream. | At rc.19, `LauncherGallery.swift:93` stopped on the stream edge but restarted on foreground and hotplug without checking the stream. `LauncherView` also kept its discovery/log observer active under the stream cover.                                                                                                                             | One availability gate handles appearance, stream, foreground and hotplug changes. Retired menu tasks cannot open a menu. Mac launcher navigation and repeats stay stopped for the entire session, including Mini Player. |
| Medium, confirmed: Mac controller diagnostics survived stream start.     | At rc.19, `ControllerInputTestView.swift:55` discarded ownership without removing the callbacks. `controllerMonitorResumesAfterTheStreamReleasesItsHandlers` failed with both the legacy callback and raw-HID UI observer still present.                                                                                                            | Suspend diagnostic handlers, connection observers, HID retains and background-delivery ownership. Pause the diagnostic 30 Hz timeline. Preserve a stream callback that has already taken ownership on its capture queue. |
| Medium, confirmed: DualSense input queued unnecessary main-thread work.  | At rc.19, `DualSenseHID.swift:390` dispatched unconditionally. `streamHIDChangesDoNotScheduleDiagnosticDelivery` observed a queued UI task with `onChange == nil`.                                                                                                                                                                                  | Queue UI delivery only with an active diagnostic observer. A generation check rejects a queued delivery after observer replacement. Synchronous stream input remains independent.                                        |

An additional confirmed Mac finding was `DualSenseRouting.swift:157` at rc.19:
both HID and GameController face-button edges scheduled a main-queue deadline
after the device was already bound. The new
`onlyUnboundDualSenseInputSchedulesBindingWork` test observed those unnecessary
tasks before the fix. Bound routes now bypass resolution; the same test retains
both scheduling paths for an ambiguous, unbound controller pair.

## Allowed controller handlers

| Stream configuration                                                 | Installed input handlers                                                                                                                                           | Queue and lifetime                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| System mapping with physical shortcuts                               | Extended-gamepad callback for game state; physical callback observes only configured chord elements. Unrelated physical axes/buttons do no sampling or forwarding. | Both use the stream's serial capture queue. The forwarder's registration/epoch rejects stale callbacks. |
| System mapping without physical shortcuts, or legacy-only controller | Extended-gamepad callback only.                                                                                                                                    | Stream capture queue; no main-actor delivery.                                                           |
| Custom layout                                                        | Physical callback only, applying the configured mapping and shortcut detector.                                                                                     | Stream capture queue; no legacy gameplay callback.                                                      |
| Generic raw HID on Mac                                               | Normal stream report handler, including configured extra-button indexes.                                                                                           | HID run loop; no `acquireLayout` subscription.                                                          |
| DualSense raw HID on Mac                                             | Synchronous stream centre-button handler and controller binding.                                                                                                   | HID run loop; no diagnostic UI dispatch without an observer.                                            |
| Layout recording/navigation                                          | UI-only capture while editing owns input; Mac suspends stream input before the editor takes ownership. iOS presents editing outside the streaming cover.           | Editing lifecycle, never interposed on active game forwarding.                                          |

`ControllerStreamHandlers` only installs the forwarder's callbacks. It owns no
lease, previous handler, UI observer, validity gate or restoration chain. Its
small timestamp clamp keeps independently timestamped profiles from reversing
chord time. Forwarders restore queues on relinquishing ownership. The chord
detector passes ordinary buttons immediately; its existing 400 ms timer
recognizes a complete shortcut and suppression starts only when that shortcut
latches.

## Per-event and per-frame work retained

| Area and source                                                                                               | Work                                                                                                                                                                          | Why it remains                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IOSControllerCapture`, `ControllerForwarder`, `ControllerStreamHandlers`, `InputCore+Layouts`                | Read the authoritative profile, register/focus gate, mapping, chord observation, touchpad routing, release ledger and encoding.                                               | Required input. No main-queue hop in game delivery.                                                                                                                     |
| `HIDGamepadCapture`, `DualSenseHID`, `DualSenseRouting`                                                       | Assemble complete HID reports; merge otherwise unavailable centre/extra buttons, battery and feedback state. Binding resolution schedules work only around candidate matches. | Required device support; diagnostic delivery is detached during streaming.                                                                                              |
| `InputBatcher`, `InputSendThread`, `InputCallbackProbe`                                                       | Preserve button edges, merge pending axes, encrypt/send; wake the sender for queued work or a pending flush. Probe callback responsiveness only under backpressure.           | Required transport and final-neutral delivery. The sender sleeps when idle; the probe is a congestion safeguard, not a UI observer.                                     |
| `ControllerMotion`, `ControllerHaptics`, platform sensor adapters                                             | Sensor callbacks at the PC's requested rate, feedback callbacks and demand-driven output writes.                                                                              | Enabled only for requested sensor/feedback capabilities; stopped on loss of ownership or teardown.                                                                      |
| `TouchGamepadCapture`, `TouchGamepadView`, iOS touch/mouse/keyboard adapters; Mac `InputForwarder+StreamView` | Input gestures and native events, mapping and pointer capture. Touch controls detach when unnecessary; no animation loop drives them.                                         | Required active input methods.                                                                                                                                          |
| `VideoRtpReceiver`, `RtpVideoQueue`, `VideoDecoder+Decode/+Session`                                           | Socket receive, FEC/reordering, frame assembly, VideoToolbox submission/completion, statistics and recovery signals.                                                          | Required video and quality safeguards. No diagnostic UI callback attached per frame.                                                                                    |
| `FramePacer+Tick/+Submit`, `VideoDecoder+Pacing`                                                              | Private display-link ticks, due-frame selection, layer enqueue and presentation accounting.                                                                                   | Required presentation. The deficit timer exists only while its measured recovery mode is active.                                                                        |
| `RtpAudioReceiver`, `AudioPacketWorker`, `AudioDecoder`, `IOSAudioOutput`                                     | Packet/decode work, PCM ring writes, render callbacks/observation, resampling and playout clock accounting.                                                                   | Required audio, synchronization and silence/stall recovery. The iOS render observer is audio bookkeeping, not UI diagnostics.                                           |
| `StatsCollector`, `TelemetryCounters`, receive/audio instrumentation                                          | Small counters and rolling samples in existing callbacks.                                                                                                                     | Feed actual bandwidth/pacing/recovery policy and visible stream statistics. Removing these would change safeguards without measurements.                                |
| `FrameTimingTracker`, `InputTimingContext`, `TelemetryFrameTrace`                                             | Optional frame/input latency and trace recording.                                                                                                                             | Explicit diagnostic capture only; iOS production compiles out input timing. Mac input timing returns immediately when no tracker exists. No UI dispatch in these paths. |

## Timers and background loops retained

| Cadence / condition                                                                       | Owner                                                                                                                            | Purpose and stopping condition                                                                                                              |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Display cadence; recovery frame interval only when active                                 | `FramePacer+TickThread`, `FramePacer+DeficitTimer`                                                                               | Presentation and measured display-governor recovery; session/display teardown cancels both.                                                 |
| 10 ms, private audio queue                                                                | `AudioDecoder+Worker.installRenderMonitor`                                                                                       | Render-clock observation and stalled-output recovery; cancelled with audio output.                                                          |
| 50 ms; 1 s; 2 s                                                                           | `StreamSession+Watchdog`, `+FrameWatchdog`, `+PresentMetric`                                                                     | Presentation recovery; dead-video detection and bandwidth evaluation; environment windows and pacer adaptation. Stopped with the session.   |
| Transport deadlines, ACK/retransmit wakes, 100 ms app ping and 500 ms idle transport ping | `EnetControlChannel+ControlLoop`, `ControlTransport`                                                                             | Keepalive, reliability and peer failure detection. Sender and receive workers block between work/deadlines.                                 |
| Pending input flush, nominal 1 ms; one-shot 400 ms chord dwell                            | `InputBatcher`, `InputCore+Layouts`                                                                                              | Flush merged axes and recognize shortcut holds; no idle repeating chord timer.                                                              |
| 120 Hz iOS / 20 Hz Mac while controller mouse moves                                       | `InputCore+Mouse`                                                                                                                | Continuous pointer movement from a held stick; cancelled at neutral or focus loss.                                                          |
| 250 ms while reconciliation is needed                                                     | `InputReconciliation`, `InputForwarder+Reconciliation`                                                                           | Recover held/missed releases; stops when no input obligations remain.                                                                       |
| 30 s with registered controllers                                                          | `ControllerBattery`                                                                                                              | PC-facing battery reports; detached/paused with controller ownership.                                                                       |
| 250 ms only with visible iOS stats                                                        | `StreamStats`                                                                                                                    | Requested stats UI and backdrop contrast; hiding cancels the timer and backdrop sampling.                                                   |
| 250 ms during Mac session                                                                 | `MacSessionStats`, `StatsOverlayRefresh`                                                                                         | Stream-stuttering banner, stream history and one-shot link audit. Detailed HUD enrichment/backdrop sampling requires a visible HUD.         |
| 1 s during explicit telemetry capture; 250 ms while a trace/log sink exists               | `TelemetryExporter+Capture`, `DisplayTelemetry`, `TelemetryFrameTrace`, `LogStore`                                               | Requested evidence capture and buffered log writes; timers stop with their sinks/session. No controller handler or per-input main delivery. |
| 1 s on Wi-Fi route; event-driven path monitor                                             | `HostRouteMonitor`, `BandwidthSignals`                                                                                           | Route changes, reconnect PHY median and adaptive bandwidth environment. Radio reads run on a utility queue.                                 |
| 1 s while menu is open                                                                    | `AppModel+MenuBar`                                                                                                               | Visible connection details; closes with the menu.                                                                                           |
| 1 s while diagnostic panels are mounted                                                   | `LogViewer`, `RawHIDControl`                                                                                                     | Explicitly opened logs/permission status; no input callback, and no subscription when the panel is absent.                                  |
| 60 s in mounted launcher readiness text                                                   | `ContentView`                                                                                                                    | Relative readiness age on a visible launcher, not per-frame work.                                                                           |
| One-shot deadlines only                                                                   | Session/RTSP connect, wake, reconnect, background grace, resize debounce, escape hold, banners, haptic grace, decode suppression | Bound active operations; cancelled by their lifecycle owners. No new periodic work added.                                                   |

## Observers and UI refresh

Connection, focus, screen/display-mode, window visibility, audio
route/interruption, power/thermal, application lifecycle and protected-data
notifications remain because they manage stream ownership or recovery. They fire
on state changes, not frames. Video layer failure/flush notifications are
session-scoped recovery inputs; no continuous layer-status KVO poll was found.
Sparkle's availability KVO belongs to the updater, which defers update work
while streaming.

Layout-library/configuration notifications reload only on edits or device
changes. Layout-device discovery and navigation belong to mounted editing
surfaces. iOS launcher controller discovery is now stopped during the stream.
Mac host status/app-list polling already cancels during streaming; updater
checks already defer. Stream SwiftUI observes coarse state changes; stats are
explicit timers described above. Mac launcher repeat and controller-diagnostic
refresh work is now stopped during streaming.

## Verification and limits

The synthetic controller tests block main while delivering press, hold, release
and stick-to-centre sequences on the capture queue, with both profile
publication orders and with/without a physical chord observer. Decrypted encoder
output must retain every changed game state in order and finish centred.
Separate tests assert the installed handler set, reject stale focus/registration
callbacks, preserve raw-HID extra-button edges without an editing lease, retire
launcher/diagnostic handlers and reject stale queued UI delivery.

Xcode 27.1 and 26.6 each passed 97 selected iOS Simulator controller/input tests
and 150 targeted Mac input/controller tests, with no compiler or strict
SwiftLint warnings. The full Mac suite and physical devices are excluded. No
pacing, bitrate, buffering or decode defaults were changed. Real-controller
feel, sustained power and frame-time changes still require the maintainer's
published build and hardware acceptance.

Continue with [the callback isolation audit](CALLBACK_ISOLATION_AUDIT.md) for
callback safety and regression coverage.
