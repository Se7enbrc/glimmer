<!--
Thanks for contributing. Pull requests start as an issue the maintainer has
agreed to; one without an agreed issue is closed. Please read
docs/CONTRIBUTING.md first - it covers setup, build (`make`), lint posture, the
Swift 6 concurrency rules, and the commit-message conventions this repo uses.
-->

## Issue

<!-- Link the issue where the maintainer agreed to this change. -->

## What

<!-- What does this PR change, and why? -->

## How verified

<!--
How did you check it works? `make app` + a real stream against a Sunshine host
is the bar for engine changes; for streaming-quality changes, telemetry
numbers (before/after) are the house currency - see docs/PROFILING.md.
-->

## Not verified

<!-- What you did not check, and why. An honest gap beats a confident guess. -->

## Checklist

- [ ] `make app` builds clean
- [ ] `make verify` passes (strict lint, zero warnings, tests)
- [ ] Comments explain the WHY for any non-obvious decision (see
      docs/CONTRIBUTING.md → Style)
- [ ] UI change: before and after screenshots at the smallest and largest window
- [ ] Links an issue the maintainer agreed to
- [ ] Leaves `CHANGELOG.md` and `Glimmer/Version.xcconfig` to the maintainer
- [ ] No tool or AI attribution in commits, this description or the changelog
