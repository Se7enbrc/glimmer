---
description: Prepare, test, and publish a release candidate.
icon: box-archive
---

# Release process

Build one verified candidate, test the published artifact, then promote those
exact files. For installing updates or joining the candidate channel, use
[Releases and updates](UPDATES.md).

## 1. Prepare the candidate

Choose a numeric CalVer version and a build number above every build in the
shared appcast.

| Value                     | Rule                                                                               |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `MARKETING_VERSION`       | `YYYY.M.MICRO`, such as `2026.10.8`; no candidate suffix.                          |
| `CURRENT_PROJECT_VERSION` | Increasing integer; bump for every changed candidate.                              |
| Candidate tag             | Version plus `-rc.N`; never replace an existing tag.                               |
| Release notes             | The version's `CHANGELOG.md` section, in plain words about changes players notice. |

1. Prepare the focused PR, changelog and both version fields.
2. Run `make verify` and inspect compiler output; no warnings.
3. Push the reviewed commit and wait for hosted Verify and all three CodeQL
   jobs.
4. Point `release-candidate` at that exact commit and create/push its signed
   candidate tag.
5. Dispatch **Release** on `release-candidate`, operation `candidate`, with
   `expected_sha` and `rc_tag`.
6. Review the SHA and workflow, then approve the protected `release` deployment.

Unsigned checks may run while fixing failures. Do not sign or package a
candidate before the hosted checks pass. Missing, skipped, pending, cancelled or
failed checks, missing analysis results or open CodeQL alerts on that ref stop
release. Fork runs cannot authorize it: mirror the reviewed commit and run
upstream checks.

### Cut a candidate from the command line

Use `make rc` only when you intend to push a candidate and dispatch Release.

It requires a clean, pushed PR branch, a new build number and no final tag for
the marketing version. It waits up to 90 minutes for checks, stops on failure,
updates `release-candidate`, pushes the next signed tag and dispatches Release.
Rerunning prints the existing run. `make rc DRY_RUN=1` previews without changes.
Deployment approval remains a separate maintainer action.

### Diagnostic candidates

Use `make rc DIAGNOSTIC=1` for an explicitly installed diagnostic candidate, or
add `DRY_RUN=1` to preview it. Tags use `YYYY.M.MICRO-rc.N-diag`, sharing the
ordinary candidate sequence. The same **Release** workflow verifies the exact
commit, builds Release, signs, notarizes and attests the artifacts. Numeric app
versions and signing entitlements stay unchanged; the signed bundle carries
`GlimmerDiagnosticBuild=YES`. Ordinary candidates carry `NO`.

Diagnostics publish as clearly marked GitHub prereleases for manual download.
They never enter the Sparkle appcast, including its RC channel, and cannot be
promoted to stable or Homebrew. The ordinary `rc` PR label does not request one.
A new build number and commit are required when switching candidate kind;
off-feed diagnostic builds still consume their build number.

Additional local telemetry defaults on in diagnostic builds; an explicit saved
off preference wins for comparison runs. Download the matching symbols ZIP and
`symbols.json` with the app: their app/engine UUIDs and source identity are
recorded in the persisted release receipt and artifact manifests. The symbols
ZIP is attested with the DMG and app ZIP. These are normal notarized builds,
without debugger-access entitlements. Profiling attachment may still be denied;
record that limitation rather than re-signing the installed candidate.

After diagnosis, cut and test a new ordinary candidate before promotion. The
diagnostic tooling must land on main before the candidate cutter will use it,
just like other release tooling changes.

### Cut a candidate from a PR label

Add `rc` to an upstream PR to request the same cut after its exact head passes
checks.

The **Release candidate** workflow runs main's tooling without checking out PR
code. It retries when Verify/CodeQL finishes; each passing new head gets a new
candidate while the label remains. The release GitHub App creates the tag.

Its `rc-cut` environment has no required reviewer and contains
`GLIMMER_RC_APP_CLIENT_ID` and `GLIMMER_RC_APP_PRIVATE_KEY`, synced from
Doppler. Install the App only here, without a webhook, with
Contents/Workflows/Actions/PR write, Checks/Code scanning read, and the
`release-candidate` ruleset bypass. The protected release deployment still needs
approval.

## 2. Test, then promote the same files

Install the published candidate DMG after verifying it; a local rebuild does not
count.

1. [Verify provenance and Apple signing](VERIFY_DOWNLOAD.md), save your game,
   stop streaming, quit Glimmer and install the downloaded app.
2. Record candidate tag, source SHA, build number, macOS, audio devices and Game
   Mode state.
3. Test at Highest quality with [telemetry](PROFILING.md#opt-in-telemetry) and
   bookmarks.
4. Mark each check passed, failed or not tested. Stop the final session to write
   its scorecard.
5. If anything changes, use a new build number/tag, repeat checks and test a new
   candidate.

[Candidate enrollment](UPDATES.md#try-release-candidates) persists across stable
releases; promotion does not change the preference or the signed app.

### Playback acceptance

Exercise the interactions this release can change on a real Mac and PC.

| Check                                          | Expected result                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------------------------ |
| Familiar game scene                            | Correct negotiated codec; bookmark freezes/pops and distinguish picture from sound.  |
| Native fullscreen, switch away/back repeatedly | Moving to the screen edge while away does not replay camera movement on return.      |
| Mini Player, Escape tap/hold                   | Tap reaches the game; hold releases capture; neither opens the PC's Start menu.      |
| Mini Player with another app focused           | Controller still works; keyboard/mouse follow focus.                                 |
| Speakers → AirPods → speakers                  | Sound follows; check spatial anchoring and voice chat with a separate microphone.    |
| Edit/reopen custom resolution                  | Saved dimensions remain.                                                             |
| Stop from fullscreen and Mini Player           | Stream ends and its PC app quits; pointer and clicks work in Glimmer and other apps. |
| Start a fresh stream with changed quality      | New resolution/FPS/HDR apply and input captures correctly.                           |
| Confirmed URL quit and cancellation            | Quit closes the named PC app; cancelling the alert leaves it running.                |

There is no disconnect-and-resume acceptance path in this release. Keep the
[audio device checks](PROFILING.md#audio-device-checks) and any targeted
input/pacing comparisons with the candidate's evidence.

### Promote

Merge only after the maintainer accepts the candidate, then wait for main's
required checks.

1. Dispatch **Release** on `main`, operation `promote`, with current
   `expected_sha`, tested `rc_tag` and full `candidate_sha`.
2. Approve the reviewed deployment.
3. Confirm the stable release, appcast, Homebrew update and Pages deployment.

Promotion verifies downloaded DMG/ZIP attestations and digests. Main's shipped
inputs must match `SHIPPED` in `scripts/promote-release.py`: app/helpers,
project/package pins, Makefile and build/sign/package scripts. Docs, tests and
release tooling may advance.

It creates the final annotated tag at `candidate_sha`, marks the existing
release stable/latest, removes the appcast's `rc` channel and updates Homebrew.
The candidate tag, asset URLs, ZIP signature and size remain. It never rebuilds,
re-signs or repackages. A conflicting final tag stops promotion.

### Local publication

Use local distribution targets only when the maintainer requests that exact
operation.

`make release` and `make dist` build locally; `make release-publish` directly
publishes and is not candidate promotion. Packaging/publication need a fully
clean tree and valid signatures, notarization, Gatekeeper and launch
authorization. Do not use this path to bypass acceptance or replace published
bytes.

## Website and update feed

Check that the public appcast returns HTTPS 200 without a redirect after every
deployment change.

| Location                                         | Purpose                                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `main`: `index.html`, `website/`                 | Static site, uploaded as files without Jekyll.                                              |
| `appcast` branch                                 | Machine-written `appcast.xml`; release metadata does not move main.                         |
| `https://se7enbrc.github.io/glimmer/appcast.xml` | Feed read by released apps.                                                                 |
| **Pages** workflow                               | Deploys main's site plus the appcast branch on main pushes, Release completion or dispatch. |

An appcast push alone cannot trigger Pages because that branch has no workflow.
After a manual feed edit, dispatch
`gh workflow run pages.yml -R Se7enbrc/glimmer`. Local publication dispatches
it. Preview the site locally with `python3 -m http.server 8765`.

Keep the site without a custom domain until an app release using the new feed
address has reached users; Pages otherwise redirects the existing address. Do
not repoint a live feed while a candidate awaits promotion.

## Hosted release

Keep verification, compilation, signing and publication as separate phases.
Three credential-free jobs verify checks, tests and ASan before the unsigned
build. A fresh signing runner uses pinned trusted-main tooling and validates the
exact unsigned artifact. Publication validates the signed artifact and retries
only missing steps; it never replaces accepted bytes.

Read the [hosted pipeline](RELEASE_PIPELINE.md) for artifact identity,
environment approvals, credential setup, publication recovery and run-summary
acceptance. Land release tooling on main before cutting a candidate that depends
on it.

## 3. Signing credentials

Use explicit Developer ID profiles with the existing certificate for installed
builds.

| Profile                             | Bundle ID                  | Capabilities                                         |
| ----------------------------------- | -------------------------- | ---------------------------------------------------- |
| Glimmer Developer ID                | `io.ugfugl.Glimmer`        | Head Pose, Spatial Audio Profile, Enhanced Security. |
| Glimmer Network Helper Developer ID | `io.ugfugl.glimmer.helper` | Network Topology Observation.                        |

Store mode-0600 files in mode-0700 `~/.config/glimmer/profiles/`:
`Glimmer_Developer_ID.provisionprofile` and
`Glimmer_Network_Helper_Developer_ID.provisionprofile`. Override paths when
needed:

```bash
make release \
  PROVISIONING_PROFILE="$HOME/Downloads/Glimmer_Developer_ID.provisionprofile" \
  HELPER_PROVISIONING_PROFILE="$HOME/Downloads/Glimmer_Network_Helper_Developer_ID.provisionprofile"
```

Validation checks identifier, team, expiry, scope and grants, then embeds each
profile in its own bundle. Missing/expired profiles stop installation; replace
the profile, not the keys. Unsigned checks/tests need no profiles. No ad hoc
installation fallback exists.

### Set up a signing machine

Run setup targets only when the maintainer explicitly requests them.

`make creds-init` creates the credentials file; fill it or set `OP_SOURCE`, then
use `make codesign-setup setup-notary sparkle-keys` for a new setup. Existing
releases must keep their Sparkle key. Secrets stay in the mode-0600 file and its
1Password item, never the repository.

`~/.config/developer-id/` and `~/Library/Keychains/developer-id.keychain-db` are
shared signing state, not repository files. Keep exactly one reachable matching
Developer ID identity. The App Store Connect team API key uses the `notary`
profile; Developer access is sufficient, and it does not depend on the Apple ID
password.

### Renew credentials and tooling

Renew the expiring item without replacing unrelated signing state.

`make dist` reports certificate expiry and warns 60 days ahead. Use the actual
certificate date. Create Developer ID certificates on Apple's G2 Sub-CA; the
older sub-CA stops signing on 2027-02-01. Timestamped builds survive expiry, but
revoking a release-signing certificate can block those builds. Never revoke one.

For an authorized certificate renewal, create the CSR/key outside the
repository, obtain the G2 certificate, export a password-protected P12, update
`P12_PATH` and `P12_PASSWORD` through `scripts/signing-creds.sh`, then rerun
`make codesign-teardown codesign-setup setup-notary`. Store the P12/passphrase
in 1Password. Team/name continuity preserves helper and update identity.

Sparkle tools downloads must match `scripts/sparkle-tools.sh`'s pinned digest. A
`SPARKLE_VERSION` override needs a trusted `SPARKLE_SHA256`. Keep the framework
pin, tool version and bundled full license in `ThirdPartyNotices.txt` aligned.

## 4. Reproducible payload

Compare clean unsigned Release payloads from the same commit, Xcode and macOS
build.

| Command                                                       | Comparison                                                                                      |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `scripts/compare-builds.sh [WORKDIR]`                         | Clone HEAD twice, build both, compare bytes, modes and symlinks.                                |
| `scripts/compare-builds.sh A.app B.app`                       | Compare existing bundles.                                                                       |
| `scripts/compare-builds.sh --normalize Shipped.app Local.app` | Compare copied bundles after removing signatures/profiles/ticket and normalizing Mach-O layout. |

`make CONFIG=Release app embed-helper` builds the unsigned payload. Commit-time
build stamps, stripped path-bearing debug maps and deterministic App Intents
JSON remove build variation. Linker UUIDs and ad hoc signatures are
content-derived. Dirty builds retain wall-clock stamps; `SOURCE_DATE_EPOCH` can
override the timestamp.

### Comparison boundary

State exactly what matched; do not call the full release package reproducible.

| Included                                                               | Excluded or normalized                                                                             |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| App/login/helper binaries, plists, resources, pinned Sparkle framework | Developer ID signatures/timestamps, profiles, ticket, seals, dSYMs, DMG/ZIP container metadata.    |
| `Assets.car` semantic comparison through `assetutil --info`            | Build stamp and temporary Icon Composer rendition names/digests; other catalog content must match. |

The recorded local proof was 2026-10-10, Xcode 27.0 (27A266a), macOS 27.0.1: 69
files matched with that catalog exception. The **Reproducible build** workflow
runs on dispatch/monthly, outside Verify. Hosted Xcode 26.6 proof and normalized
comparison against a published Developer ID candidate remain to be recorded. A
normalized local ad hoc comparison is not that evidence.
