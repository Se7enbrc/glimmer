<!--
Thanks for contributing! Please read docs/CONTRIBUTING.md first - it covers
setup, build (`make`), lint posture, the Swift 6 concurrency rules, and the
commit-message conventions this repo uses.
-->

## What

<!-- What does this PR change, and why? Link the issue if there is one. -->

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
- [ ] `CHANGELOG.md` entry and `Glimmer/Version.xcconfig` bump for anything a
      person will notice
- [ ] No tool or AI attribution in commits, this description or the changelog
