# Contributing

Start with an issue the maintainer agrees to. Follow [AGENTS.md](AGENTS.md) and
our [code of conduct](CODE_OF_CONDUCT.md). Keep each change focused.

## Build and test

Use Xcode 26.6 or later, SwiftLint, Actionlint, Python 3, pre-commit and
TruffleHog. CI uses Xcode 26.6 on macOS 26. No third-party runtime dependencies
are added.

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

## Engine dependency

The shared project pins `Se7enbrc/glimmer` to the exact commit
`410e8280defd936f89e21dab61772faea2acdec7`, including the public connection API,
shared transport, audio output contract, video decoder and display pacing. The
package lock records the same revision. Update the pin to a full commit SHA,
never a branch or tag, and never copy engine source here.

For development against a local engine checkout:

```sh
make app ENGINE_PATH=/absolute/path/to/glimmer
make test ENGINE_PATH=/absolute/path/to/glimmer
```

Use an absolute path for any other engine checkout. This creates an ignored
`build/GlimmerLocal.xcodeproj` with a local package reference and the same
source files and shared scheme. Open that project for local Xcode work. The
tracked project and its exact revision stay unchanged. Do not open both projects
at once.

When updating the engine dependency, update the revision in
`Glimmer.xcodeproj/project.pbxproj`, resolve in Xcode, and check in Xcode’s
`Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Then run the default commands without `ENGINE_PATH`, including CI. A successful
local override does not prove remote resolution. The public connection tests
exercise cancellation and teardown without opening a connection to the PC; they
do not prove media playback or complete the framework handoff. The iOS
[AudioToolbox adapter](docs/AUDIO.md) supplies real output units and session
lifecycle handling through that public contract and is attached to the streaming
UI. Video decoding and display pacing also use the shared engine through public
APIs; the app supplies the native display layer and display link.

## Physical devices

Put your team ID in the ignored `Config/Signing.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

The checked-in `Signing.xcconfig` is intentionally blank. The app’s bundle ID is
`io.ugfugl.Glimmer.iOS`; its name is Glimmer. The owner must configure device
provisioning in Xcode before installing. No signing secrets belong in this repo.
App Store Connect, distribution profiles and release automation come later.

Before accepting UI, inspect light/dark appearance, large Dynamic Type,
VoiceOver, keyboard focus, iPhone and iPad, both landscape directions, safe-area
Disconnect button, status/home indicator behavior and portrait restoration after
streaming. Native UI rendering tests attach PNGs to the test result bundle; CI
retains those bundles in the `simulator-logs` artifact. Inspect the images
before claiming visual acceptance.

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
It does not advertise complete controller navigation yet.

## Repository protection

`.github/rulesets/` records this repository’s three active rulesets as
importable JSON. Required checks are `iOS`, `Analyze (swift)` and
`Analyze (actions)`. The maintainer-pushes ruleset permits only the repository
admin bypass; it has no integration bypass. Keep the signed-history and
squash-only policy. Editing these files does not change live GitHub settings.
