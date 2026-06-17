# Release

Glimmer ships continuously off `main`. CalVer `YYYY.M.MICRO`, bumped only in
`Glimmer/Version.xcconfig`.

## Make a change

```bash
git switch main && git pull && git switch -c my-change
# ...edit...
make dev     # build + install + relaunch, notarized = exactly what ships
make test    # unit tests
```

`make app` = fast compile-only check. `make dist` = notarized DMG, no publish.

## Ship it

```bash
git switch main && git merge my-change
# bump both lines in Glimmer/Version.xcconfig (MICRO +1, build +1); add a CHANGELOG entry
git commit -am "release: 2026.6.X" && git push
make release-publish    # sign, notarize, GitHub release + Sparkle appcast
```

Clients auto-update within a day. Fresh machine, one-time: `make creds-init`,
`codesign-setup`, `setup-notary`, `sparkle-keys`.
