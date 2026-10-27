# Run player journeys

Run real-app XCUITest journeys with silent fake-PC video and input receipts.
Touch journeys start without a controller or keyboard; controller journeys
connect one at the GameController boundary.

## Run the iPhone and iPad matrix

1. Build once and run iPhone 17 Pro and 11-inch iPad Pro in light and dark:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer make ios-touch-journeys
   ```

2. Inspect `iOS/build/touch-journey-results/*.xcresult` and the exported
   `*-shots` directories for screenshots, accessibility trees and PC receipts.
3. For CI, run four independent device/appearance jobs using the same target:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
     JOURNEY_DEVICE=phone JOURNEY_APPEARANCE=light make ios-touch-journeys
   ```

Use `phone` or `ipad` and `light` or `dark`; omitted selectors run the full
matrix serially. The script prints elapsed seconds and returns nonzero if any
journey fails. Measured combined shards took 13 minutes 38 seconds on iPhone
(light, 19 journeys) and 16 minutes 5 seconds on iPad (light, 20 journeys),
including incremental build and attachment export on this shared Mac. Budget 20
minutes per parallel CI shard plus a cold build; these are measured local
durations, not a hosted CI guarantee. The matrix currently reports unresolved
failures described below.

`JOURNEY_RUNTIME` defaults to `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
`JOURNEY_DERIVED` and `JOURNEY_RESULTS` select build/results directories. Keep
separate DerivedData for each Xcode version. `JOURNEY_PHONE_ID` and
`JOURNEY_IPAD_ID` may reuse dedicated test Simulators; the script deletes only
Simulators it creates. It reinstalls both app and test runner before each run
because Simulator can otherwise retain an older unsigned runner.

To reproduce one test after building, uninstall those two task bundles from the
dedicated Simulator, then use
`make -C iOS test-run SCHEME=Glimmer-Touch-Journeys`, setting `DERIVED`,
`TEST_DESTINATION` and
`TEST_FLAGS=-only-testing:GlimmerUITests/ControllerJourneyUITests/testName`. The
target Simulator must pass
`python3 scripts/check-journey-silence.py --simulator UUID` before any launch.

## Run the Mac controller matrix

1. Compile and run only the isolated controller UI target:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer make mac-controller-journeys
   ```

2. Inspect `build/controller-journey-results/*.xcresult` and `*-shots`.

The target uses `io.ugfugl.Glimmer.JourneyHost`, temporary storage, fake network
services and shipping launcher, Settings and stream views. It never invokes the
normal application startup, helper setup or identity creation. It does not run
`GlimmerTests` or the full Mac suite. Builds are unsigned. On the development
Mac, macOS currently kills the unsigned UI runner before bootstrap because its
bundle seal is invalid. Mac execution and timing remain unverified pending
explicit permission for keyless ad-hoc signing of disposable test products. No
signing material is required or accessed by these commands.

## What the fixtures prove

The native touch controls, menus, settings, lifecycle and input engine run
unchanged. Tests select existing identifiers or visible labels. Drags are
relative to identified controls, not device pixel positions. The iPad journey
uses the system's Left and Right arrangement and resizes during playback.

The DEBUG-only PC fixture renders moving color bars through the real
`AVSampleBufferDisplayLayer`. Tests wait for display readiness and check the
screenshot for colored video. Receipts record launch/resume/quit and post-engine
PC input, including holds, releases, controller slots, analog values and mouse
clicks/scroll. The latency assertion measures fixture injection to PC transport
receipt with a 100 ms ceiling; it is not a hardware or network latency
benchmark.

On iOS, `GCVirtualController` supplies a framework integration case. PS-like,
Xbox-like and Nintendo cases use public snapshot-controller elements and invoke
the app-installed callbacks on their assigned GameController queue. Snapshot
adapters supply missing live timestamps and physical-input collections using the
snapshot's actual values. Discovery posts the standard connection notifications.
Neither the tests nor the command-file bridge call view-model actions.

Pairing uses a reserved `.invalid` address. The fake PC checks a digest of the
PIN read from the pairing screen against its pairing seam. PINs are never
attached or logged. Preferences and files use `PersistentStorage` isolation
before app initialization. No fixture talks to a real PC or starts an audio
sink.

## Silence and coverage limits

VoiceOver and Speak Screen stay off. The scripts refuse a speech-enabled target
before boot or testing; unknown speech state fails closed. Accessibility uses
`performAccessibilityAudit` for descriptions/traits and the accessibility
hierarchy for labels and reachability. It does not prove spoken VoiceOver focus.

These are UI journeys, not Sunshine protocol tests. PC receipts are transport
interface calls, not encoded network packets. Video uses pixel buffers rather
than compressed RTP, and PIN progression does not prove TLS pairing or Bonjour
discovery. Public XCUITest has no arbitrary simultaneous distant
stick-plus-button gesture; multi-touch acceptance remains open.

Strict expected failures identify `TJ99-01` (largest-text iPhone menu clips),
`TJ99-02` (iPad diagram label duplicates its button trait), `CJ99-01`
(button-only Menu delivery misses Stop) and `CJ99-02` (Menu hold does not open
iOS controls) and `CJ99-03` (editing Stop dismisses Settings). An unexpected
pass fails the test so fixed defects cannot silently retain obsolete markers.
Unclassified harness/integration failures remain ordinary failures. Full
controller-only Settings navigation and Running tile resume still need coverage;
source presence or a compile is not a pass.

Use the [iOS engine roadmap](IOS_ENGINE_ROADMAP.md) for protocol, physical input
and device acceptance beyond these journeys.
