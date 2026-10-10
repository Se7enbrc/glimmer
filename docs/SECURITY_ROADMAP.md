# Security roadmap

Glimmer's long-term target is the OpenSSF Best Practices **Gold** badge. The
Passing badge was achieved on 2026-10-09. This roadmap records the evidence and
engineering work still needed for higher levels. Badge gaps do not establish
that the app has a known vulnerability. There are no committed delivery dates.

Gold includes the
[passing criteria](https://www.bestpractices.dev/en/criteria/0) and
[silver criteria](https://www.bestpractices.dev/en/criteria/1), as well as the
[gold criteria](https://www.bestpractices.dev/en/criteria/2). Submit answers
against the current criteria, with public evidence for the release reviewed.

## Passing checkpoint

Passing does not require DCO/CLA contributor agreements or succession
arrangements. Use the repository evidence below, then have the maintainer
confirm human security knowledge, report-response history, applicable
vulnerability history and credential-leak history. Assess each cryptographic
criterion against the documented Sunshine protocol. Record the required Apple
toolchain honestly for `build_floss_tools`.

Distinguish mandatory answers from recommendations and suggestions; explain
exceptions where the form allows them. Do not mark an unknown mandatory answer
as met. Coverage percentages and the additional people and governance work below
concern the higher levels. A recorded sanitizer run strengthens the Passing
evidence without implying that Gold has been achieved.

### Cryptography assessment

The maintainer recorded both mandatory cryptography answers as Met on 2026-10-09
in the [Passing questionnaire](https://www.bestpractices.dev/en/projects/15346).
The assessment covers Glimmer's implementation and use of the public protocol.
Sunshine's server implementation is maintained separately; protocol constraints
that affect the client remain part of this assessment.

- **`crypto_published`.** The review covered published TLS, AES, RSA and
  SHA-256, along with the client's pairing, encrypted RTSP, control and media
  handling. It examined key sizes, certificate pinning, nonce domains and input
  validation. Public upstream evidence includes
  [Sunshine's pairing-order advisory](https://github.com/LizardByte/Sunshine/security/advisories/GHSA-3hrw-xv8h-9499)
  and
  [Moonlight's PIN-disclosure advisory](https://github.com/moonlight-stream/moonlight-ios/security/advisories/GHSA-g298-gp8q-h6j3).
  This is a scoped maintainer assessment, not a claim of an independent audit.
- **`crypto_random`.** Keys, random challenges, request nonces and session seeds
  use system CSPRNGs. The protocol constructs GCM nonces from per-session
  counters and direction/channel identifiers.
  [NIST SP 800-38D, section 8.2.1](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf#page=28)
  permits deterministic GCM IVs when uniqueness under each key is maintained.
  The maintainer's interpretation applies the CSPRNG requirement to required
  entropy and accepts these protocol-defined deterministic constructions. Audio
  IVs follow the session-seed/sequence construction; video IVs come from
  Sunshine. The form records this interpretation explicitly, without claiming an
  OpenSSF ruling on the wording.

The protocol limitations documented in [SECURITY](SECURITY.md) still apply. The
recommendations on known weaknesses and forward secrecy remain Unmet with
interoperability explanations.

[CodeQL run 37993312754](https://github.com/Se7enbrc/glimmer/actions/runs/37993312754)
passed Swift, Python and Actions analysis for commit
`1f2c3347d6b09a627b1c3f9fa1bdbaa288936db9` on 2026-10-09. The extraction gate
confirmed all 280 tracked production Swift files. The release gate verified the
corresponding analysis records and no open code-scanning alerts on the analyzed
ref. Later release commits must pass these checks again.

## Evidence already in the repository

| Area                                              | Evidence                                                                                                                                                  | What still needs verification                                                                                                                                        |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public source, licensing and contribution process | [LICENSE](../LICENSE), [CREDITS](../CREDITS.md), [CONTRIBUTING](CONTRIBUTING.md), Git history                                                             | Source-file notices and contributor rights need a separate audit.                                                                                                    |
| Build, tests and warnings                         | [Makefile](../Makefile), [Verify workflow](../.github/workflows/verify.yml), `GlimmerTests/`, `scripts/tests/`                                            | Retain the tested SHA and successful run. Passing tests do not establish coverage percentages.                                                                       |
| Static analysis and dependencies                  | [CodeQL workflow](../.github/workflows/codeql.yml), [Renovate](../renovate.json), `.pre-commit-config.yaml`, `Package.resolved` under the Xcode workspace | Confirm successful extraction and analysis for each configured language, triage findings, and include copied code and downloaded build tools in dependency tracking. |
| Security boundaries and release controls          | [SECURITY](SECURITY.md), [ARCHITECTURE](ARCHITECTURE.md), [RELEASE](RELEASE.md), `scripts/sign-bundle.sh`, `scripts/ci-release.sh`                        | These support an assurance case; they do not establish dated human security review, reproducibility or historical response performance.                              |

These paths support `repo_public`, `license_location`, `contribution`, `build`,
`test`, `warnings_strict`, `documentation_architecture`,
`documentation_security`, `dependency_monitoring` and
`static_analysis_common_vulnerabilities`. Each enrollment answer still needs its
own evidence and any applicable qualification.

## Work that can ship through normal releases

1. **Measure coverage before setting a gate.** Hosted Verify runs
   `make verify COVERAGE=1`, publishes per-component tables in the job summary
   and uploads the reports as the `coverage` artifact, with no threshold. The
   first recorded results are under "Coverage commands". Next, add behavioral
   tests for missing paths and give the login item and the installed helper an
   instrumented execution. Silver's `test_statement_coverage80` and Gold's
   `test_statement_coverage90` / `test_branch_coverage80` require measurements,
   subject to available FLOSS tools. Do not exclude difficult components just to
   raise the aggregate.
2. **Run sanitizers on parser tests before major releases.**
   `GlimmerTests/FuzzTests.swift` and `FuzzTests+Stream.swift` already exercise
   mutated and random protocol input. `make verify` now runs both suites under
   AddressSanitizer through `make test-asan`, with findings blocking the gate.
   The first local run passed all 17 tests on 2026-10-09. Keep assertions
   enabled and retain hosted results for each release. This addresses
   `dynamic_analysis` and strengthens `dynamic_analysis_unsafe` evidence around
   unsafe buffers and `Glimmer/Stream/CHelpers.h`.
3. **Prove build repeatability.** `scripts/generate-build-info.sh` embeds the
   current time on a fresh checkout. Reusing a stamp locally does not make two
   clean builds identical. Make release metadata deterministic, pin the exact
   toolchain and dependency inputs, then compare two independent clean builds.
   Record differences in paths, UUIDs and archive metadata. Define the
   comparison boundary for signing and notarization, and how shipped artifacts
   bind to the reproducible payload. An unsigned comparison alone must not be
   presented as proof that the whole distributed package is reproducible.
   Criteria: `build_repeatable`, `build_reproducible`.
4. **Finish source and release evidence.** Audit `copyright_per_file` and
   `license_per_file` against actual ownership, including ported code. Root GPL
   licensing does not supply every source-file notice. Check `signed_releases`
   for source archives and every distributed artifact as well as the app and
   Sparkle update. Signed commits alone do not authenticate every release asset.
   Public verification steps are in
   [SECURITY](SECURITY.md#verifying-a-download), tested on 2026-10-10. The DMG
   container is unsigned (the app inside is signed, notarized and stapled), and
   only releases from 2026.10.6-rc.1 on carry build attestations.

### Coverage commands

`make test COVERAGE=1` and `make test-scripts COVERAGE=1` measure the same runs
the gate makes, into `build/coverage`; `scripts/coverage-report.py` writes each
component's summary. The Swift run records an `.xcresult` for xccov and the one
`Coverage.profdata` of that run for `llvm-cov export -summary-only` against
`Glimmer.debug.dylib` (the app) and the test bundle (helper sources). Generated
asset symbols under `DerivedSources` are excluded; nothing else is. Python uses
[coverage.py](https://coverage.readthedocs.io/en/latest/branch.html) 7.16.2 with
branch measurement and subprocess patching (`scripts/tests/coveragerc`). Verify
installs it from `scripts/coverage-requirements.txt` with `--require-hashes`; it
is not needed for normal builds or tests.

First recorded run, 2026-10-10, commit `5ace115`, Xcode 27.0 (Hosted Verify uses
26.6), local Apple silicon Mac:

| Component                                  | Lines (xccov)          | Lines (llvm-cov)       | Regions               | Branches     |
| ------------------------------------------ | ---------------------- | ---------------------- | --------------------- | ------------ |
| App, `Glimmer.debug.dylib`                 | 45.11% (25,080/55,599) | 44.92% (24,974/55,599) | 49.95% (9,537/19,095) | No counters  |
| Helper sources linked into the test bundle | 43.72% (174/398)       | 43.72% (174/398)       | 44.32% (78/176)       | No counters  |
| Login item                                 | 0.00% (0/36)           | Not executed           | Not executed          | Not executed |

| Python release tooling (`scripts/*.py`) | Statements         | Branches         |
| --------------------------------------- | ------------------ | ---------------- |
| All files, tests omitted                | 53.62% (652/1,216) | 49.39% (241/488) |

Across three local runs the app's xccov covered lines ranged from 25,080 to
25,083.

What these numbers do not cover:

- The login item is built with coverage but never runs under test.
- The installed helper daemon is compiled separately by `swiftc` and never runs
  under test. Its sources other than `helper/main.swift` are compiled into the
  test bundle, and only that copy is measured.
- Swift emitted no branch counters for either binary, so branch coverage is not
  measured; the upstream
  [branch-coverage issue](https://github.com/swiftlang/swift/issues/81730)
  remains open. A zero denominator is not full coverage. Line and region counts
  are not statement or branch counts.
- Shell scripts under `scripts/` run in the tests but no shell coverage tool is
  in use. Python run from a fixture copy outside `scripts/`, which is how
  `release-candidate.py` is tested, records nothing, so that file reads 0%.

### Smallest useful sanitizer run

```bash
scripts/generate-build-info.sh
xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer \
  -configuration Debug -xcconfig Glimmer/StreamLib.xcconfig \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath build \
  -destination 'platform=macOS' -enableAddressSanitizer YES \
  -only-testing:GlimmerTests/FuzzTests \
  -only-testing:GlimmerTests/StreamFuzzTests \
  -resultBundlePath build/asan-parsers.xcresult
```

This covers host-reachable parser and reassembly targets. It does not exercise
all playback, controller or concurrency lifecycles. Expand the release checks
with relevant ThreadSanitizer and real streaming checks after validating those
tools against the platform frameworks. The parser sanitizer run is recorded
above.

## Engineering evidence to sustain

Keep a dated human review of the threat model, trust boundaries, pairing,
transport parsers, helper authorization, updates and release tooling, with
findings and their disposition. Gold's `security_review` requires human review
within five years; it can be internal. Automated scanning cannot substitute for
that review. [SECURITY](SECURITY.md) is the starting point for silver's
`assurance_case`, not an attestation that all arguments have been independently
checked.

Use the existing contribution guide to make review acceptance explicit and
retain release evidence: reviewed SHA, reviewer, meaningful regressions,
analysis findings and checks. This supports `code_review_standards` and
`regression_tests_added50`. Confirm actual report acknowledgments, resolutions
and reporter credit privately before answering history-based criteria. Published
response targets alone do not establish past performance.

## Maintainer, contributor and upstream requirements

| Requirement                                                                                   | Remaining work or constraint                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bus_factor`, `contributors_unassociated`, `two_person_review`                                | Establish at least two capable maintainers and two unassociated significant contributors. Retain evidence that a human other than the author reviews at least 50% of proposed modifications before release. A reviewer bot or an additional account cannot establish these facts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `governance`, `roles_responsibilities`, `access_continuity`, `code_of_conduct`, `small_tasks` | Document real roles and succession arrangements in the existing contribution guide, adopt conduct expectations, and identify bounded contributor tasks. The maintainer must establish actual continuity of repository, domain and release access; this document grants none.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `require_2FA`, `secure_2FA`, `know_secure_design`, `know_common_errors`                       | Obtain truthful maintainer evidence for account protections and human expertise. SSH commit signing does not prove two-factor authentication.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `documentation_roadmap`                                                                       | The maintainer must confirm product direction and exclusions for at least the next year. This security work list alone does not establish that product commitment.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `build_floss_tools`, `build_standard_variables`, `installation_standard_variables`            | Xcode and Apple's SDKs are required; the all-FLOSS build recommendation needs an honest qualification. Review compiler flag propagation and installation destination conventions against the supported Mac build, rather than claiming unsupported behavior.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `crypto_used_network`, `crypto_tls12`, `crypto_weaknesses`                                    | `ControlTransport.swift` enforces TLS 1.2 minimum and certificate pinning. The [network paths matrix](SECURITY.md#network-paths) (2026-10-10) covers every path, discovery and Wake on LAN included. Stock Sunshine still uses pre-pairing HTTP, plaintext LAN video by default and unauthenticated audio CBC. Seek upstream or badge-criteria clarification. The current behavior does not establish Gold's secure-network requirement. Do not claim a LAN exemption or require a patched PC.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `hardened_site`                                                                               | Measured with `curl -L` on 2026-10-10, final hosts only. `github.com/Se7enbrc/glimmer` and the release download's first hop send CSP, HSTS (one year, preload), `nosniff`, `X-Frame-Options: deny` and `Referrer-Policy: no-referrer-when-downgrade`; the download then lands on `release-assets.githubusercontent.com`, which sends none of the five. `glimmer.ugfugl.io` (GitHub Pages) sends none of the five, and Pages lets no site set response headers. Pages' HTTPS enforcement is off (`https_enforced: false`): the site answers on plain HTTP, and the update feed `https://se7enbrc.github.io/glimmer/appcast.xml` redirects to `http://glimmer.ugfugl.io/appcast.xml`. Turning enforcement on is the maintainer's fix. `index.html` now sets a CSP and a referrer policy in `<meta>` tags. `frame-ancestors`, HSTS, `nosniff` and `X-Frame-Options` cannot be set from a meta tag; meeting those needs a header-setting edge in front of Pages. Check against the [official details](https://www.bestpractices.dev/en/criteria?details=true&rationale=true). |

Record remaining owner-only answers and justified exceptions before submitting
each level. A badge claim must follow the evidence, including any prerequisite
that remains unresolved by the work above.
