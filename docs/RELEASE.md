# Release

Continuous off `main`, CalVer `YYYY.M.MICRO` (bump only in
`Glimmer/Version.xcconfig`). Every change ships through a PR.

## 1. Branch + build

```bash
git switch main && git pull && git switch -c my-change
# ...edit; bump both lines in Glimmer/Version.xcconfig + add a CHANGELOG entry...
make dev     # tests, then build + install + relaunch (notarized = what ships)
```

`make app` = fast compile-only check. `make dist` = notarized DMG, no publish.

## 2. PR + release

```bash
git push -u origin my-change && gh pr create --fill
# merge the PR on GitHub, then:
git switch main && git pull && make release-publish
```

`release-publish` signs, notarizes, cuts the GitHub release, and updates the
Sparkle appcast (clients auto-update within a day). Fresh machine, one-time:
`make creds-init`, `codesign-setup`, `setup-notary`, `sparkle-keys`.
