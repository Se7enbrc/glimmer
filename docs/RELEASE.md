# Release

Continuous off `main`, CalVer `YYYY.M.MICRO`. Bump both lines of
`Glimmer/Version.xcconfig` and nothing else; the version is not set in
`project.pbxproj`. Every change ships through a PR.

## 1. Branch + build

```bash
git switch main && git pull && git switch -c my-change
# ...edit; bump Glimmer/Version.xcconfig + add a CHANGELOG entry...
make dev     # tests, then build + install + relaunch (notarized = what ships)
```

`make app` is the fast compile-only check. `make dist` builds the notarized DMG
without publishing. Both `dist` and `release-publish` refuse to run against a
dirty worktree, so commit or stash first: a release built from uncommitted
changes would not reproduce from the source at the tag.

## 2. PR + release

```bash
git push -u origin my-change && gh pr create --fill
# merge the PR on GitHub, then:
git switch main && git pull && make release-publish
```

`release-publish` signs, notarizes, staples, cuts the DMG, EdDSA-signs a ZIP of
the bundle, uploads both to the GitHub release, and updates the Sparkle appcast.
Existing installs pick the update up at their next check (startup, then once a
day). New installs come from the Releases DMG or the Homebrew cask,
`brew install --cask se7enbrc/glimmer/glimmer`.

Last, `release-publish` runs `scripts/homebrew-bump.sh` to checksum the
published DMG and push version + sha256 to the
[tap](https://github.com/Se7enbrc/homebrew-glimmer) - if only that step fails
the release is still live, so just re-run `make brew-bump`.

Release notes come from `CHANGELOG.md`, so write that section before publishing:
`scripts/changelog.py` lifts the `## <version>` block into the GitHub release
body and, as HTML, into the appcast `<description>` Sparkle shows as "what's
new" (`update-appcast.py --backfill` adds it to older items). The DMG is styled
by `scripts/make-dmg.sh` - background, window bounds, icon positions, baked-in
`.DS_Store`; re-run `make dmg-background` after changing that layout.

Fresh machine, one-time: `make creds-init`, then `codesign-setup`,
`setup-notary`, `sparkle-keys`.
