# Contributing

Start with an issue the maintainer agrees to. Follow [AGENTS.md](AGENTS.md) and
our [code of conduct](../CODE_OF_CONDUCT.md). Keep each change focused.

## Build and test

Use Xcode 26.6 or later, SwiftLint, Actionlint, Python 3, pre-commit and
TruffleHog. CI uses Xcode 26.6 on macOS 26. No third-party runtime dependencies
are added.

From this directory (`iOS/`):

```sh
make app
make test
make check
```

These targets never sign, install or provision. `make app` compiles for a
generic iOS Simulator. `make test` needs an installed Simulator runtime and an
iPhone 17 Pro Simulator; override `TEST_DESTINATION` to use another installed
iOS 26+ device. `make check` runs workflow, SPDX, strict SwiftLint and
build-tool checks. Read full build logs: zero warnings is required.
`pre-commit install` is an owner setup step; hooks include verified credential
and offline private-key scans.

CI also compiles the production Release app for a generic iOS device, without
signing. It runs alongside Simulator verification; the root required `macOS`
check passes only when both apps and the engine succeed. Compile the same
production configuration locally:

```sh
make app CONFIG=Release DESTINATION='generic/platform=iOS' \
  BUILD_FLAGS='SWIFT_ACTIVE_COMPILATION_CONDITIONS='
```

Simulator CI records line coverage and retains the report and result bundle in
`ios-Simulator-results`. This establishes a baseline, not a coverage threshold
or physical-device acceptance. To record coverage locally, choose an unused
result bundle path:

```sh
make test TEST_FLAGS='-enableCodeCoverage YES -resultBundlePath build/coverage.xcresult'
xcrun xccov view --report build/coverage.xcresult
```

Swift CodeQL must successfully extract every tracked production Swift file in
`iOS/Glimmer/`, alongside the Mac app, helpers and shared engine in one
analysis. Python build tools and GitHub Actions receive separate analysis jobs.
Hosted extraction must pass before treating a local script check as analysis
evidence.

## Engine dependency

The project references `../Package.swift` through a local Swift package. Both
apps compile the same `GlimmerEngine/` sources from the same commit. No pin
bump, checkout override or generated Xcode project is needed. Open
`Glimmer.xcodeproj` and choose the `Glimmer-iOS` scheme.

From the repository root, run `make ios-app`, `make ios-test` or
`make ios-device`. `make verify-all` verifies both apps. Changes to shared
behavior belong in the engine and must pass both clients' tests in the same pull
request. See [repository ownership](../docs/APPLE_REPOSITORY.md).

The public connection tests exercise cancellation and teardown without opening a
connection to the PC; they do not prove media playback or complete the framework
handoff. The iOS [AudioToolbox adapter](docs/AUDIO.md) supplies real output
units and session lifecycle handling through that public contract and is
attached to the streaming UI. Video decoding and display pacing also use the
shared engine through public APIs; the app supplies the native display layer and
display link.

## Physical devices

Put your team ID in the ignored `Config/Signing.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

The checked-in `Signing.xcconfig` is intentionally blank. The app’s bundle ID is
`io.ugfugl.Glimmer.iOS`; its name is Glimmer. The owner must configure device
provisioning in Xcode before installing. No signing secrets belong in this repo.
For CI beta distribution, follow the [TestFlight guide](docs/TESTFLIGHT.md). Its
distribution setup is separate from local development provisioning.

Debug builds keep the active app awake throughout the launcher and stream.
Production Release keeps it awake only during a stream. For an optimized local
development build, add
`SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) GLIMMER_DEVELOPMENT` on one
line in the ignored local configuration. Verify production behavior with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=''` on the unsigned Release build command.
Inactive/background scenes always restore auto-lock.

Before accepting UI, inspect light/dark appearance, large Dynamic Type,
VoiceOver, keyboard focus, iPhone and iPad, both landscape directions, safe-area
Disconnect button, status/home indicator behavior and menu rotation after
streaming. The iPhone launcher, settings, pairing and address entry support
portrait and both landscape orientations. Streams request landscape while
presented; dismissing them releases that restriction for their window. iPad
declares all orientations for system windowing without the deprecated fullscreen
compatibility key. Native UI rendering tests attach PNGs to the test result
bundle; CI retains those bundles in the `ios-Simulator-results` artifact.
Inspect the images before claiming visual acceptance.

Pairing recovery must preserve other PCs and reject forgetting during a stream
or while protected data is unavailable. Verify Cancel, successful forgetting,
and fresh PIN pairing on a real PC. Certificate failures never delete trust or
start pairing automatically. Cached cover images remain bounded by the shared
engine cache; its per-PC removal API is not yet public to this client.

Plug in Backbone One and another controller: verify initial detection, unplug,
reconnect and background/return. Follow the fixed [input mapping](docs/INPUT.md)
and validate controller navigation, held-input release and native feedback.
Pairing, hardware decode, audio routing, background/lock teardown and sustained
play need real-PC and physical-device measurements. The UI rendering tests use
fake network/session state only and do not prove playback.

The app opts into
[higher refresh rates](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone)
and declares the
[extended gamepad profile](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportedgamecontrollers).
It opts into system-managed Game Mode with `LSSupportsGameMode`, following
[Apple’s Game Mode guidance](https://developer.apple.com/videos/play/wwdc2025/209/).
The system controls activation; this declaration does not prove it is active. It
does not advertise complete controller navigation yet.

## Repository protection

Use the root repository's hooks, workflows, dependency updates and branch
protection. Do not add workflows under `iOS/.github`; GitHub does not run nested
workflows. The existing `macOS` gate now includes iOS Simulator tests and a
production device build. CodeQL verifies extraction for both apps and the
engine. Editing workflow files does not change live GitHub protection settings.
