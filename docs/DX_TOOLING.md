# Developer tooling

Use one pinned toolchain locally and in CI, then run `make preflight` before
pushing. Start with [the developer setup](CONTRIBUTING.md#setup).

## Target inventory

| Status  | Targets                                                                                                                                                                                                                                  |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kept    | `app`, `helper-build`, `embed-helper`, `test`, `test-build`, `test-run`, `test-asan`, `test-scripts`, `check`, `check-portable`, `check-macos`, `verify`, `verify-all`, `ios-app`, `ios-test`, `ios-device`, `clean`, `rc` and `DRY_RUN` |
| Added   | Default `help`, `ci-parity`, `check-hooks`, `check-boundaries`                                                                                                                                                                           |
| Changed | `all` shows help; `preflight` is the single pre-push gate; profiling uses an installed CI build                                                                                                                                          |
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

The old markdownlint invocation consumes filenames as values of `--disable` and
checks no files. This migration preserves that invocation as requested;
activating the rules requires a separate review of existing Markdown findings.

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

Continue with [the release process](RELEASE.md) for hosted candidate acceptance.
