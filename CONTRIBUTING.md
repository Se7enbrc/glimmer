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

## Engine dependency and first publication

The shared project pins `Se7enbrc/glimmer` to the exact commit
`29b17cc703a2eab3c81fd662fe25c151b35f64b5`, the first with `Package.swift`.
Update the pin to a full commit SHA, never a branch or tag, and never copy
engine source here.

For development against the uncommitted package:

```sh
make app ENGINE_PATH=../wt-spm
make test ENGINE_PATH=../wt-spm
```

Use an absolute path for any other engine checkout. This creates an ignored
`build/GlimmerLocal.xcodeproj` with a local package reference and the same
source files and shared scheme. Open that project for local Xcode work. The
tracked project and its exact revision stay unchanged. Do not open both projects
at once.

After publishing the engine package, update the revision in
`Glimmer.xcodeproj/project.pbxproj`, resolve in Xcode, and check in Xcode’s
`Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Then run the default commands without `ENGINE_PATH`, including CI. A successful
local override does not prove remote resolution. This is the first-publication
blocker, not a complete framework handoff.

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
Done button, status/home indicator behavior and portrait restoration after the
preview. Attach screenshots from the first rendered build; there is no earlier
app UI.

Plug in Backbone One and another controller: verify initial detection, unplug,
reconnect and background/return. The preview sends no input and opens no network
connection. Pairing, hardware decode, controller input, audio and sustained 120
Hz play still need later engine slices and real-PC measurements.

The app opts into
[higher refresh rates](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone)
and declares the
[extended gamepad profile](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportedgamecontrollers).
It does not advertise complete controller navigation yet.

## Repository protection

`.github/rulesets/` mirrors Glimmer’s three live rulesets as importable JSON.
Only the required checks differ: `iOS`, `Analyze (swift)` and
`Analyze (actions)`. No rules have been applied. Before importing, review the
copied integration bypass IDs for this repository, enable private vulnerability
reporting, and confirm that the required checks have run. Keep the
signed-history and squash-only policy.
