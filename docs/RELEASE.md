---
description: Prepare, test, and publish a release candidate.
icon: box-archive
---

# Release process

Build one verified candidate, test the published artifact, then promote those
exact files. For installing updates or joining the candidate channel, use
[Releases and updates](UPDATES.md).

Comprehensive render/UI and device/appearance journeys are a single resumable
acceptance pass for this feature release, not a restart for every RC. Dispatch
Verify in `acceptance` mode and resume its ledger; keep completed testcase
evidence and rerun failures or the cases affected by reviewed changes. Each
receipt names its actual tested source, including an explicit note for reviewed
uncommitted working-tree evidence. The release owner reviews affected scope;
historical passes are not claims of complete latest-SHA coverage. See
[acceptance and local reproduction](CONTRIBUTING.md#hosted-verification-and-local-reproduction).

## iPhone and iPad artifacts

Choose the compiled flavour before archiving: `beta` enables adaptive stream
quality by default; `production` leaves it off. Saved choices take precedence.
Neither flavour records custom diagnostics. Only a production archive may be
used as App Store submission source. A beta build cannot be promoted unchanged
to production.

Follow the [iOS TestFlight process](../iOS/docs/TESTFLIGHT.md). Keep flavour in
the sealed archive identity and attested receipt, and inspect the executable and
resources before delivery. Delivery may reach internal and external TestFlight
testers; public submission requires its own reviewed export from the tested
production archive. Land trusted workflow and script changes on `main` before
dispatching; land app and shared-engine exclusions on the reviewed feature
branch.

## 1. Prepare the candidate

Choose a numeric CalVer version and a build number above every build in the
shared appcast.

| Value                     | Rule                                                                               |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `MARKETING_VERSION`       | `YYYY.M.MICRO`, such as `2026.10.8`; no candidate suffix.                          |
| `CURRENT_PROJECT_VERSION` | Increasing integer; bump for every changed candidate.                              |
| Candidate tag             | Version plus `-rc.N`; never replace an existing tag.                               |
| Release notes             | The version's `CHANGELOG.md` section, in plain words about changes players notice. |

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

### When PR checks do not start

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

Every cutter wait reports its start, timeout and completion with UTC timestamps.
While blocked, it prints a heartbeat every 60 seconds, including during Git and
API calls. Progress goes to stderr and is flushed immediately; ordinary cutter
output is also unbuffered. Check messages link the source checks, workflow or
specific runs as soon as their IDs are available. Integration checks have a
90-minute budget, candidate scans 45 minutes, and delivery admission 20 minutes.
Release-run discovery has a one-minute wall-clock deadline, including API time.
Individual Git commands have a five-minute timeout, and API lookups one minute.

The local cutter does not wait for the main **Release candidate** workflow or
poll an occupied reservation. A green main workflow can mean its `ready` job
finished but its `cut` job was skipped; inspect both jobs. On October 27, the
[07:31 UTC run](https://github.com/Se7enbrc/glimmer/actions/runs/40467656334)
skipped cutting because PR #205 did not satisfy its label/base requirements. RC
19's hold was only
[abandoned at 09:51:34 UTC](https://github.com/Se7enbrc/glimmer/commit/4549b8d79423a7ebbec84087c3f24f4fcc7a0452),
and RC 20 was
[reserved at 09:52:41 UTC](https://github.com/Se7enbrc/glimmer/commit/815d73aa99c3c2e83a4a1741e5f8800d0efd0f0f),
before its scans dispatched at 09:53. GitHub records locate the gap before
reservation; a local terminal log is needed to attribute time to a local command
or retry. No delivery-admission run occurred between 07:00 and 10:00 UTC.

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

### Cut a candidate from a PR label

Add `rc` to an upstream PR to request the same cut after its exact head passes
checks.

The **Release candidate** workflow runs main's tooling without checking out PR
code. It retries when Verify/CodeQL finishes; each passing new head gets a new
candidate while the label remains. The release GitHub App creates the tag.

Its `rc-cut` environment has no required reviewer and contains
`GLIMMER_RC_APP_CLIENT_ID` and `GLIMMER_RC_APP_PRIVATE_KEY`, synced from
Doppler. Install the App only here, without a webhook, with
Contents/Workflows/Actions/PR write, Checks/Code scanning read, and the
`release-candidate` ruleset bypass. The protected release deployment still needs
approval.

## 2. Test, then promote the same files

Install the published candidate DMG after verifying it; a local rebuild does not
count.

1. [Verify provenance and Apple signing](VERIFY_DOWNLOAD.md), save your game,
   stop streaming, quit Glimmer and install the downloaded app.
2. Record candidate tag, source SHA, build number, macOS, audio devices and Game
   Mode state.
3. Test at Highest quality with [telemetry](PROFILING.md#opt-in-telemetry) and
   bookmarks.
4. Mark each check passed, failed or not tested. Stop the final session to write
   its scorecard.
5. If anything changes, use a new build number/tag, repeat checks and test a new
   candidate.

[Candidate enrollment](UPDATES.md#try-release-candidates) persists across stable
releases; promotion does not change the preference or the signed app.

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

| Check                                          | Expected result                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------------------------ |
| Familiar game scene                            | Correct negotiated codec; bookmark freezes/pops and distinguish picture from sound.  |
| Native fullscreen, switch away/back repeatedly | Moving to the screen edge while away does not replay camera movement on return.      |
| Mini Player, Escape tap/hold                   | Tap reaches the game; hold releases capture; neither opens the PC's Start menu.      |
| Mini Player with another app focused           | Controller still works; keyboard/mouse follow focus.                                 |
| Speakers → AirPods → speakers                  | Sound follows; check spatial anchoring and voice chat with a separate microphone.    |
| Edit/reopen custom resolution                  | Saved dimensions remain.                                                             |
| Stop from fullscreen and Mini Player           | Stream ends and its PC app quits; pointer and clicks work in Glimmer and other apps. |
| Start a fresh stream with changed quality      | New resolution/FPS/HDR apply and input captures correctly.                           |
| Confirmed URL quit and cancellation            | Quit closes the named PC app; cancelling the alert leaves it running.                |

There is no disconnect-and-resume acceptance path in this release. Keep the
[audio device checks](PROFILING.md#audio-device-checks) and any targeted
input/pacing comparisons with the candidate's evidence.

### Promote

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

1. Dispatch **Release** on `main`, operation `promote`, with current
   `expected_sha`, tested `rc_tag` and full `candidate_sha`.
2. Approve the reviewed deployment.
3. Confirm the stable release, appcast, Homebrew update and Pages deployment.

Promotion verifies downloaded DMG/ZIP attestations and digests. Main's shipped
inputs must match `SHIPPED` in `scripts/promote-release.py`: app/helpers,
project/package pins, Makefile and build/sign/package scripts. Docs, tests and
release tooling may advance.

It creates the final annotated tag at `candidate_sha`, marks the existing
release stable/latest, removes the appcast's `rc` channel and updates Homebrew.
The candidate tag, asset URLs, ZIP signature and size remain. It never rebuilds,
re-signs or repackages. A conflicting final tag stops promotion.

### Local source checks

Use `make rc DRY_RUN=1` to inspect candidate source checks. `make rc` dispatches
the hosted workflow when explicitly requested. Signing, notarization, update
keys, credentials, publication and Homebrew updates run only in CI. Local
installation and distribution targets have been removed.

## Website and update feed

Check that the public appcast returns HTTPS 200 without a redirect after every
deployment change.

| Location                                         | Purpose                                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `main`: `index.html`, `website/`                 | Static site, uploaded as files without Jekyll.                                              |
| `appcast` branch                                 | Machine-written `appcast.xml`; release metadata does not move main.                         |
| `https://se7enbrc.github.io/glimmer/appcast.xml` | Feed read by released apps.                                                                 |
| **Pages** workflow                               | Deploys main's site plus the appcast branch on main pushes, Release completion or dispatch. |

An appcast push alone cannot trigger Pages because that branch has no workflow.
After a manual feed edit, dispatch
`gh workflow run pages.yml -R Se7enbrc/glimmer`. The release workflow dispatches
it. Preview the site locally with `python3 -m http.server 8765`.

Keep the site without a custom domain until an app release using the new feed
address has reached users; Pages otherwise redirects the existing address. Do
not repoint a live feed while a candidate awaits promotion.

## Hosted release

Keep verification, compilation, signing and publication as separate phases.
Three credential-free jobs verify checks, tests and ASan before the unsigned
build. A fresh signing runner uses pinned trusted-main tooling and validates the
exact unsigned artifact. Publication validates the signed artifact and retries
only missing steps; it never replaces accepted bytes.

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

Compare clean unsigned Release payloads from the same commit, Xcode and macOS
build.

| Command                                                       | Comparison                                                                                      |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `scripts/compare-builds.sh [WORKDIR]`                         | Clone HEAD twice, build both, compare bytes, modes and symlinks.                                |
| `scripts/compare-builds.sh A.app B.app`                       | Compare existing bundles.                                                                       |
| `scripts/compare-builds.sh --normalize Shipped.app Local.app` | Compare copied bundles after removing signatures/profiles/ticket and normalizing Mach-O layout. |

`make CONFIG=Release app embed-helper` builds the unsigned payload. Commit-time
build stamps, stripped path-bearing debug maps and deterministic App Intents
JSON remove build variation. Linker UUIDs and ad hoc signatures are
content-derived. Dirty builds retain wall-clock stamps; `SOURCE_DATE_EPOCH` can
override the timestamp.

### Comparison boundary

State exactly what matched; do not call the full release package reproducible.

| Included                                                               | Excluded or normalized                                                                             |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| App/login/helper binaries, plists, resources, pinned Sparkle framework | Developer ID signatures/timestamps, profiles, ticket, seals, dSYMs, DMG/ZIP container metadata.    |
| `Assets.car` semantic comparison through `assetutil --info`            | Build stamp and temporary Icon Composer rendition names/digests; other catalog content must match. |

The recorded local proof was 2026-10-10, Xcode 27.0 (27A266a), macOS 27.0.1: 69
files matched with that catalog exception. The **Reproducible build** workflow
runs on dispatch/monthly, outside Verify. Hosted Xcode 26.6 proof and normalized
comparison against a published Developer ID candidate remain to be recorded. A
normalized local ad hoc comparison is not that evidence.
