<!-- Start with an issue the maintainer agreed to; one without it is closed.
Read docs/CONTRIBUTING.md for setup, checks and contribution terms. -->

## Issue

<!-- Link the issue where the maintainer agreed to this change. -->

## What

<!-- What does this PR change, and why? -->

## How verified

<!-- Record `make verify` and real-PC checks for engine changes.
Streaming-quality changes need before/after telemetry; see docs/PROFILING.md. -->

## Not verified

<!-- What you did not check, and why. An honest gap beats a confident guess. -->

## Checklist

- [ ] I agree to GPL-3.0 with the [LICENSE additional permission](../LICENSE)
      and certify the [DCO 1.1](https://developercertificate.org) with a
      `Signed-off-by:` matching the author of each contribution commit
- [ ] `make verify` passes on the exact PR head in a clean worktree; SHA and
      checks recorded above (strict lint, zero warnings, tests)
- [ ] Comments explain the WHY for any non-obvious decision (see
      docs/CONTRIBUTING.md → Style)
- [ ] UI change: before and after screenshots at the smallest and largest window
- [ ] Links an issue the maintainer agreed to
- [ ] Leaves `CHANGELOG.md` and `Glimmer/Version.xcconfig` to the maintainer
- [ ] No tool or AI attribution in commits, this description or the changelog
