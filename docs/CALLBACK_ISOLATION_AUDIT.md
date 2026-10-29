# Framework callback isolation audit

Reviewed the framework callback entry points in `Glimmer/`, `iOS/Glimmer/`, and
`GlimmerEngine/` for the 2026.10.8 rc.19 controller crash fix. The search
started with handler assignments and expanded to completion/error arguments,
notifications, dispatch sources, timers, native C callbacks, KVO, event
monitors, and thread/run-loop blocks. SDK contracts were checked against Xcode
26.6. Both projects use Swift 6 complete concurrency with no default MainActor
setting.

`safe-nonisolated` means the entry has no inherited main-actor accesses: either
its SDK/explicit function type is Sendable, it is constructed in nonisolated
code, or a background invocation verifies the inferred boundary.
`safe-main-queue` means delivery is bound to main, including main-run-loop
callbacks. `FIXED` identifies a callback changed in this work.

## Findings and regression coverage

- The shared lease's nested Mutex closure inherited main isolation. Invoking the
  installed physical-input handler on `controller-lease-test` traps in
  `swift_task_checkIsolated` without `@Sendable`. Its regression also invokes a
  saved handler after stop and checks that no sample is delivered. The same test
  source is already in the Mac and iOS projects.
- The Mac diagnostics monitor used `MainActor.assumeIsolated` for a controller
  whose handler queue it does not own. A background invocation traps inside that
  assertion. The fix keeps input routing synchronous and hops only the
  diagnostic count to main.
- Stream forwarding and launcher navigation receive background invocation tests.
  Their existing handlers only use nonisolated capture APIs or schedule
  main-actor work; they do not require a production change.

A text-only static guard was omitted: actor isolation crosses extensions and SDK
callback types, and safe nonisolated handlers can be declared lexically inside
MainActor methods. A lexical rule would reject the verified safe cases or miss
the nested closure that caused this crash. Runtime regressions exercise actual
installed handlers instead.

## Verification

The lease regression was run without `@Sendable` and crashed on the background
queue with both Xcode 26.6 and Xcode 27.1. The monitor regression also crashed
before its main-queue hop. Both pass with the fixes.

Xcode 26.6 passed 64 tests across `ControllerLayoutCaptureTests`,
`ControllerStatePushTests`, `LauncherControllerTests`, `HIDGamepadTests`, and
`HelperClientTests`. Xcode 26.6 and 27.1 each passed 33 Simulator tests across
`ControllerLayoutCaptureTests`, `ControllerMonitorTests`,
`IOSControllerCaptureTests`, `IOSControllerFeedbackTests`, and
`IOSControllerSensorsTests`. Compiler outputs contained no warnings.

The default Xcode 27.1 `make verify` gate passed: strict lint, 525 tooling
tests, 2,918 Mac tests, and 17 AddressSanitizer fuzz tests. Compiler outputs
contained no warnings.

Physical-controller acceptance on macOS 15 and hosted verification remain with
the release candidate; local checks do not establish either result.

## Controller delivery regression after rc.17

The rc.18 layout lease removed the extended-gamepad callback while its
unmapped-input callback still read that legacy profile for system mappings. If
the legacy profile published afterward, its new state had no callback to forward
it. iOS also returned from layout installation before assigning the controller
capture queue or disabling system gestures. Mac uses the same lease and
system-profile reader, so it shares the missing-update defect.

`ControllerLayoutDeliveryTests` scripts both publication orders with a synthetic
controller while main waits on a semaphore. It follows physical A remapped to B,
a held button, release, a rightward stick and centre through `InputCore`, the
send thread, batcher, encoder and encrypted reliable queue. Before the fix, the
physical-first sequence ended at X = 16384 instead of zero. The controller queue
also remained main. The test checks ordered encoded states, monotonic callback
timestamps and the installed handler set. Separate ownership tests cover queue
restoration and rejection of retained callbacks after stop.

System-mapped streams now install their own legacy gameplay callback and a
physical observer restricted to configured chord elements. Custom layouts use
only the physical gameplay callback. Both run on the stream capture queue with
explicit Sendable boundaries; the forwarder's registration/epoch owns validity.
No layout-capture lease or handler restoration chain sits in the stream path.
The UI-only lease retains the rc.19 isolation fix. Profile timestamps cannot
move chord detection backward.

The owner's two Organizer reports confirm the exact TestFlight 8 crash class:
iPhone OS 27.0.1, build 8, 18:27–18:28, EXC_BREAKPOINT in the lease's nested
closure, called from `_GCDevicePhysicalInput handleGamepadEvent:`. The rc.19
`@Sendable` correction remains covered by the background-handler regression.

The follow-up ownership tests cover launcher reactivation/hotplug, diagnostic
retirement, direct raw-HID extra-button delivery and absence of main-queue HID
UI work without an observer. Xcode 26.6 and 27.1 verification uses only selected
Simulator and Mac input/controller suites; never the full Mac suite. See
[the stream work audit](STREAM_WORK_AUDIT.md) for the recurring-work inventory,
confirmed removals and hardware acceptance limits.

The stream-ownership follow-up adds these audited boundaries:

| Location                                                     | Callback                     | Evidence                                                                                                    |
| ------------------------------------------------------------ | ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `Glimmer/ControllerLayouts/ControllerLayoutReader.swift:231` | Physical stream input        | Explicit Sendable callback on the serial capture queue; synchronous immutable reader and registration gate. |
| `Glimmer/ControllerLayouts/ControllerLayoutReader.swift:237` | Legacy stream input          | Explicit Sendable callback; busy-main encoder regression covers both publication orders.                    |
| `Glimmer/Stream/DualSenseHID.swift:404`                      | Optional diagnostic delivery | MainActor Sendable scheduled closure; generation gate and no dispatch when detached.                        |

## Reviewed callbacks

Locations refer to this change's source. Selector observers and nil/restored
handler assignments do not create closure literals. Restored handlers preserve
their existing queue/ownership contracts. Internal adapter closures are covered
by the Sendable boundary at the framework entry.

| Location                                                         | Callback                                              | Verdict          | Evidence                                                                              |
| ---------------------------------------------------------------- | ----------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------- |
| `Glimmer/AWDLHelperManager.swift:66`                             | conn.invalidationHandler                              | safe-nonisolated | No main isolation; task awaits HelperClient; anonymous XPC regression passes.         |
| `Glimmer/AppModel+Commands.swift:138`                            | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+HostRoute.swift:64`                            | DispatchSource handler                                | safe-nonisolated | Explicit @Sendable with main-actor task hop.                                          |
| `Glimmer/AppModel+HostRoute.swift:134`                           | conn.pathUpdateHandler                                | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `Glimmer/AppModel+HostRoute.swift:143`                           | conn.betterPathUpdateHandler                          | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `Glimmer/AppModel+HostRoute.swift:151`                           | conn.stateUpdateHandler                               | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `Glimmer/AppModel+Lifecycle.swift:84`                            | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+Lifecycle.swift:107`                           | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+Lifecycle.swift:132`                           | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+Lifecycle.swift:142`                           | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+Lifecycle.swift:162`                           | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/AppModel+Lifecycle.swift:215`                           | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `Glimmer/AppModel+Lifecycle.swift:220`                           | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/AppModel+MenuBar.swift:76`                              | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `Glimmer/AppModel+Power.swift:260`                               | Discovery/authorization completion                    | safe-nonisolated | Empty capture-free callback; no isolated accesses.                                    |
| `Glimmer/CLI/GlimmerCLI+Commands.swift:209`                      | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/CLI/GlimmerCLI+Diagnostics.swift:63`                    | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `Glimmer/CLI/GlimmerDiagnosticCapture+Process.swift:120`         | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; explicit main hop for UI work.                                 |
| `Glimmer/CLI/GlimmerDiagnosticCapture+Process.swift:145`         | File enumeration error handler                        | safe-nonisolated | Nonisolated CLI enumeration; synchronous callback.                                    |
| `Glimmer/ContentView.swift:165`                                  | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/ControllerInputTestView.swift:38`                       | Discovery/authorization completion                    | safe-nonisolated | Empty capture-free callback; no isolated accesses.                                    |
| `Glimmer/ControllerInputTestView.swift:45`                       | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/ControllerInputTestView.swift:80`                       | controller.extendedGamepad?.valueChangedHandler       | FIXED            | Explicit @Sendable; dispatches diagnostic count to main when needed.                  |
| `Glimmer/ControllerInputTestView.swift:85`                       | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/ControllerLayouts/ControllerLayoutCapture.swift:214`    | input.elementValueDidChangeHandler                    | FIXED            | Explicit @Sendable; locked delivery gate and Sendable sampler.                        |
| `Glimmer/ControllerLayouts/ControllerLayoutNavigation.swift:31`  | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/ControllerLayouts/ControllerLayoutNavigation.swift:69`  | pad.valueChangedHandler                               | safe-main-queue  | Sets controller.handlerQueue = .main before installation.                             |
| `Glimmer/ControllerLayouts/ControllerLayoutsModel.swift:168`     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/EngineAdapters/AudioHALDevice.swift:172`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `Glimmer/EngineAdapters/MacAudio+Route.swift:93`                 | HAL property listener                                 | safe-nonisolated | Static C entry halListenerFired; locked Sendable callback registry.                   |
| `Glimmer/EngineAdapters/MacAudio.swift:55`                       | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `Glimmer/EngineAdapters/MacSessionFeedback.swift:15`             | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/EngineAdapters/MacSessionServices.swift:96`             | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/EngineAdapters/MacSessionServices.swift:104`            | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/EngineAdapters/WiFiTelemetry.swift:223`                 | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `Glimmer/EngineAdapters/WiFiTelemetry.swift:225`                 | newMonitor.pathUpdateHandler                          | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `Glimmer/EngineAdapters/WiFiTelemetry.swift:258`                 | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `Glimmer/GlimmerApp.swift:275`                                   | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/GlimmerApp.swift:278`                                   | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/GlimmerApp.swift:282`                                   | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/LauncherController.swift:63`                            | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/LauncherController.swift:68`                            | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/LauncherController.swift:133`                           | pad.valueChangedHandler                               | safe-nonisolated | Only schedules a MainActor task; background invocation regression.                    |
| `Glimmer/LauncherController.swift:149`                           | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `Glimmer/PairSheet.swift:228`                                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/PairSheet.swift:482`                                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/PairSheet.swift:488`                                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/SettingsGeneralStreamingPanes+LoginItem.swift:199`      | process.terminationHandler                            | safe-nonisolated | Created inside Task.detached; locked single-resume completion.                        |
| `Glimmer/SettingsGeneralStreamingPanes.swift:29`                 | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/SettingsInput+NintendoLayout.swift:24`                  | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/SettingsShortcutRecorders.swift:164`                    | Local event monitor                                   | safe-main-queue  | AppKit local event delivery on main.                                                  |
| `Glimmer/SettingsShortcutRecorders.swift:167`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/ControllerButtonLayout.swift:49`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/ControllerForwarder.swift:80`                    | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/ControllerForwarder.swift:94`                    | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/ControllerForwarder.swift:128`                   | Discovery/authorization completion                    | safe-nonisolated | Empty capture-free callback; no isolated accesses.                                    |
| `Glimmer/Stream/ControllerForwarder.swift:498`                   | gamepad.extendedGamepad?.valueChangedHandler          | safe-nonisolated | Only nonisolated capture APIs and locked InputCore; background invocation regression. |
| `Glimmer/Stream/ControllerHaptics+Actuation.swift:21`            | engine.stoppedHandler                                 | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `Glimmer/Stream/ControllerHaptics+Actuation.swift:22`            | engine.resetHandler                                   | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `Glimmer/Stream/ControllerHaptics.swift:26`                      | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/ControllerHaptics.swift:28`                      | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/ControllerHaptics.swift:33`                      | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `Glimmer/Stream/ControllerHaptics.swift:36`                      | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `Glimmer/Stream/ControllerMotion.swift:27`                       | motion.valueChangedHandler                            | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `Glimmer/Stream/DualSenseHID.swift:292`                          | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/DualSenseHID.swift:296`                          | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/DualSenseHID.swift:323`                          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/DualSenseHID.swift:355`                          | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/DualSenseHID.swift:390`                          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/DualSenseHID.swift:451`                          | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `Glimmer/Stream/DualSenseRouting.swift:114`                      | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/DualSenseRouting.swift:157`                      | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/HIDGamepad/HIDGamepadCapture.swift:81`           | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:66`           | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:108`          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:122`          | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:127`          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:133`          | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:137`          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/HIDGamepad/HIDGamepadManager.swift:177`          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/HIDGamepad/HIDInputThread.swift:13`              | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `Glimmer/Stream/HIDGamepad/HIDInputThread.swift:34`              | Run-loop block                                        | safe-nonisolated | Forwards an explicitly @Sendable body.                                                |
| `Glimmer/Stream/InputForwarder+Capture.swift:31`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/InputForwarder+Capture.swift:55`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/InputForwarder+Capture.swift:175`                | Local event monitor                                   | safe-main-queue  | AppKit local event delivery on main.                                                  |
| `Glimmer/Stream/InputForwarder+Capture.swift:264`                | Local event monitor                                   | safe-main-queue  | AppKit local event delivery on main.                                                  |
| `Glimmer/Stream/InputForwarder+CommandKeyUp.swift:20`            | Local event monitor                                   | safe-main-queue  | AppKit local event delivery on main.                                                  |
| `Glimmer/Stream/InputForwarder+Core.swift:55`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/InputForwarder+Core.swift:77`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/InputForwarder+Core.swift:82`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/InputForwarder+Core.swift:85`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/InputForwarder+Core.swift:95`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/InputForwarder+Reconciliation.swift:122`         | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/MacControllerLayouts.swift:33`                   | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/MacControllerLayouts.swift:37`                   | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/MacControllerLayouts.swift:41`                   | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StatsOverlayLayer.swift:317`                     | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamBanner.swift:48`                           | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamBanner.swift:134`                          | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamSession+StatsOverlayTimer.swift:55`        | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `Glimmer/Stream/StreamWindow+Fade.swift:57`                      | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamWindow+Fade.swift:122`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Fade.swift:151`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Fade.swift:163`                     | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamWindow+Fade.swift:198`                     | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamWindow+PointerAffordances.swift:81`        | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+PointerAffordances.swift:104`       | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Show.swift:123`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Show.swift:138`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:158`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Show.swift:202`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Show.swift:233`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:242`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:254`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:273`                     | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Show.swift:309`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:333`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:353`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Show.swift:390`                     | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Slide.swift:139`                    | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamWindow+Slide.swift:149`                    | Animation completion                                  | safe-main-queue  | AppKit animation/main-run-loop Core Animation transaction.                            |
| `Glimmer/Stream/StreamWindow+Views.swift:20`                     | Local event monitor                                   | safe-main-queue  | AppKit local event delivery on main.                                                  |
| `Glimmer/Stream/StreamWindow+Views.swift:154`                    | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Windowed.swift:62`                  | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Windowed.swift:68`                  | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/Stream/StreamWindow+Windowed.swift:173`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Windowed.swift:182`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Windowed.swift:200`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Windowed.swift:246`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow+Windowed.swift:256`                 | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `Glimmer/Stream/StreamWindow.swift:217`                          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/TroubleshootingPane.swift:118`                          | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; explicit main hop for UI work.                                 |
| `Glimmer/TroubleshootingPane.swift:120`                          | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/UpdaterController.swift:70`                             | Sparkle availability KVO                              | safe-main-queue  | Sparkle main-thread updater property and initial registration on main.                |
| `Glimmer/UpdaterController.swift:157`                            | Sparkle availability KVO                              | safe-main-queue  | Sparkle main-thread updater property and initial registration on main.                |
| `iOS/Glimmer/ControllerMonitor.swift:43`                         | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `iOS/Glimmer/IOSAudioSession+Notifications.swift:75`             | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `iOS/Glimmer/IOSAudioSession+Notifications.swift:118`            | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `iOS/Glimmer/IOSControllerCapture.swift:78`                      | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `iOS/Glimmer/IOSControllerCapture.swift:207`                     | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; explicit main hop for UI work.                                 |
| `iOS/Glimmer/IOSControllerCapture.swift:223`                     | entry.controller.extendedGamepad?.valueChangedHandler | safe-nonisolated | Explicit @Sendable; locked delivery and shared input submission.                      |
| `iOS/Glimmer/IOSControllerFeedback.swift:29`                     | engine.stoppedHandler                                 | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `iOS/Glimmer/IOSControllerFeedback.swift:30`                     | engine.resetHandler                                   | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `iOS/Glimmer/IOSControllerFeedback.swift:125`                    | Native completion                                     | safe-nonisolated | Created in nonisolated native adapter; Sendable completion.                           |
| `iOS/Glimmer/IOSControllerSensors.swift:44`                      | motion.valueChangedHandler                            | safe-nonisolated | Nonisolated native adapter; no main-actor state.                                      |
| `iOS/Glimmer/StreamBackgroundGrace.swift:13`                     | Background expiration                                 | safe-main-queue  | UIKit main-actor expiration contract; forwarded @MainActor @Sendable closure.         |
| `iOS/Glimmer/StreamStats.swift:41`                               | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `iOS/Glimmer/StreamView.swift:165`                               | Geometry error handler                                | safe-nonisolated | Existing rc.18 @Sendable fix; only logs the error.                                    |
| `iOS/Glimmer/TouchGamepadView.swift:35`                          | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `GlimmerEngine/Audio/AudioDecoder+CushionMemory.swift:399`       | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Audio/AudioDecoder+Resampler.swift:188`           | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Audio/AudioDecoder+Resampler.swift:221`           | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Audio/AudioDecoder+Route.swift:24`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Audio/AudioDecoder+Worker.swift:43`               | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Audio/AudioDecoder+Worker.swift:56`               | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Audio/AudioDecoder+Worker.swift:73`               | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Audio/AudioOutput.swift:24`                       | Audio render callback                                 | safe-nonisolated | Top-level C callback; preallocated render storage.                                    |
| `GlimmerEngine/Audio/AudioOutput.swift:28`                       | Audio render callback                                 | safe-nonisolated | Top-level C callback; preallocated render storage.                                    |
| `GlimmerEngine/Diagnostics/AudioDiagnostics.swift:11`            | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/AudioDiagnostics.swift:15`            | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/AudioDiagnostics.swift:19`            | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/AudioDiagnostics.swift:23`            | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/DisplayTelemetry.swift:119`           | DispatchSource handler                                | safe-main-queue  | Source created on .main; assumeIsolated is queue-backed.                              |
| `GlimmerEngine/Diagnostics/LogStore.swift:380`                   | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/LogStore.swift:385`                   | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Diagnostics/RendererTelemetry.swift:94`           | Native completion                                     | safe-nonisolated | Created in nonisolated native adapter; Sendable completion.                           |
| `GlimmerEngine/Diagnostics/RendererTelemetry.swift:148`          | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryExporter+Capture.swift:26`   | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Diagnostics/TelemetryExporter+Sinks.swift:114`    | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryExporter+Sinks.swift:207`    | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:218`          | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:415`          | newListener.stateUpdateHandler                        | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:442`          | newListener.newConnectionHandler                      | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:459`          | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:492`          | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Diagnostics/TelemetryExporter.swift:515`          | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Diagnostics/TelemetryFrameTrace.swift:135`        | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Diagnostics/TelemetryFrameTrace.swift:151`        | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Input/ControllerBattery.swift:120`                | DispatchSource handler                                | safe-main-queue  | Source created on .main; assumeIsolated is queue-backed.                              |
| `GlimmerEngine/Input/ControllerHaptics+Actuation.swift:204`      | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:124`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:139`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:154`                | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:163`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:183`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:202`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:231`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:248`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:264`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:280`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:369`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:380`                | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Input/ControllerHaptics.swift:394`                | Dispatch work item                                    | safe-nonisolated | Created in nonisolated queue-owned engine code.                                       |
| `GlimmerEngine/Input/InputCore+Layouts.swift:153`                | Dispatch work item                                    | safe-nonisolated | Created in nonisolated queue-owned engine code.                                       |
| `GlimmerEngine/Input/InputCore+Mouse.swift:171`                  | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Input/InputReconciliation.swift:9`                | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `GlimmerEngine/Input/StreamInput+Attempts.swift:65`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/AudioPacketWorker.swift:40`               | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Network/ControlTransport.swift:183`               | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/ControlTransport.swift:197`               | connection.stateUpdateHandler                         | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/ControlTransport.swift:203`               | Dispatch work item                                    | safe-nonisolated | Created in nonisolated queue-owned engine code.                                       |
| `GlimmerEngine/Network/ControlTransport.swift:213`               | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Network/ControlTransport.swift:229`               | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Network/Discovery.swift:69`                       | browser.browseResultsChangedHandler                   | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/Discovery.swift:78`                       | browser.stateUpdateHandler                            | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/Discovery.swift:188`                      | conn.stateUpdateHandler                               | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/EnetControlChannel+Send.swift:29`         | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Network/InputCallbackProbe.swift:33`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/InputSendThread.swift:26`                 | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Network/Network.swift:53`                         | conn.stateUpdateHandler                               | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/RtpAudioReceiver+Events.swift:99`         | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; explicit main hop for UI work.                                 |
| `GlimmerEngine/Network/RtpAudioReceiver+Ping.swift:40`           | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Network/RtpAudioReceiver+Receive.swift:21`        | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/RtspClient.swift:314`                     | connection.stateUpdateHandler                         | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Network/RtspClient.swift:324`                     | Dispatch work item                                    | safe-nonisolated | Created in nonisolated queue-owned engine code.                                       |
| `GlimmerEngine/Network/RtspClient.swift:330`                     | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Network/RtspClient.swift:375`                     | Network receive/send completion                       | safe-nonisolated | SDK @Sendable; created in nonisolated transport/telemetry code.                       |
| `GlimmerEngine/Network/StreamPathMTU.swift:127`                  | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/StreamPathMTU.swift:161`                  | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; explicit main hop for UI work.                                 |
| `GlimmerEngine/Network/VideoRtpReceiver.swift:271`               | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Network/VideoRtpReceiver.swift:388`               | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Pacing/FramePacer+DeficitTimer.swift:33`          | DispatchSource handler                                | safe-nonisolated | Nonisolated callback body; only queue-owned or locked state.                          |
| `GlimmerEngine/Pacing/FramePacer+Recovery.swift:50`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+Recovery.swift:88`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+Recovery.swift:260`             | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+Submit.swift:115`               | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+Submit.swift:315`               | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Pacing/FramePacer+Tick.swift:186`                 | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Pacing/FramePacer+Tick.swift:208`                 | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+TickDeficitEvents.swift:57`     | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Pacing/FramePacer+TickThread.swift:96`            | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Pacing/FramePacer.swift:459`                      | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Session/BandwidthSignals.swift:41`                | monitor.pathUpdateHandler                             | safe-nonisolated | Network SDK declares callback @Sendable; actor publications hop explicitly.           |
| `GlimmerEngine/Session/BandwidthSignals.swift:80`                | NotificationCenter block observer                     | safe-main-queue  | Explicit main operation queue.                                                        |
| `GlimmerEngine/Session/EnvSignalController+Evidence.swift:16`    | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Session/EnvSignalController+Evidence.swift:328`   | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Session/NativeBackend+Pipeline.swift:154`         | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Session/NativeBackend.swift:170`                  | Thread entry                                          | safe-nonisolated | Nonisolated owner; queue/run-loop-confined work.                                      |
| `GlimmerEngine/Session/NativeConnectionEvents.swift:161`         | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Session/StreamSession+Callbacks.swift:29`         | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Session/StreamSession+FrameWatchdog.swift:67`     | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `GlimmerEngine/Session/StreamSession+PresentMetric.swift:24`     | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `GlimmerEngine/Session/StreamSession+Reconnect.swift:26`         | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Session/StreamSession+Reconnect.swift:111`        | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Session/StreamSession+Watchdog.swift:109`         | Foundation timer                                      | safe-main-queue  | Installed on RunLoop.main or scheduled inside MainActor.run.                          |
| `GlimmerEngine/Video/VideoDecoder+API.swift:330`                 | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Video/VideoDecoder+Decode.swift:256`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Video/VideoDecoder+Decode.swift:271`              | Dispatch queue block                                  | safe-nonisolated | SDK @Sendable closure; nonisolated queue-owned work.                                  |
| `GlimmerEngine/Video/VideoDecoder+Pacing.swift:238`              | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Video/VideoDecoder+Session.swift:146`             | C callback                                            | safe-nonisolated | C function-pointer entry; nonisolated/locked native work.                             |
| `GlimmerEngine/Video/VideoDecoder+Session.swift:252`             | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Video/VideoDecoder+Suppression.swift:332`         | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `GlimmerEngine/Video/VideoDecoder+Suppression.swift:338`         | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `GlimmerEngine/Video/VideoDecoder+Suppression.swift:362`         | NotificationCenter block observer                     | safe-nonisolated | SDK @Sendable observer; nonisolated work or explicit main hop.                        |
| `GlimmerEngine/Video/VideoDecoder+Suppression.swift:372`         | Dispatch queue block                                  | safe-main-queue  | Explicit main queue.                                                                  |
| `Glimmer/AWDLHelperManager.swift:53`                             | XPC proxy error                                       | safe-nonisolated | Forwards an explicitly @Sendable error closure.                                       |
| `Glimmer/AWDLHelperManager.swift:107`                            | XPC setAWDLDown error                                 | safe-nonisolated | Sendable proxy factory callback; locked continuation.                                 |
| `Glimmer/AWDLHelperManager.swift:119`                            | XPC currentStatus error                               | safe-nonisolated | Sendable proxy factory callback; locked continuation.                                 |
| `Glimmer/AWDLHelperManager.swift:121`                            | XPC currentStatus reply                               | safe-nonisolated | No actor state; forwards to Sendable completion; anonymous transport tests.           |
| `Glimmer/AWDLHelperManager.swift:129`                            | XPC reSuppressCount error                             | safe-nonisolated | Sendable proxy factory callback; locked continuation.                                 |
| `Glimmer/AWDLHelperManager.swift:131`                            | XPC reSuppressCount reply                             | safe-nonisolated | No actor state; forwards to Sendable completion; anonymous transport tests.           |
| `Glimmer/AppModel+Continuation.swift:53`                         | Sheet completion                                      | safe-main-queue  | AppKit sheet callback; confirm is main-isolated.                                      |
| `GlimmerEngine/Audio/OpusDecoder+Stream.swift:37`                | AVAudioConverter input                                | safe-nonisolated | Nonisolated conversion lane; immutable packet source with atomic claim.               |
| `GlimmerEngine/Network/EnetControlChannel+Handshake.swift:98`    | Connection state callback                             | safe-nonisolated | Forwards the handshake Sendable handler into the Network SDK property.                |
| `GlimmerEngine/Network/EnetControlChannel+Inbound.swift:22`      | Datagram receive completion                           | safe-nonisolated | Network SDK Sendable callback; nonisolated channel owner.                             |
| `GlimmerEngine/Network/ControlTransport.swift:162`               | TLS certificate verification                          | safe-nonisolated | Created in nonisolated exchange; queue delivery and locked rejection state.           |
| `Glimmer/AWDLHelperManager.swift:112`                            | XPC setAWDLDown reply                                 | safe-nonisolated | Forwards the Sendable single-resume completion.                                       |
| `Glimmer/AppModel+Commands.swift:30`                             | Observation change                                    | safe-main-queue  | Observed AppModel.isStreaming is mutated only on MainActor.                           |
| `Glimmer/UpdaterController.swift:127`                            | Observation change                                    | safe-nonisolated | Observation Sendable callback schedules a MainActor task.                             |
| `Glimmer/SequoiaFallbacks.swift:24`                              | Observation change                                    | safe-nonisolated | Observation Sendable callback yields to an AsyncStream continuation.                  |
| `Glimmer/Stream/InputForwarder+Core.swift:54`                    | Observation change                                    | safe-nonisolated | Observation Sendable callback dispatches to main.                                     |
| `Glimmer/LogViewerView.swift:66`                                 | Timer publisher                                       | safe-main-queue  | Publisher explicitly uses RunLoop.main.                                               |
| `Glimmer/TroubleshootingPane.swift:46`                           | Timer publisher                                       | safe-main-queue  | Publisher explicitly uses RunLoop.main.                                               |
| `Glimmer/LauncherNavigation.swift:167`                           | Activation publisher                                  | safe-main-queue  | AppKit application activation notification on main.                                   |
| `Glimmer/SettingsGeneralStreamingPanes.swift:141`                | Activation publisher                                  | safe-main-queue  | AppKit application activation notification on main.                                   |
| `iOS/Glimmer/LauncherView.swift:101`                             | Protected-data publisher                              | safe-main-queue  | UIKit application lifecycle notification on main.                                     |
| `iOS/Glimmer/LauncherView.swift:105`                             | Protected-data publisher                              | safe-main-queue  | UIKit application lifecycle notification on main.                                     |
| `Glimmer/SettingsPCsShortcutsPanes.swift:286`                    | Controller connection publisher                       | safe-main-queue  | GameController connection notifications use main; separate from input handlerQueue.   |
| `Glimmer/SettingsPCsShortcutsPanes.swift:287`                    | Controller disconnection publisher                    | safe-main-queue  | GameController connection notifications use main; separate from input handlerQueue.   |
| `Glimmer/ControllerLayouts/ControllerLayoutAssignment.swift:136` | Controller disconnection publisher                    | safe-main-queue  | GameController connection notifications use main; separate from input handlerQueue.   |
| `Glimmer/ControllerLayouts/ControllerLayoutAssignment.swift:143` | HID device publisher                                  | safe-main-queue  | HIDGamepadManager posts device changes from its MainActor lifecycle.                  |

Continue with [the concurrency rules](CONTRIBUTING.md#concurrency) when adding
framework callbacks.
