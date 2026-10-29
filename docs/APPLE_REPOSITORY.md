# Work on both Apple clients

Change shared behavior once, then verify both apps from the same checkout.

| Path                                                        | Ownership                                                       |
| ----------------------------------------------------------- | --------------------------------------------------------------- |
| `GlimmerEngine/`, `Package.swift`                           | Shared streaming, recovery, audio, input policy and diagnostics |
| `Glimmer/`, `Glimmer.xcodeproj`                             | Mac app and native adapters                                     |
| `iOS/Glimmer/`, `iOS/Glimmer.xcodeproj`                     | iPhone/iPad app and native adapters                             |
| `GlimmerTests/`, `EnginePackageTests/`, `iOS/GlimmerTests/` | Mac, public package and iOS tests                               |
| `scripts/`, `.github/workflows/`                            | Shared checks, CI and separate Mac/iOS release workflows        |

## Build and verify

1. Open the root `Glimmer.xcodeproj` for Mac, or `iOS/Glimmer.xcodeproj` for
   iPhone/iPad. Choose `Glimmer` or `Glimmer-iOS`, respectively.
2. Run the focused checks while editing: `make test`, `make ios-test`, or
   `swift test -Xswiftc -warnings-as-errors` for public engine contracts.
3. Use normal pre-push checks and hosted Verify/CodeQL for the changed source.
   `make verify-all` is available when a full local cross-platform pass is
   needed: source checks, Mac tests, AddressSanitizer, public package tests, iOS
   Simulator tests and an unsigned production iOS device build. Use
   `TEST_DESTINATION` for another installed iOS 26+ Simulator.

Build checks never sign, provision or install onto physical devices. Simulator
tests run the test host in Simulator. For unsigned compile checks, use
`make app`, `make ios-app` and `make ios-device`. Read logs for zero warnings.
Mac installation and release commands retain their existing explicit-approval
requirements.

The iOS package reference points to `..`. There is no remote engine revision,
`ENGINE_PATH` override or generated local project. Both builds consume the
canonical engine directory; the two boundary audits reject missing membership,
engine files compiled by native targets and a remote iOS pin.

## Keep behavior shared

Transport, decoding, pacing, recovery, input transforms and telemetry belong in
the shared engine. Native window, scene, audio-route and device APIs belong in
platform adapters. When adapters contain behavior that must be identical,
extract that implementation into a shared Apple module and call it from both
apps. Do not copy fixes between clients or add platform frameworks to the
portable engine merely to avoid defining an appropriate boundary.

This migration establishes common source ownership and verification. It does not
yet consolidate existing native controller/haptics adapter duplication. That
work should preserve platform lifecycle differences and carry shared tests.

Apple TV and Vision Pro are potential clients, not supported targets yet. Add
native tvOS or visionOS app targets beside the existing clients when their port
starts. Reuse common policy and Apple implementations, with platform adapters
for input, audio, presentation and lifecycle. Add each actual consumer to the
required CI gate; a successful engine-only build does not validate an app.

## CI and releases

The existing required `macOS` check remains named the same and now includes both
iOS Simulator tests and the unsigned iOS Release device build. Shared or app
code changes run both clients; documentation-only changes still run source
checks. Render/UI and comprehensive journeys are one resumable acceptance pass
per feature release; rerun only pending or affected cases. CodeQL builds both
apps and requires successful extraction of every tracked production Swift file,
including `iOS/Glimmer/`. Lint, credential scans, dependency updates and source
checks are configured at the root.

Mac and iOS keep separate bundle identifiers and release lifecycles. The Mac and
iOS apps share the CalVer in `Glimmer/Version.xcconfig`; iOS includes that file
and overrides only its increasing build number in `iOS/Config/App.xcconfig`. The
Mac release workflow and artifacts retain their paths. Internal and external iOS
beta distribution follow the [TestFlight guide](../iOS/docs/TESTFLIGHT.md);
upload eligibility does not establish Beta App Review approval. Public App Store
release is separate. The Raycast extension and Homebrew tap remain separate
repositories with their existing distribution roles.

## Import provenance

The iOS history through `bbe3d843c16b128a76176b85b6e2ed113be49c4c` was imported
under `iOS/` with `git subtree add` without squashing or rewriting its commits.
The Mac starting point is RC12, `dc74ced497fc84defd706b4270e50478b430e562`. The
original iOS repository is unchanged by this local migration.

Use `git log --all` to inspect original iOS commits. Before the import, their
paths are relative to the old repository root. For example,
`git show bbe3d84:Glimmer/LauncherModel.swift` reads an original source file.
The maintainer's original iOS repository was bootstrap work, with no functional
release to preserve. Normal squash merges are permitted for this integration;
retaining its parent history on main is not a release requirement. The recorded
import commit and retained candidate history provide provenance without a
repository merge-policy exception.

The import is a one-time move, not an ongoing bidirectional subtree sync.
Superseded nested workflows and scanners remain available in Git history.

Continue with the [iOS build and device guide](../iOS/CONTRIBUTING.md) or
[Mac contributing guide](CONTRIBUTING.md).
