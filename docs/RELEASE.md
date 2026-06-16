# Release

## The whole release, step by step (2026.6.2-era flow)

```
# 0. one-time, ever: nothing - `make dist` bootstraps itself (see First-run flow)
# 1. bump Glimmer/Version.xcconfig (MARKETING_VERSION + CURRENT_PROJECT_VERSION)
#    + add the CHANGELOG entry; commit + push
# 2. build the artifact (signs, notarizes, staples, DMGs - non-interactive):
make dist
# 3. verify the triple-match BEFORE publishing (the near-miss-shipped-old-code
#    gotcha, hit three times historically):
#      git rev-parse HEAD                       == the commit you think it is
#      /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
#          build/Build/Products/Release/Glimmer.app/Contents/Info.plist
#      spctl --assess --type execute build/Build/Products/Release/Glimmer.app
# 4. tag THAT commit + publish with the DMG:
git tag 2026.6.2 && git push origin 2026.6.2
gh release create 2026.6.2 build/dist/Glimmer-2026.6.2.dmg \
    --title "Glimmer 2026.6.2" --notes-file <notes>
# 5. update the Homebrew cask (tap repo) with the new version + sha256
```

Signing never prompts: the Developer ID lives in a dedicated, never-locking
keychain; every codesign call (bundle AND embedded dylibs) is PINNED to it with
`--keychain`, so the unauthorized login-keychain copy of the same cert can never
shadow it. If a keychain dialog ever appears again, that invariant broke - fix
the pinning, don't click through.

The details of each step follow.

## 1. Version bump

Glimmer uses **CalVer**, not SemVer. Format: `YYYY.M.MICRO`.

- `YYYY.M` is the year and month the release is cut (no zero-pad on month).
- `MICRO` is the patch counter within that month, starting at `0`.

Examples: first May 2026 release is `2026.5.0`; a same-month hotfix is
`2026.5.1`; the next month's release is `2026.6.0`.

`CURRENT_PROJECT_VERSION` (build number) is a monotonic `YYYYMMDD` date stamp,
which guarantees it never goes backwards across patches or hotfixes within the
same month.

**`Glimmer/Version.xcconfig` is the single source of truth** - bump both values
there and nowhere else. The version is NOT set in `project.pbxproj` (the
Makefile applies the xcconfig via `-xcconfig`, which feeds both Info.plists, the
DMG name, and the release tag):

```
MARKETING_VERSION = 2026.6.1
CURRENT_PROJECT_VERSION = 20260605
```

Commit the bump as its own change so the tag points at it:

```bash
git add Glimmer/Version.xcconfig
git commit -m "release 2026.6.1"
```

CalVer rationale: Glimmer is shipped continuously off a single branch, not
versioned by a feature contract - semver's major/minor/patch distinction is
noise for a one-person app. CalVer makes "what version am I running" answer
itself (when, not which marketing milestone).

## 2. Build and install locally

```bash
make clean
make release && make install
```

This produces `build/Build/Products/Release/Glimmer.app`, adhoc-signs it, and
copies to `/Applications/Glimmer.app`.

## 3. Pre-tag smoke-test checklist

Run all of these against a real host before tagging. Don't skip any of them -
every one has caught a regression at some point.

- [ ] Launch from `/Applications`. Confirm the menu-bar item appears.
- [ ] Pair with a fresh host (one not in your `UserDefaults`): PIN entry
      succeeds, host appears in the list, server cert is pinned.
- [ ] Stream Desktop. Confirm the stream window goes fullscreen, cursor hides,
      keyboard input reaches the host.
- [ ] Stream a 10-bit HDR app on an HDR-capable display. Confirm the HDR chip
      lights up and panel brightness lifts (the host's HDR signalling actually
      reaches the display).
- [ ] Stream a 10-bit HDR app on an SDR display. Confirm the chip stays off and
      tone-mapping doesn't blow out highlights.
- [ ] Quit hotkey: configure a non-default combo in Settings, confirm it ends
      the stream and refocuses the main Glimmer window.
- [ ] Resume path: start a stream, force-quit Glimmer, relaunch, click Stream
      again. Confirm the `/resume` / `/cancel+/launch` busy recovery picks the
      right path (check `log stream` for `→ /resume` or
      `→ /cancel then     /launch`).
- [ ] One-shot moonlight-qt migration: on a Mac with a prior moonlight-qt
      install + paired host, confirm the host appears in Glimmer on first launch
      with no re-pairing required.

If any of these fails, do not tag.

## 4. Tag and push

```bash
git tag -a v2026.5.0 -m "v2026.5.0"
git push origin main
git push origin v2026.5.0
```

Releases are cut manually - there is no automated CI. Create a GitHub release
from the tag and attach the `build/Build/Products/Release/Glimmer.app` zipped,
plus the SHA256:

```bash
cd build/Build/Products/Release
ditto -c -k --sequesterRsrc --keepParent Glimmer.app Glimmer-2026.5.0.zip
shasum -a 256 Glimmer-2026.5.0.zip
```

## 5. Homebrew cask

Not yet shipped. A Homebrew cask (`brew install --cask glimmer`) is planned via
submission to [homebrew-cask](https://github.com/Homebrew/homebrew-cask) once
the app clears their notability bar; the notarized DMG + Sparkle auto-update are
the install paths until then. The cask will set `auto_updates true` so Homebrew
defers to Sparkle.

## Code-signing & notarization

The Makefile auto-detects a `Developer ID Application` cert across the keychain
search list (`DEVELOPER_ID`). When present, `make sign` / `make embed` /
`make dist` sign with it (hardened runtime + secure timestamp); when absent
(e.g. CI or a fresh machine) they fall back to **adhoc** so local dev still
works. `make install` follows the same auto-detection.

The whole pipeline is **non-interactive from any session** - SSH, cron, a CI
runner - once the one-time setup below is done. Two design rules make that
possible:

- **All signing secrets live in ONE credentials file** (default
  `~/.config/glimmer/signing.env`; override with `make ... SIGNING_CREDS=/path`
  or the `GLIMMER_SIGNING_CREDS` env var). Plain `KEY=VALUE`, **mode 0600,
  outside the repo**. `scripts/signing-creds.sh` is the sole reader/writer and
  refuses loose permissions - the same trust model as an `~/.ssh` key. Nothing
  signing-related is pulled from 1Password at build time (`op read` needs an
  interactive signin) or from the **login keychain** (locked outside GUI
  sessions, and the known re-prompt trap).
- **The Developer ID key lives in a dedicated keychain**
  (`glimmer-signing.keychain-db`), imported with `-T /usr/bin/codesign` and
  partition-list-authorized (`apple-tool:,apple:,codesign:`) so codesign never
  shows a "wants to use key" prompt. The keychain's password is stored in the
  credentials file, so every build can re-unlock it after a sleep/lock
  (`ensure-signing` runs on every signed build).

Keys in the credentials file (template: `make creds-init`):

| Key                      | What                                           | Filled by               |
| ------------------------ | ---------------------------------------------- | ----------------------- |
| `P12_PATH`               | absolute path to the Developer ID .p12 export  | owner, once             |
| `P12_PASSWORD`           | passphrase chosen at .p12 export               | owner, once             |
| `APPLE_ID`               | Apple ID email for notarytool                  | owner, once             |
| `APPLE_APP_PASSWORD`     | app-specific password for notarytool           | owner, once (rotatable) |
| `APPLE_TEAM_ID`          | optional; derived from the cert name if absent | owner, optional         |
| `SIGN_KEYCHAIN_PASSWORD` | dedicated release-keychain password            | `make codesign-setup`   |
| `DEV_KEYCHAIN_PASSWORD`  | dedicated dev-keychain password                | `make dev-sign-setup`   |

### One-time owner setup

These four steps are the ONLY manual ones; everything downstream is automatic.

1. **Export the cert.** Keychain Access → My Certificates → right-click the
   `Developer ID Application` cert → Export as `.p12` with a passphrase. Park it
   outside the repo, e.g. `~/.config/glimmer/developer-id.p12` (or pull it from
   1Password once:
   `op read 'op://<vault>/<item>/developer-id-p12' --out-file ~/.config/glimmer/developer-id.p12`).
2. **Create the credentials file.** `make creds-init`, then edit it: set
   `P12_PATH`, `P12_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`. Keep mode 0600
   - the tooling refuses anything looser.
3. **`make codesign-setup`** - builds the dedicated signing keychain from the
   .p12 (codesign pre-authorized), generates the keychain password and stores it
   back into the credentials file.
4. **`make setup-notary`** - stores the notarytool profile `glimmer-notary` **in
   the dedicated keychain** (`--keychain`), so `notarytool submit` can read it
   from any session (the default would be the login keychain - GUI sessions
   only).

Remaining interactive surface after this: none at build time. (First-ever
`xcodebuild` on a fresh machine needs the Xcode license accepted once -
`sudo xcodebuild -license accept` - and notarization needs network.)

### Rotation / maintenance

- **App-specific password rotated** → edit `APPLE_APP_PASSWORD` in the creds
  file, re-run `make setup-notary`.
- **Cert renewed** → re-export the .p12, update `P12_PATH`/`P12_PASSWORD`,
  re-run `make codesign-setup`.
- **New machine** → recreate the creds file + .p12 (steps 1-4 above).
- **Tear down** → `make codesign-teardown`, then delete the creds file.
- **Legacy machines** (set up under the old 1Password/login-keychain flow) keep
  working in GUI sessions - `ensure-signing` and `notarize` fall back to the
  login-keychain stash/profile when the creds file has no answer. Run the
  one-time steps to upgrade to any-session builds.

`make dev` follows the same pattern: `make dev-sign-setup` (zero-prep - it
creates the creds file itself if needed) stores `DEV_KEYCHAIN_PASSWORD` there,
and every `make dev` unlocks the dev keychain from it. The login keychain is
never touched.

### Cutting a signed, notarized DMG

```bash
make dist
```

Runs: **preflight** (fail-fast: identity + creds file + notary profile checked
before any compiling) → clean Release build → Developer ID sign + embed dylibs →
notarize (submit + wait) → staple → DMG (`build/dist/Glimmer-<version>.dmg`).
The DMG's app is stapled, so it passes Gatekeeper offline on any Mac. Verify
with:

```bash
spctl --assess --type execute --verbose=2 build/Build/Products/Release/Glimmer.app
# → "accepted / source=Notarized Developer ID"
```

Individual steps are available too: `make preflight` (just the checks),
`make embed` (sign only), `make notarize` (sign + embed + notarize + staple),
`make dmg` (package an already-signed app).

### Distribution paths

- **Developer-ID DMG** (the `make dist` output) - direct download, passes
  Gatekeeper on first launch once notarized. This is the primary path.
- **Homebrew cask** - still fine; `--cask` strips quarantine regardless.

> MAS note: the streaming transport is a Swift port of GPLv3 moonlight-common-c
> (a derivative work - see [CREDITS.md](../CREDITS.md)), so the Mac App Store
> remains off the table regardless of signing. The clean-room reimplementation
> that would unblock MAS is future work.

### First-run flow (self-bootstrapping)

`make dist` bootstraps itself: the first invocation writes the credentials
template (`~/.config/glimmer/signing.env`, mode 0600) and prints exactly which
keys to fill (`APPLE_ID`, `APPLE_APP_PASSWORD`; plus `P12_PATH`/`P12_PASSWORD`
only if the signing keychain ever needs rebuilding). Fill them - by hand or
piped from a password manager via
`scripts/signing-creds.sh set KEY "$(op read ...)"` - then re-run `make dist`:
the legacy login-keychain password migrates into the file automatically, the
notary profile is stored automatically, and the build → sign → notarize → DMG
pipeline runs unattended. Two invocations, one edit.

## Auto-update (Sparkle)

Glimmer self-updates via [Sparkle 2](https://sparkle-project.org). Updates are
EdDSA-signed and served from a **separate public repo**,
`Se7enbrc/glimmer-releases` (GitHub Pages hosts `appcast.xml`; the notarized
ZIP + DMG + GPL source tarball are the release assets). The source repo stays
private - only the per-release source tarball is published, which satisfies
GPLv3's corresponding-source obligation.

### One-time setup (done 2026-06; here for reference / disaster recovery)

- **Keypair:** `make sparkle-keys` generates the ed25519 keypair. The PUBLIC key
  is in `Glimmer/Info.plist` (`SUPublicEDKey`). The PRIVATE key lives in three
  places: `SPARKLE_ED_PRIVATE_KEY` in `~/.config/glimmer/signing.env` (what the
  pipeline reads via stdin), the login keychain (Sparkle's default), and
  **1Password → Private → `sparkle-key`** (off-machine backup). It is the ROOT
  OF UPDATE TRUST - never commit it; gitleaks/TruffleHog guard every commit. If
  it leaks, rotate: new key → new `SUPublicEDKey` → all clients must re-install
  out-of-band.
- **App wiring:** the Sparkle SPM package (pinned in `Package.resolved`) is
  linked to the Glimmer target; `Glimmer/UpdaterController.swift` exposes "Check
  for Updates..." in the app menu and the menu-bar dropdown. `Info.plist`
  carries `SUFeedURL` (the Pages appcast), `SUEnableInstallerLauncherService`,
  and daily background checks; `Glimmer.entitlements` has the
  `mach-lookup.global-name` exception the sandboxed installer XPC needs
  (`io.ugfugl.Glimmer-spks` / `-spki`).
- **Hosting:** `Se7enbrc/glimmer-releases` is public with Pages enabled; the
  feed is `https://se7enbrc.github.io/glimmer-releases/appcast.xml`.

### Cutting an auto-updatable release

1. Bump `Glimmer/Version.xcconfig` (both `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION`) and **commit** - the appcast version + source
   tarball come from `HEAD`.
2. `make release-publish`. Non-interactive (same creds rig as `make dist`). It:
   builds Release → signs → notarizes → staples → DMG (`dist`), then ZIPs the
   notarized bundle, EdDSA-signs it, archives the corresponding source, creates
   the GitHub release `<version>` on `glimmer-releases` with ZIP + DMG + source
   tarball, and inserts the `<item>` into the Pages appcast.
3. Verify: the new item appears at the appcast URL above, and a prior install's
   "Check for Updates..." offers it.

> **First Sparkle-enabled release:** existing installs have no Sparkle, so they
> cannot auto-update _to_ the first Sparkle build - ship that one out-of-band
> (DMG / Homebrew). Every release after it auto-updates.

Override the releases repo or Sparkle version per-invocation:
`make release-publish RELEASES_REPO=... SPARKLE_VERSION=...`.
