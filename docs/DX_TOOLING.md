# Developer tooling

Use one pinned toolchain locally and in CI, then run `make preflight` before
pushing. Start with [the developer setup](CONTRIBUTING.md#setup).

## Target inventory

| Status  | Targets                                                                                                                                                                                                                                  |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kept    | `app`, `helper-build`, `embed-helper`, `test`, `test-build`, `test-run`, `test-asan`, `test-scripts`, `check`, `check-portable`, `check-macos`, `verify`, `verify-all`, `ios-app`, `ios-test`, `ios-device`, `clean`, `rc` and `DRY_RUN` |
| Added   | Default `help`, `ci-parity`, `check-hooks`, `check-boundaries`                                                                                                                                                                           |
| Changed | `all` shows help; `preflight` checks affected builds and fast tests; profiling uses an installed CI build                                                                                                                                |
| CI only | `codesign-setup`, `setup-notary`, `ensure-signing`, `sign-bundle`, `notarize-bundle`, `notarize-dmg`, `dmg`, `sparkle-zip`; old signing `preflight` becomes `signing-preflight`                                                          |
| Removed | `dev`, `install`, `reinstall`, `open`, `release`, `dist`, `release-publish`, `brew-bump`, `sign`, `notarize`, `asan-reinstall`, `quit-running`, `uninstall`, `creds-init`, `codesign-teardown`, `sparkle-keys`, `dmg-background`         |

`guard-clean-tree`, `guard-release-version` and `appcast-feed` remain shared
release source checks. `profile`, `profile-signposts`, `enable-telem` and
`disable-telem` remain available. Independent check prerequisites can run with
`make -j`; recipes sequence operations that share build products explicitly.

## Tool and hook coverage

mise pins hk, Pkl, SwiftLint, Actionlint, Zizmor, ShellCheck, TruffleHog, Node,
Prettier, markdownlint, Python, uv, yamllint, the standalone YAML validator from
pre-commit-hooks, coverage and GitHub CLI. The pre-commit framework is removed.
Native Apple tools come from Xcode; Git, Make and system shell utilities come
from the OS. Sparkle's build tools retain their existing version and archive
checksum. Renovate keeps all managed updates in the existing single manual-merge
group.

hk retains file hygiene, structured-data checks, formatters, secret scans and
strict SwiftLint, and adds a standard-library Python import guard. Fixers share
hk's file locks; whole-tree SwiftLint is exclusive. Fixes stop a commit for
review and explicit staging. SwiftLint runs only on macOS.

Markdownlint now receives file arguments after `--` and rejects malformed
headings. Duplicate headings are checked among siblings, so release sections can
reuse labels; front-matter titles do not replace the visible heading. The HTML
rule permits the existing image and link markup. The four original rule
exclusions are unchanged; no additional rule is disabled.

## Cache budget

The official mise action is pinned by full SHA and mise version. Installs use
`mise install --locked`. Runtime and tool caches are separate, each admitted by
the existing 512 MiB entry limit and 5 GiB repository watermark, within the 10
GB free budget. Protected credential jobs install pinned runtimes without
restoring caches. Dependency graphs are committed for npm and Python tools.

## Local measurements

Measured on 2026-10-25 in the feature worktree, at utility priority. These are
local wall-clock observations, not hosted timing claims.

| Command                   |   Before |    After | Result                                      |
| ------------------------- | -------: | -------: | ------------------------------------------- |
| All-file fixing hooks     |  12.07 s |   6.22 s | Passed                                      |
| `make check`              | 171.03 s | 153.64 s | Passed                                      |
| `make verify`             | 373.80 s | 337.57 s | Both stopped at the same Accessibility test |
| `make ci-parity`          |      n/a | 181.58 s | All requested unsigned targets compiled     |
| Separate `make test-asan` |      n/a | 121.46 s | Passed                                      |

Both full verification runs executed 2,869 Swift tests. The only failed test was
`SettingsAccessibilityTests.customFieldsExposeDistinctNamesAndValues`, with
three assertions and Accessibility error `-25212`. The after run used Xcode
26.6; no compiler warnings were found. No tests were skipped or disabled. Hosted
Linux execution, notarization and publication remain unverified locally.

The companion branch from merged PR #196 passed `make check` in 152.24 s (459
fixtures) and `make ci-parity` in 54.83 s. That branch has no iOS app yet; the
compile check reports that explicitly.

## Push safety and warm timings

Preflight passed in 63.56 s on the feature branch and 52.34 s on the main
companion, including hook checks, boundary audits, fast tests and affected Xcode
26.6 builds. Neither run reported compiler warnings. Full integration, Mac and
AddressSanitizer tests remain in `make verify` and hosted verification.

All script fixtures isolate Git and XDG variables, home, configuration and
working directory before setup; Git transports permit only local files. Every
suite runs with poisoned hook variables pointing at a decoy repository and
checks that its bytes remain unchanged. The feature suite passed all 516 tests
in 203.81 s, including a second candidate-suite run against the decoy. The
companion passed all 466 tests; its complete `make check` took 182.36 s.

Install the [guarded hooks](CONTRIBUTING.md#migrate-shared-hooks) once. The old
framework accepts missing configuration until every active branch has migrated;
then uninstall its hooks. Hook installation and Git configuration were not
changed as part of this follow-up.

## Swift CodeQL timing

[Run 40202604052](https://github.com/Se7enbrc/glimmer/actions/runs/40202604052)
took 31m24s: traced builds consumed 26m15s and analysis 2m22s, with a framework
cache hit. The Simulator built both arm64 and x86_64; the redundant x86_64
engine and app work occupied about 3m55s. The helper ran for another 69s after
the Mac app completed.

The traced build now uses arm64 for both SDKs and builds the helper alongside
the Mac app. No production file or query is removed; both apps, the engine and
helpers still must pass the complete-extraction gate. No production source uses
an architecture conditional. A conservative warm estimate is 28–30 minutes,
allowing for overlap and CPU contention; this requires a hosted run to measure.

[Swift supports manual or autobuild, not build-mode none](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages#building-swift).
Compiler caches remain off because a cache hit can bypass extraction. Mac and
iOS extraction already overlap in one database; reusing ordinary compiled
products would lose coverage.

Continue with [the release process](RELEASE.md) for hosted candidate acceptance.
