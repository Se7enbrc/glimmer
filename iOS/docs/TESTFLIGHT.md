# Test Glimmer through TestFlight

Build an internal iPhone/iPad beta or production candidate from an exact
reviewed commit using CI. The Mac release workflow and Sparkle feeds are
separate.

## First-time setup

Complete these steps once with the maintainer. Never paste private keys,
certificates, passwords or provisioning profiles into an issue or chat.

1. Create an iOS app record in App Store Connect for `io.ugfugl.Glimmer.iOS`.
   Use the existing registered identifier; do not create a replacement
   identifier. App Store display name: **Glimmer: Game Streaming**. Suggested
   primary language: **English (U.S.)**; suggested SKU: **glimmer-ios**.
2. Prepare Apple Distribution signing and an App Store distribution profile for
   that identifier. Mac Developer ID credentials and development profiles do not
   serve this purpose. Reuse suitable distribution credentials if present; do
   not revoke or replace existing certificates as a troubleshooting step.
3. Authorize App Store Connect API access for uploading this app. An existing
   approved API key may be reused if its permissions cover this app; use its
   secure secret-management reference rather than exporting it into chat. Create
   a new key only if needed. Confirm agreements and access are current.
4. Configure the protected GitHub `ios-testflight` environment with a maintainer
   reviewer and deployments restricted to `main`. Keep its signing and upload
   values in environment secrets, using the existing approved secret-management
   process. Never expose them as repository variables.
5. Create an **Internal** TestFlight group. Initially add only the maintainer
   and enable automatic internal distribution if desired. Review the app's
   encryption answers before making the first processed build available.

Internal testers must be eligible App Store Connect users. Internal builds are
available for 90 days. See Apple's
[internal testing guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).

### Protected environment values

Sync only these iOS credentials into `ios-testflight`, using a dedicated secret
configuration rather than copying the whole Mac release environment. Keep values
out of command output and build artifacts.

| Secret                          | Contents                                                     |
| ------------------------------- | ------------------------------------------------------------ |
| `IOS_TEAM_ID`                   | Approved Apple development team identifier                   |
| `IOS_DISTRIBUTION_P12_BASE64`   | Base64 Apple Distribution certificate and private key export |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password protecting that export                              |
| `IOS_APP_STORE_PROFILE_BASE64`  | Base64 App Store distribution provisioning profile           |
| `ASC_KEY_BASE64`                | Base64 App Store Connect API private key (`.p8`)             |
| `ASC_KEY_ID`                    | Identifier of that API key                                   |
| `ASC_ISSUER_ID`                 | Issuer identifier for the API key                            |

Environment approval must remain enabled for every upload. Provisioning and
credential creation are maintainer actions; the workflow must not register a
device or automatically repair account signing state.

## Prepare each build

1. Land reviewed release tooling on `main` before using it. The workflow uses
   trusted tooling from `main` for the protected phase; app source can come from
   the reviewed feature commit. Do not merge the unfinished app stack merely to
   bootstrap release tooling.
2. Require successful Verify and all three CodeQL analyses for the exact source
   commit, with no unresolved CodeQL alerts. Use the complete 40-character SHA.
3. Use the shared CalVer from `Glimmer/Version.xcconfig` and choose an unused,
   increasing iOS build number. The archive rejects a different marketing
   version. Check App Store Connect before dispatching. A retry after Apple
   accepts an upload must not overwrite or silently reuse that build number.
4. Dispatch **iOS TestFlight Build** on the candidate branch whose HEAD is that
   exact SHA, with the version, build number and `flavour` (`beta` or
   `production`). The builder rejects `main` and the repository's default
   branch. It checks out only its own workflow commit, so candidate code cannot
   write caches in the default branch's trust scope.
5. After that build succeeds, dispatch **iOS TestFlight** from `main`. Provide
   the same source SHA, version, build number and flavour, plus the successful
   build's workflow run ID as `archive_run_id`. The trusted gate selects that
   run's exact producing attempt and immutable archive artifact. Review its
   source identity and verification evidence before approving the protected job.
6. After Apple processes the upload, review its status and compliance questions,
   then confirm availability in **Internal** (automatic distribution is enabled
   for the initial maintainer group). Enter a short **What to Test** description
   covering the actual changes and known limitations.

Choose `beta` for local diagnostic recording, on by default unless the player
has turned it off. Choose `production` to test the diagnostics-free App Store
candidate through TestFlight. Installation through TestFlight never changes the
compiled flavour. Production ignores saved diagnostic preferences and leaves old
files untouched, without exposing them.

Only a production archive is eligible as App Store submission source. This
workflow still exports **internal-only** TestFlight IPAs. Neither flavour's
internal-only IPA can be submitted to the App Store. Public delivery needs a
separate reviewed export path from the accepted production archive.

## What CI must preserve

The candidate-branch workflow builds a Release archive without signing
credentials or local development compilation flags. `beta` sets
`GLIMMER_DIAGNOSTICS` for both the app and shared engine; `production` leaves it
unset. Unspecified local builds are production. Unknown flavour inputs fail. The
separate main workflow does not check out or execute candidate code. Its fresh
protected job validates the successful build run, workflow, source, repository,
producing attempt, GitHub artifact digest, manifest, compiled flavour and bundle
identity before signing/exporting and uploading the existing bytes.

Retain the archive, matching dSYMs, source and tooling SHAs, build/version,
verification evidence, artifact digests, compiled flavour and upload result. The
sealed manifest and attested receipt bind `IOS_FLAVOUR`; bundle metadata and
binary/resource inspection must agree at archive, import and export. A
successful upload means Apple received the build; processing and tester
availability are separate states. A failed upload or validation must not be
recorded as release success.

Local unsigned archives establish packaging and symbol matching. They do not
prove Apple Distribution signing, App Store validation or successful processing.
The first authorized CI run must establish those remaining boundaries.

## Verify both compiled flavours

Run these unsigned Simulator checks at low priority. No PC or physical device is
used. Repeat with `beta` in place of `production`.

```sh
nice -n 15 taskpolicy -c utility make ios-test IOS_FLAVOUR=production
nice -n 15 taskpolicy -c utility make ios-app IOS_FLAVOUR=production CONFIG=Release BUILD_FLAGS='ARCHS=arm64'
python3 scripts/check-ios-diagnostics.py \
  iOS/build/production/DerivedData/Build/Products/Release-iphonesimulator/Glimmer.app \
  --flavour production
```

The inspection scans defined symbols, executable contents, debug dylibs and
resources. Production rejects recording, trace, probe and control markers; beta
must contain the recording components. See the
[diagnostics audit](../../docs/IOS_DIAGNOSTICS.md) for operational measurements
that remain and the physical-device acceptance checklist.

## Privacy and encryption review

The app's privacy manifest describes required-reason API use in the iOS app and
its statically linked shared engine. Audit changes to preferences, timestamps,
timing, file storage, diagnostics and dependencies before uploading. The absence
of tracking does not remove the required-reason API declaration requirement.

The audited declarations are:

| Category         | Reason             | Use in the shipped app                                                |
| ---------------- | ------------------ | --------------------------------------------------------------------- |
| User defaults    | `CA92.1`           | Private preferences, saved PCs and audio seeds                        |
| System boot time | `35F9.1`, `8FFB.1` | Elapsed input/session timing and receive-event timestamps             |
| File timestamps  | `C617.1`           | Sandbox cache eviction, identity/pin files; beta diagnostic retention |

The app-level resource covers the same-developer, statically linked engine.
There are no external Swift package dependencies. This does not establish
manifest packaging for a future independently distributed SDK. Beta diagnostics
are local files and loopback metrics; production has no diagnostic recording or
listener; no analytics or developer upload endpoint is present. Confirm actual
support/data-handling practices when completing account-side privacy answers.

Encryption answers must match the shipped pairing and transport implementation.
Do not set `ITSAppUsesNonExemptEncryption` to false merely to suppress an App
Store Connect question. Keep the implementation inventory and the maintainer's
confirmed classification with release evidence. See Apple's
[export-compliance guide](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

Current source uses Apple Security for RSA identities/signatures, CommonCrypto
for pairing AES-ECB and audio AES-CBC, CryptoKit for SHA-256 and AES-GCM
control, RTSP and optional video encryption, and Network/Security for pinned
TLS. Glimmer implements Sunshine framing, certificate encoding and nonce
assembly; the audit found no bundled custom cipher implementation. This supports
reviewing Apple's operating-system-only category, which its
[documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)
lists as requiring no App Store Connect encryption documentation. The maintainer
must confirm that classification and intended distribution before answering.
Encryption exists; do not answer that the app has none.

Continue with [Simulator and hardware verification](../CONTRIBUTING.md) before
accepting a beta for wider testing.
