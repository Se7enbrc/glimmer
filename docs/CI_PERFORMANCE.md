# PR CI measurements

Measured on 2026-10-25 with `gh run list`, `gh run view --json jobs`, the jobs
API and completed job logs. All durations are minutes. Queue is job creation to
runner start, excluding dependencies. Setup includes checkout, tools and cache
maintenance. Build/test splits use the first test-suite timestamp; Simulator
boot is included with build. Test includes coverage reporting. Analysis and
static checks occupy the test/check column. Upload includes artifact and cache
uploads; teardown and step gaps are not shown.

These PR heads include the feature branch's iOS and iPad UI tests; main still
has only the Mac app. #193 predates the iOS and Sequoia gate additions. The
reported 105-minute PR run was not found in these attempts; #195 completed in 58
minutes, not 105.

## PR #191

[Verify](https://github.com/Se7enbrc/glimmer/actions/runs/40184324320) ·
[CodeQL](https://github.com/Se7enbrc/glimmer/actions/runs/40184324311)

| Job                    | Queue | Setup | Build/boot | Test/check | Upload | Total active |
| ---------------------- | ----: | ----: | ---------: | ---------: | -----: | -----------: |
| Decide what to verify  |  0.02 |  0.08 |       0.00 |       0.00 |   0.00 |         0.13 |
| iOS (device)           |  0.05 |  0.10 |       2.43 |       0.00 |   0.03 |         2.65 |
| Verify (sequoia build) |  0.05 |  0.05 |       4.30 |       0.00 |   0.08 |         4.53 |
| iOS (Simulator)        |  0.05 |  0.07 |       4.58 |      20.21 |   0.62 |        25.57 |
| Engine iOS             |  0.07 |  0.10 |       4.41 |       0.62 |   0.03 |         5.27 |
| libFuzzer              |  0.03 |  0.03 |       0.00 |       3.33 |   0.05 |         3.47 |
| Verify (checks)        | 14.30 |  0.72 |       0.00 |       8.23 |   0.07 |         9.13 |
| Verify (fuzz)          | 16.00 |  0.20 |       5.57 |       1.65 |   0.03 |         7.53 |
| Verify (tests)         |  2.73 |  0.20 |       5.70 |       5.13 |   0.43 |        11.53 |
| Verify (sequoia)       | 25.62 |  0.18 |       0.00 |       4.58 |   0.32 |         5.18 |
| macOS                  |  0.03 |  0.00 |       0.00 |       0.00 |   0.00 |         0.03 |
| Analyze (swift)        |  0.05 |  5.98 |      16.53 |       2.47 |   0.02 |        25.40 |
| Analyze (actions)      |  0.03 |  0.58 |       0.00 |       0.38 |   0.00 |         1.05 |
| Analyze (python)       |  0.02 |  0.55 |       0.00 |       0.50 |   0.00 |         1.12 |

## PR #193

[Verify](https://github.com/Se7enbrc/glimmer/actions/runs/40149491889) ·
[CodeQL](https://github.com/Se7enbrc/glimmer/actions/runs/40149491967)

| Job                   | Queue | Setup | Build/boot | Test/check | Upload | Total active |
| --------------------- | ----: | ----: | ---------: | ---------: | -----: | -----------: |
| Decide what to verify |  0.03 |  0.05 |       0.00 |       0.00 |   0.00 |         0.10 |
| libFuzzer             |  0.03 |  0.03 |       0.00 |       3.62 |   0.00 |         3.67 |
| Verify (checks)       |  4.73 |  0.43 |       0.00 |       4.68 |   0.02 |         5.18 |
| Verify (tests)        |  1.15 |  0.20 |       0.00 |       8.08 |   0.15 |         8.53 |
| Verify (fuzz)         |  3.95 |  0.15 |       0.00 |       4.83 |   0.00 |         5.05 |
| macOS                 |  0.03 |  0.00 |       0.00 |       0.00 |   0.00 |         0.07 |
| Analyze (actions)     |  0.03 |  0.27 |       0.00 |       0.38 |   0.00 |         0.73 |
| Analyze (swift)       |  0.07 |  2.37 |       9.70 |       1.27 |   0.00 |        13.55 |
| Analyze (python)      |  0.02 |  0.27 |       0.00 |       0.38 |   0.02 |         0.73 |

## PR #194

[Verify](https://github.com/Se7enbrc/glimmer/actions/runs/40181079500) ·
[CodeQL](https://github.com/Se7enbrc/glimmer/actions/runs/40181079509)

| Job                    | Queue | Setup | Build/boot | Test/check | Upload | Total active |
| ---------------------- | ----: | ----: | ---------: | ---------: | -----: | -----------: |
| Decide what to verify  |  0.03 |  0.10 |       0.00 |       0.00 |   0.00 |         0.15 |
| Verify (sequoia build) |  0.03 |  0.08 |       5.18 |       0.00 |   0.08 |         5.50 |
| Engine iOS             |  0.03 |  0.08 |       4.21 |       0.50 |   0.03 |         4.93 |
| iOS (device)           |  0.03 |  0.08 |       3.02 |       0.00 |   0.03 |         3.23 |
| Verify (fuzz)          |  0.03 |  0.15 |       3.83 |       1.22 |   0.02 |         5.27 |
| libFuzzer              |  0.05 |  0.03 |       0.00 |       3.37 |   0.07 |         3.52 |
| Verify (checks)        |  3.30 |  0.48 |       0.00 |       6.87 |   0.05 |         7.53 |
| iOS (Simulator)        |  4.97 |  0.05 |       3.83 |      16.42 |   0.40 |        20.78 |
| Verify (tests)         |  5.32 |  0.17 |       3.83 |       5.00 |   0.37 |         9.48 |
| Verify (sequoia)       |  0.05 |  0.15 |       0.00 |       4.97 |   0.45 |         5.95 |
| macOS                  |  0.03 |  0.00 |       0.00 |       0.00 |   0.00 |         0.05 |
| Analyze (python)       |  0.03 |  0.32 |       0.00 |       0.50 |   0.00 |         0.90 |
| Analyze (actions)      |  0.03 |  0.28 |       0.00 |       0.38 |   0.00 |         0.72 |
| Analyze (swift)        |  0.05 |  5.63 |      20.42 |       2.17 |   0.00 |        28.48 |

## PR #195

[Verify](https://github.com/Se7enbrc/glimmer/actions/runs/40184392983) ·
[CodeQL](https://github.com/Se7enbrc/glimmer/actions/runs/40184392945)

| Job                    | Queue | Setup | Build/boot | Test/check | Upload | Total active |
| ---------------------- | ----: | ----: | ---------: | ---------: | -----: | -----------: |
| Decide what to verify  |  0.03 |  0.05 |       0.00 |       0.00 |   0.00 |         0.10 |
| libFuzzer              |  0.02 |  0.05 |       0.00 |       3.37 |   0.05 |         3.52 |
| Verify (tests)         |  4.45 |  0.17 |       0.00 |       9.97 |   0.37 |        10.60 |
| iOS (device)           | 22.55 |  0.07 |       2.20 |       0.00 |   0.03 |         2.43 |
| Engine iOS             | 22.65 |  0.08 |       3.95 |       0.50 |   0.03 |         4.65 |
| Verify (sequoia build) | 24.40 |  0.08 |       4.55 |       0.00 |   0.07 |         4.83 |
| Verify (fuzz)          | 24.75 |  0.22 |       5.60 |       1.50 |   0.07 |         7.47 |
| iOS (Simulator)        | 27.32 |  0.07 |       7.05 |      22.49 |   0.73 |        30.48 |
| Verify (checks)        | 25.02 |  0.60 |       0.00 |       7.62 |   0.05 |         8.37 |
| Verify (sequoia)       |  3.03 |  0.23 |       0.00 |       4.98 |   0.20 |         5.52 |
| macOS                  |  0.03 |  0.00 |       0.00 |       0.00 |   0.00 |         0.05 |
| Analyze (python)       |  0.03 |  0.28 |       0.00 |       0.62 |   0.00 |         0.97 |
| Analyze (swift)        |  3.83 |  5.00 |      26.20 |       2.63 |   0.47 |        34.72 |
| Analyze (actions)      |  0.03 |  0.30 |       0.00 |       0.30 |   0.00 |         0.65 |

## Expected critical path

The observed worst run was 58 minutes: iOS waited 27.32 minutes and ran for
30.48 minutes. With five available free Mac slots, budget **22–28 minutes cold**
and **20–26 minutes warm** for a full feature PR. These are estimates, not
hosted acceptance. Concurrent PRs compete for the same five slots.

| Change                                                          | Expected saving or effect                                                                                                                                                  |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One instrumented Mac build, reused on macOS 15                  | Removes 4.3–5.2 build minutes and one Mac allocation.                                                                                                                      |
| One iOS build, complementary core/render consumers              | Removes 8–11 render minutes from the core path; all suites still run.                                                                                                      |
| Portable checks on Linux, native fixtures in the Mac checks job | Removes roughly 6–8 occupied Mac minutes; boundaries using Apple's plutil and signature tests using CryptoKit stay on Mac.                                                 |
| Combine package, engine SDK and device validation               | First Mac wave fits five slots including Swift CodeQL.                                                                                                                     |
| Overlap the two traced CodeQL builds                            | Estimated 4–8 minutes saved, subject to memory/CPU contention.                                                                                                             |
| Untrace only framework-cache keying/copying                     | Removes most of the observed 3.7–4.2 maintenance minutes. Production compilation remains traced and uncached.                                                              |
| Version-only PR selection                                       | Numeric-only version metadata runs checks; direct candidate and main dispatches still run everything.                                                                      |
| Xcode CAS, SDK modules, SwiftPM and unsigned DerivedData        | First new key has 0% hits. At an assumed 30–70% reusable compiler work, expect 2–4 fewer build minutes, less upload/download cost. This hit rate needs hosted measurement. |
| Release verification cache reuse and Linux checks               | Avoids another Mac checks allocation and reuses candidate compiler state; test, ASan and Release configurations remain distinct.                                           |
| Credential-free TestFlight compilation cache                    | Reuses unchanged compilation inputs across candidate archives; signing and delivery restore no cache.                                                                      |

Cache keys separate runner OS/architecture/image, Xcode build, configuration
consumer and dependency/build-setting hashes. Fallbacks never cross those
boundaries. GitHub isolates PR cache writes from main and candidate branches.
TestFlight also separates compiled flavours and retains its exact-source gate.
No cache includes keychains, credentials, profiles or signed distribution
assets. Third-party inputs are hashed; their SwiftPM checkouts and built
artifacts live inside the cached package/build directories. Compiler caches
never authorize a job to skip its build or test command.

Mac coverage and ASan instrumentation cannot share object files, nor can device,
Simulator, Debug, Release and CodeQL instrumentation. Each compatible test build
is produced once; its consumers use test-without-building artifacts. Both
script-test partitions are required, then their coverage is combined into the
original complete report. No coverage thresholds or CodeQL source roots change.

## Local compiler evidence

Only Xcode 27.1 is installed locally. Apple's
[Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
and
[build settings](https://developer.apple.com/documentation/xcode/build-settings-reference)
document compilation caching; the hosted cache action requires Xcode 26.6. That
exact toolchain still needs the first hosted run.

A controlled rebuild with products/intermediates deleted, stable generated
source and the same environment took **42.16 seconds**, then **7.18 seconds** on
repeat: **59 cache hits, zero misses**. SDK module and CAS directories were
retained. An earlier dirty-source experiment invalidated dependent modules and
ran during concurrent validation; its 555.78 seconds is not a cache benchmark.

Build timing summaries and cache diagnostic remarks remain in CI logs. Temporary
100 ms type-check diagnostics found ContentView.body at 1,486 ms,
AWDLHelperManagerTests.failedReleasesWaitForDelayedRestoration at 309 ms and
PairingCryptoTests.digestCrossChecksCryptoKitOnRandomInput at 256 ms. These
reporting flags are not committed. The target graph already builds dependencies
in parallel, uses explicit modules, Debug -Onone, DWARF and the active arm64
architecture. Changing UI structure for roughly a second would add review work
without addressing the measured multi-minute duplication; no Swift source or
assertion changed. Release archives retain dSYMs and production optimization.

## Hook and security audit

The warm pre-commit baseline on main was **7.00 seconds**; the expanded suite
was **7.43 seconds** on main and **8.50 seconds** on the larger integration
branch, including actionlint, pinned offline zizmor and ShellCheck. Existing
YAML/JSON, merge-marker, size, whitespace, TruffleHog and private-key checks
remain. Hook revisions are full SHAs; environments are installed once and
cached. Normal commits do not fetch tools. TruffleHog's required credential
verification remains online. Swift hooks run only when Swift files change;
workflow and shell hooks are scoped to their file types.

Fixed the cutter's persisted checkout token and two shell-safety findings. The
only zizmor exceptions are individually annotated, verified false positives:

- Candidate delivery's workflow_run executes trusted main code and reads run
  identities only.
- Pages' workflow_run checks out the default branch and reads the feed as data.
- Candidate cutting's workflow_run and pull_request_target never execute
  candidate code.
- Same-ref local workflow/action calls have no intervening external checkout or
  action mutation. The installed actionlint does not yet accept the auditor's
  newer $/ syntax; reusable workflows are already resolved at the caller's
  commit.

No rule is disabled globally. The auditor is an official 1.31.1 release binary
verified against its SHA-256 checksum on both Linux and Mac. Protected release
path equality now also covers the new helper/action files.

## Local validation

Both branches passed make check, actionlint and the complete hook suite. Main
passed 445 Python fixtures, 2,015 Swift tests and 17 ASan tests; the integration
branch passed 493 Python fixtures, 2,699 Swift tests and 17 ASan tests. Compiler
logs contain no compiler warnings. The subsequent missing-boundary-tool
regression failed before the fix and passed with all six policy tests on both
branches. A synthetic two-part coverage merge reported all four statements and
both branches, without modifying the coverage reporter.

Install the auditor once with scripts/install-ci-auditor.sh and an existing bin
directory on PATH, then run pre-commit install-hooks before committing. The
installer verifies the official binary checksum; commits never download it.

## Remaining hosted acceptance

The first #196 hosted attempt exposed a Linux packaging mismatch: SwiftLint's
static executable disables SourceKit, and Ubuntu's ShellCheck differs from local
0.11.0. The correction selects the full SwiftLint executable and active Swift
toolchain libraries, fails closed when SourceKit is missing, and pins ShellCheck
0.11.0 by its official checksum. Regression fixtures prove the SourceKit
environment is required. A replacement hosted run is necessary. The first hosted
ASan job passed on Xcode 26.6, emitted CAS miss diagnostics on its cold build
and saved the compiler cache. Warm hit rates remain unmeasured.

Confirm Linux SwiftLint and all portable fixtures, Xcode 26.6 CAS hit rates,
artifact transfer sizes, complete Simulator shard counts, macOS 15 execution,
CodeQL extraction and queue-adjusted wall time. Docker's daemon was stopped
locally, so Linux execution was not claimed as validated.

A prebuilt GHCR tools image could remove roughly 20–90 seconds on a cold Linux
job; a warm tool cache already avoids installation. It does not reduce the Mac
critical path and needs its own digest-producing build and maintenance, so no
image publication is added to this single CI round. Swift stays on Mac. No paid
or self-hosted runners are proposed.

Next: inspect the first hosted timing summaries and the
[Go migration decision](CI_GO_MIGRATION.md).
