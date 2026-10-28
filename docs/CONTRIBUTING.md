---
description: Build, test, and prepare a change for review.
icon: code
---

# Developer guide

Start with an agreed issue, make one focused change, and verify it before
requesting review.
[AGENTS.md](https://github.com/Se7enbrc/glimmer/blob/main/AGENTS.md) is binding;
where it differs from this guide, follow the stricter rule.

Both the Mac and iOS apps live here and build the same engine checkout. Use
[repository ownership](APPLE_REPOSITORY.md) for paths and cross-platform checks,
and [iOS contributing](../iOS/CONTRIBUTING.md) for Simulator and device setup.

## Setup

Use the same Mac toolchain as hosted verification.

Use macOS 26 or later on Apple Silicon, with Xcode 26.6 or later. CI uses Xcode
26.6. The committed mise lockfile pins every other development tool.

1. Install mise: `brew install mise`.
2. From this checkout, install the pinned tools: `mise install`.
3. Install the [guarded hooks](#migrate-shared-hooks) for all worktrees.
4. List the everyday commands: `make help`.

Hooks launch through mise and do not download tools during a commit.

### Migrate shared hooks

Git hooks are shared by all worktrees. With Git 2.54 or later, run these
commands once from a migrated checkout. Keep the old framework installed while
any active branch still uses `.pre-commit-config.yaml`.

1. Let the old hooks accept migrated branches:

   ```bash
   pre-commit install --allow-missing-config --hook-type pre-commit --hook-type pre-push
   ```

2. Install hk and guard its launch before mise runs:

   ```bash
   mise exec -- hk install --mise
   for event in pre-commit pre-push; do
     git config --local "hook.hk-$event.command" \
       "test -f hk.pkl || exit 0; test -f mise.toml || exit 0; test \"\${HK:-1}\" = 0 || mise x -- hk run $event --from-hook"
   done
   ```

3. After every active branch has hk, remove the old hooks:

   ```bash
   pre-commit uninstall --hook-type pre-commit --hook-type pre-push
   ```

The config-based hk hooks remain installed. Repeat step 2 after reinstalling hk;
the guards make older worktrees silent even when mise cannot find hk there.

Sparkle is the app's only third-party framework. The engine uses system
frameworks; there are no submodules or vendored C streaming libraries. Read the
relevant [architecture](ARCHITECTURE.md) section before changing it.

## Build

Use unsigned checks for correctness; install only when someone will use the
build.

| Command                                   | Result                                                        |
| ----------------------------------------- | ------------------------------------------------------------- |
| `make app`                                | Unsigned Debug compile check.                                 |
| `make check`                              | hk checks, SPDX notices, boundary audits and tooling tests.   |
| `make test`                               | Hostless Swift unit tests.                                    |
| `make test TEST_SUITE=DatagramBatchTests` | One suite; append `/testName` for one test.                   |
| `make test-asan`                          | Protocol fuzz tests under AddressSanitizer.                   |
| `make verify`                             | All checks above; ignores `TEST_SUITE` so the full gate runs. |
| `make test COVERAGE=1`                    | Swift coverage in `build/coverage`.                           |
| `make test-scripts COVERAGE=1`            | Release-tool coverage in `build/coverage`.                    |

### Hosted verification and local reproduction

Pull requests use three Apple workers in Verify: independent Mac and iOS
build/core workers, then one that runs the same Mac products on macOS 15. CodeQL
uses one additional Apple worker. There is no Apple job matrix competing for all
five available runners. Portable checks and libFuzzer run on Linux.

Pushes, PRs and the default manual dispatch run the core gate. Candidates need
`macOS` and CodeQL on their exact commit; the Release workflow still runs its
sanitizer checks. Security queries, complete extraction, coverage reports,
production device builds, and macOS 15 validation remain required.

Run comprehensive render/UI and journeys once per feature release, such as
`2026.10.8`. Dispatch **Verify** with mode `acceptance` and that release key.
This uses one Apple worker and does not rerun the core gate. To continue, supply
the previous acceptance run ID in `resume_run`; pending and failed cases run,
while passed cases retain their actual tested SHA. The owner reviews production
changes and supplies affected `rerun` patterns, for example
`iphone/*/*Rotation* mac/*/*Mouse*`. This historical acceptance record does not
claim that every retained pass tested the latest SHA.

New or changed journey methods and their test helpers become pending
automatically. Journey methods are batched by device and appearance, with one
build per platform. Passing methods survive a failed batch. Render/UI is one
separately resumable batch, selected by `ios/all/render`. There is no automatic
nightly acceptance run. The `acceptance-ledger` artifact lasts 90 days; download
its minimal JSON before expiry if the release remains open. Hosted screenshots
and results last 14 days. Keep local desktop screenshots private: import only
testcase JSON with `scripts/acceptance_ledger.py`, using a source note instead
of inventing a SHA for an uncommitted working tree. A reviewed initial ledger
can be committed at `docs/release-acceptance/2026.10.8.json`; a resumed artifact
takes precedence.

Run the same test shard with `make ci-local SHARD=mac`, `core`, `render`, or
`journeys`, or `acceptance CI_TEST_FLAGS='--release 2026.10.8'`. The command
requires Xcode 26.6 and its matching Simulator runtime; it fails explicitly when
either is unavailable. Each simulator run uses a new owned device and deletes
only that device. Core and render share one arm64 Simulator build in
`iOS/build/ci/DerivedData`; use `CI_TEST_FLAGS=--run-only` to reuse it. Fresh
builds replace only the runner's own scheme manifests, keeping manual build
products separate. Journeys always run their full Mac/iPhone/iPad and light/dark
matrix. Local simulator tooling can be selected explicitly through
`GLIMMER_SIMCTL` for core/render; the selected Xcode and SDK never change
implicitly.

The shard logs, result bundles, coverage and failure summaries are under
`build/logs`, `build/coverage`, and `iOS/build/ci`. Test failures appear with
source locations when available. Normal runs use one attempt and require a
positive passed-test count. Local diagnosis can use
`CI_TEST_FLAGS='--run-only --diagnostic-retry'` to retry once; it always exits
nonzero and cannot qualify a candidate. Recovered failures remain visible.
Runtime limits produce a failure and preserve the log.

The CodeQL compiler wrapper limits each concurrent platform build to one WMO
thread on the three-core host. Compare traced build duration and complete
extraction receipts against the previous 23.3-minute build before claiming a
speedup; neither a local build nor fewer queued jobs proves faster extraction.

`scripts/fuzz.sh` runs coverage-guided harnesses in a pinned Swift Linux
container. It needs Docker; `FUZZ_SECONDS` controls each target and crashing
inputs stay in `build/fuzz/`.

Release-tool integration fixtures use `scripts/tests/fixture_process.py` to stop
the entire process group before removing temporary files. Its five-minute hang
guard can be raised with `GLIMMER_TEST_TIMEOUT` (seconds) on loaded runners.
Tests of production deadlines use fake responses and clocks instead of elapsed
wall time; production timeout values stay independent of this guard.

The shared scheme runs tests one at a time. Socket deadline tests measure real
elapsed time; launching every test together can starve their callbacks on hosted
runners. Each concurrency test still creates its own overlapping tasks or
threads. Keep those assertions and time limits intact.

### Before pushing

Run `make preflight`. The hk pre-push hook runs this same command: all hooks,
boundary audits, fast script tests and CI-compiler builds for affected targets.
Full script integration tests, Mac tests and AddressSanitizer remain in
`make verify` and hosted verification. On a release branch it also runs
`make rc DRY_RUN=1 SOURCE_ONLY=1`. This validates source before it is pushed;
hosted-check and reservation checks still run when cutting a candidate. The hook
has no project-specific skip switch. Never bypass it as an agent.

`make ci-parity` uses `/Applications/Xcode-26.6.0.app/Contents/Developer` when
installed, without changing the selected Xcode. It compiles the unsigned Mac app
and tests, iOS Simulator app and tests, and iOS device app into separate
directories under `build/ci-parity`. If Xcode 26.6 is absent, it prints a clear
skip message. Preflight selects Mac or iOS from changes against the upstream
branch, including staged, unstaged and untracked files; shared build inputs
select both. Missing base information selects both conservatively.

### Run the app

Install a published CI candidate when you need to inspect the app. Signing,
notarization, credentials, update keys and publication stay in the hosted
Release workflow. Local Make targets only compile and test unsigned products.

For Xcode, run `scripts/generate-build-info.sh` first and base Debug on
`Glimmer/StreamLib.xcconfig` locally. Keep that project setting out of commits.
The script creates the untracked `Glimmer/BuildInfo.generated.swift`; `make app`
and `make test` run it for you.

The equivalent compile command is:

```bash
scripts/generate-build-info.sh
SWIFT_DETERMINISTIC_HASHING=1 xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
  -xcconfig Glimmer/StreamLib.xcconfig CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath ./build -destination 'platform=macOS' build
```

### Build hygiene: don't mint app copies

Build once per thing you need to inspect; use `make verify` between inspections.

Registered copies of `Glimmer.app` gain separate macOS privacy records. Deleting
a copy or rebooting does not remove those records. Stale copies can make Local
Network failures look like PC connectivity problems.

To inspect and unregister a known stale copy:

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -dump | grep -oE '/[^ ]*Glimmer\.app' | sort -u
"$LSREG" -u /path/to/stale/Glimmer.app
```

Unregistering does not revoke privacy grants. Only the user should reset them
with `sudo tccutil reset All io.ugfugl.Glimmer`; this also clears Input
Monitoring. `LocalNetwork` is not a supported `tccutil` service name. Do not
make resets a routine step.

## UI changes

Read [DESIGN.md](https://github.com/Se7enbrc/glimmer/blob/main/DESIGN.md) and
[PRODUCT.md](https://github.com/Se7enbrc/glimmer/blob/main/PRODUCT.md), then
inspect the running result.

| Rule                                                                       | Reason                                                    |
| -------------------------------------------------------------------------- | --------------------------------------------------------- |
| Keep the launcher column's `.fixedSize(horizontal: false, vertical: true)` | The launcher is sized to content.                         |
| No flexible outer frame, height floor or trailing `Spacer`                 | These let the window stretch.                             |
| Match the window's minimum width to the real content width                 | A smaller floor squeezes margins and permits resizing.    |
| Use system controls; custom appearance belongs in a control style          | Keeps focus, keyboard and VoiceOver behavior.             |
| Animate once on a state change                                             | Avoid continuous main-thread work; respect Reduce Motion. |

For a geometry change, run this against the app:

```bash
osascript <<'EOS'
tell application "System Events"
  tell process "Glimmer"
    set w to first window
    set s0 to size of w
    set out to "opens at " & ((item 1 of s0) as integer) & "x" & ((item 2 of s0) as integer)
    try
      set size of w to {1200, 900}
    end try
    delay 0.7
    set s1 to size of w
    return out & "  after_grow=" & ((item 1 of s1) as integer) & "x" & ((item 2 of s1) as integer)
  end tell
end tell
EOS
```

For the content-sized launcher, `after_grow` must match the opening size.
Include before/after screenshots at the smallest and largest allowed sizes.
Check empty, one PC, many apps, mid-stream, disconnected, light and dark,
VoiceOver labels and keyboard navigation.

## Lint

Treat every compiler or strict SwiftLint warning as a failure.

| Check       | Requirement                                                                                |
| ----------- | ------------------------------------------------------------------------------------------ |
| Scope       | SwiftLint covers `Glimmer/`, `GlimmerTests/`, `helper/` and `LoginHelper/`.                |
| Size        | Files and type bodies at most 600 lines; functions at most 80.                             |
| Width       | Keep changed lines within 120 columns, even where lint allows more.                        |
| Fixes       | No suppressions, raised thresholds, force unwraps, force casts or `try!`.                  |
| Hooks       | Never use `--no-verify`; review and restage any `swiftlint --fix` changes.                 |
| Other files | Prettier, markdownlint and yamllint run through hk.                                        |
| Secrets     | Verified-credential scanning plus offline private-key scanning; findings stay out of logs. |

`swift-format` is not enforced because it rewrites the established argument
alignment. Hosted checks run all hk checks; formatting failures require a
reviewed fix.

## Style

Match the neighboring code and reuse shared helpers before adding another.

Use four spaces, same-line opening braces and a trailing newline. Split by
feature into `Type+Feature.swift`. Keep protocol constants' upstream C names.
New and changed comments, including headers, are at most three lines and explain
why. Keep longer rationale in the commit body.

New source files need the neighboring SPDX license/copyright header and four
unique `project.pbxproj` entries: file reference, build file, group and Sources.
Use Swift Testing for new tests. Cover pure logic and every behavior change; a
regression test must fail without its fix. Use defaulted closures or parameters
for seams, not a new protocol with one conformer.

Use sentence case, “the PC”, curly quotation marks, straight apostrophes and
`…`. No emoji, em dashes or exclamation marks in copy. Reuse shared failure
text.

## Concurrency

Keep Swift 6 complete strict concurrency and document ownership at each
boundary.

| State                                  | Isolation                                                                                  |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| UI, AppKit and SwiftUI bindings        | `@MainActor`.                                                                              |
| Session, network, pairing and identity | Actors.                                                                                    |
| Framework callbacks outside actors     | `@unchecked Sendable` only with a documented lock or equivalent invariant.                 |
| Audio render callback                  | Preallocated storage and lock-free atomics; no locks, allocation or runtime metadata work. |

### `nonisolated(unsafe)`

Document why an actor or lock cannot express a safe existing ownership rule.

Valid cases include serial decode-queue ownership, atomic weak callback
references with serialized delivery, and main-actor-only timer slots. A single
writer does not make arbitrary multi-field state safe. Never use it for
multi-writer races or an unprotected layer pointer; the decoder's display layer
uses a lock and its shared format description uses `inputFormatBox`.

### Event-yield discipline

Yield engine events directly through `StreamBridgeContext.eventContinuation`.

Its Sendable continuation preserves callback order. Separate unstructured tasks
can reorder consecutive stage events. Drain receive threads before subsystem
teardown; weak references alone do not establish safe teardown ordering.

## Logging

Use `Logger` on `io.ugfugl.Glimmer`, with a per-file category; CLI output is the
only `print` exception.

| Data                                                            | Rule                                                                 |
| --------------------------------------------------------------- | -------------------------------------------------------------------- |
| PC names, addresses, errors and identifying values              | `.private` in both Logger and Diag; Diag defaults to public.         |
| Timing, stages and non-sensitive format codes                   | May be public.                                                       |
| Keys, PINs, certificates, keystrokes and sensitive query values | Never log. Use `NetworkClient.sensitiveQueryKeys` for URL redaction. |
| Repeated frame or mouse activity                                | Nothing per-frame at `.info`.                                        |
| Root helper                                                     | Separate subsystem `io.ugfugl.glimmer.helper`.                       |
| Telemetry identity                                              | Per-install pseudonyms.                                              |

Private Diag values reach only the in-app viewer; copied, system and session
logs redact them. Logs retain timings, codec configuration, sanitized network
errors, pairing transitions and pin mismatches without fingerprints. See
[log categories](PROFILING.md#unified-log).

## Commits

Use an imperative, lowercase conventional prefix and explain why in the body.

Prefixes include `fix(area):`, `feat(area):`, `perf(area):`, `refactor(area):`,
`test:`, `build:`, `chore:` and `docs:`. No trailing period. Wrap bodies near 72
columns. Commits entering `main` need a signature GitHub verifies; keep private
keys local.

Do not add tool or agent attribution, co-author trailers, session links or
“Generated with” text to commits, PRs, code comments or the changelog. Never
commit secrets or signing material.

## The bar

Prove the behavior you claim, including what the user sees and feels.

Run the app for UI changes, pull the cable for recovery claims, and collect
before/after [telemetry](PROFILING.md) for pacing, bitrate, buffering or decode
changes. Green checks do not replace a real stream or visual review. State what
you did not verify.

## Pull requests

Agree on an issue before coding, then submit one area from your fork against
current `main`.

1. Link the agreed issue. Only the maintainer pushes branches here or merges.
2. Follow
   [fork identity and update-feed rules](https://github.com/Se7enbrc/glimmer/blob/main/AGENTS.md#working-in-a-fork)
   before distributing your build. Keep `LICENSE` and `CREDITS.md`.
3. Leave changelog/version selection to the maintainer. Maintainer releases need
   a user-facing changelog bullet and both version fields bumped together.
4. Run `make verify`, inspect warnings, and include your visual or real-PC
   checks and gaps.
5. Before merging, review the exact head in a clean worktree, rerun
   `make verify`, and record the SHA and results.

### Hosted checks

Wait for the required checks on the exact commit under review.

| Check                         | Scope                                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `macOS`                       | Checks, Mac/iOS core tests, production builds, macOS 15 and libFuzzer; docs-only PRs run checks alone.              |
| CodeQL                        | Required Swift, Python and Actions analysis; Swift uses Xcode 26.6, the other jobs Linux.                           |
| Swift extraction              | Requires every tracked production Swift file; unsupported compilers or incomplete extraction fail.                  |
| Documentation-only Swift skip | PRs with no traced build inputs can skip Swift analysis; release candidates still need exact-commit analysis.       |
| Coverage                      | Per-component reports, no threshold.                                                                                |
| libFuzzer                     | 30 seconds per target in a Linux job required by `macOS`.                                                           |
| Release acceptance            | Explicit resumable render/UI and journey history; owner-reviewed affected reruns, separate from the exact-SHA gate. |

Outside-contributor workflows need maintainer approval. PRs receive no release
credentials. Releases use a separate protected workflow. Main requires squash
PRs, green checks and verified signatures; no force-push or deletion. Repository
admins can bypass the PR/check rule, not the protected release approval.

CodeQL uses security-extended queries and scheduled scans. AI Scan is advisory
and omits fork/bot PRs. Neither replaces testing or security review. TruffleHog
is pinned and verified before use; scan output stays suppressed.

## Write documentation

{% hint style="info" %}

**Writing docs:** Lead with what readers do or get; no intros or hedging. Number
procedures, one action per step, with copy-paste commands where useful. Keep
sections within one screen and lists near five items; split recovery steps. Put
detail in hints; move tests, telemetry fields, internals and code paths to
developer pages. End each user page with a next-step link; first and last lines
must explain purpose and destination.

{% endhint %}

Keep user tasks in the first four GitBook groups and developer work under
Project › Contributing.

Preserve filenames and front matter. Use short action-led sections, tables for
reference and numbered procedures. `docs/SUMMARY.md` defines navigation and
`docs/README.md` is the landing page.

Use
[GitBook's documented hint syntax](https://gitbook.com/docs/create-content/blocks/hint)
for a brief note:

```text
{% hint style="info" %}

Your note goes here.

{% endhint %}
```

Use `warning` for consequences such as quitting a PC app. Run `make check` and
the Markdown formatting hooks, then inspect a GitBook preview for layout and
links.

## Release artifact checks

The [user verification guide](VERIFY_DOWNLOAD.md) covers provenance, Apple
signatures and notarization. Hosted attestations identify source and workflow;
they neither establish a SLSA level nor replace Apple and Sparkle checks.

For `gh attestation verify`, add `--format json` to inspect the source commit,
`--source-digest CANDIDATE_FULL_SHA` to require a full SHA, or
`--bundle FILE.intoto.jsonl` to use a saved bundle. A release may include one;
otherwise download it with:

```bash
gh attestation download FILE --repo Se7enbrc/glimmer
```

Let Sparkle verify updates automatically, or use OpenSSL 3 for an independent
check.

Get the ZIP's exact `sparkle:edSignature` from the
[appcast](https://se7enbrc.github.io/glimmer/appcast.xml) and replace
`SIGNATURE_FROM_APPCAST` below. Use your downloaded ZIP's filename.

```bash
KEY=bUc9IWEtH/FuDUIsGqyDIVy/1gvlPtBkFXNcVO/TrPU=
{ printf 302a300506032b6570032100; echo "$KEY" | base64 -d | xxd -p -c 64; } \
  | xxd -r -p > glimmer-ed25519.der
echo 'SIGNATURE_FROM_APPCAST' | base64 -d > Glimmer.zip.sig
openssl pkeyutl -verify -pubin -keyform DER -inkey glimmer-ed25519.der \
  -rawin -in Glimmer-2026.10.8.zip -sigfile Glimmer.zip.sig
```

Expect “Signature Verified Successfully”. macOS's LibreSSL lacks Ed25519; this
command requires OpenSSL 3. The key above is public and matches `SUPublicEDKey`
in the released app.

Sparkle signs each ZIP, not the feed itself; the feed relies on HTTPS. The
documented checks were exercised on 2026-10-10 against 2026.10.5 and
2026.10.6-rc.1. Repeat them for the particular artifact you download.

Stable promotion reuses the candidate's exact DMG and ZIP. Versions follow
`year.month.release`; the final number is not a day. See the
[changelog](https://github.com/Se7enbrc/glimmer/blob/main/CHANGELOG.md) and
[release process](RELEASE.md).

[![Verification status](https://github.com/Se7enbrc/glimmer/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/Se7enbrc/glimmer/actions/workflows/verify.yml)
[![OpenSSF Best Practices status](https://www.bestpractices.dev/projects/15346/badge)](https://www.bestpractices.dev/en/projects/15346)

[![GPL license](https://img.shields.io/github/license/Se7enbrc/glimmer)](../LICENSE)

## Roles and continuity

Bring proposals to the maintainer, who owns triage, review, merges, versions and
release approval.

Everyone follows the
[code of conduct](https://github.com/Se7enbrc/glimmer/blob/main/CODE_OF_CONDUCT.md);
report conduct concerns to <glimmer-conduct@ugfugl.io> and security issues
through [private reporting](SECURITY.md#reporting).

Only the maintainer has write access and uses a passkey for GitHub two-factor
authentication. Release secrets live in Doppler, accessed through that account.
A designated successor has emergency password-manager access to GitHub, Doppler,
the domain credentials and recovery codes so releases and the update feed can
continue.
