# Release

Continuous off `main`, CalVer `YYYY.M.MICRO`. Bump both lines of
`Glimmer/Version.xcconfig` and nothing else; the version is not set in
`project.pbxproj`. Every change ships through a PR.

## 1. Branch and build

```bash
git switch main && git pull && git switch -c my-change
# edit; bump Glimmer/Version.xcconfig and add a CHANGELOG entry
make dev     # tests, then build + install + relaunch (notarized = what ships)
```

`make app` is the fast compile-only check. `make dist` builds the notarized DMG
without publishing. Both `dist` and `release-publish` refuse to run against a
dirty worktree, so commit or stash first: a release built from uncommitted
changes would not reproduce from the source at the tag.

## 2. PR and release

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
published DMG and push version and sha256 to the
[tap](https://github.com/Se7enbrc/homebrew-glimmer). If only that step fails,
the release is still live: re-run `make brew-bump`.

Release notes come from `CHANGELOG.md`, so write that section before publishing.
Each release is a `## <version> - <date>` heading followed by a flat list of
bullets, one per change a player will notice, written for them.
`scripts/changelog.py` lifts that block into the GitHub release body and, as
HTML, into the appcast `<description>` Sparkle shows as “what's new”
(`update-appcast.py --backfill` adds it to older items). The DMG is styled by
`scripts/make-dmg.sh` (background, window bounds, icon positions, baked-in
`.DS_Store`); re-run `make dmg-background` after changing that layout.

## 3. Signing credentials

Fresh machine, one-time: `make creds-init`, fill in the file it prints (or set
its `OP_SOURCE`), then `make codesign-setup setup-notary sparkle-keys`. Secrets
live in that 0600 file and its 1Password item, never in the repo.

These belong to your Developer ID, not to Glimmer: `~/.config/developer-id/` and
`~/Library/Keychains/developer-id.keychain-db` hold one identity and one
`notary` profile, and any other project can sign and notarize with them. Exactly
one Developer ID Application identity should be reachable, or signing by name
fails as ambiguous.

- The **Developer ID Application certificate** (`P12_PATH`, `P12_PASSWORD`)
  signs the app. Create it on the G2 Sub-CA; the previous sub-CA ends
  2027-02-01, and nothing it issued signs after that. Apple says G2 certificates
  expire yearly, though the first one issued here runs to 2031-09-17, so go by
  the date `make dist` prints. Shipped builds keep working after their
  certificate expires, because every signature is timestamped. Never revoke a
  certificate that signed a release: Gatekeeper would then block those builds.
- The **App Store Connect team API key** (`NOTARY_KEY_PATH`, `NOTARY_KEY_ID`,
  `NOTARY_ISSUER_ID`) notarizes through the `notary` notarytool profile that
  `make setup-notary` stores in the signing keychain. Developer access is
  enough. It doesn't expire and doesn't depend on the Apple ID password.

`make dist` prints the certificate's expiry and warns 60 days ahead. To renew:

```bash
D=~/.config/developer-id; umask 077
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout $D/developer-id.key \
    -out ~/Downloads/Glimmer-Developer-ID.certSigningRequest -subj "/CN=Glimmer Developer ID/C=US"
# developer.apple.com → Certificates → + → Developer ID Application → G2 Sub-CA → upload it
/usr/bin/openssl x509 -inform der -in ~/Downloads/developerID_application.cer -out $D/developer-id.pem
P="$(/usr/bin/openssl rand -base64 24)"
/usr/bin/openssl pkcs12 -export -inkey $D/developer-id.key -in $D/developer-id.pem \
    -out $D/developer-id.p12 -passout "pass:$P"
scripts/signing-creds.sh set P12_PATH $D/developer-id.p12
scripts/signing-creds.sh set P12_PASSWORD "$P"
rm $D/developer-id.key $D/developer-id.pem
make codesign-teardown codesign-setup setup-notary
```

Then put the new `.p12` and its passphrase in the 1Password item. The signing
identity is matched by name and the app's designated requirement by team, so
updates, privacy permissions and the helpers carry over to the new certificate.
