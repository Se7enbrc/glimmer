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

## Licensing of contributions

By submitting a contribution, you agree to license it under GPL-3.0 together
with the [additional permission in LICENSE](../LICENSE), including App Store and
TestFlight distribution. Contributions use the same terms as the project; you
keep your copyright.

If you are not a project maintainer or writer, please certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org) by
adding a `Signed-off-by: Your Name <your.email@example.com>` trailer to every
commit in your PR with `git commit -s`. The name and email must match that
commit's author. This sign-off is separate from the cryptographic signature
required below.

The DCO check exempts PRs whose author has admin, maintain or write access. If
GitHub cannot return the author's repository permission, it falls back to an
`OWNER`, `MEMBER` or `COLLABORATOR` association. Exempt PRs report success; all
other PRs must have a matching sign-off on every commit.

## Setup

Use the same Mac toolchain as hosted verification.

| Requirement | Version                                                               |
| ----------- | --------------------------------------------------------------------- |
| macOS       | 26 or later, Apple Silicon.                                           |
| Xcode       | 26.6 or later; hosted Swift checks and releases use 26.6 on macOS 26. |
| Python      | 3.10 or later.                                                        |
| TruffleHog  | 3.97.8 or later for the required scan flags.                          |
| Homebrew    | Installs the tools below.                                             |

```bash
brew install python swiftlint actionlint trufflehog pre-commit shellcheck
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
pre-commit install
```

Sparkle is the app's only third-party framework. The engine uses system
frameworks; there are no submodules or vendored C streaming libraries. Read the
relevant [architecture](ARCHITECTURE.md) section before changing it.

## Build

Use unsigned checks for correctness; install only when someone will use the
build.

| Command                                   | Result                                                             |
| ----------------------------------------- | ------------------------------------------------------------------ |
| `make app`                                | Unsigned Debug compile check.                                      |
| `make check`                              | Actionlint, SPDX notices, strict SwiftLint and release-tool tests. |
| `make test`                               | Hostless Swift unit tests.                                         |
| `make test TEST_SUITE=DatagramBatchTests` | One suite; append `/testName` for one test.                        |
| `make test-asan`                          | Protocol fuzz tests under AddressSanitizer.                        |
| `make verify`                             | All checks above; ignores `TEST_SUITE` so the full gate runs.      |
| `make test COVERAGE=1`                    | Swift coverage in `build/coverage`.                                |
| `make test-scripts COVERAGE=1`            | Release-tool coverage in `build/coverage`.                         |

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

### Run the app

Use the signed installation path only when you need to inspect the app.

`make`, `make open` and `make dev` install a signed, notarized Release build;
`make dev` tests first and relaunches it. They require your Developer ID and
explicit [provisioning profiles](RELEASE.md#3-signing-credentials). Compile
checks and tests need neither.

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
| Other files | Prettier, markdownlint and yamllint run through pre-commit.                                |
| Secrets     | Verified-credential scanning plus offline private-key scanning; findings stay out of logs. |

`swift-format` is not enforced because it rewrites the established argument
alignment. Hosted checks run all pre-commit hooks; formatting failures require a
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

| Check                         | Scope                                                                                                                |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `macOS`                       | Parallel checks, Swift tests and ASan tests; docs-only PRs run checks alone. Every `main` commit runs the full gate. |
| CodeQL                        | Required Swift, Python and Actions analysis; Swift uses Xcode 26.6, the other jobs Linux.                            |
| Swift extraction              | Requires every tracked production Swift file; unsupported compilers or incomplete extraction fail.                   |
| Documentation-only Swift skip | PRs with no traced build inputs can skip Swift analysis; release candidates still need exact-commit analysis.        |
| Coverage                      | Per-component reports, no threshold.                                                                                 |
| libFuzzer                     | 30 seconds per target in a separate job, outside the required `macOS` check.                                         |

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
