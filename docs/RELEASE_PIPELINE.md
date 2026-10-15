# Hosted release pipeline

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

Before any candidate compilation, three independent jobs check out the exact
candidate SHA: all pre-commit hooks plus `make check`, `make test`, and
`make test-asan`. Each checks the existing hosted Verify and CodeQL
prerequisites, uses its own build directory, and has no release environment or
secrets. Their records must match the SHA, run ID and check name before the
unsigned build job can start. Successful records from an earlier attempt of the
same run remain valid when only failed jobs are rerun; future attempts are
rejected. Compiler warnings fail both Xcode and the standalone helper build. An
existing candidate release, including a draft, blocks rebuilding that tag.

## Fresh signing runner and artifact identity

The unsigned build has read-only permissions and no environment. It uploads only
`Glimmer.app.tar.gz` and a manifest, named `unsigned-RUN_ID-ATTEMPT-SOURCE_SHA`.
GitHub assigns an immutable artifact ID; the build reports that ID and the
manifest's SHA-256 through job outputs. No checkout, scripts, caches or compiler
outputs outside the bundle cross this boundary.

An independent job pins `main` for tooling. The build cannot choose the signing
checkout. After `release` approval, a fresh macOS runner checks out that pinned
main SHA after proving it is an ancestor of `origin/main`, rechecks source and
prerequisites, and downloads the exact artifact ID. Each tooling consumer checks
out static `main` with full history, proves ancestry, then detaches at the pin.
Main may advance during approval or retries without changing the code used. The
signing runner checks GitHub's artifact metadata, source SHA, run, producing
attempt, tag, manifest digest, file set and every payload digest before
importing the bundle. Archive paths, special files, duplicate entries, escaping
links and writes through symlink parents are rejected. Signing policy
entitlements must match main; land signing-policy changes on main before making
a candidate that depends on them.

Signing calls `notarize-bundle`, whose dependency graph cannot compile or embed
the helper. Tooling, entitlements and packaging scripts come from main, never
from the transferred bundle. The candidate's version config and changelog are
read as data from its exact Git commit. Apple credentials are decoded under
`RUNNER_TEMP` with private permissions and removed with the temporary keychain
before packaging. Cleanup failure blocks packaging. An unconditional cleanup
step also runs when the job finishes.

The protected runner never launches the transferred app or helper. Their
Gatekeeper, signature, notarization and launch probes, plus verification of the
Sparkle update signature, run on another fresh runner without the release
environment. Those checks gate publication. No build or release job restores a
cache. The approved workflow, main's tooling, reviewed source and dependencies
remain trusted: a digest binds the handoff, it does not make a malicious build
trustworthy. This is not a SLSA-level claim.

Only the signing job has `id-token: write` and `attestations: write`. The pinned
`actions/attest` action attests the final DMG and ZIP using the candidate
dispatch identity. The main tooling SHA is shown separately in the run summary.
Verify that distinction in the first hosted run. For either downloaded asset:

```bash
gh attestation verify path/to/Glimmer-VERSION.dmg --repo Se7enbrc/glimmer \
  --signer-workflow Se7enbrc/glimmer/.github/workflows/release.yml \
  --source-ref refs/heads/release-candidate \
  --source-digest CANDIDATE_FULL_SHA
```

GitHub stores the provenance and Sigstore records it publicly. This supplements
Developer ID, notarization and Sparkle signatures. See
[GitHub's artifact attestation guide](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

Land these workflow and tooling changes on main before dispatching a candidate
with them. The candidate cutter refuses differences from main in either release
workflow or the release scripts executed by candidate jobs and their imported
helpers. This check runs before moving the candidate branch or creating a tag.
Review the candidate SHA and pinned tooling SHA before approving. Keep the
`release` environment's reviewer, allowed branches (`main` and
`release-candidate`) and disabled administrator bypass. Do not change `rc-cut`:
its main-only environment and separate App retain their existing roles.

## Publication and Homebrew recovery

Before any GitHub Release write, the signing job persists
`signed-RUN_ID-ATTEMPT-SOURCE_SHA` for 30 days. It contains the final signed
DMG, ZIP, attestation bundle, update signature, version and build, release
notes, changelog, exact prerequisite run records, and a manifest of SHA-256
hashes. There is no private key or unsigned checkout in this artifact. The
upload must succeed and the credential-free distribution checks must pass before
publication.

Publication runs separately through `release-publication.yml`, with its own
protected environment approval. It validates the artifact ID and producing
attempt plus the job-output manifest digest again. It receives a publication
token, with no Apple or Sparkle signing key. Uploads add only missing assets;
existing assets, including provenance, must have matching digests and completed
upload state. A retry never replaces them. The appcast update uses the persisted
signature and ZIP length, and a GitHub-signed compare-and-swap commit. A service
or authentication error is not treated as an absent release.

Promotion verifies attestations, public asset hashes, source and unchanged
shipped inputs before minting the tag token. Final tagging uses this job's
pinned main tooling and ancestry check; the separate publication token marks the
same release stable. Promotion never compiles, signs, repackages or uploads
replacement bytes. Homebrew is a separate dependent job. It independently
downloads and verifies that candidate again, requires a stable release, and
checks its downloaded DMG against the verified digest before changing the cask.
Release reads use the read-only run token; only tap writes use the tap token.
Both metadata paths require GitHub's verified signature and signing key through
`createCommitOnBranch`; there is no unsigned fallback.

Recovery is by rerunning the failed job in the **original Release run**:

| Failed phase                               | Safe action                                                                                                          |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Verification or unsigned build             | Before a candidate exists, rerun failed jobs; successful verification records remain valid for the same run and SHA. |
| Signing or persistence, before publication | Resolve the failure and rerun the signing job; never use this to repair a public candidate.                          |
| Distribution validation                    | Rerun validation against the already persisted signed artifact.                                                      |
| Candidate upload or RC feed                | Rerun the publication job only. It can complete a partial draft or repair the feed after the candidate is public.    |
| Stable promotion or feed                   | Rerun the publication job only; it revalidates and reuses the same published assets.                                 |
| Homebrew                                   | Rerun only the tap job; an already current cask creates no second commit.                                            |
| Pages                                      | Rerun Pages and confirm the public appcast, even if a later Release phase failed.                                    |

Successful producer outputs survive a failed-job retry. Consumers use the
explicit **producing** attempt, not the newer retry attempt; another run or SHA
is rejected. Do not select “Re-run all jobs” after signed bytes were accepted or
publication started. GitHub supports reruns for 30 days; see its
[rerun guide](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs).

Source branch movement and tooling removed from main history still fail closed.
If either happens, stop and review recovery instead of weakening the checks.
Advancing main does not invalidate a tooling pin still in its history. Stable
promotion and tap repair can use a new promotion dispatch from reviewed current
main with the same candidate SHA only when the shipped-input comparison still
passes. If a candidate is partially published and its original run cannot
resume, preserve its artifact and remote assets for an explicitly reviewed
recovery. Do not rebuild, replace assets, or invent a manifest to bypass the
producing run's identity. Expired artifacts also require maintainer review; keep
the accepted public release.

GitHub Pages still deploys after the parent **Release** run, even if publication
succeeded and the tap failed. A feed commit changes `appcast`, never `main`.
Check
[Pages runs](https://github.com/Se7enbrc/glimmer/actions/workflows/pages.yml)
and confirm the public appcast contains the correct channel, URL and signature.

Promotion is bound to `main`'s exact commit. If `main` moves after a promote
dispatch, re-running its publication or tap job fails closed; dispatch a fresh
promote on the new `main` instead. That works whenever the shipped paths are
unchanged, and it reuses the same accepted candidate bytes.

## Publication GitHub App setup and PAT retirement

Keep all release credentials as protected `release` **environment secrets**, not
repository secrets. Doppler project `glimmer`, config `release`, syncs them to
that environment. Leave syncing unmasked values as variables disabled; GitHub
needs no Doppler runtime token. Editing only GitHub can be overwritten by sync.

| Secret                            | Purpose                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `DEVELOPER_ID_P12_BASE64`         | Existing Developer ID certificate and private-key export, single-line base64 |
| `P12_PASSWORD`                    | Existing export password                                                     |
| `NOTARY_KEY_BASE64`               | Existing notarization key, single-line base64                                |
| `NOTARY_KEY_ID`                   | Existing notarization key identifier                                         |
| `NOTARY_ISSUER_ID`                | Existing issuer identifier                                                   |
| `APP_PROVISIONPROFILE_BASE64`     | Approved app Developer ID profile, single-line base64                        |
| `HELPER_PROVISIONPROFILE_BASE64`  | Approved helper Developer ID profile, single-line base64                     |
| `SPARKLE_ED_PRIVATE_KEY`          | Existing update-signing key, used only before signed-asset persistence       |
| `GLIMMER_RELEASE_APP_CLIENT_ID`   | New publication App's client ID                                              |
| `GLIMMER_RELEASE_APP_PRIVATE_KEY` | New publication App's PEM private key                                        |
| `RELEASE_CONTENTS_TOKEN`          | Temporary migration fallback PAT for the two release repositories            |

Make `GLIMMER_RC_APP_CLIENT_ID` and `GLIMMER_RC_APP_PRIVATE_KEY` available in
`release` as well as `rc-cut`. Only promotion mints this token, requesting
Contents and Workflows write for `glimmer` with the App's existing ruleset
bypass. It creates only the final tag; publication and tap keep their separate
App. The post-job hook revokes the token, including after a failure.

The publication App does not exist yet. The marked PAT fallback is active only
when both App secrets are absent, and each publication or tap job records that
choice in its summary. A partial pair or an App that cannot mint a token fails;
it does not fall back to the PAT. Keep the existing PAT's 30-day rotation and
day-25 reminder until App acceptance is complete. Never use the broad token from
a local `gh` login.

Maintainer setup, without transferring or replacing Apple or Sparkle keys:

1. Create a dedicated GitHub App, separate from the RC cutter, with repository
   **Contents: read and write** and the automatic **Metadata: read** permission.
   It needs no webhook, Workflows, Actions, Pull requests, Administration or
   OIDC permission. Install it on **only** `Se7enbrc/glimmer` and
   `Se7enbrc/homebrew-glimmer`.
2. Review both repositories' rulesets. Allow this App to write `appcast` in
   glimmer and `main` in the tap where required. Prefer rulesets scoped to those
   branches; do not give publication the RC cutter's workflow-write permission
   or unrestricted branch bypass. Keep verified-signature requirements. No
   workflow creates or changes these bypasses automatically.
3. Generate the App key and store `GLIMMER_RELEASE_APP_CLIENT_ID` and
   `GLIMMER_RELEASE_APP_PRIVATE_KEY` in Doppler's release config, synced to the
   protected environment. Treat the key as a long-lived credential; authorize
   its transfer explicitly and never print it. Do not configure half the pair.
4. Run an approved candidate, verify its provenance, manually accept it, then
   promote it and check Homebrew. Confirm both metadata commits show the
   intended App identity, a valid GitHub signature and GitHub's signing key. The
   existing signature checks deliberately remain mandatory; an incompatibility
   blocks migration rather than allowing unsigned commits.
5. Exercise a failed publication retry and a tap-only retry using the same
   digests. Confirm no compilation or signing job reruns, no asset is replaced,
   Pages deploys the feed, and the cask points to the accepted DMG. Verify the
   App token post-job revocation steps succeed.
6. After a normal release and its tap update succeed through the App, remove the
   marked PAT fallback expressions and their environment selection from
   `release-publication.yml`, delete `RELEASE_CONTENTS_TOKEN` from Doppler and
   GitHub's environment, and revoke the PAT in GitHub. Remove any redundant
   repository copy. Update the “Glimmer release token rotation” maintenance note
   and retire its PAT reminder. Keep an owner and rotation procedure for the App
   private key itself.

The pinned `actions/create-github-app-token` action mints one token immediately
before publication, scoped only to `glimmer`, and a separate token immediately
before the tap write, scoped only to `homebrew-glimmer`. Each requests only
Contents write. Its default post-job hook revokes the token; do not enable
`skip-token-revoke`. Use `client-id`; the pinned version deprecates `app-id`;
see the
[pinned action inputs](https://github.com/actions/create-github-app-token/blob/bcd2ba49218906704ab6c1aa796996da409d3eb1/action.yml).

## Run summaries and hosted acceptance

The final `GITHUB_STEP_SUMMARY` shows the source and tooling SHAs, candidate
tag, build, job and step durations, verified artifact hashes, exact accepted
prerequisite runs and candidate/Pages/feed links. It distinguishes no published
release, a partial draft, and a public candidate or stable release whose feed or
tap may still need repair. It contains recovery instructions, not credentials or
raw signing diagnostics. Each checks job also records its exact prerequisite
links at the time the gate succeeds.

Local fixtures prove rejection paths and idempotent mutations; they cannot prove
GitHub's environment approvals, retained job outputs across partial reruns,
artifact metadata, attestation source identity, App installation permissions,
App commit signatures, Apple notarization, or Pages propagation. Verify those on
the first hosted candidate and promotion, including an intentional late failure.
The owner must still install and test the published candidate on a real PC using
section 2's acceptance checks, and inspect the DMG's Finder presentation.

Do not enable Actions debug logging; release context validation rejects it.
Never upload temporary credential directories, keychains or raw signing inputs.
Embedded provisioning profiles in the signed app are intentional. Cleanup traps
cannot run after a forced kill or runner loss; GitHub decommissions the hosted
VM as the final boundary. See
[GitHub's hosted-runner lifecycle](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners).

Return to the [release procedure](RELEASE.md).
