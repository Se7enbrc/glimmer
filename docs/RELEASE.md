---
description: Prepare, test, and publish a release candidate.
icon: box-archive
---

# Release Glimmer

Releases use CalVer `YYYY.M.MICRO` and a tested release candidate. Every code
change goes through a PR. A candidate must pass the hosted checks before it is
built, then pass a playback test before the PR is merged or the candidate is
promoted. A green build alone is not release acceptance.

## iPhone and iPad artifacts

Choose the compiled flavour before archiving: `beta` includes local diagnostics;
`production` excludes them, even when installed through TestFlight. Only a
production archive may be used as App Store submission source. A beta build
cannot be promoted unchanged to production.

Follow the [iOS TestFlight process](../iOS/docs/TESTFLIGHT.md). Keep flavour in
the sealed archive identity and attested receipt, and inspect the executable and
resources before delivery. The current delivery workflow remains internal-only;
public submission requires its own reviewed export from the tested production
archive. Land trusted workflow and script changes on `main` before dispatching;
land app and shared-engine exclusions on the reviewed feature branch.

## 1. Prepare the candidate

Keep the final numeric marketing version in `Glimmer/Version.xcconfig`, such as
`2026.10.6`. Increment `CURRENT_PROJECT_VERSION` for every changed candidate.
Build numbers are increasing integers, not dates, and must exceed every build in
the shared appcast. GitHub tags distinguish candidates, such as
`2026.10.6-rc.1`; do not put that suffix in either bundle version field.

Use `make verify` for development checks. It runs workflow lint, the SPDX notice
check, strict Swift lint, release-tool tests, hostless Swift tests and protocol
tests under AddressSanitizer. Inspect compiler output for warnings. Ordinary
unsigned compile checks and tests can run while fixing a failing check; signing
or packaging a candidate must wait for the hosted checks to pass.

Push the reviewed PR commit X and wait for Verify's macOS job and all three
CodeQL jobs (Swift, Python and Actions) to succeed. These PR checks remain the
integration review prerequisite. They do not authorize candidate delivery.

Use the cutter below to atomically reserve X and move `release-candidate` to X.
It dispatches Verify and CodeQL on that branch and waits for their latest
attempts. Candidate gates require successful upstream dispatches on that exact
branch, all expected language categories with `commit_sha == X`, completed SARIF
processing, and no currently open CodeQL alerts on
`refs/heads/release-candidate`. PR merge analyses never substitute for this
evidence. Successful language jobs and analyses retained by a failed-job rerun
remain valid; a newer pending, failed or cancelled candidate run blocks the
gate. Current global dismissals remain valid, and reopening an alert blocks
delivery again.

The gate checks the branch and reservation before and after reading evidence,
and compares analysis IDs and run attempts around the alert lookup. Missing,
deleted, truncated or changing evidence fails closed. Evidence records include
analysis and upload IDs for diagnosis, not a frozen authorization receipt. The
feature branch may advance to Y or regenerate its PR merge while X remains
reserved. A fix on Y cannot clear an open alert on the candidate ref at X.

Dispatch **Release** on `release-candidate`, choose `candidate`, and supply
`expected_sha` and `rc_tag`. Review the exact SHA and workflow before approving
the protected `release` deployment. The workflow verifies again, builds once,
signs and notarizes, packages the final DMG and ZIP, attests them, then
publishes a GitHub prerelease and its Sparkle `rc` appcast item. It does not
update Homebrew.

**One command.** From the pushed PR branch, `make rc` does the steps above. It
refuses a dirty or unpushed tree, a build number that doesn't exceed every build
on the `appcast` branch, and a marketing version that already has a final tag.
It waits up to 90 minutes for integration checks, then atomically reserves X and
moves `release-candidate`. If the held candidate has the same marketing version
and an older build, it automatically abandons that candidate as superseded,
provided delivery has stopped and it has not been promoted to GA. It dispatches
credential-free Verify and CodeQL and waits up to 45 minutes for candidate
checks and processing, stopping on a terminal failure. Only then does it create
and push the next signed `-rc.N` tag and dispatch **Release**. It opens the run;
approving the protected `release` deployment there is the remaining step.
Rerunning prints an existing Release run, or resumes the held scans without
replacing a failed attempt. Rerun failed jobs in Actions before resuming.
`make rc DRY_RUN=1` prints the steps without changing remote state. A timeout or
failed dispatch keeps the reservation. If the PR has advanced, resume the
original cutter workflow or check out the held `release-candidate` branch
locally and rerun the cutter there. Resumption does not ask the moving PR ref to
prove X again.

**From the pull request.** Adding the `rc` label to a pull request from this
repository runs the same cut in the **Release candidate** workflow, which
comments the Release run on the pull request; approving the deployment is still
the maintainer's step. It runs when the label is added and again each time
Verify or CodeQL finishes, and cuts only once every required check is green on
the pull request's current head; until then it stops in seconds without loading
the app's key. It runs main's tooling and never checks out the pull request.
While the label stays, a new head with a higher build for the same marketing
version automatically supersedes an idle, unpublished candidate. The same
delivery and promotion guards apply as for `make rc`. If a cut was refused while
delivery was pending, remove and reapply the label after delivery stops and its
claims are reconciled. The workflow tags as the release GitHub App rather than
with a personal signature; the run's attestation identifies the build. It needs
a GitHub App installed only on this repository, with read and write access to
contents, workflows, actions and pull requests and read access to checks and
code scanning alerts, no webhook, and a bypass on the ruleset that protects
`release-candidate`. Its client ID and private key live in the `rc-cut`
environment (no required reviewers) as `GLIMMER_RC_APP_CLIENT_ID` and
`GLIMMER_RC_APP_PRIVATE_KEY`, synced from Doppler like the release secrets.

CodeQL records its `sarif-id` as a successful job step after the extraction
safeguard. The gate joins that receipt to the selected run ID, producing
attempt, head SHA and ref, and requires the analysis timestamp inside that job's
interval. A later rerun of an older run supersedes earlier execution evidence;
pending, failed or cancelled executions cannot borrow a different run's green
verdict. Partial reruns may retain successful language jobs only from the same
run.

Stable promotion keeps main's prerequisite gate and also rechecks the held
candidate SHA before tag creation, publication and tap authorization. Valid
attestations and unchanged shipped inputs do not replace the current candidate
reservation, direct scans or ref-scoped alert verdict. Keep X reserved until its
intended promotion and any publication or tap repair finish.

### Shared Mac and iOS reservation

`candidate-reservation` is a durable metadata branch. Its commit message records
the held source SHA and state; it contains no source or credentials. The cutter
updates this record and `release-candidate` in one atomic Git push, with
explicit leases on both refs. Concurrent cutters cannot both allocate the
branch. The reservation covers all Mac publication and iOS delivery of X
together; there is no automatic expiry or release on cancellation, failure or
successful publication. Both platform gates require the reservation still to be
held. Schema 2 records also contain durable delivery claims, each bound to a
workflow, run ID, attempt, head SHA and ref.

When reserving a newer build of the same marketing version, both `make rc` and
the CI `--ci-sha` cutter retire the previous hold automatically. They read both
versions from the exact source commits, then refuse replacement if any delivery
claim remains or any `release.yml`, `ios-testflight-build.yml` or
`ios-testflight.yml` run is incomplete, including deployment approval waits. The
workflow, run ID and status identify pending work; claims identify the workflow,
run ID and attempt to reconcile. The run check includes other refs, because
promotion and iOS delivery can run on `main`.

A final version tag or a GA GitHub release for that version also blocks
automatic retirement. Complete or repair that promotion and explicitly release
its hold. A reservation already marked `released` stays released in history.
Different marketing versions, equal or lower builds, moved refs and `closing`
holds still require explicit recovery or retirement.

Automatic retirement records the previous SHA as `abandoned`, with
`superseded_by` naming its successor, in the reservation's commit history. This
uses the existing state set; legacy schema 1 records remain readable. The
retirement record and new reservation are published with the candidate ref in
one atomic push under both leases. No intermediate unheld state is published,
and a racing delivery admission prevents the replacement. The cutter prints one
line naming the retired SHA and its successor. `make rc DRY_RUN=1` performs the
same guards and prints what it would retire without changing either ref.

Keep both branches under the maintainer/RC App write restrictions. All branch
moves must use the cutter; manual bypass writes can break availability and are
rejected by subsequent gates. No workflow changes rulesets or credential-bearing
allowed refs. Before first use, confirm the RC App can atomically update both
refs under the existing rules. Bootstrap refuses any active Mac or iOS delivery;
finish the shipping release before deploying this tooling.

The **Candidate delivery admission** controller runs only main's tooling in
`rc-cut`. It handles requested, in-progress (including reruns) and completed Mac
Release and iOS TestFlight executions, verifies their live API identity, and
updates claims with a reservation lease. It never downloads or executes
candidate artifacts. Its RC App token has only repository contents write and
Actions read; candidate build jobs keep read-only credentials. Before signing,
publication or Apple upload, the delivery gate requires its exact claim as well
as the current candidate analysis verdict. Admission checks wait at most 20
minutes for admission; missing or failed admission stops delivery without
credentials. Credential gates wait for their current attempt again on partial
reruns; a retained earlier wait or approval cannot admit the new attempt.

Completion removes only that exact attempt's claim after GitHub reports it
completed. Cancellation and failure count as completion, not as permission to
retire the candidate. A missing completion event leaves a durable claim. Recover
by dispatching **Candidate delivery admission** on main with the exact `run_id`
and `attempt`; it rereads GitHub and cannot clear an active attempt. Do not
manually erase claims. A failed or cancelled controller never frees a hold.

After **all intended Mac and iOS deliveries, including stable promotion and tap
repair**, are complete, the maintainer runs from a trusted tooling checkout with
the normal origin credentials:

```bash
python3 scripts/candidate_reservation.py release FULL_CANDIDATE_SHA
```

To abandon X without cutting a superseding build, first cancel its pending
workflows and wait for them to stop, then run
`python3 scripts/candidate_reservation.py abandon FULL_CANDIDATE_SHA`. Both
commands first atomically fence the reservation as `closing`, denying new
admissions. A delivery whose claim won the lease first may finish, with its live
analysis gate still enforced; retirement cannot complete while any claim
remains. The command also refuses while any Mac Release or iOS build/delivery
run is active, including approval waits. A failure leaves the fence in place.
Drain or cancel the admitted attempts, reconcile their completed claims, then
repeat the same release/abandon command. A closing candidate cannot be reopened
or replaced. Release is an explicit assertion that no further platform delivery
is intended; absence of a running workflow is not proof of publication or
Apple's acceptance. These commands close X's delivery gates and leave an
auditable state transition. They do not delete artifacts, tags or releases.
Never release while publication repair or iOS delivery is still intended. A
released or abandoned SHA cannot immediately be reallocated; use a new reviewed
commit. A moved reservation or candidate ref needs maintainer recovery, not a
force push to make a gate pass.

### iOS TestFlight from the held candidate

For iOS without a Mac candidate, run
`python3 scripts/release-candidate.py --prepare-only` from the clean, pushed PR
checkout. It checks that guarded tooling matches main, waits for integration
checks, reserves X, dispatches direct scans and waits for them, without making a
Mac tag or dispatching Release. If Mac already holds X, this resumes the same
reservation. A different platform SHA must wait until X is finished or
abandoned.

Dispatch **iOS TestFlight Build** on `release-candidate` with `expected_sha=X`
and the intended iOS version/build. The credential-free archive checkout and
manifest must identify X. Dispatch **iOS TestFlight** on main with that SHA,
version/build and the successful archive run ID. The trusted-main gate and the
rechecks before signing and Apple upload all require the same held candidate-ref
evidence. Archive ID, producing attempt, digest, signing policy and attestation
checks remain mandatory; the delivery job never compiles or executes the app.
The `ios-testflight` approval and main-only credential boundary are unchanged.

Land this tooling on main after 2026.10.8 ships, then synchronize the guarded
workflow/scripts into the next candidate before preparing it. Existing archives
or tags with only PR-merge analysis do not acquire eligibility from this change.
Their recovery requires a separate maintainer decision; do not rebuild accepted
bytes or invent evidence to bypass the old gate.

### Diagnostic candidates

Use `make rc DIAGNOSTIC=1` for an explicitly installed diagnostic candidate, or
add `DRY_RUN=1` to preview it. Tags use `YYYY.M.MICRO-rc.N-diag`, sharing the
ordinary candidate sequence. The same **Release** workflow verifies the exact
commit, builds Release, signs, notarizes and attests the artifacts. Numeric app
versions and signing entitlements stay unchanged; the signed bundle carries
`GlimmerDiagnosticBuild=YES`. Ordinary candidates carry `NO`.

Diagnostics publish as clearly marked GitHub prereleases for manual download.
They never enter the Sparkle appcast, including its RC channel, and cannot be
promoted to stable or Homebrew. The ordinary `rc` PR label does not request one.
A new build number and commit are required when switching candidate kind;
off-feed diagnostic builds still consume their build number.

Additional local telemetry defaults on in diagnostic builds; an explicit saved
off preference wins for comparison runs. Download the matching symbols ZIP and
`symbols.json` with the app: their app/engine UUIDs and source identity are
recorded in the persisted release receipt and artifact manifests. The symbols
ZIP is attested with the DMG and app ZIP. These are normal notarized builds,
without debugger-access entitlements. Profiling attachment may still be denied;
record that limitation rather than re-signing the installed candidate.

After diagnosis, cut and test a new ordinary candidate before promotion. The
diagnostic tooling must land on main before the candidate cutter will use it,
just like other release tooling changes.

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
published digests. Main must have the same shipped inputs as the candidate: the
app, login item and helper sources, the Xcode project and package pins, the
Makefile and the build, signing and packaging scripts (`SHIPPED` in
`scripts/promote-release.py`). Release tooling, docs and tests may move on. The
workflow marks the existing release stable and latest, removes the item's `rc`
channel, and updates Homebrew. It never rebuilds, re-signs or repackages. The
original candidate tag and asset URLs stay in place; the stable release title
uses the final marketing version. The appcast keeps the exact ZIP URL, signature
and size that the candidate used.

Release notes come from the version's `CHANGELOG.md` section: a flat list of
changes players will notice. The publisher includes these notes in GitHub and
Sparkle. Candidate and stable items share one appcast; normal Sparkle clients
ignore items in the `rc` channel, while enrolled clients can receive both.

Signing, notarization and publication run only in the hosted Release workflow.
Use `make rc DRY_RUN=1 SOURCE_ONLY=1` for pre-push source checks and `make rc`
only when a reviewed candidate is ready to dispatch.

### Website and update feed

GitHub Pages serves `https://se7enbrc.github.io/glimmer/`, the address
`SUFeedURL` reads, from the **Pages** workflow, which uploads `main`'s files as
they are (no Jekyll) plus `appcast.xml` from the `appcast` branch. `index.html`
and `website/` are the static landing page. The `appcast` branch holds only the
machine-written feed: releases and promotions commit there, so they never move
`main` or put open pull requests behind it. Preview the site with
`python3 -m http.server 8765` from the repository root.

The workflow deploys on every push to `main`, after every **Release** run and on
demand. A push to `appcast` cannot start it, because push events run the
workflows on the pushed branch and that branch has none. After a manual change
to the feed, run `gh workflow run pages.yml -R Se7enbrc/glimmer`; the release
workflow dispatches it.

One-time setup, in this order. Promote any pending candidate first with the
tooling already on `main`, then:

1. Create the `appcast` branch as a single signed commit holding `main`'s
   current feed blob, and nothing else. The ruleset that covers every branch
   except `main` and `dependabot/**` already limits it to the maintainer and the
   release app.

   ```bash
   git fetch origin main
   TREE="$(printf '100644 blob %s\tappcast.xml\n' "$(git rev-parse origin/main:appcast.xml)" | git mktree)"
   COMMIT="$(git commit-tree -S "$TREE" -m "appcast: start the update feed branch")"
   git push git@github.com:Se7enbrc/glimmer.git "$COMMIT:refs/heads/appcast"
   git fetch origin appcast
   git ls-tree -r --name-only origin/appcast   # only appcast.xml
   curl -fsSL https://se7enbrc.github.io/glimmer/appcast.xml | cmp - <(git show origin/appcast:appcast.xml)
   ```

2. Switch the Pages source to GitHub Actions:
   `gh api -X PUT repos/Se7enbrc/glimmer/pages -f build_type=workflow`. The last
   legacy deployment stays live until the workflow's first deploy.
3. Merge the pull request that adds the workflow. Its push to `main` deploys the
   site; confirm the run passed and the live feed still matches the branch.

Until step 2 the legacy build keeps serving `main`'s feed, and between steps 2
and 3 its last deployment stays live, so publish nothing in between. Merging
before step 2 would let the legacy build publish a site without `appcast.xml`.

The site has no custom domain. A custom domain makes Pages redirect the
github.io address, which every released app reads, so add one only after a
release that reads the feed from the custom domain directly has reached users.
After any Pages change, confirm that
`https://se7enbrc.github.io/glimmer/appcast.xml` answers 200 over HTTPS with no
redirect.

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

Before any candidate compilation, three independent jobs check out the exact
candidate SHA: all hk checks plus `make check`, `make test`, and
`make test-asan`. Each checks the existing hosted Verify and CodeQL
prerequisites, uses its own build directory, and has no release environment or
secrets. Their records must match the SHA, run ID and check name before the
unsigned build job can start. Successful records from an earlier attempt of the
same run remain valid when only failed jobs are rerun; future attempts are
rejected. Compiler warnings fail both Xcode and the standalone helper build. An
existing candidate release, including a draft, blocks rebuilding that tag.

### D. Fresh signing runner and artifact identity

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

Signing calls `notarize-bundle`, creates the DMG, then calls `notarize-dmg`;
none of these targets compile or embed the helper. Tooling, entitlements and
packaging scripts come from main, never from the transferred bundle. The
candidate's version config and changelog are read as data from its exact Git
commit. Apple credentials are decoded under `RUNNER_TEMP` with private
permissions and removed with the temporary keychain after DMG stapling and
before ZIP packaging, final hashes or attestation. Cleanup failure blocks that
handoff. An unconditional cleanup step also runs when the job finishes. The
package phase preserves the finished DMG; it must never recreate it.

The DMG uses the same Developer ID Application identity and temporary keychain
as the app, a secure timestamp, and identifier `io.ugfugl.Glimmer.dmg`. It has
no app entitlements. After the app is notarized and stapled, the compressed DMG
is signed, submitted with `notarytool --wait`, required to return `Accepted`,
and stapled. Apple recommends signing nested containers and notarizing the
outermost distribution in
[Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
We retain the app's ZIP submission for the separate Sparkle distribution and
submit the signed DMG as its own distribution. Apple's
[custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
explains stapling the app before creating the final ZIP; ZIPs cannot themselves
be stapled. The DMG's ticket is stapled directly to the image.

This adds one serial DMG upload and notary wait per candidate, plus signing and
stapling. Apple's queue time is variable; there is no measured Glimmer duration
yet. The run summary records the DMG packaging/signing/notarization/stapling
duration. The signing job retains its 45-minute timeout; measure both
submissions in hosted acceptance before deciding whether that budget needs to
change.

The protected runner never launches the transferred app or helper. Their
Gatekeeper, signature, notarization and launch probes, plus verification of the
Sparkle update signature, run on another fresh runner without the release
environment. That validate stage also checks the DMG with
`codesign --verify --strict`,
`spctl -a -t open --context context:primary-signature`, and
`xcrun stapler validate`. Any failure blocks publication. Credential-free
verification jobs may restore unsigned compiler state. Signing, validation and
publication jobs never restore build caches. The approved workflow, main's
tooling, reviewed source and dependencies remain trusted: a digest binds the
handoff, it does not make a malicious build trustworthy. This is not a
SLSA-level claim.

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
with them, then sync main into the release branch. DMG signing lands after
2026.10.8; do not retrofit or replace its accepted assets. The candidate cutter
refuses differences from main in either release workflow or the release scripts
executed by candidate jobs and their imported helpers. This check runs before
moving the candidate branch or creating a tag. Review the candidate SHA and
pinned tooling SHA before approving. Keep the `release` environment's reviewer,
allowed branches (`main` and `release-candidate`) and disabled administrator
bypass. Do not change `rc-cut`: its main-only environment and separate App
retain their existing roles.

For the first hosted candidate with DMG signing, record both notary submissions
as accepted, credential cleanup, and all three DMG validation results. Download
the published DMG and repeat those read-only checks; `codesign -dv --verbose=2`
must show the app's Developer ID authority/team and a timestamp. Verify the
attestation against that final stapled file. On a separate Mac, test a fresh
quarantined download offline, including opening the image and launching its
installed app. Confirm the ZIP's app and helper still pass their existing
checks. After acceptance, promotion and a publication retry must preserve both
asset digests. The unsigned-payload reproducibility comparison below is
unchanged; DMG signatures and tickets remain outside that comparison.

### E. Publication and Homebrew recovery

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

### Local source checks

Use `make rc DRY_RUN=1` to inspect candidate source checks. `make rc` dispatches
the hosted workflow when explicitly requested. Signing, notarization, update
keys, credentials, publication and Homebrew updates run only in CI. Local
installation and distribution targets have been removed.

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

### F. Publication GitHub App setup and PAT retirement

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

### G. Run summaries and hosted acceptance

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

For the candidate-ref policy, first exercise only credential-free gates. Hold X,
finish direct Verify and CodeQL, then advance the feature PR to Y and regenerate
its merge. Both Mac and iOS selectors must still accept X, recording the same
candidate ref and direct-X analysis identities. Do not approve signing or upload
anything merely to test selection. Confirm GitHub's ref-scoped open-alert query
blocks a candidate finding even after a feature fix, accepts a current global
dismissal, and blocks reopening. Exercise processing delays, missing analysis, a
newer pending/failed candidate run, and a failed-job rerun retaining the other
two successful language analyses. Specifically rerun lower-numbered A after
successful B: pending, failed or cancelled A must close both gates, and an
upload from A must never join B's successful job, even with overlapping
timestamps. Confirm the jobs API exposes the successful upload receipt and
retained producing attempts. Check API permissions and request volume.

Prove that a second cut cannot move the branch during either platform's approval
wait, both platforms can use X concurrently, and release/abandon refuses active
runs. Pause retirement at its delivery snapshot and race admission against the
closing lease: only an already admitted attempt may drain, and retirement must
wait for its completion. Repeat with concurrent Mac and iOS claims, delayed
completion events, cancellation and partial job reruns. After explicit
completion, Y can be allocated atomically; stale writers and old gates must
fail. Promotion must reject unreserved X, a moved/deleted ref, absent scans or
an open candidate alert even with valid assets, attestations, unchanged shipped
inputs and green main. Confirm prerequisite reads still use the read token after
publication and tag credentials are selected. Confirm the branch protections
cover the new reservation ref and that an interrupted cut resumes without a
second Release. Local fixtures do not establish these hosted behaviors.

Do not enable Actions debug logging; release context validation rejects it.
Never upload temporary credential directories, keychains or raw signing inputs.
Embedded provisioning profiles in the signed app are intentional. Cleanup traps
cannot run after a forced kill or runner loss; GitHub decommissions the hosted
VM as the final boundary. See
[GitHub's hosted-runner lifecycle](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners).

## 3. Signing credentials

Supply approved signing credentials and app/helper provisioning profiles through
the protected GitHub release environment. The workflow uses temporary runner
files and keychains, then removes them. It never reads a developer's local
keychain or `~/.config/developer-id`.

The CI-only Make entry point is `scripts/ci-signing.mk`. It requires hosted CI
and temporary credential paths. Developers cannot invoke signing or publication
through the root Makefile. Certificate exports, key generation and cloud secret
changes require the maintainer's explicit authorization and are outside local
build tooling.

Sparkle tools downloads must match `scripts/sparkle-tools.sh`'s pinned digest.
Keep its version, the framework pin and `ThirdPartyNotices.txt` aligned.

## 4. Reproducible payload

The unsigned Release bundle is a pure function of the commit and the toolchain.
`make CONFIG=Release app embed-helper`, the build the hosted Release workflow
goes on to sign, produces a `Glimmer.app` whose every byte, mode and symlink
matches another clean build of the same commit in another directory. Three
things used to differ between builds, and the build itself fixes them.
`BuildInfo.date` stamps the commit time instead of the wall clock
(`SOURCE_DATE_EPOCH` overrides it; a dirty tree still stamps the clock so local
builds stay distinguishable). Release binaries are stripped of their debug map
(`STRIP_STYLE=debugging`): the SO, OSO and AST stabs that named the building
machine's checkout and DerivedData paths. The symbol table stays, so crash logs
still name functions without a dSYM. The App Intents metadata processor wrote
its JSON in Swift's per-process hash order, so `make app` runs xcodebuild with
`SWIFT_DETERMINISTIC_HASHING=1`. The linker already zeroes stab timestamps,
derives `LC_UUID` from the content and ad-hoc signs by hashing it, so nothing
else varies.

Prove it with `scripts/compare-builds.sh [WORKDIR]`: it clones HEAD twice,
builds each clone from clean and compares the two bundles, every entry's mode
and link target plus a SHA-256 of every file.
`scripts/compare-builds.sh A.app B.app` compares two existing bundles the same
way. One file is compared through `assetutil --info` rather than by bytes:
actool stamps `Assets.car` with the build time and names the renditions it
rasterizes from `AppIcon.icon` after temporary files, and those renditions'
digests change with their names. No environment variable or flag pins them.
Everything else in the catalog, including every other rendition's digest, must
match. Byte for byte, the two catalogs of the last proof differed only in the
header stamp, those seven names and a few index bytes beside them; every
rendition's image data matched. The **Reproducible build** workflow runs the
two-clone comparison on the hosted runner on dispatch and monthly; it is not
part of Verify because it costs two clean Release builds. The comparison holds
for one toolchain: `Info.plist` records `DTXcodeBuild`, `DTSDKBuild` and
`BuildMachineOSBuild`, so a different Xcode or macOS build is a different
payload, and a local rebuild must use the hosted runner's Xcode. Last proved
locally on 2026-10-10 with Xcode 27.0 (27A266a) on macOS 27.0.1: identical, 69
files, with `Assets.car` as above.

What is reproducible is the unsigned payload: the app, login helper and network
helper binaries, the Info.plists, the resources and the Sparkle framework as its
pinned package ships it. What is not, by design: the Developer ID signatures and
their timestamps, the embedded provisioning profiles, the stapled notarization
ticket and `_CodeSignature` seals, the dSYMs (not shipped, and they record the
build directory), and the DMG and ZIP containers (file times, `.DS_Store`,
hdiutil layout).

A shipped bundle binds to the payload through normalization.
`scripts/compare-builds.sh --normalize Shipped.app Local.app` copies both,
removes the seals, profiles and ticket, strips every Mach-O's signature with
`codesign --remove-signature` and runs `strip -S` so `__LINKEDIT` is laid out
without the room the removed signature took, then compares. On a local build
re-signed ad-hoc with the hardened runtime and the app's entitlements, the
normalized copies were identical. This has not yet been run against a hosted,
Developer ID-signed release, so treat that binding as untested until it has.
