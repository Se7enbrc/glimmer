# Release

Releases use CalVer `YYYY.M.MICRO` and a tested release candidate. Every code
change goes through a PR. A candidate must pass the hosted checks before it is
built, then pass a playback test before the PR is merged or the candidate is
promoted. A green build alone is not release acceptance.

## 1. Prepare the candidate

Keep the final numeric marketing version in `Glimmer/Version.xcconfig`, such as
`2026.10.6`. Increment `CURRENT_PROJECT_VERSION` for every changed candidate.
Build numbers are increasing integers, not dates, and must exceed every build in
the shared appcast. GitHub tags distinguish candidates, such as
`2026.10.6-rc.1`; do not put that suffix in either bundle version field.

Use `make verify` for development checks. It runs workflow lint, strict Swift
lint, release-tool tests, hostless Swift tests and protocol tests under
AddressSanitizer. Inspect compiler output for warnings. Ordinary unsigned
compile checks and tests can run while fixing a failing check; signing or
packaging a candidate must wait for the hosted checks to pass.

Push the reviewed PR commit and wait for Verify's macOS job and all three CodeQL
jobs (Swift, Python and Actions) to succeed. The release workflow checks that
exact commit, the upstream workflow identities and their analysis results.
Missing, pending, skipped, cancelled or failed required checks stop it before
compilation. Open code-scanning findings on the analyzed ref also stop the
release.

Once all checks pass, point the maintainer-controlled `release-candidate` branch
at that exact reviewed commit. Fork-owned workflow runs cannot authorize a
release: after mirroring a reviewed fork commit, run Verify and CodeQL on
`release-candidate` and wait for both to pass. Create its candidate tag with the
maintainer's normal signed Git workflow and push it over SSH. Do not replace an
existing tag. The publisher requires the tag to exist already, so the scoped
release token does not create a tag for a commit containing workflow changes.

Dispatch **Release** on `release-candidate`, choose `candidate`, and supply
`expected_sha` and `rc_tag`. Review the exact SHA and workflow before approving
the protected `release` deployment. The workflow verifies again, builds once,
signs and notarizes, packages the final DMG and ZIP, attests them, then
publishes a GitHub prerelease and its Sparkle `rc` appcast item. It does not
update Homebrew.

**One command.** From the pushed PR branch, `make rc` does the steps above. It
refuses a dirty or unpushed tree, a build number that doesn't exceed every build
in the live appcast, and a marketing version that already has a final tag. It
waits up to 90 minutes for the required checks, stopping at once on a failure,
then moves `release-candidate` to HEAD, creates and pushes the next signed
`-rc.N` tag and dispatches **Release**. It opens the run; approving the
protected `release` deployment there is the remaining step. Rerunning prints the
existing run. `make rc DRY_RUN=1` prints each step without changing anything.

**From the pull request.** Adding the `rc` label to a pull request from this
repository runs the same cut in the **Release candidate** workflow, which
comments the Release run on the pull request; approving the deployment is still
the maintainer's step. To cut again after new commits, remove and re-add the
label. The workflow tags as the release GitHub App rather than with a personal
signature; the run's attestation identifies the build. It needs a GitHub App
installed only on this repository, with read and write access to contents,
workflows, actions and pull requests and read access to checks and code scanning
alerts, no webhook, and a bypass on the ruleset that protects
`release-candidate` and `*-rc.*` tags. Its client ID and private key live in the
`rc-cut` environment (no required reviewers) as `GLIMMER_RC_APP_CLIENT_ID` and
`GLIMMER_RC_APP_PRIVATE_KEY`, synced from Doppler like the release secrets.

## 2. Test, then promote the same files

For the first candidate, download its DMG from the GitHub prerelease and verify
its provenance as described below. Stop streaming, quit Glimmer, and install
that app. Test the downloaded candidate itself, rather than a local rebuild.

Enroll this Mac once to receive future candidates through Sparkle:

```bash
defaults write io.ugfugl.Glimmer GlimmerUpdateChannel -string rc
```

Restart Glimmer after setting the preference. Enrollment persists across stable
releases and future candidates. It belongs to this user's Glimmer preferences,
so copies with the same bundle identifier share it. Regular installs remain on
stable updates. To leave the candidate channel, set the value to `stable` and
restart. The signed app is identical for both groups; the preference is never
embedded in the app or changed automatically during promotion.

Record the candidate tag, source SHA, build number, macOS version, audio devices
and Game Mode state with playback results. Test at Highest quality. For this
release, use the following acceptance checks:

- Play a familiar scene and check the basic overlay's negotiated codec. Bookmark
  any freeze or pop with **⌃B**, noting whether video, sound or both stopped.
- In native fullscreen, switch to another Mac app, move the pointer to the top
  of the screen, then switch back. Repeat several times. The game camera must
  not replay that movement or jump when capture resumes.
- Enter Mini Player, tap Escape in a game menu, and hold Escape to release
  capture. Neither action should open the PC's Start menu. With another Mac app
  frontmost, the gamepad should still control the game in Mini Player.
- Switch speakers → AirPods → speakers during one stream. Sound must follow both
  switches; check screen-anchored spatial audio with AirPods. Compare with
  Discord's microphone inactive and with a separate microphone selected.
- Save a custom resolution, reopen its editor and confirm the saved dimensions.
- Choose Stream → Stop Streaming from fullscreen and from Mini Player. The Mac
  pointer must be visible, and clicks must work in Glimmer and other apps. Start
  another stream and confirm input capture works again.

Stop the final session so telemetry writes its scorecard, then review it with
the bookmarks and listening notes. Record each result as passed, failed or not
tested; earlier local-build results do not count for this artifact. A fix after
acceptance requires a new build number, tag, green checks and another candidate
test. See [PROFILING](PROFILING.md) for the telemetry files.

Only after the maintainer accepts the candidate, merge the PR. Wait for main's
required checks to pass, then dispatch **Release** on `main` with operation
`promote`, its current `expected_sha`, the tested `rc_tag`, and that candidate's
full `candidate_sha`.

Promotion verifies the downloaded DMG and ZIP against their attestations and
published digests. Main must have the same source tree as the candidate, except
for `appcast.xml`. The workflow marks the existing release stable and latest,
removes the item's `rc` channel, and updates Homebrew. It never rebuilds,
re-signs or repackages. The original candidate tag and asset URLs stay in place;
the stable release title uses the final marketing version. The appcast keeps the
exact ZIP URL, signature and size that the candidate used.

Release notes come from the version's `CHANGELOG.md` section: a flat list of
changes players will notice. The publisher includes these notes in GitHub and
Sparkle. Candidate and stable items share one appcast; normal Sparkle clients
ignore items in the `rc` channel, while enrolled clients can receive both.

Local `make release` and `make dist` remain available for explicitly requested
local builds. Local `make release-publish` is a separate direct publication
path, not the candidate promotion procedure. Do not use it to bypass acceptance
or to rebuild an already published candidate. Packaging and publication require
a clean worktree, including untracked files, and validate signatures,
notarization, Gatekeeper acceptance and app/helper launch authorization.

### Website and update feed

GitHub Pages serves the repository root on `main` at `glimmer.ugfugl.io`.
`index.html` and `website/` are the static landing page; `.nojekyll` keeps the
site and `appcast.xml` as plain files. Preview with
`python3 -m http.server 8765` from the repository root. No site build is needed.

Configure Cloudflare with a DNS-only CNAME to `se7enbrc.github.io` and GitHub's
domain verification TXT record. Keep the TXT record and the root `CNAME` file.
After any domain or Pages change, verify that the website has valid HTTPS and
that `https://se7enbrc.github.io/glimmer/appcast.xml` still resolves to the
update feed. Released apps use that original URL.

### Hosted release

The manual **Release** workflow uses GitHub's standard Apple Silicon `macos-26`
runner with Xcode 26.6, matching Verify and CodeQL. Candidate dispatches accept
only `release-candidate`; promotion dispatches accept only `main`. Both bind the
reviewed full SHA to the dispatch, checkout and current upstream branch. Moving
the branch stops the next protected phase. Runs are serialized, not cancelled by
a later dispatch.

The `release` environment requires a maintainer reviewer, allows deployments
from exactly `main` and `release-candidate`, and disables administrator bypass.
For a sole maintainer, self-review remains allowed; deployment approval is still
separate from dispatch. Review the workflow and SHA before approving. Adding an
allowed branch expands access to release secrets and requires maintainer
approval.

Before any candidate compilation, the workflow requires the existing hosted
checks to be green. It then runs all pre-commit hooks with
`GLIMMER_SECRET_SCAN_ALL_FILES=1` and `make verify`. App and helper compilation
finish before Apple signing credentials are exposed. Signing reuses those
outputs; it cannot compile. Completion records bind each phase to this run and
SHA. Compiler warnings fail both Xcode and standalone helper builds. Pull
requests receive no release secrets, and releases use no pull-request artifacts
or restored caches. Promotion receives only the scoped publication token, with
no Apple signing material or Sparkle private key.

Store these nine values as **environment secrets**, not repository secrets:

| Secret                           | Existing material or permission                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------ |
| `DEVELOPER_ID_P12_BASE64`        | Single-line base64 of the existing Developer ID certificate and private-key export         |
| `P12_PASSWORD`                   | Password for that export                                                                   |
| `NOTARY_KEY_BASE64`              | Single-line base64 of the existing notarization API key                                    |
| `NOTARY_KEY_ID`                  | Existing API key identifier                                                                |
| `NOTARY_ISSUER_ID`               | Existing API issuer identifier                                                             |
| `APP_PROVISIONPROFILE_BASE64`    | Single-line base64 of the approved Glimmer Developer ID profile                            |
| `HELPER_PROVISIONPROFILE_BASE64` | Single-line base64 of the approved network-helper Developer ID profile                     |
| `SPARKLE_ED_PRIVATE_KEY`         | Existing update-signing private key; never generate a replacement for CI                   |
| `RELEASE_CONTENTS_TOKEN`         | Expiring fine-grained token for only `glimmer` and `homebrew-glimmer`, Contents read/write |

The publishing token belongs to the maintainer whose existing repository role
can publish through the ruleset. It needs neither Workflows nor Administration
permission. Do not substitute the broad personal token used by a local `gh`
login, or grant GitHub Actions a general ruleset bypass. This scoped token still
permits content changes throughout the two selected repositories; it is not
restricted to the appcast and cask files. Record its expiry and renew it before
the next release when necessary.

For Doppler-managed credentials, use the dedicated `glimmer` project and
`release` config. Configure its GitHub Actions sync for `Se7enbrc/glimmer` and
the protected `release` environment. Keep unrelated secrets out of that config
and leave syncing unmasked values as variables disabled. Make changes in
Doppler; the sync can overwrite edits made only in GitHub. The workflow reads
GitHub environment secrets directly and needs no Doppler service token at
runtime.

The publishing token currently has a 30-day lifetime. Rotate it before expiry:
create a replacement with the same two-repository scope, update Doppler, confirm
the sync and permissions, then revoke the old token. A day-25 reminder leaves
time to resolve an access problem. This schedule does not apply to the Apple
certificate, provisioning profiles or Sparkle update key.

Prepare and review the workflow before transferring any signing material. The
repository's signing-material restrictions still apply: obtain the maintainer's
explicit authorization for the specific secret transfer. Reuse the existing
certificate and profiles; this setup does not require new certificates or keys.

`scripts/ci-release.sh` decodes signing files under the runner's temporary
directory with private permissions, generates a fresh keychain password, and
cleans up the keychain and files when signing finishes or fails. Publication
receives only the Sparkle key and scoped publishing token. The token stays in
the process environment; an HTTPS credential helper reads it without putting it
in a remote URL or Git configuration. The tap uses a fresh HTTPS checkout. An
unconditional cleanup step also runs at job completion. Do not enable Actions
debug logging for release runs; the script rejects it. Never upload the runner
temporary directory, credentials, keychains or raw signing inputs as artifacts.
The provisioning profiles embedded in the signed distribution are intentional.

The DMG and Sparkle ZIP are packaged in a separate step after signing
credentials are removed. Packaging requires a successful signing record for this
run and SHA, and publication requires completed packaging and artifact
attestation. A keychain-deletion or file-cleanup failure fails the signing phase
and cannot authorize packaging, even when notarization succeeded. The completion
records enforce sequencing on this trusted runner; they are not independent
attestations of the build.

The pinned `actions/attest` action attests exactly the final DMG and Sparkle ZIP
before publication. It receives no release credentials and uses GitHub OIDC with
a short-lived public Sigstore certificate, not a stored signing key. GitHub
stores the signed build provenance; Sigstore records it in a public transparency
log. Publication checks both files against their packaging digests before
preparing credentials, and never recreates the ZIP. A failed or missing
attestation stops publication. This records the build's source and workflow
identity; it does not claim a SLSA level or replace Developer ID, notarization
or Sparkle signatures. See
[GitHub's artifact attestation guide](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

For a downloaded asset, verify its provenance and release-workflow identity:

```bash
gh attestation verify path/to/Glimmer-VERSION.dmg --repo Se7enbrc/glimmer \
  --signer-workflow Se7enbrc/glimmer/.github/workflows/release.yml \
  --source-ref refs/heads/release-candidate \
  --source-digest CANDIDATE_FULL_SHA
```

Use the ZIP path to verify the update archive. Local `make release-publish`
still prepares and publishes both assets, but does not create a hosted build
attestation.

All these steps share the same job and runner. The reviewed source, build tools
and dependencies remain trusted throughout the run. Limiting each step's
credentials and deleting temporary files reduces exposure; it does not provide
process isolation from earlier steps on that runner.

Cleanup traps cannot run after a forced process kill or runner failure. GitHub
decommissions its hosted VM when the job completes, providing the final boundary
for temporary runner state. Cleanup remains best effort in those failure cases;
it is not a guarantee that no credential ever existed in memory or on disk. See
[GitHub's hosted-runner lifecycle](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners).

Publication uses the existing immutable-release checks and commits the appcast
after pinning the release tag. Hosted appcast and cask updates use GitHub's
`createCommitOnBranch` API, which signs the commit with GitHub's key. The
request includes the expected branch-head SHA, so a concurrent update fails
instead of being overwritten. The script requires GitHub to report both a valid
signature and its own signing key. No personal SSH signing key goes to the
runner. Local publication continues using normal Git commits and the
maintainer's configured signing method.

The API commit updates the remote branch; the disposable hosted checkout keeps
its generated metadata without resetting other files. If a response fails or
does not confirm the signature, inspect the remote branch before retrying: the
commit may already exist. The script never retries a commit mutation or falls
back to an unsigned commit. See
[GitHub's commit API](https://docs.github.com/en/graphql/reference/commits#createcommitonbranch).

An update authenticated with the scoped token triggers the existing Pages build;
`GITHUB_TOKEN` would not. Check that Pages finishes and the public appcast
contains the new version. The repository token provided automatically by Actions
has read-only Contents, Actions and Security events access, plus write access to
Attestations. The job also has OIDC token permission for the attestation
certificate. These job permissions apply throughout the run; they do not isolate
the attestation step from other trusted build steps. The separate scoped token
still owns content publication.

If publication succeeds but the tap step fails, the release is already public.
Retry the promotion with the reviewed current main SHA and the same candidate
inputs; it reuses the existing assets. Do not rebuild the published version. If
the appcast push fails after assets publish, preserve the original assets and
resolve that publication step without replacing them. A new build of the same
source can contain different signed bytes and must not overwrite an existing
release.

## 3. Signing credentials

Installed builds require two explicit macOS **Developer ID** provisioning
profiles, made with the existing Developer ID Application certificate:

| Profile                             | Explicit App ID            | Capabilities                                        |
| ----------------------------------- | -------------------------- | --------------------------------------------------- |
| Glimmer Developer ID                | `io.ugfugl.Glimmer`        | Head Pose, Spatial Audio Profile, Enhanced Security |
| Glimmer Network Helper Developer ID | `io.ugfugl.glimmer.helper` | Network Topology Observation                        |

Store these files with mode 0600 in the mode-0700 directory
`~/.config/glimmer/profiles/`, outside the repository:

- `Glimmer_Developer_ID.provisionprofile`
- `Glimmer_Network_Helper_Developer_ID.provisionprofile`

These are the Makefile's default paths, so normal `make release`, `make dev` and
`make reinstall` commands need no extra arguments. The signing private key
remains in the existing Developer ID keychain. To use profiles elsewhere,
override their paths:

```bash
make release \
  PROVISIONING_PROFILE="$HOME/Downloads/Glimmer_Developer_ID.provisionprofile" \
  HELPER_PROVISIONING_PROFILE="$HOME/Downloads/Glimmer_Network_Helper_Developer_ID.provisionprofile"
```

Use the actual filenames. The same variables apply to `make dev`,
`make reinstall` and distribution targets; they can also be exported in the
shell. Profile names are labels; the build validates the bundle identifier,
team, expiration, distribution scope and requested entitlement grants. It
derives the signing identifiers from the profiles and embeds each one in its own
bundle before signing inside out. It uses only the two configured paths; it
never scans other signing directories. Both `.provisionprofile` and
`.mobileprovision` files are gitignored as a second safeguard.

Missing or incompatible profiles stop signing. There is no ad hoc installation
fallback for these restricted capabilities. `make app`, `make test` and
`make verify` remain unsigned and need no profiles or signing credentials.

Fresh machine, one-time: `make creds-init`, fill in the file it prints (or set
its `OP_SOURCE`), then `make codesign-setup setup-notary sparkle-keys`. Secrets
live in that 0600 file and its 1Password item, never in the repo.

Sparkle's command-line tools are downloaded only after their archive matches the
SHA-256 pinned in `scripts/sparkle-tools.sh`. When overriding `SPARKLE_VERSION`,
supply `SPARKLE_SHA256` from that release's trusted digest. Keep the framework
package pin and the tools version in step, and refresh Sparkle's full license
text in `Glimmer/ThirdPartyNotices.txt`. The app bundles that file, `CREDITS.md`
and `LICENSE` as resources.

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
