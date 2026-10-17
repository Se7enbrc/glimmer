# Engine extraction for 2026.10.8

Phase 0 plan, 2026-10-12. Phase 1 ships **inside 2026.10.8** on `engine/phase0`,
based on `feat/2026.10.8`. Inventory: `4e87494dbf0d` plus the existing
`IOS_ENGINE_ROADMAP.md`. This round changes this document only.
[AGENTS.md](../AGENTS.md) governs; [roadmap](IOS_ENGINE_ROADMAP.md),
[architecture](ARCHITECTURE.md), [profiling](PROFILING.md),
[security](SECURITY.md) and [contribution rules](CONTRIBUTING.md) supply the
contracts. No tuning, new dependency, additional launch round trip, iOS app, or
release operation is part of Phase 0.

## Target and dependency structure

| Decision                   | Implementation for Phase 1                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Product                    | One source-built **GlimmerEngine.framework**, Xcode Framework target (`com.apple.product-type.framework`, dynamic `mh_dylib`) in `Glimmer.xcodeproj`. No package, XCFramework, C engine, or second implementation.                                                                                                                                                                   |
| Sources                    | `GlimmerEngine/{Protocol,Network,Models,Session,Video,Audio,Input,Diagnostics}/`; retain feature filenames. `Glimmer/EngineAdapters/` owns Mac API implementations; existing UI stays in place. No reverse import from engine to app.                                                                                                                                                |
| Targets                    | macOS 26, arm64 first. Framework supports iOS/iPadOS 26 and Simulator as each slice becomes portable; Phase 2 adds the consumer. SDK-specific source membership excludes Mac SPI. No Catalyst target.                                                                                                                                                                                |
| Build settings             | Swift 6, complete strict concurrency, same release optimization and security compiler settings as the app; `DEFINES_MODULE=YES`, `SKIP_INSTALL=YES`. No library-evolution requirement for consumers built together. Keep Mac arm64; do not impose `StreamLib.xcconfig`'s global arm64 override on future Simulator destinations.                                                     |
| App                        | Explicit target dependency, link, and Embed Frameworks copy (Code Sign On Copy for signed builds) to `Contents/Frameworks`; existing `@executable_path/../Frameworks` runpath. Remove each moved source from app Sources in the same slice. Import at callers, expose only necessary API and initializers; no blanket public conversion or production `@testable` imports.           |
| CLI                        | Remains in the app executable. Headless commands use the same framework; `glimmer stream` still hands off to the running app through `CommandChannel`. Preserve real-path re-exec, `Bundle.main`, defaults and launch-argument dispatch. No second CLI target or stream process.                                                                                                     |
| Tests                      | Keep `GlimmerTests` and its scheduling. Moved tests use `@testable import GlimmerEngine`; mixed tests also import `Glimmer`. Link the framework and depend on it, without compiling its source into tests or embedding a second copy. Debug enables testability.                                                                                                                     |
| Test-loader discrepancy    | Current pbxproj sets `TEST_HOST` to Glimmer.app and `BUNDLE_LOADER=$(TEST_HOST)` in both configurations, despite the docs' “hostless” label. Preserve this loader in Phase 1; tests need no PC. Do not combine extraction with a test-host migration.                                                                                                                                |
| Signing                    | Proposed framework ID `io.ugfugl.Glimmer.Engine`; no framework entitlements or provisioning profile. Add explicit inside-out `sign_plain` handling in `scripts/sign-bundle.sh` before the app seal. It currently handles Sparkle and loose dylibs, not arbitrary frameworks. Preserve Sparkle's own entitlements; never sign with `--deep`.                                          |
| Notarization and Sparkle   | Framework is nested code in the same app, DMG and update ZIP. Existing app/helper IDs, profiles, feed, update key and installed path stay fixed. Notarization covers the complete bundle; promotion reuses accepted bytes. No separate framework updater.                                                                                                                            |
| Build/release gate         | Slice 1 wires the new target through the existing scheme, `make app`, `make test`, `make check`, ASan/CodeQL and `make dist` dependencies. Extend strict lint/SPDX/coverage inventories to `GlimmerEngine`; preserve generated DB exception by exact path if it moves. Preserve dSYMs and deterministic stripping for both binaries. `make dist` remains maintainer-authorized only. |
| Current toolchain evidence | Local Xcode is 27.0 with 27.0 SDKs. Header inspection is not a 26.6 compile or deployment proof. Required hosted Xcode 26.6/macOS 26 checks remain the release gate; availability-check every moved API against the minimum SDK/runtime.                                                                                                                                             |

The roadmap's Objective-C exception-guard paragraph is stale: current audio is
Swift-controlled AudioToolbox, with no bridging header or exception shim. Do not
recreate one. The current datagram fallback is `recvmsg` in
`DatagramBatch.receiveOne`, preserving ancillary timestamps; earlier
roadmap/AGENTS references to `recvfrom` describe an older path.

## External source package, slice 1 follow-up

`Package.swift` now exposes the existing `GlimmerEngine/` source tree as the
`GlimmerEngine` library for macOS/iOS 26. The iOS consumer now lives under
`iOS/` and references this root package locally; see
[repository ownership](APPLE_REPOSITORY.md). The Phase 1 framework decision
above remains the Mac build path; no Mac make, signing or embedding step
changes.

Swift tools 6.2 supplies the platform 26 declarations; Swift 6 language mode
supplies complete concurrency checking and the enabled Swift 6 language
features. SwiftPM sets package identity itself, so no unsafe `-package-name`
override is needed. Package-only members remain inaccessible to external apps.
The small public `RtspMessage` request initializer, ordered headers, serializer
and protocol version provide a real linking check without broadening the whole
wire API.

Debug and Release use SwiftPM’s standard `-Onone`/`-O` settings. The framework’s
Clang-only stack/typed-allocation settings have no source to act on in this pure
Swift package. Bundle hardening, install paths and code signing remain consumer
responsibilities. There are no resources, plugins, dependencies, copied sources
or extra network requests in the package.

Run `swift build -Xswiftc -warnings-as-errors` and
`swift test -Xswiftc -warnings-as-errors`. Verify’s required engine job runs
both alongside the device and Simulator framework builds. `EnginePackageTests`
also belongs to the existing Mac test target. The iOS consumer compiles the
public API from a separate package identity, without `@testable` or
`-package-name` access.

The source package has no independent semantic version yet; its consumer pins an
exact commit. Publish this change before updating the consumer revision. The
uncommitted scaffold uses a documented local-path override until that commit
exists. Slice 1 links but cannot discover, pair or stream; the framework handoff
and hardware performance gates remain open.

## Slice 3 implementation and Public API

Slice 3 moves `ControlTransport`, `Discovery`, `Identity` (+ Crypto/Loading),
`Network` (+ Support), `NetworkClient` (+ Endpoints/Request), `PEM`, `Pairing`
(+ Crypto), `Types+Cert` and the Wake on LAN packet/target logic into
`GlimmerEngine/Network/`. The Mac and source-package consumers compile these
same files. Request ordering, timeouts, TLS resumption policy, exact DER
pinning, log categories/privacy and persisted keys are unchanged.

The required cut points also move the shared `StreamAttempt` deadline helper,
`PairingFailure` cases and bounded `HostReadiness` loop. Mac foreground polling,
visibility/sleep handling, poll cadence, readiness wording and publication stay
in `HostStatusPoller`. HTTP launch/resume consume the already-extracted
`StreamRequest`; Mac overloads forward `StreamConfig.request`. There are no
additional launch requests or per-frame cross-module calls.

### Public API

External packages need no `@testable` import or shared package identity for:

- `HostDiscovery`: construct a browser, start its update stream, and stop all
  browsing or just the matching run. `Discovered` exposes service ID, display
  name, resolved address and port; `Update` exposes PCs and permission denial.
  The shared Mac instance is package-only; an iOS shell creates its own
  instance.
- `IdentityManager(defaultsSuite:supportBase:protectedDataAvailable:)` and
  `uniqueID()`: the shell must supply its defaults domain (nil explicitly means
  standard defaults) and writable application-support base. Existing identity
  filenames remain under `Glimmer/Identity` relative to that base. The
  synchronous Sendable policy must reflect protected-data availability; false
  throws `IdentityStorageError.unavailable` before cache access, migration or
  generation. This policy is a required initializer argument. If a named
  defaults suite cannot be opened, identity access throws
  `IdentityStorageError.defaultsUnavailable` before storage or migration; it
  never falls back to standard defaults. Identity PEM getters remain
  package-only.
- `ServerInfo`: construct the address, stable PC ID and name, set known ports
  and the previously authenticated certificate, and read pairing/readiness
  results. Codec negotiation fields remain package-only. `PairStatus`,
  `StreamError` and `PairingFailure` let the shell interpret results without
  string-matching private diagnostic details.
- `NetworkClient(server:identity:deviceName:)`, `fetchServerInfo`,
  `pinnedServerCertPEM`, `shutdown` and the shared `controlTimeout`: the device
  name is supplied by the shell. A saved certificate requires pinned mutual TLS;
  an unpaired HTTP discovery reply cannot install or replace a pin.
- `PairingClient(network:server:)` and `pair(pin:expectedUniqueId:)`: return the
  authenticated PC and certificate only after the five handshake requests and a
  pinned `fetchServerInfo(requiredUniqueId:)` bind the certificate to that PC.
  Missing or mismatched IDs reject pairing. Persist only the returned result.
  The package-only `pair(pin:)` keeps the Mac's existing two-step flow and its
  cancellation checks; the Mac still verifies the pinned identity before saving.
- `HostReachability.measureRTT` and its `Outcome`, plus `HostReadiness`'s
  predicate and bounded polling loop. The shell owns when to poll and cancel.
- `CertFingerprint.sha256`, `WakeOnLAN.normalizeMac` and `magicPacket`:
  certificate comparison and portable packet building. The shell sends packets.

Everything else added by this slice is package or internal access. Raw HTTP,
XML, crypto helpers, launch/resume, entropy seams and file migration helpers are
not an external API. The existing public RTSP smoke-test API is unchanged.

The first iPhone launcher also consumes `NetworkClient.appList()` and the
read-only `HostApp` values (`id`, `name`, `hdrCapable`, `hidden`). The existing
single pinned mutual-TLS request and hidden-app metadata remain unchanged.
`StreamFailureCopy.needsSunshineMessage` provides the shared requirement text.

The shared `LauncherArtCache` now owns the existing bounded Mac artwork cache.
Both shells use `NetworkClient.appAsset(appID:)` through the same pinned client;
`revision(for:)` accepts public `HostApp` values. Cache keys separate PCs and
app list revisions, negative entries suppress missing art, and decode/storage
limits remain unchanged. iOS chooses its Caches directory and requests artwork
only for visible Covers while foregrounded outside a stream; Buttons add no
requests.

`PinnedCertStore.load/store/delete` require the shell's explicit defaults,
Application Support base and protected-data availability closure. Store only an
authenticated pairing result under its verified PC ID. Protected-data
unavailability throws before storage access; load distinguishes an absent pin
from unreadable, empty or non-UTF8 storage and never substitutes a legacy pin
for a broken saved file. Delete reports failures rather than claiming success
while a pin survives. Existing Mac adapter methods and migration behavior remain
unchanged. PC metadata and the decision to pair or forget stay in the shell.

### iOS local-network requirements

The consuming app's Info.plist must include `NSLocalNetworkUsageDescription` and
`NSBonjourServices` entries for both `_nvstream._tcp` and `_nvstream-tcp._tcp`,
matching the engine's browsers. Start discovery while the app is foregrounded
and the person expects to find a PC: the first protected local-network operation
can trigger the system permission prompt. The system remembers the decision;
restarting discovery does not prompt again after a refusal. The shell owns the
explanation and Settings guidance. See Apple's
[local-network privacy requirements](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The engine reports Bonjour policy refusal through `HostDiscovery.Update.denied`;
consume it separately from an empty PC list. It does not present permission UI
or bypass the decision. An iOS shell owns its browser's lifetime and stops it
when discovery is no longer needed.

### Mac adapters and persistence

`MacIdentity` owns the singleton, Application Support lookup, Moonlight suite
selection and read-only adoption. `MacNetworkClient` supplies that identity, the
Mac computer name and `StreamConfig` overloads. `MacPinnedCertStore` supplies
existing defaults and paths. `MacWakeOnLAN` retains interface enumeration and
Darwin UDP sending; shared engine networking uses Network.framework. No AppKit,
IOKit, Keychain lookup or Mac home-directory lookup enters the engine.

Identity and pin stores require explicit bases; protected-data refusal does not
regenerate, overwrite, migrate or delete anything. The Mac adapter preserves its
existing legacy-pin fallback on write failure. External shells persist the
returned authenticated PEM with their PC record and restore it into
`ServerInfo.serverCertPEM`; Mac records and `glimmer.pinnedCert.*` migration
keys are unchanged. No new storage backend, keychain migration or iOS lifecycle
policy is introduced.

`PCCommunicationTests` belongs to both SwiftPM and the Mac test target. It
covers unavailable identity/pin stores, protected-data recovery, failing path
providers, denied/stale discovery runs, one-request unpaired polling and the
magic-packet layout. Existing Mac crypto, handshake, persistence, HTTP,
readiness and wake suites keep testing the same implementation through engine
imports.

After slice 3, live transport and session startup remained unavailable to the
external consumer. Slice 4 below closes those transport cuts. Hosted Xcode 26.6
verification and real-PC PIN/pin-rotation, discovery-denial, wake and poll
timing checks remain owner gates; local Xcode 27 builds are not that proof.

## Slice 4 implementation and Public API

The remaining `Glimmer/Stream/Native/` files now live in
`GlimmerEngine/Network/`: RTSP/handshake, all ENet features, UDP pings,
video/audio receive, timestamps, batch storage, reorder/FEC/depacketization,
input batching/sender and the shared route gate/RTT sampler. The queue-specific
`AudioFecDecoder+Recovery` extension becomes `AudioFecDecoder+Queue` to avoid
colliding with the existing engine recovery kernel. `NativeBackend` and its
Pipeline/Helpers/Input/Controllers features live in `GlimmerEngine/Session/`.
Battery and motion uplink methods moved out of the Mac controller files.
`AudioDiagnostics` moved from AudioDecoder+Worker to shared diagnostics,
retaining its queue label, QoS and deferred formatting.

### Public API

`StreamConnection` is a Sendable actor for one transport attempt. Construct it
with a `VideoSink`, an optional `NativeAudioSink`, and a Sendable event
callback. Call `connect(network:appID:configuration:)` with a previously paired
and polled `NetworkClient`. The client's cached authenticated PC record supplies
codec and session information. The same app resumes; another app uses the
existing launch request. There is no additional discovery, polling, readiness or
launch request. An invalid configuration or unpaired client fails before
credential loading.

`StreamConnection.Configuration` accepts dimensions, fps, bitrate, hardware
supported `VideoFormats`, `AudioConfig`, remote-path classification and optional
observed MTU. It preserves the shared remote packet-size clamp. The shell owns
route observation and quality selection; this API does not duplicate the Mac
session's pre-launch RTT sampling or recovery policy. Sinks receive the existing
`DecodeUnit`/`DecodeBuffer` and `OpusConfig` values. Return 0 for video success,
-1 to request an IDR; borrowed Opus bytes are valid only during the sink call.
Media decoding and presentation remain consumer responsibilities until slices
5–7. Backend resources, locks, wire packets and controller uplinks remain
internal or package-only.

Callbacks carry the immutable connection `id` and a `StreamConnection.Event`:
stage start/complete/failure, connected/terminated, connection quality, HDR
mode, and nonfatal audio failure. Calls are synchronous on the originating
engine thread; enqueue them in received order, avoid blocking, and reject IDs
belonging to an earlier connection. `stop()` is idempotent, stops local
transport, cancels a pending launch/resume and joins media workers; it does not
send PC quit. Cancelling connect cancels the launch/resume or interrupts the
live handshake. The attempt is reserved before reading the network actor, so a
second connect cannot launch concurrently and stop during that read prevents
launch. A stopped/used connection cannot be restarted. The Mac's existing
StreamSession still owns its original cancel/reconnect policy.

### Mac adapters and hot paths

`NativeConnectionEvents` stays app-side, injected before connect. Its existing
actor-event task chain and main-queue HDR/controller hops remain in place.
`StreamBridgeContext` records the originating backend identity under a lock;
late HDR/audio/state callbacks cannot update a replacement, including an HDR
operation already queued to main. Decoder recovery capabilities now come from
the supplied video sink at RTSP setup, and gate-lift diagnostics use a defaulted
sink method instead of a concrete decoder cast.

`MacTransport` supplies the existing `dlsym("recvmsg_x")` C function pointer and
unchanged audio/input realtime policies. `TransportPlatform` captures those
hooks once per connection; workers invoke scheduling once at thread startup. iOS
uses user-interactive QoS and public `recvmsg`, with no private batching or Mach
realtime policy symbols. Both receive paths retain ancillary timestamps, peer
checks and preallocated storage. Missing timestamps remain missing.

`MacStreamPath` retains interface/MTU observation and bounded TCP RTT syscalls.
The shared sampler accepts its measurement function; its existing launch wait
and sample limits are unchanged. `TransportRoute` holds the existing route label
under a lock inside the engine, so audio reorder never calls the app per packet.
Ping cadence/lifecycle hooks and counters retain the Mac environment
controller's policy; the standalone transport conservatively keeps the existing
fast cadence.

The receive, reorder, FEC and depacketization loops compile together in the
engine. `scripts/fuzz.sh` builds those same queue sources beside the wire/FEC
kernels in its instrumented Linux module; all five drivers import that module.
The Mac ASan suites still exercise the complete transport. No timers, queue
bounds, thread names, log categories, privacy annotations or telemetry field
names changed. Release undefined-symbol inspection and build/test evidence are
recorded in the slice handoff; hardware performance acceptance remains the
paired-run gate below.

Slice 5 must supply the audio output/route adapter while retaining the shared
packet worker's join-before-cleanup contract and nonfatal audio reporting.
Physical-PC checks still cover encrypted launch/resume, HDR changes, controller
feedback, ten reconnect/stop cycles and paired receive/CPU/power telemetry.
Local Xcode 27 compilation does not replace hosted Xcode 26.6 verification.

## Slice 5 implementation and Public API

`GlimmerEngine/Audio/` now owns `AudioDecoder` and its decode, admission,
playout, cushion memory, resampler, route recovery and diagnostics features, all
three Opus decoder files, the PCM ring and output-silence probes.
`Glimmer/EngineAdapters/` owns `MacAudio`, HAL device/output construction,
spatial routing, property listeners and device-volume reads. `StreamSession`
keeps its existing decoder construction through the Mac convenience initializer.

### Output adapter contract

Construct the public `AudioDecoder(platform:)` with explicit `AudioPlatform`
hooks, then supply it as the existing `NativeAudioSink` to `StreamConnection`.
The platform supplies an output factory, route identity, route/device listener
installation and removal, optional-volume observations and `AudioEnvironment`
evidence (PC identity, link class and measured jitter). There is no default
output, implicit platform selection or second decoder. Mac constants needed by
telemetry stay package-only; decoder state and PCM ring internals stay internal.

An output factory receives the negotiated planar float `AVAudioFormat`. It
creates `AudioRenderStorage` with the source channel count, installs its
`renderCallback` on the existing varispeed input, and installs `renderObserver`
with `context` on the final output mixer. Both callbacks execute inside the
engine. Return `AudioOutput` with actual output rate/channels/latency and hooks
for start, running-state checks, varispeed and last-render-error reads. Factory
failures can throw `AudioOutput.Failure(status:)`; start failures return
OSStatus. The shared recovery ladder remains armed while receive/decode
continues.

The output's closures retain a separate graph owner and its storage. The
long-lived platform adapter keeps only a weak graph reference: retaining the
graph independently would prevent decoder shutdown from disposing it. During
teardown call `storage.dispose(using:)` to stop and dispose every unit before
releasing the storage. A failed disposal permanently retains its raw callback
memory, even if a later disposal reports success. The adapter must never free or
repurpose callback context itself. Graph/listener hooks are serialized by the
decoder; route, environment and volume probes must be thread safe. Deliver
listener notifications asynchronously on the supplied queue, never inline during
a hook. Queued callbacks carry the decoder generation and cannot restart a
stopped or replacement session. Backend stop still joins the packet worker
before cleanup.

An iOS adapter should configure/activate `AVAudioSession` in the app, build its
public RemoteIO output using this storage, and report actual route values after
activation. Route changes, interruptions and media-services reset feed the same
shared recovery boundary. Start with stereo and retain AUVarispeed so shared
drift correction has the same meaning. This slice supplies and verifies the
public contract; it does not implement an iOS output graph or prove device
audio.

### Hot paths and verification

Opus decode, PCM enqueue/observe and pull/render-notify callbacks compile
together in the engine. Output hooks are used for graph operations, rate updates
and health/error checks off the render thread. The existing 10 ms monitor and
roughly 4 Hz rate-update cadence remain unchanged. No additional timer,
per-packet adapter callback, render allocation, lock or runtime metadata lookup
is added. Cushion thresholds, persisted keys, privacy, log wording and telemetry
names are preserved. The Mac supplies its existing route/jitter evidence off the
packet thread during seeding and bounded link resolution.

Boundary tests cover output failure and recovery, callbacks after shutdown or
reinitialization, shutdown during a blocked route rebuild, listener callback
identity, and disposal-failure storage retention. A public-only consumer test
constructs the shared sink from explicit hooks. The package is also compiled
from a separate Swift package identity to check public access. Existing audio,
spatial impulse, channel-layout, lifecycle, persistence and fuzz tests remain
part of the gate. Physical routes, audible equivalence, idle/load/recovery
telemetry and iPhone RemoteIO playback still need owner testing; local builds do
not establish those results.

## Paired slices 6 and 7: pacing and video

`GlimmerEngine/Pacing/` owns the existing pacer state, bounded queue, cadence
and rate-hint decisions, `CADisplayLink` target, tick thread and release queue.
`GlimmerEngine/Video/` owns `VideoDecoder`, VideoToolbox session and output
callbacks, bitstream/colour/HDR handling, presentation and backdrop sampling.
The decoded-frame handoff and renderer enqueue stay inside one module. These
slices are reviewed and validated as a pair; the intermediate pacer commit is
not a mergeable or performance-validated release boundary.

`MacPacer` supplies the NSView-bound link factory, scalar screen capabilities,
existing defaults and one-time Mach scheduling. `MacVideo` supplies NSScreen
headroom/name/refresh observations. Both adapters remain in
`Glimmer/EngineAdapters/`. The existing evidence reconciler publishes headroom
level/generation into `PacerHeadroom` at the same reconciliation/reset sites;
the release loop reads only shared engine storage. No per-frame adapter call,
new renderer, clock policy, timer or tuning change is introduced.

### Public video attachment contract

Construct `VideoDecoder(configuration:displayInfo:)` on main with the same
`StreamConnection.Configuration` used to connect. The display-info closure
returns current/potential EDR headroom, screen name and maximum refresh rate, or
nil for no display. It is sampled only for existing display/colour probes.
Attach the app-owned `AVSampleBufferDisplayLayer` through `attach(to:)`;
replacement attachments restore the decoder's current resolved colour/HDR state.

`startPacing(display:configuredFps:)` accepts `PacerDisplay`: a main-actor
factory that creates the platform's display-bound `CADisplayLink` with the
engine's NSObject target and selector, a scalar `PacerScreen` probe, a bind-time
`tickOffMain` preference closure, and a once-per-thread scheduling hook. Capture
the view weakly; a nil link means detached. The engine retains the target and
link and reads timestamps directly. iOS uses public display-link creation and an
empty scheduling hook; it must not copy the Mac Mach policy. Call
`pacingScreenDidChange()` on display changes. Stable screen signatures retain
the existing link; changed identity, scale or refresh capabilities rebind it.

Supply the decoder as `StreamConnection`'s video sink. Successful backend
adoption binds its existing IDR and HDR-metadata access internally; stopped
backends cannot adopt or bind a replacement. Consume ordered connection HDR
events and call `setHDR(enabled:)` once per current connection event. The
decoder reports resolved output through `onHDRActiveChanged` and first pixels
through `onFirstDecodedFrame`. A shell may set `rebuildDisplayLayerHook` to
replace and reattach its layer on a hard renderer failure.

Await connection stop before `teardown()`. Final teardown releases display
factory/probe, rebuild, first-frame and HDR callback contexts; nonfinal sink
stop/cleanup retains them for reconnect. The first-frame callback is main-actor
isolated and guarded by a connection-lifecycle generation, so replacing a live
layer preserves its pending notification while stopping cancels it. Stop
invalidates pending display ticks and releases; attachment generations reject
deferred colour, failure-recovery, and notification work from replaced or
detached layers. The shell owns foreground/background policy; iOS
disconnect/lock/background leave the PC game running. Mac watchdog and telemetry
helpers stay package-only. Public consumer tests construct, attach and stop real
engine objects without networking.

## Slice 8: synchronous input and prepared feedback

`GlimmerEngine/Input/` owns controller slot/arrival state, normalized
acceptance, button layout, stop-chord dwell, controller mouse/touchpad behavior,
pointer residuals, scroll quantization and release obligations. The engine
retains the existing feedback mapping, haptic coalescing/backoff, motion
rate/unit conversion, battery mapping and reconciliation cadence. Mac GC/raw-HID
capture, device routing, AppKit/Carbon ownership, native actuator objects and UI
stay in the Mac adapters. Window/capture pointer-mode policy stays native;
aspect-fit/origin mapping stays shared. A GC snapshot delivers touch once;
raw-HID centre-button updates only merge the registered controller's retained
axes and centre/shoulder state.

### Public input contract

Each `StreamConnection` owns one synchronous, Sendable `input` handle. Register
an actual controller descriptor to obtain an opaque `ControllerRegistration`;
all samples and prepared feedback/sensor attachments use that exact identity.
Unregister before releasing native capture. Slot reuse never authorizes a stale
callback. Controller arrival must succeed before state or touch is sent, and
failed releases block new presses until the existing reconciliation retry
accepts them. Connection lifecycle activation is ordered on a serial lifecycle
queue, leaving the backend state lock before input can send an arrival.

`submitController(_:sample:capturedAt:)` takes GC-normalized physical button
positions, triggers in [0,1], sticks in [-1,1] with Y up, optional GC touch
axes, and monotonic capture uptime. The engine owns layout, timing and wire
conversion. Nonfinite analog values become neutral; touch coordinates are
bounded and an invalid contact becomes absent. `setFocused(false)` releases
ownership. Before reopening input after native UI, capture a current snapshot
while unfocused; `setFocused(true)` suppresses each held button, axis and
contact independently until its release/neutral sample. Mac resynchronization
keeps its existing policy.

`movePointer` uses native pixels, positive right/down; `scroll` accepts precise
pixel deltas (or wheel lines when not precise), positive right/up. The shared
core retains fractions and owns wire quantization and absolute pointer mapping.
Pointer buttons and controller touch share release barriers. `setStopChord`
selects the existing presets; ordered `.input` connection events report local
stop requests, mouse mode and controller activity. Stop requests mean local
disconnect, with the PC game left running. Chord edges and delayed expiry both
validate capture generation, including release/repress and reused slots.

`ControllerFeedbackOutput` supplies scalar localities and prepared motor/light/
player-index functions. Its optional throwing factory receives shared sharpness
and intensity and returns a closure-owned `ControllerMotor`. Native start/reset/
stop operations stay in the adapter. The shared feedback queue owns mapping and
coalescing; cancellation revokes adoption synchronously, and a motor returned
late is disposed before queued cleanup. Each remaining actuation in a drained
batch rechecks the original ownership epoch; old feedback cannot replay after
resume. `ControllerMotionCapture` supplies raw acceleration in G and angular
velocity in radians/second plus native handler/power hooks; delayed callbacks
validate registration and ownership generation. `ControllerBatteryCapture`
supplies a main-actor raw state/level probe. The engine owns existing polling
and protocol conversion; applications add no sampler timer.

## Slice 9: shared session and native lifecycle ownership

`StreamSession` and its attempt, launch, recovery, watchdog, quality and
telemetry extensions compile in `GlimmerEngine/Session/`. The Mac app prepares
presentation/input hooks and activity, wake, logging and route services through
`MacSessionPresentation`, `MacSessionFeedback`, `MacSessionServices` and
`MacEnvironment`. It retains its existing windows, HUD, history and native input
forwarder. There is one session policy implementation and no second input owner
for the Mac path.

The external entry point is
`StreamSession.make(media:network:hostDisposition:diagnosticsDirectory:)`,
called on the main actor. The optional local diagnostics directory uses the
existing telemetry opt-in gate and session lifetime; the metrics listener stays
on loopback. It returns the session and one stable synchronous `StreamInput`.
`PreparedMedia` requires the actual `VideoDecoder`, `AudioDecoder`, a native
capture-quiesce closure and an awaited final-disposal closure. Attach native
rendering before calling `start(appID:configuration:)`; consume `session.events`
from creation. Each `Update` contains `sessionID`, `attemptID` and a
`StreamEvent`. Lifecycle events retain FIFO order and use the existing unbounded
stream, with no per-frame Task or actor relay. The Mac path allocates only its
legacy event stream. `waitingForVideo(Bool)` reports existing watchdog hold
transitions without changing input ownership. Explicit route MTU survives
recovery, and public startup/recovery preserve the low-level session-key
validation contract.

`StreamHostDisposition` is required and immutable. `.disconnectOnly` leaves the
PC app running on every stop/failure path and never enters cancellation-based
busy retry. Initial start uses the paired client's cached PC information and
resumes the same app or launches once. Recovery makes fresh clients with the
same identity, device name and transport; another nonzero app ends the local
session. `.cancelOwnedHostSession` retains the Mac's ownership checks, bounded
cancellation and late-launch cleanup. Diagnostic disconnect reasons do not grant
host cancellation capability.

Recovery retains media and physical controller registrations. It revokes the old
input attempt before closing its backend, releases held state and rebinds the
same handle to the replacement. Battery samples, feedback and decoder callbacks
retain their originating identity. Final stop is terminal, awaits native
disposal exactly once, emits `.stopped`, and finishes events. A stop before
start disposes prepared media without networking. `StreamConnection` remains
available as the low-level single-attempt compatibility API; it does not gain a
second recovery policy.

`EnvSignalController` folds the same evidence on the same cadence in the engine.
`EnvObservationSource` owns optional native route/radio observations; missing
observations remain unknown. Late samples are rejected after stop or
replacement, and native probe cleanup is idempotent. Public
`StreamSession.audioEnvironment(host:)` exposes shared link and smoothed jitter
evidence to the native audio adapter. No pacing, bitrate, timeout or media
defaults are retuned by this extraction.

The source/package, Mac, device and Simulator gates, exact-revision hosted
Verify/CodeQL, optimized boundary audit, and physical stream/performance
acceptance remain required before this slice is declared complete. Consumer pins
change only after the reviewed engine revision is published.

## Consumer boundary closure (slice 10)

`StreamFailure` classifies start errors and termination codes without choosing
native controls or wording. Its associated messages are transport/server
presentation inputs and may contain Mac wording; a consumer can use local copy
for the neutral reason instead. The Mac retains its exact sentences, video
history lookup and existing fallback for non-`StreamError` failures.

`RouteBitratePolicy` owns scalar route selection, codec/boost multiplication,
floor/cap rounding, PHY gating and reconnect host matching. Native route probes,
preferences and measured boost defaults remain in `AppModel`; the package-only
policy receives those values explicitly. `StreamQuality.videoFormats` owns the
SDR format mask. These cuts add no mobile tuning API or changes to the iPhone's
explicit 1080p/60 H.264, 20 Mbps, stereo baseline.

`make check` now runs `scripts/check-engine-boundary.py`. The persistent audit
checks unique Xcode objects/source membership, agreement with SwiftPM's engine
sources, dependency/import direction and the committed shared engine scheme.
Existing native helper source sharing and generated `BuildInfo` remain explicit
exceptions. Lint, CodeQL/coverage filters and signing fixtures include the
engine.

These are source-ownership and reproducible-build closures. Final reviewed-tree
Verify, ASan fuzz, platform builds and all three CodeQL jobs remain gates;
framework loading, app/CLI identity, real-PC media/input and CPU/energy
acceptance still require the owner-installed published RC. Extraction keeps RC
disabled.

## Ownership map

Baseline extraction inventory: **245 Stream files, 4 Models files, all 63 root
Swift files, and 8 CLI files**. Rows track those original files and their
ownership cuts; the persistent boundary audit checks the current engine source
inventory and target membership. Paths below are relative to each original
heading.

| Code  | Ownership and meaning                                                                                                                                                                                                                                                        |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E     | Engine, portable across the intended Apple platforms after shared dependencies move. Apple media frameworks and Darwin do not by themselves mean Mac-only. This is source review, not an iOS compile result.                                                                 |
| W     | Engine-with-adapter. Shared logic moves; the named platform operation or app type stays in a Mac adapter. A transitive blocker means an extension inherits coupling from its base type. Wholly platform implementations become adapter files, not dummy iOS implementations. |
| A     | App-only. A pure shell policy can be A without an unavailable API; those rows explicitly say so.                                                                                                                                                                             |
| Slice | First owning extraction slice; `1/2`, etc. denotes an explicit split. A rows stay app-side and are rewired only by their indicated slice.                                                                                                                                    |

### Glimmer/Stream/Native

| File                                       | Owner | Blocking symbol or move boundary                                                                                  | Slice |
| ------------------------------------------ | ----- | ----------------------------------------------------------------------------------------------------------------- | ----- |
| `AudioFecDecoder.swift`                    | E     | Pure wire layout, parsing, crypto-independent values or FEC.                                                      | 1     |
| `AudioPacketWorker.swift`                  | W     | thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY); Mac scheduling hook, shared owned worker and join.              | 4     |
| `DatagramBatch.swift`                      | W     | dlsym("recvmsg_x"); inject batch receive, retain public recvmsg fallback and buffer ownership.                    | 4     |
| `EnetControlChannel+ControlLoop.swift`     | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `EnetControlChannel+ControlMessages.swift` | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `EnetControlChannel+Handshake.swift`       | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `EnetControlChannel+Inbound.swift`         | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `EnetControlChannel+Send.swift`            | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `EnetControlChannel.swift`                 | E     | Portable control channel; lift AtomicCounter into shared diagnostics in slice 2.                                  | 2/4   |
| `EnetWire.swift`                           | E     | Pure wire layout, parsing, crypto-independent values or FEC.                                                      | 1     |
| `InputBatcher.swift`                       | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `InputCallbackProbe.swift`                 | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `InputEncoder.swift`                       | E     | Pure wire layout, parsing, crypto-independent values or FEC.                                                      | 1     |
| `InputSendThread.swift`                    | W     | thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY); Mac scheduling hook, shared owned worker and join.              | 4     |
| `ReceiveTiming.swift`                      | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `ReedSolomon.swift`                        | E     | Pure wire layout, parsing, crypto-independent values or FEC.                                                      | 1     |
| `RtpAudioQueue+Fec.swift`                  | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioQueue.swift`                      | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Decrypt.swift`           | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Events.swift`            | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Ping.swift`              | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Receive.swift`           | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Socket.swift`            | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+StartupGate.swift`       | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver+Telemetry.swift`         | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpAudioReceiver.swift`                   | E     | Move NativeAudioSink contract in slice 2, receiver and lifetime in slice 4.                                       | 2/4   |
| `RtpVideoQueue+AddPacket.swift`            | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpVideoQueue+ReceiveQuality.swift`       | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpVideoQueue+Reconstruct.swift`          | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpVideoQueue+ReorderStats.swift`         | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtpVideoQueue.swift`                      | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtspClient+Handshake.swift`               | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `RtspClient.swift`                         | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `SdpCodec.swift`                           | E     | Pure wire layout, parsing, crypto-independent values or FEC.                                                      | 1     |
| `SocketTimestamp.swift`                    | W     | SO_TIMESTAMP_MONOTONIC / SCM_TIMESTAMP_MONOTONIC; SDK/runtime capability and missing-value path.                  | 4     |
| `StreamCrypto.swift`                       | E     | Move ControlCrypto first; VideoDecryptor keeps its Diag breadcrumb until diagnostics move.                        | 1/2   |
| `StreamPathMTU.swift`                      | W     | ioctl(SIOCGIFMTU), getifaddrs route probe; inject observed route/MTU, retain shared gate and existing RTT budget. | 4     |
| `UdpPinger.swift`                          | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `VideoDepacketizer+AnnexB.swift`           | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `VideoDepacketizer+FrameHeader.swift`      | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `VideoDepacketizer.swift`                  | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `VideoRtpReceiver+Recovery.swift`          | E     | Portable protocol/transport logic; shared diagnostics from slice 2.                                               | 4     |
| `VideoRtpReceiver.swift`                   | W     | DatagramBatch receive strategy; preserve pooling, peer checks and timestamp provenance.                           | 4     |

### Glimmer/Stream

| File                                       | Owner | Blocking symbol or move boundary                                                                                      | Slice |
| ------------------------------------------ | ----- | --------------------------------------------------------------------------------------------------------------------- | ----- |
| `AudioDecoder+CushionMemory.swift`         | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder+Decode.swift`                | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder+Engine.swift`                | W     | AudioHALOutput / AudioObjectID and HAL graph or route state; retain shared playout/recovery.                          | 5     |
| `AudioDecoder+Meter.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder+Prime.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder+Resampler.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder+Route.swift`                 | W     | AudioHALOutput / AudioObjectID and HAL graph or route state; retain shared playout/recovery.                          | 5     |
| `AudioDecoder+Spatial.swift`               | W     | Actually extends AudioHALOutput; kAudioUnitProperty_SpatialMixer\* graph remains Mac adapter.                         | 5     |
| `AudioDecoder+Worker.swift`                | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioDecoder.swift`                       | W     | AudioHALOutput / AudioObjectID and HAL graph or route state; retain shared playout/recovery.                          | 5     |
| `AudioHALDevice.swift`                     | W     | AudioObjectGetPropertyData / kAudioUnitSubType_HALOutput; Mac device/output/spatial adapter.                          | 5     |
| `AudioHALOutput.swift`                     | W     | AudioObjectGetPropertyData / kAudioUnitSubType_HALOutput; Mac device/output/spatial adapter.                          | 5     |
| `AudioPCMQueue.swift`                      | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `AudioPipelineTelemetry.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `BitrateDownshiftController.swift`         | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 9     |
| `ControlTransport.swift`                   | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `ControllerBattery.swift`                  | W     | DualSenseHID / InputForwarder; split NativeBackend battery method into framework with slice 4.                        | 4/8   |
| `ControllerButtonLayout.swift`             | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerForwarder+HID.swift`            | W     | HIDGamepadManager / HIDGamepadDevice; Mac capture adapter supplies canonical slot/state values.                       | 8     |
| `ControllerForwarder+Mouse.swift`          | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerForwarder+QuitChord.swift`      | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerForwarder+StatePush.swift`      | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerForwarder+Touchpad.swift`       | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerForwarder+TouchpadMouse.swift`  | E     | Pure ControllerTouchpadMouseState; share pointer/scroll semantics.                                                    | 8     |
| `ControllerForwarder.swift`                | W     | InputForwarder extension / GCController capture or actuator objects; move semantics to shared input state.            | 8     |
| `ControllerHaptics+Actuation.swift`        | W     | DualSenseHID output merge / NSApplication lifecycle; GameController/CoreHaptics actuator adapter.                     | 8     |
| `ControllerHaptics.swift`                  | W     | DualSenseHID output merge / NSApplication lifecycle; GameController/CoreHaptics actuator adapter.                     | 8     |
| `ControllerMotion.swift`                   | W     | GCController sensor capture; split NativeBackend motion method into framework with slice 4.                           | 4/8   |
| `Discovery.swift`                          | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `DisplayTelemetry.swift`                   | E     | Already consumes a main-actor DisplayProbe closure; NSScreen exists only at caller.                                   | 2     |
| `DualSenseBinder.swift`                    | A     | Mac raw-HID side-channel consumer; pure state/binding helpers remain with that adapter.                               | 8     |
| `DualSenseDeviceState.swift`               | A     | Mac raw-HID side-channel consumer; pure state/binding helpers remain with that adapter.                               | 8     |
| `DualSenseHID+Decode.swift`                | A     | Extension of Mac DualSenseHID; report parsing stays with raw-HID adapter.                                             | 8     |
| `DualSenseHID.swift`                       | A     | IOHIDManager / IOHIDDeviceRegisterInputReportWithTimeStampCallback / IOHIDDeviceSetReport.                            | 8     |
| `DualSenseRouting.swift`                   | A     | DualSenseHID plus GCController device correlation; Mac side-channel routing.                                          | 8     |
| `EnvSignalController+Evidence.swift`       | W     | StreamRouteProbe construction and lifetime; supplied route observer, shared evidence handling.                        | 9     |
| `EnvSignalController+Tunables.swift`       | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 9     |
| `EnvSignalController.swift`                | W     | StreamRouteProbe stored state from WiFiTelemetry; inject observed route, retain shared recovery decisions.            | 9     |
| `FramePacer+AdaptiveDepth.swift`           | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+Constants.swift`               | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+DeficitTimer.swift`            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+DueGate.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+FrameRateRange.swift`          | W     | NSView.displayLink / NSScreen through FramePacer attachment; scalar ticks and lifecycle hooks.                        | 6     |
| `FramePacer+Recovery.swift`                | W     | NSView.displayLink / NSScreen; lift LivenessSnapshot/RefreshWindowSnapshot values in 2, pacing in 6.                  | 2/6   |
| `FramePacer+State.swift`                   | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+Submit.swift`                  | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+Tick.swift`                    | W     | NSView.displayLink / NSScreen through FramePacer attachment; scalar ticks and lifecycle hooks.                        | 6     |
| `FramePacer+TickDeficit.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+TickDeficitEvents.swift`       | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 6     |
| `FramePacer+TickThread.swift`              | W     | Mac tick-thread scheduling via thread_policy_set; attach/detach on owned run loop.                                    | 6     |
| `FramePacer.swift`                         | W     | NSView.displayLink / NSScreen through FramePacer attachment; scalar ticks and lifecycle hooks.                        | 6     |
| `IOReportSampler.swift`                    | W     | Private IOReport dlopen/dlsym; Mac-only optional probe, preserve process-lifetime objects.                            | 2     |
| `Identity+Crypto.swift`                    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `Identity+Loading.swift`                   | W     | FileIdentityStore supportRoot / moonlightQtSuite migration; inject container/protection policy, keep Mac paths.       | 3     |
| `Identity.swift`                           | W     | FileIdentityStore supportRoot / moonlightQtSuite migration; inject container/protection policy, keep Mac paths.       | 3     |
| `InputCore+Controller.swift`               | W     | InputForwarder.TouchpadState / attached GCController state; promote canonical snapshots and release ledger.           | 8     |
| `InputCore.swift`                          | W     | InputForwarder.TouchpadState / attached GCController state; promote canonical snapshots and release ledger.           | 8     |
| `InputForwarder+Capture.swift`             | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+CommandKeyUp.swift`        | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+Core.swift`                | W     | InputForwarder extension forwards into InputCore; capture owner remains Mac-side.                                     | 8     |
| `InputForwarder+Cruise.swift`              | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+EscapeHold.swift`          | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+HoverCapture.swift`        | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+Lifecycle.swift`           | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+Paste.swift`               | W     | NSPasteboard / NSEvent; app supplies resolved text to shared UTF-8 sender.                                            | 8     |
| `InputForwarder+Reconciliation.swift`      | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+Releases.swift`            | W     | Lift pure InputReleaseLedger in slice 2; InputForwarder release methods stay app-side until 8.                        | 2/8   |
| `InputForwarder+StreamView.swift`          | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder+SystemKeys.swift`          | W     | NSEvent plus private CGSMainConnectionID / CGSSetGlobalHotKeyOperatingMode; Mac-only.                                 | 8     |
| `InputForwarder+WindowPointer.swift`       | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputForwarder.swift`                     | W     | AppKit InputForwarder / NSEvent / NSView transitively; retain Mac capture, extract canonical input logic.             | 8     |
| `InputLatency.swift`                       | E     | Portable timing; lift InputReleaseLedger.Release with diagnostics before remaining input moves.                       | 2     |
| `KeyboardScanMap.swift`                    | A     | Carbon.HIToolbox Mac virtual-key map; iOS capture maps public key codes separately.                                   | 8     |
| `ModifierSides.swift`                      | A     | NSEvent.ModifierFlags; Mac left/right modifier interpretation.                                                        | 8     |
| `MouseAccelerationControl.swift`           | A     | IOServiceOpen / IOConnectSetCFProperty on IOHIDSystem; Mac restore-on-release adapter.                                | 8     |
| `NativeBackend+Helpers.swift`              | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 4     |
| `NativeBackend+Input.swift`                | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 4     |
| `NativeBackend+Pipeline.swift`             | W     | as? VideoDecoder HDR cast and events.bridge; route through existing ConnectionEvents.setHdrMode and status events.    | 4     |
| `NativeBackend.swift`                      | W     | NativeConnectionEvents.bridge: StreamBridgeContext; extract callback sink, keep ordered lifecycle delivery.           | 4     |
| `Network+Support.swift`                    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `Network.swift`                            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `NetworkClient+Endpoints.swift`            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `NetworkClient+Request.swift`              | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `OpusDecoder+Packet.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `OpusDecoder+Stream.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `OpusDecoder.swift`                        | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 5     |
| `PEM.swift`                                | E     | SecIdentityCreate is public on iOS (header: 11.2+); DER/PEM and in-memory identity stay shared.                       | 3     |
| `Pairing+Crypto.swift`                     | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `Pairing.swift`                            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 3     |
| `PointerMapping.swift`                     | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 8     |
| `ReceiveTimingTelemetry.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `RendererTelemetry+Compositing.swift`      | W     | Pure renderer path values/tracker move in 2; extension VideoDecoder stays with decoder until 7.                       | 2/7   |
| `RendererTelemetry.swift`                  | E     | AVSampleBufferVideoRenderer metrics; availability-gate and preserve unavailable state.                                | 2     |
| `ResourceTelemetry.swift`                  | W     | IOKit.ps IOPSCopyPowerSourcesInfo and raw THREAD_QOS_POLICY probe; split public own-process metrics.                  | 2     |
| `ScrollQuantizer.swift`                    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 8     |
| `Signposts.swift`                          | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `SpatialAudio.swift`                       | W     | AudioObjectGetPropertyData / kAudioUnitSubType_HALOutput; Mac device/output/spatial adapter.                          | 5     |
| `StatsCollector+Record.swift`              | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `StatsCollector.swift`                     | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `StatsOverlayLayer+Rows.swift`             | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StatsOverlayLayer+Traces.swift`           | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StatsOverlayLayer.swift`                  | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamBannerLayer.swift`                  | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamBridgeContext.swift`                | W     | StreamSession / InputForwarder weak references; session bridge stays app-side until slice 9.                          | 4/9   |
| `StreamHistory.swift`                      | A     | StreamHistoryFeed feeds menu-bar UI at 4 Hz; pure shell history, no unavailable API.                                  | 9     |
| `StreamInputView+Text.swift`               | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamInputView.swift`                    | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamProtocolConstants.swift`            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 1     |
| `StreamSession+Attempt.swift`              | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Callbacks.swift`            | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Connect.swift`              | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Downshift.swift`            | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+FrameWatchdog.swift`        | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Lifecycle.swift`            | W     | Window/input shutdown and ProcessInfo activity assertion; preserve shared teardown order.                             | 9     |
| `StreamSession+PresentMetric.swift`        | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+PresentTrip.swift`          | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Reconnect.swift`            | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Start.swift`                | W     | StreamWindow construction, NSScreen, InputForwarder; attach through app-owned prepared media/input hooks.             | 9     |
| `StreamSession+StartSetup.swift`           | W     | StreamWindow construction, NSScreen, InputForwarder; attach through app-owned prepared media/input hooks.             | 9     |
| `StreamSession+StatsOverlayTimer.swift`    | W     | MacSystemStats / StreamHistoryFeed / overlay presentation; keep shell refresh, shared stats snapshots.                | 9     |
| `StreamSession+Telemetry.swift`            | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession+Wake.swift`                 | W     | NSWorkspace wake observers; app lifecycle adapter supplies wake/reanchor event.                                       | 9     |
| `StreamSession+Watchdog.swift`             | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamSession.swift`                      | W     | Extension of StreamSession owning StreamWindow / InputForwarder; extract shared session state and decisions.          | 9     |
| `StreamWindow+Cursor.swift`                | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+Fade.swift`                  | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+MiniPlayer.swift`            | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+PointerAffordances.swift`    | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+RendererDiagnostics.swift`   | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+Show.swift`                  | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+Slide.swift`                 | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+Views.swift`                 | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow+Windowed.swift`              | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindow.swift`                       | A     | NSWindow / NSView / AppKit layer presentation; Mac shell.                                                             | 7     |
| `StreamWindowCloseState.swift`             | A     | Pure Mac window geometry/close policy; no unavailable API, shell-owned.                                               | 7     |
| `StreamWindowGeometry.swift`               | A     | Pure Mac window geometry/close policy; no unavailable API, shell-owned.                                               | 7     |
| `StreamingBackend.swift`                   | E     | Split wire values in slice 1; move existing sink/backend contracts with NativeAudioSink in slice 2.                   | 1/2   |
| `TelemetryCounters+AudioGauges.swift`      | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters+AudioSkew.swift`        | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters+Gauges.swift`           | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters+InputActivity.swift`    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters+Lifecycle.swift`        | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters+Types.swift`            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryCounters.swift`                  | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+AudioPipeline.swift`    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+Capture.swift`          | W     | Exporter owns WiFiTelemetry / IOReportSampler / ResourceTelemetry; inject optional sampled values.                    | 2     |
| `TelemetryExporter+CaptureExtras.swift`    | W     | DualSenseHID.shared and EnvSignalController.shared; app-supplied optional HID/evidence snapshots.                     | 2     |
| `TelemetryExporter+CaptureSections.swift`  | W     | Exporter owns WiFiTelemetry / IOReportSampler / ResourceTelemetry; inject optional sampled values.                    | 2     |
| `TelemetryExporter+Render.swift`           | W     | SCDynamicStoreCopyLocalHostName / ProcessInfo.hostName; app provides per-install pseudonym input.                     | 2     |
| `TelemetryExporter+RenderAudio.swift`      | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderInput.swift`      | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderNDJSON.swift`     | W     | ProcessMetrics task_threads probe mixed with rendering; split probe from portable serializer.                         | 2     |
| `TelemetryExporter+RenderNDJSONLink.swift` | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderNetwork.swift`    | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderP2.swift`         | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderRenderer.swift`   | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderSystem.swift`     | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+RenderVideo.swift`      | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter+Sinks.swift`            | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryExporter.swift`                  | W     | IOReportSampler.shared, WiFiTelemetry, homeDirectoryForCurrentUser; inject probes and output directory.               | 2     |
| `TelemetryFrameTrace.swift`                | W     | Default TelemetryExporter.logsDirectory points to Mac home; use supplied diagnostics directory.                       | 2     |
| `TelemetryLatency+Composites.swift`        | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryLatency+Trace.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryLatency.swift`                   | W     | Default TelemetryExporter.logsDirectory points to Mac home; use supplied diagnostics directory.                       | 2     |
| `TelemetryLatencyHistograms.swift`         | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetryLatencySnapshot.swift`           | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetrySessionAggregate.swift`          | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetrySessionEvents.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 2     |
| `TelemetrySessionReport.swift`             | W     | EnvSignalController.shared keepalive totals; serialize supplied shared snapshot, no app singleton lookup.             | 2     |
| `TelemetrySnapshot.swift`                  | E     | Value schema; lift FramePacer snapshot values early; remove StreamDisplayMode default dependency.                     | 2     |
| `Types+Cert.swift`                         | W     | PinnedCertStore.supportRoot/defaults migration; supplied storage environment. PairStatus value moves in 2.            | 2/3   |
| `Types+Stats.swift`                        | A     | StatsRow / StatsOverlayPreset / StatsThresholds are pure HUD policy; keep shell-owned.                                | 2     |
| `Types+StatsSnapshot.swift`                | W     | MacSystemStatsSnapshot and HUD row formatting; move media values, retain shell formatting.                            | 2     |
| `Types.swift`                              | W     | AppModel.needsSunshineMessage, Mac presentation fields and hw.optional.arm64; extract shared error copy/capabilities. | 2     |
| `VideoDecoder+API.swift`                   | W     | NSView drivingView / NSScreen through decoder attachment; layer and display capabilities supplied by app.             | 7     |
| `VideoDecoder+AV1.swift`                   | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Backdrop.swift`              | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Backlog.swift`               | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Bitstream.swift`             | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Color.swift`                 | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+ColorProbe.swift`            | W     | NSView drivingView / NSScreen through decoder attachment; layer and display capabilities supplied by app.             | 7     |
| `VideoDecoder+Decode.swift`                | E     | Media-only methods after base attachment split; remove unused AppKit import, audit SDK availability.                  | 7     |
| `VideoDecoder+DecodeTelemetry.swift`       | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+GovernorRepaint.swift`       | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+HDR.swift`                   | E     | Media-only methods after base attachment split; remove unused AppKit import, audit SDK availability.                  | 7     |
| `VideoDecoder+HDRMetadata.swift`           | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Pacing.swift`                | W     | NSView drivingView / NSScreen through decoder attachment; layer and display capabilities supplied by app.             | 7     |
| `VideoDecoder+Session.swift`               | E     | Media-only methods after base attachment split; remove unused AppKit import, audit SDK availability.                  | 7     |
| `VideoDecoder+Sink.swift`                  | E     | Portable logic; preserve existing ownership and shared dependencies.                                                  | 7     |
| `VideoDecoder+Suppression.swift`           | E     | Media-only methods after base attachment split; remove unused AppKit import, audit SDK availability.                  | 7     |
| `VideoDecoder.swift`                       | W     | NSView drivingView / NSScreen through decoder attachment; layer and display capabilities supplied by app.             | 7     |
| `WiFiRoamWatch.swift`                      | W     | CWWiFiClient / CWEventDelegate; Mac roam observation, shared evidence values.                                         | 2     |
| `WiFiTelemetry.swift`                      | W     | CoreWLAN CWWiFiClient; NWPath route values shared, RSSI/PHY probe Mac-only.                                           | 2     |

### Glimmer/Stream/HIDGamepad

| File                          | Owner | Blocking symbol or move boundary                                               | Slice |
| ----------------------------- | ----- | ------------------------------------------------------------------------------ | ----- |
| `GameControllerDB+Data.swift` | A     | Pure Mac raw-HID support/data; no unavailable API, retained with its consumer. | 8     |
| `HIDGamepadCapture.swift`     | A     | IOHIDDevice / IOHIDManager / IOHIDValue callbacks; Mac-only capture.           | 8     |
| `HIDGamepadCard.swift`        | A     | SwiftUI HIDGamepadCard / HIDGamepadManager; diagnostics UI.                    | 8     |
| `HIDGamepadDevice.swift`      | A     | IOHIDDevice / IOHIDManager / IOHIDValue callbacks; Mac-only capture.           | 8     |
| `HIDGamepadElements.swift`    | A     | Pure Mac raw-HID support/data; no unavailable API, retained with its consumer. | 8     |
| `HIDGamepadManager.swift`     | A     | IOHIDDevice / IOHIDManager / IOHIDValue callbacks; Mac-only capture.           | 8     |
| `HIDGamepadMapping.swift`     | A     | Pure Mac raw-HID support/data; no unavailable API, retained with its consumer. | 8     |
| `HIDGamepadRumble.swift`      | A     | ForceFeedback FFCreateDevice / IOKit service; Mac-only actuation.              | 8     |
| `HIDInputThread.swift`        | A     | Pure Mac raw-HID support/data; no unavailable API, retained with its consumer. | 8     |

### Glimmer/Models

| File                        | Owner | Blocking symbol or move boundary                                                                            | Slice  |
| --------------------------- | ----- | ----------------------------------------------------------------------------------------------------------- | ------ |
| `BitrateMode.swift`         | E     | Portable bitrate/codec preference semantics.                                                                | 2      |
| `Host.swift`                | W     | LibraryApp.icon: SwiftUI.Image, LauncherStyle and Mac preference copy; extract PC/app/input/quality values. | 2      |
| `HostCodecPreference.swift` | E     | Portable bitrate/codec preference semantics.                                                                | 2      |
| `StreamDisplayMode.swift`   | A     | Pure Mac fullScreen/window preference; extract StreamSizeBounds into shared values, retain persisted mode.  | 2/9/10 |

### Glimmer

| File                                            | Owner | Blocking symbol or move boundary                                                                                                                   | Slice  |
| ----------------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `AWDLHelperManager.swift`                       | A     | SMAppService.daemon / NSXPCConnection / AWDLEnablePrompt; helper offer remains in Mac app.                                                         | 9      |
| `AWDLHelperRecovery.swift`                      | A     | Mac AWDL service/process/lease policy; no iOS helper equivalent.                                                                                   | 9      |
| `AWDLProcess.swift`                             | A     | Foundation.Process and ifconfig child process; Mac helper support.                                                                                 | 9      |
| `AWDLStreamLease.swift`                         | A     | Mac AWDL service/process/lease policy; no iOS helper equivalent.                                                                                   | 9      |
| `AboutPane.swift`                               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `AppModel+Audio.swift`                          | A     | MutedOutput / CoreAudio AudioObject APIs; Mac local-output muting and restoration.                                                                 | 9      |
| `AppModel+CommandURL.swift`                     | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+Commands.swift`                       | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+Defaults.swift`                       | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+Derived.swift`                        | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+HostRoute.swift`                      | W     | HostRouteMonitor tied to AppModel; share NWPath route values, retain observation/publication.                                                      | 9      |
| `AppModel+Lifecycle.swift`                      | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+MenuBar.swift`                        | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+Pairing.swift`                        | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+Power.swift`                          | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+RawHID.swift`                         | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel+SessionReceipt.swift`                 | A     | SessionReceiptStore app persistence and notification copy; pure shell consumer.                                                                    | 9      |
| `AppModel+StreamFailure.swift`                  | W     | AppModel presentation dependency; shared Sunshine requirement copy moves in 2, neutral classification completed in 10; native copy/history remain. | 2/9/10 |
| `AppModel+Streaming+Config.swift`               | W     | Native preferences/display/route inputs; scalar request/bitrate policy shared in 9/10, Mac defaults retained.                                      | 9      |
| `AppModel+Streaming.swift`                      | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `AppModel.swift`                                | A     | AppModel @MainActor shell orchestration; construct engine request and adapters here.                                                               | 9      |
| `ContainerMigration.swift`                      | A     | AppModel/UserDefaults and Mac container or Moonlight migration; keep persistence orchestration app-side.                                           | 3      |
| `ContentView+ConnectBanner.swift`               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentView+Covers.swift`                      | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentView+Menus.swift`                       | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentView+ReadinessChip.swift`               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentView+StreamButton.swift`                | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentView.swift`                             | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ContentViewSubviews.swift`                     | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `ControllerInputTestView.swift`                 | A     | SwiftUI/AppKit test UI plus ControllerBackgroundEvents; keep Mac background ownership outside engine.                                              | 8      |
| `DiagnosticsPane.swift`                         | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `GlimmerApp.swift`                              | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `GlimmerIntents.swift`                          | A     | AppIntents PCEntity / AppModel dispatch; Mac product entry point.                                                                                  | 10     |
| `HostStatusPoller.swift`                        | A     | NSApp / AppModel foreground polling; no extra engine launch request.                                                                               | 3      |
| `HostsStore.swift`                              | A     | AppModel/UserDefaults and Mac container or Moonlight migration; keep persistence orchestration app-side.                                           | 3      |
| `LauncherArtCache.swift`                        | A     | App artwork cache/storage policy; NetworkClient fetch shared, decoded artwork stays shell-side.                                                    | 3      |
| `LauncherController.swift`                      | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `LauncherNavigation.swift`                      | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `LauncherStyle.swift`                           | A     | Pure pairing/launcher/menu presentation state; no unavailable API, shell-owned.                                                                    | 10     |
| `LogStore.swift`                                | W     | SessionLogFileSink default TelemetryExporter.logsDirectory; shared Diag/privacy/ring, supplied file destination.                                   | 2      |
| `LogViewerView.swift`                           | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `MacSystemStats.swift`                          | W     | IOKit.ps plus machine-wide host_statistics; Mac probe, neutral optional snapshot for engine.                                                       | 2      |
| `MenuBarChartAccessibility.swift`               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `MenuBarPanel+Charts.swift`                     | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `MenuBarPanel.swift`                            | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `MenuBarPresentation.swift`                     | A     | Pure pairing/launcher/menu presentation state; no unavailable API, shell-owned.                                                                    | 10     |
| `Motion.swift`                                  | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `PairSheet+Launcher.swift`                      | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `PairSheet.swift`                               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `PairingAttempt.swift`                          | A     | Pure pairing/launcher/menu presentation state; no unavailable API, shell-owned.                                                                    | 10     |
| `QualityCalculator.swift`                       | W     | extension AppModel, NSScreen / CGDisplayCopyAllDisplayModes; move math, inject capability values.                                                  | 9      |
| `SettingsGeneralStreamingPanes+LoginItem.swift` | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `SettingsGeneralStreamingPanes.swift`           | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `SettingsInput+NintendoLayout.swift`            | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `SettingsPCsShortcutsPanes.swift`               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `SettingsShortcutRecorders.swift`               | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `SettingsView.swift`                            | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `StatsOverlaySettings.swift`                    | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `StreamingState.swift`                          | A     | Pure pairing/launcher/menu presentation state; no unavailable API, shell-owned.                                                                    | 10     |
| `TerminationGate.swift`                         | A     | NSApplication termination coordination; await shared session teardown.                                                                             | 9      |
| `TroubleshootingPane.swift`                     | A     | AppKit/SwiftUI shell or shell-owned state; imports engine only at use sites.                                                                       | 10     |
| `UpdaterController.swift`                       | A     | Sparkle / SPUStandardUpdaterController; Mac update presentation.                                                                                   | 10     |
| `WakeOnLAN.swift`                               | E     | Darwin UDP magic-packet logic; iOS entitlement/network-permission acceptance remains Phase 2.                                                      | 3      |

### Glimmer/CLI

| File                             | Owner | Blocking symbol or move boundary                                                            | Slice |
| -------------------------------- | ----- | ------------------------------------------------------------------------------------------- | ----- |
| `CommandLineToolInstaller.swift` | A     | Mac command symlink installation; app-only, no Phase 0 execution.                           | 10    |
| `GlimmerCLI+Commands.swift`      | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerCLI+JSON.swift`          | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerCLI+List.swift`          | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerCLI+Stream.swift`        | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerCLI+URL.swift`           | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerCLI.swift`               | A     | GlimmerCLI / AppModel / CommandChannel; Mac executable entry point, shared engine consumer. | 10    |
| `GlimmerMain.swift`              | A     | App/CLI dispatch and real-path re-exec; preserve Bundle.main and app identity.              | 10    |

## Platform and private API boundaries

Private SPI and public Mac-only API are separate concerns. Keep the Mac
implementation; iOS source membership must exclude private code and its symbol
strings, not just skip a failed lookup.

| Current dependency                                                   | Status                                           | iOS replacement or adapter contract                                                                                                                                                                                                                    |
| -------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dlsym("recvmsg_x")`, DatagramBatch                                  | Private Darwin SPI                               | Compile only the existing public `recvmsg` single-datagram path; preserve preallocated storage, peer validation and truncation checks. Benchmark packet rate, drops and CPU before considering another public receive API. Mac batching stays intact.  |
| `SO_TIMESTAMP_MONOTONIC`, `SCM_TIMESTAMP_MONOTONIC`                  | Darwin ancillary timestamp capability            | Check minimum SDK declarations and runtime `setsockopt` success. Unsupported means missing kernel-arrival timing; retain userspace-read timing with its existing distinct meaning. Never substitute zero or relabel a timestamp.                       |
| IOReport `dlopen`/`dlsym` functions                                  | Private Mac energy/residency API                 | No iOS equivalent in the engine. Omit rail fields; use Instruments/device energy evidence outside normal playback. Preserve Mac sampler process-lifetime retention and baseline resets.                                                                |
| `THREAD_QOS_POLICY = 9`, Mach thread-policy probes                   | Hard-coded policy flavor / platform-sensitive    | Keep Mac diagnostics isolated. Audit SDK-supported own-process sampling on iOS; omit unavailable policy fields. Do not infer power from residency.                                                                                                     |
| `thread_policy_set`, Mach time-constraint scheduling                 | Best-effort scheduling, not a guarantee          | Inject worker scheduling at thread startup. Mac retains current policy and failure breadcrumbs; iOS starts with supported QoS and validates scheduling on hardware. No per-packet dispatch or Task.                                                    |
| `CWWiFiClient`, `CWEventDelegate`                                    | Public CoreWLAN, Mac-only                        | `NWPathMonitor` for usable path/interface changes; no general iOS RSSI/PHY/roam equivalent. Optional evidence feeds the same recovery policy, never invented radio readings.                                                                           |
| `StreamPathMTU` interface ioctl / route enumeration                  | Darwin route access, environment-dependent       | Supply measured optional route/MTU values; reuse current Network/BSD operations where permitted. Unknown follows existing conservative behavior. Reuse prelaunch RTT samples; no new probe or round trip.                                              |
| AWDL helper, `SMAppService`, XPC, `Process`, `ifconfig`              | Privileged Mac product integration               | No iOS adapter that mutates interfaces. App-owned lease hooks on Mac; absent capability on iOS. Keep the Mac first-open/every-launch offer and 1 Hz lease renewal unchanged.                                                                           |
| `AudioObject*`, `kAudioUnitSubType_HALOutput`, device terminal types | Public Mac CoreAudio HAL                         | iOS `AVAudioSession` owns category, active state, actual format/latency, route changes, interruptions and media-services reset. Public RemoteIO output pulls the same PCM ring; retain shared Opus, cushion, drift and recovery decisions.             |
| AUSpatialMixer, head pose/HRTF and audio entitlements                | Public APIs with platform/capability differences | Mac multichannel/spatial path stays intact. Phase 2 begins with stereo; validate iOS unit availability separately. Do not copy Mac entitlements or assume HAL layout/property support.                                                                 |
| IOHIDManager/device/value, ForceFeedback, IOHIDSystem                | Mac raw input/output integration                 | GameController public profiles for Backbone and other pads; public keyboard/mouse capture if later required. Unsupported adaptive triggers/center buttons remain unadvertised. No vendor SDK, raw-HID emulation or Input Monitoring prompt on iOS.     |
| `CGSMainConnectionID`, `CGSSetGlobalHotKeyOperatingMode`             | Private CoreGraphics hotkey SPI                  | Exclude entirely from iOS. Native responder/system-gesture rules own capture; do not suppress system navigation.                                                                                                                                       |
| `NSEvent`, Carbon scan codes, `NSPasteboard`, cursor APIs            | Public Mac input APIs                            | App capture adapters submit canonical key/button/motion/text values. iOS touch resolves gestures before submission; no Mac keycode assumptions or acceleration mutation.                                                                               |
| `NSView.displayLink`, `NSScreen`, `CGDisplay*`, `NSWindow`           | Public Mac window/display APIs                   | UIKit scene/view geometry and a public CADisplayLink feed scalar timestamp/target/cadence values into one pacer. Layer attachment is main-actor-owned; orientation and visibility are explicit events. No shared API takes NSView or UIViewController. |
| VideoToolbox, AVSampleBufferDisplayLayer, renderer metrics           | Shared public Apple media APIs                   | Same hardware-decoder requirement and pixel-buffer presentation. Availability-gate newer metrics/HDR features and report unavailable; device tests prove decode support. Mac `hw.optional.arm64` is not an iPhone codec capability test.               |
| GameController, CoreHaptics, background event monitoring             | Shared public APIs, different lifecycle          | Shared slot/release/feedback semantics; native capture/actuator objects stay behind adapter functions. `shouldMonitorBackgroundEvents` is ignored on iOS; background releases input and stops streaming.                                               |
| `NSWorkspace` wake/focus, ProcessInfo activity assertions            | Mac lifecycle integration                        | Scene activation, interruption, background/lock and protected-data events. Shared generation/cancellation decisions; platform-specific visibility semantics. iOS inactive is not Mac Mini Player.                                                      |
| FileIdentityStore Mac path, Moonlight defaults migration             | Storage environment                              | Inject container URL and protected-data availability. Preserve RSA/PEM validation and exact DER pinning; inaccessible storage must not regenerate identity. Mac files/migration stay unchanged.                                                        |
| `SecIdentityCreate`, CommonCrypto, CryptoKit, Network TLS            | Public/shared; not a keychain requirement        | Continue in-memory identity creation and disabled TLS resumption. Local iOS SDK header marks SecIdentityCreate available since 11.2. No signing-keychain access or new identity migration.                                                             |
| `IOKit.ps`, `host_statistics`, local machine name                    | Mac system telemetry/pseudonym input             | Own-process metrics where supported, public battery/thermal/Low Power Mode observations, optional unsupported values. Supply install pseudonyms and container log destinations from the app.                                                           |

API references:
[in-memory identity creation](<https://developer.apple.com/documentation/security/secidentitycreate(_:_:_:)>),
[audio preferences versus actual route values](https://developer.apple.com/library/archive/qa/qa1631/_index.html),
and
[display-link rate hints](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange).
The local SDK confirms declaration availability, not minimum-OS behavior or App
Store acceptance.

## Ordered extraction slices

Each numbered slice lands working Mac consumption and its tests before the next
starts. Within a slice, review seam extraction before file/target moves; never
leave duplicate source owners. The inventory's slice column is the exact file
list; the table below specifies splits and dependencies. Preserve load-bearing
comments and Diag breadcrumbs when moving; shorten changed comments without
losing their invariants. New Swift files require SPDX plus unique pbxproj
file-reference/build-file/group/Sources entries, checked for ID collisions.

| Slice                                | Files moved and adapter work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Tests to retain/add                                                                                                                                                                                                                                                                                                                                                                              | Risk; Mac proof beyond common baseline                                                                                                                                                                                                                                                |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. Pure protocol foundation**      | Move EnetWire, ReedSolomon, AudioFecDecoder, InputEncoder, SdpCodec and StreamProtocolConstants. Split immutable GamepadAnalog/BackendStreamConfig/OpusConfig values from StreamingBackend and ControlCrypto/StreamCryptoError from StreamCrypto; leave diagnostic VideoDecryptor until 2. Create/link/embed framework and signing-script fixture support.                                                                                                                                                                                                                                                                                                           | EnetWireTests, ReedSolomonTests, InputEncoderTests, SdpCodecTests, StreamProtocolConstantsTests, StreamCryptoTests, FuzzTests; mock `test_sign_bundle.py` verifies engine-before-app signing and no entitlement inheritance.                                                                                                                                                                     | Low algorithmic risk; module/link risk. Byte-for-byte fixtures and unchanged `ConnectFlow`, `gate_*`, receive/FEC outcomes. Confirm framework is loaded once by app/tests/CLI.                                                                                                        |
| **2. Shared values and diagnostics** | Move Types request/error/media values, bitrate/codec values, portable pieces of Host and stats snapshots, remaining existing backend/sink contracts including NativeAudioSink, remaining crypto, all shared stats/counter/latency/export files and Diag. Split Mac presentation fields/HUD formatting out. Lift FramePacer snapshot values, AtomicCounter, InputReleaseLedger and PairStatus ahead of their implementations. Move existing Sunshine requirement copy out of AppModel. Inject all capture inputs, probe functions, diagnostic directories and identity labels using existing TelemetrySource/outputDirectory seams. Keep OS samplers in Mac adapters. | StreamTypesTests, ModelTypesTests, StatsSupportTypesTests, StatsSnapshotRowsTests, StatsCollectorWindowTests, LogPrivacyTests, LogRetentionTests, Telemetry\* suites, ResourceTelemetryTests, IOReportSamplerLifetimeTests. Add absent-probe and module-boundary privacy tests.                                                                                                                  | Medium, many mechanical moves. Separate values, sinks and probes in review. Same NDJSON/Prometheus fields, opt-in cadence, omitted values, pseudonyms and diagnostics-off CPU; no new timers.                                                                                         |
| **3. PC communication and pairing**  | Move Network/NetworkClient, ControlTransport, Discovery, Pairing, PEM, Identity crypto/loading and Types+Cert, plus WakeOnLAN. Storage functions take existing base/defaults parameters plus protected-data policy; Mac migration orchestration stays app-side.                                                                                                                                                                                                                                                                                                                                                                                                      | ControlTransportTests, NetworkClientRequestTests, SunshineHTTPParsingTests, PEMTests, PairingCryptoTests, PairingHandshakeTests, PairingFlowTests, StoragePersistenceTests, IdentityKeychainCleanupTests, WakeOnLANTests, FakeSunshine. Add unavailable-store and denied-discovery failure tests.                                                                                                | Medium security/lifetime risk. Identical PIN rounds, pin mismatch refusal, no TLS resumption, request counts and `ConnectFlow`/handshake timing. CLI pair/list still uses the same identity.                                                                                          |
| **4. Live transport and backend**    | Move remaining Native and NativeBackend files. Move backend battery/motion methods out of ControllerBattery/ControllerMotion now. Replace pipeline VideoDecoder cast with existing ConnectionEvents HDR delivery. Split NativeConnectionEvents from its concrete bridge: app supplies existing event sink and ordered callbacks until 9; no reverse app dependency. Inject receive/scheduling/route seams once per connection/thread.                                                                                                                                                                                                                                | DatagramBatchTests, ReceiveTimingTests, Enet* loopback/control suites, Rtsp* suites, RtpReceiverLoopbackTests, RtpVideoQueueLossTests, RtpReceiveQualityTests, RtpAudioStartupGateTests, StreamPathMTUTests, BackendGlueTests, InputBatcherTests, StreamFuzzTests. Add HDR forwarding and stale-event source tests.                                                                              | High lifetime risk. Preserve sender/receiver threads, peer validation, 64-slot audio worker, queue bounds, join-before-sink-release. Compare receive timing, loss, RTT and input tails; no extra launch requests.                                                                     |
| **5. Audio boundary**                | Move AudioDecoder features, AudioPCMQueue and OpusDecoder. Extract AudioHALDevice/AudioHALOutput/SpatialAudio and route listeners into Mac adapter. Construct output hooks off render thread; pass stable preallocated ring/callback storage. Shared code owns admission, cushion, resampling and recovery; adapter owns graph/device operations.                                                                                                                                                                                                                                                                                                                    | AudioPCMQueueTests, AudioWorkerTests, AudioEngineLifecycleTests, AudioHALDeviceTests, AudioPlayout* tests, AudioCushion* tests, AudioResamplerHoldTests, AudioPrimeEdgeSafetyTests, AudioPacketSpliceTests, SpatialAudioTests. Add adapter failure and shutdown-during-route-change tests.                                                                                                       | High real-time risk. Same `audio_receive_gap_*`, `audio_queue_wait_*`, `audio_output_latency_ms`, audio skew, underruns and CPU under idle/load/recovery; speakers/headphones/Bluetooth and native multichannel routes. Zero allocation/locks/metadata lookup added in pull callback. |
| **6. Pacer boundary**                | Move FramePacer and features. Move NSView link creation, screen signature/rate reads and Mac scheduling to adapter; keep state, depth, due/recovery decisions, tick thread ownership and direct media handoff. Use scalar tick values and retained start/stop/rebuild functions, not an asynchronous event bus.                                                                                                                                                                                                                                                                                                                                                      | FramePacerTests, FramePacerTickTests, FramePacerTickDeficitTests, FramePacerDeficitEventTests, FramePacerContentRateTests, FramePacerHandoffTests, FramePacerReleaseTests, PresentTripTests. Add late tick after detach and screen-change handoff tests.                                                                                                                                         | High cadence risk. `lat_output_to_present_*`, `pacing_*`, `refresh_*`, `pacer_*`, `present_cadence_err_ms` and presentation-late drops; visible/hidden/refocus and both fullscreen paths.                                                                                             |
| **7. Video boundary**                | Move VideoDecoder features; app provides AVSampleBufferDisplayLayer attachment, prepared display capabilities and display probe. Reuse existing decoder factory seams. StreamWindow, StreamInputView, HUD/banner and geometry remain app-owned. Remove unused AppKit imports from media-only extensions.                                                                                                                                                                                                                                                                                                                                                             | VideoDecoder\* suites, AV1SequenceHeaderTests, AnnexBToAVCCTests, VideoFormatDescriptionTests, VideoDepacketizerRecoveryTests, VideoRecoveryEventTests, HUDBackdropLuminanceTests, StreamHDRTests, StreamWindowFirstFrameTests. Add detached-layer/stale-renderer callback tests.                                                                                                                | High presentation risk. Same hardware decode, pixel buffers, suppression/recreation, HDR/EDR and renderer path; no new copy/pass. Direct versus composited watts and renderer deltas are mandatory.                                                                                   |
| **8. Input and controller boundary** | Move InputCore, release ledger, controller slot/arrival/chord/mouse/touchpad/button semantics, PointerMapping and ScrollQuantizer. Split InputForwarder/ControllerForwarder into shared state and Mac capture; GameController/CoreHaptics functions supply normalized states and feedback. Raw HID, DualSense side channel, Carbon, private hotkey hooks and background-event ownership remain Mac adapters.                                                                                                                                                                                                                                                         | InputCoreTests, InputReleaseTests, InputRecoveryTests, InputLatencyTests, ControllerArrivalTests, ControllerStatePushTests, ControllerMouseTests, ControllerTouchpadMouseTests, ControllerQuitChordTests, ControllerButtonLayoutTests, ControllerHapticsActuationTests, HIDGamepadTests, DualSense* and StreamView* suites. Add detach/focus-generation tests across adapter boundary.           | High input risk. Preserve synchronous local edge acceptance and shared slot mask. Match `input_*_capture_send_*`, queue tails and zero dropped timing samples; real held-input, two-pad, raw-HID, IME and paste checks.                                                               |
| **9. Session and quality boundary**  | Move StreamSession features, bridge, EnvSignalController, BitrateDownshiftController and pure QualityCalculator/config/failure logic. Mac AppModel supplies prepared presentation/input/audio, route provider, activity/visibility/wake and helper lease hooks. Reuse makeNetwork/makeBackend/SessionClock. HUD/history timers stay shell-owned; shared watchdogs keep their meaning/cadence.                                                                                                                                                                                                                                                                        | SessionLaunchFlowTests, SessionReconnectFlowTests, SessionSafetyTests, SessionTimerBodyTests, StreamSessionDecisionTests, StreamReconnectTests, DisconnectRegressionTests, AdaptiveRecoveryTests, EnvSignalStateMachineTests, BitrateDownshiftTests, WiredBitrateTests, QualityPresetMigrationTests, AWDLHelperManagerTests. Add slow-consumer terminal-order and adapter startup-failure tests. | High cancellation risk. Same launch epochs, takeover rules, reconnect/downshift decisions and idempotent stop; ten start/stop cycles. Mac hidden/audio behavior, helper offer and lease remain unchanged.                                                                             |
| **10. Consumer and release closure** | Finish necessary AppModel/CLI imports and remove obsolete glue; touch other shell files only at affected call sites; no deferred engine source left in app Sources. Check engine-facing API contains no native views/device objects. Update architecture/build/profiling references and source/API audits, lint/coverage/CodeQL path filters and shared scheme. Complete remaining neutral failure/route policy cuts; native copy/preferences remain in shells.                                                                                                                                                                                                      | Full GlimmerTests including GlimmerCLI\*, AppModelSunshineTests, GlimmerIntentsTests, SystemServiceSeamTests, AppShellTests, StreamAwareUpdateAlertsTests; release-tool signing/packaging fixtures, full ASan fuzz gates. Add dependency/membership audit, not tests mirroring trivial moves.                                                                                                    | Medium packaging risk. Required hosted Verify and all three CodeQL jobs on reviewed commit; owner-installed published RC verification and exact-byte promotion rules. Check framework load, app/CLI identity, Sparkle, login/helper and teardown on a real PC.                        |

### Buildable cut points

Import-only auditing misses these dependencies. Apply these cuts in the named
slice; do not widen the framework boundary to import the app or temporarily copy
implementations.

| Slice | Current cycle or later dependency                                                                                  | Required cut                                                                                                                                                                                                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | SdpCodec/InputEncoder need values from StreamingBackend; StreamCrypto contains Diag-using VideoDecryptor           | Move immutable value declarations with parsers; split crypto at type boundaries, keeping the decryptor caller in the app until 2.                                                                                                                             |
| 2     | TelemetryLatency needs AtomicCounter from EnetControlChannel; InputLatency needs InputReleaseLedger.Release        | Move these pure support types now and update both callers. Do not duplicate counters/ledgers in each module.                                                                                                                                                  |
| 2     | TelemetrySource names FramePacer nested snapshots; renderer tracker file extends VideoDecoder                      | Lift neutral snapshot/renderer values now; keep decoder accessor beside the decoder until 7. Avoid an early dependency on presentation.                                                                                                                       |
| 2     | Exporter reads EnvSignalController, AudioDecoder constants, StreamPathMTU gate, UdpPinger cadence and DualSenseHID | App supplies typed configuration/evidence snapshots through defaulted capture functions; move snapshot values now. Reuse the same seam after later implementations move. No new sampler or changed capture frequency.                                         |
| 2     | StreamError calls AppModel.needsSunshineMessage; ServerInfo needs PairStatus; stats format MacSystemStats/HUD rows | Extract existing copy and PairStatus once. Split value snapshots from shell formatting/extensions. Keep raw persisted keys and displayed wording identical.                                                                                                   |
| 4     | NativeConnectionEvents has bridge/session/controller references; pipeline directly sets VideoDecoder HDR           | Keep app-side existing ConnectionEvents implementation until session moves; inject it into NativeBackend. Forward HDR and nonfatal audio status through callbacks with the same queue/order. Carry originating backend identity for stale-callback rejection. |
| 4     | ControllerBattery/ControllerMotion extensions access readyBatcher, featureFlags and gamepadChannel                 | Move those backend methods with NativeBackend before controller capture moves. Do not make backend internals public to accommodate app extensions.                                                                                                            |
| 5–9   | Cross-module extensions cannot access private/internal storage in moved types                                      | Move shared state and its feature extensions together; native capture/attachment becomes an owning adapter with explicit functions. Expose operations, not locks, sinks or arbitrary state.                                                                   |

New boundary/behavior tests use Swift Testing (`@Test`, `#expect`); each fix
needs a test that fails without it. No new single-conformer protocols: use
defaulted closures/parameters or small concrete value structs at proven
boundaries, retaining existing StreamingBackend/sink contracts. AppKit/UIKit
object ownership stays on main; session state remains actor-owned. Preserve
documented locks, weak references and buffer lifetimes. The callback bridge is
retained until receive/control/audio workers stop, then sinks tear down, then
events finish. Input releases precede disconnect. Reconnect generations reject
old callbacks and controller slot reuse. Statistics may coalesce;
terminal/lifecycle events must retain order and cannot disappear behind a full
buffer. Do not introduce an arbitrary bufferingNewest limit as an extraction
shortcut; test slow consumers explicitly. Keep `io.ugfugl.Glimmer`, Diag
privacy/redaction and `NetworkClient.sensitiveQueryKeys` unchanged. PC
addresses/names and error text remain private; no keys/PINs/certificates or
per-frame info logging.

### Commands and gates for implementation rounds

These are future execution instructions, not results from Phase 0.

| Gate                  | Command or owner action                                                                                                                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Every slice           | `make check`, `make test`; inspect complete build log for zero warnings. `make app` only when an extra app compile check is needed. No install/sign/TCC changes for compile verification.                                                                                                  |
| Focused iteration     | After initial tests: `xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug -xcconfig Glimmer/StreamLib.xcconfig CODE_SIGNING_ALLOWED=NO -derivedDataPath build -destination 'platform=macOS' -only-testing:GlimmerTests/DatagramBatchTests` (substitute suite). |
| Required gate         | Full `make verify` or hosted equivalent (`make check`, `make test`, `make test-asan`); retain nonparallel scheduling and sanitizer coverage. Run only under that round's authorization.                                                                                                    |
| Release configuration | Authorized unsigned `make app CONFIG=Release` compile check; owner supplies installed optimized artifacts for performance. Never time Debug builds.                                                                                                                                        |
| Portable API gate     | As slices move, compile framework for iOS device and Simulator with deployment target 26; inspect linked frameworks, symbols and embedded strings for Mac SPI. Phase 2 adds cross-platform deterministic tests. Header inspection alone does not pass this gate.                           |
| Release artifact      | Maintainer separately authorizes candidate workflow/install; exact-commit hosted checks first. Check nested framework signature, dSYM, load paths, notarization and update packaging; preserve existing promotion pipeline. Never run `make dist` as an extraction check.                  |

## Mac baseline and before/after protocol

| Evidence                     | What is established                                                                                                                                                                                                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Owner rc.4 reference         | `~/Library/Logs/Glimmer/telemetry-2026-10-12T17:43:49Z.ndjson`; config records `build_commit=c2522d5f5110`, AV1, 3840×2160, requested 240 fps, fullscreen, `highestQuality`, dial 226000 kbps, configured/asked 361600 kbps, route en12.                                                 |
| Owner rc.4 A/B               | `telemetry-2026-10-12T18:09:36Z.ndjson` in the same directory; same recorded commit/request. Both files were read as local evidence; do not commit raw logs or identities.                                                                                                               |
| Owner's measured direct path | **GPU 0 mW (0 W), process CPU 38%, RTT p95 approximately 0.5 ms.** Preserve as owner measurements, not values recomputed from entire files.                                                                                                                                              |
| Owner's composited path      | **GPU 655 mW (0.655 W).** Compare against direct path under the same scene and HUD state. The older approximately 690 mW example in PROFILING is a different reference.                                                                                                                  |
| File limitations             | Inspected rows contain no `gpu_power_w`; package power/residency are not substitutes. Logs include extensive suppressed/decode-gated periods and the A/B file was still growing during inspection. No labelled A/B time bounds or external rail capture are available here.              |
| RTT distinction              | Config prelaunch `gate_rtt_p95_ms` is 0.802 ms / 0.679 ms respectively; it is not the owner's selected steady-state approximately 0.5 ms figure. Compare the same measurement/window, never silently replace one with the other.                                                         |
| Quality caveats              | Requested 240 fps is not measured content or presentation fps. Both inspected sessions have a cumulative `audio_render_underrun_total` reaching 1; its cause/window is unverified. Do not claim zero-underrun baseline from these files.                                                 |
| Missing baseline metadata    | Exact Mac/display/OS and PC/Sunshine builds, scene, direct/composited bounds, external power method, audio/controller routes, HDR settings, wakeup counts and variance need owner annotation or controlled recapture. These two mixed sessions alone do not establish three paired runs. |

Use this protocol for **every slice**, adding that slice's scenarios from the
plan:

| Step            | Required procedure and acceptance                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pair            | Compare preceding accepted slice with proposed slice, plus final rc.4 reference. Owner-installed optimized builds only; retain version/commit and artifact identity. Keep Mac, PC, scene, codec, actual/requested dimensions and fps, bitrate, display/refresh/HDR, audio, input, helper state and network fixed.                                                                                                  |
| Segment         | Warm up 60 seconds, then record at least 120 seconds each: visible direct/HUD hidden, visible composited/HUD shown, hidden, and refocused. Record UTC interval boundaries and renderer path evidence. Run three matched before/after pairs, alternating order. Match background load, AC power and thermal state.                                                                                                  |
| Diagnostics     | Repeat comparable visible windows with diagnostics off, counters/HUD and full capture. With diagnostics off use external resource instrumentation; do not enable capture merely to measure its absence. No added always-on sampler.                                                                                                                                                                                |
| Common fields   | Compare `cpu_percent`, `phys_footprint_bytes`, thread/resource samples, `gpu_power_w`, `package_power_w`, `rtt_ms`, `fps_received`, `fps_decoded`, `fps_rendered`, `drops_decoder`, `drops_backpressure`, `drops_presentation_late`, `audio_render_underrun_total` and hardware decode evidence. Missing readings stay missing.                                                                                    |
| Stage latency   | Compare `lat_recv_to_assemble_*_ms`, `lat_assemble_to_submit_*_ms`, `lat_decode_submit_to_output_*_ms`, `lat_output_to_present_*_ms` at p50/p95/p99, plus receive gap/queue and audio fields from PROFILING. These are pipeline stages, not input-to-photon latency.                                                                                                                                               |
| Rendering       | Use ready, fresh `renderer_frames_delta`, `renderer_optimized_frames_delta`, dropped-frame and frame-delay deltas. More than half optimized classifies the interval; discard visibility-edge/reset intervals. Pair `pacing_depth`, `pacing_target_depth`, `present_cadence_err_ms`, refresh/tick/release fields with measured content fps. Watts decide cost, not GPU residency.                                   |
| Input           | Compare all source `input_*_capture_send_*`, `batcher_flush`, `flush_send` and callback-queue fields; require `input_timing_dropped_total=0`. Older `lat_input_queue_to_wire` is not a substitute. Match event counts and include release edges under load.                                                                                                                                                        |
| Statistics      | Use interval counter/bucket differences, not differences of cumulative percentiles. Use established rolling 60-second media fields only for fully settled same-state windows; preserve session-wide totals separately. Capture missing wakeup evidence with Instruments; `wake_total` counts wake handling, not process wakeups.                                                                                   |
| Stress/lifetime | For audio/input/transport/session slices, add PROFILING's 120 seconds idle + 120 seconds CPU load + 120 seconds recovery. For each slice run ten warm start/stop/reconnect cycles; no active worker/link/timer after stop or monotonic retained-memory/session-object growth. Explain cache plateaus with allocation evidence.                                                                                     |
| Pass/fail       | Resolve reproducible >5% CPU, physical-footprint or wakeup increases and any p95/p99 media-latency regression outside paired baseline variability. No new client-caused underruns, stuck input or missed cadence on a clean link. Any reproducible watt increase or direct-path loss needs investigation; zero baseline power cannot use a percentage comparison. A tradeoff needs explicit maintainer acceptance. |
| Evidence record | Keep per-pair interval table, configuration, instrument method, numeric deltas/ranges and raw evidence location in the review. Passing tests are not measured performance. No threshold/default changes in extraction slices.                                                                                                                                                                                      |

## Phase 2 integration app outline, not implemented here

| Area                | Minimum proof using the same GlimmerEngine                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Target              | A small native iOS/iPadOS 26 SwiftUI/UIKit application target, own identity/container, linking and embedding the same source framework. No copied engine, Sparkle, helper, Mac UI or private symbols.                                                                                                                                                                                                                                                              |
| Flow                | Enter/discover PC, PIN pair, choose an app, stream, leave and reconnect. Show existing typed failures through shared copy. Native focus/VoiceOver and a safe-area leave control; enter/leave by controller after pairing. No finished launcher design in this phase.                                                                                                                                                                                               |
| Video               | UIKit-backed AVSampleBufferDisplayLayer, hardware VideoToolbox, landscape SDR 60 fps first. Video extends behind cutouts/home indicator; controls respect safe areas. Both landscape orientations; no reconnect for unchanged dimensions. Aspect-matched mode when supported, truthful aspect-fit fallback. Phase 3 owns general mode selection/PC setup.                                                                                                          |
| Input               | Backbone plus a second controller through GameController capabilities, shared slots/edges/feedback. Hot-plug and cancellation release held input. Simple relative touch drag, tap, two-finger secondary click/scroll; cancellation releases and player-control gestures are not forwarded. No full virtual gamepad or vendor SDK.                                                                                                                                  |
| Audio               | AVAudioSession playback/route/interruption adapter plus public output unit, same shared PCM/decode/drift path. Begin stereo; validate actual rate/buffer/latency after activation and route change. Test speakers and wired/Bluetooth output plus media-services reset.                                                                                                                                                                                            |
| Lifecycle           | Inactive immediately releases input; background/lock stops local work and deactivates audio as appropriate. Returning offers controlled reconnect. Preserve Mac semantics: current StreamSession.stop cancels the owned PC app. Phase 2 must explicitly distinguish local disconnect from PC quit before wiring background to stop; never silently quit a game on background.                                                                                      |
| Permissions/storage | App target declares local-network purpose and required Bonjour services. Test denial, unavailable protected data and invalid pin; no indefinite retry or identity regeneration. Assess multicast entitlement only if chosen discovery/Wake on LAN operation requires it; no entitlement assumptions from Mac.                                                                                                                                                      |
| Device matrix       | Owner's iPhone + compatible Backbone, oldest intended iOS 26 device, a higher-refresh iPhone, and an iPad. Record exact models/OS builds and hardware codec support before testing; roles may overlap. Do not guess a supported device list from chip names.                                                                                                                                                                                                       |
| Acceptance          | Thirty-minute optimized on-device run after warmup, ten reconnect/stop cycles, both orientations, controller entry/exit/hot-plug, denied permission, audio interruption and lock/return. Record CPU seconds/minute, peak/steady footprint, wakeups, energy, thermal state, measured fps, drops, latency and underruns. Set numerical per-device budgets before higher modes or handoff. Simulator runs shared deterministic tests, not energy/hardware acceptance. |

## Maintainer choices and remaining evidence

Defaults below permit Phase 1 planning to proceed; Phase 2 hardware acceptance
waits for exact device details.

| Question                                              | A                                                                                                                        | B                                                                                                               |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| How should we label the rc.4 A/B baseline?            | Supply direct/composited UTC ranges and external power capture method, then complete three paired trials (recommended).  | Recapture a controlled rc.4 reference with the protocol above; retain existing sessions as historical evidence. |
| Which physical devices lead Phase 2?                  | Owner's current iPhone/Backbone plus available iPad, then oldest/high-refresh roles (recommended; provide exact models). | Oldest intended supported iPhone first, then owner's iPhone/Backbone and iPad.                                  |
| When to review the iOS disconnect-versus-quit policy? | At Phase 2's first lifecycle slice, before any background/lock wiring (recommended).                                     | As a separate explicitly scoped policy slice after Phase 1 acceptance and before iOS bring-up.                  |

Phase 0 verification: source/build membership and SDK-header inspection,
privacy-safe local telemetry inspection, complete inventory/path checks and
Markdown whitespace review only. No Swift/project/build files changed, no tests
added, and no build/test/sign/install command run. The existing roadmap file is
untouched.
