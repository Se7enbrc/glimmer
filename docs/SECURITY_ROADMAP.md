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
corresponding analysis records and no open CodeQL alerts on the analyzed ref.
Later release commits must pass these checks again.

## Evidence already in the repository

| Area                                              | Evidence                                                                                                                                                  | What still needs verification                                                                                                                                        |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public source, licensing and contribution process | [LICENSE](../LICENSE), [CREDITS](../CREDITS.md), [CONTRIBUTING](CONTRIBUTING.md), Git history                                                             | Done for source-file notices ([#122](https://github.com/Se7enbrc/glimmer/pull/122)). Contributor rights still need a separate audit.                                 |
| Build, tests and warnings                         | [Makefile](../Makefile), [Verify workflow](../.github/workflows/verify.yml), `GlimmerTests/`, `scripts/tests/`                                            | Retain the tested SHA and successful run. Coverage is measured per component; see below.                                                                             |
| Static analysis and dependencies                  | [CodeQL workflow](../.github/workflows/codeql.yml), [Renovate](../renovate.json), `.pre-commit-config.yaml`, `Package.resolved` under the Xcode workspace | Confirm successful extraction and analysis for each configured language, triage findings, and include copied code and downloaded build tools in dependency tracking. |
| Security boundaries and release controls          | [SECURITY](SECURITY.md), [ARCHITECTURE](ARCHITECTURE.md), [RELEASE](RELEASE.md), `scripts/sign-bundle.sh`, `scripts/ci-release.sh`                        | These support an assurance case; they do not establish dated human security review, reproducibility or historical response performance.                              |

These paths support `repo_public`, `license_location`, `contribution`, `build`,
`test`, `warnings_strict`, `documentation_architecture`,
`documentation_security`, `dependency_monitoring` and
`static_analysis_common_vulnerabilities`. Each enrollment answer still needs its
own evidence and any applicable qualification.

## Work that can ship through normal releases

1. **Measure coverage before setting a gate.** Hosted Verify's checks and tests
   jobs run `make check COVERAGE=1` and `make test COVERAGE=1`
   ([#124](https://github.com/Se7enbrc/glimmer/pull/124)), publish per-component
   tables in the job summary and upload the reports as the `coverage-python` and
   `coverage-swift` artifacts, with no threshold. The first recorded results are
   under "Coverage results". Next, reach 80% through test seams and UI tests for
   the missing paths, and give the login item and the installed helper an
   instrumented execution. Silver's `test_statement_coverage80` and Gold's
   `test_statement_coverage90` / `test_branch_coverage80` require measurements,
   subject to available FLOSS tools. Do not exclude difficult components just to
   raise the aggregate.
2. **Sanitizers and fuzzing on the parsers: done.**
   `GlimmerTests/FuzzTests.swift` and `FuzzTests+Stream.swift` exercise mutated
   and random protocol input. `make verify` runs both suites under
   AddressSanitizer through `make test-asan`, and hosted Verify's fuzz job runs
   it on every pull request and `main` commit, with findings blocking the
   required check. The first local run passed all 17 tests on 2026-10-09.
   Coverage-guided libFuzzer harnesses in `fuzz/` for RTSP and SDP, video,
   audio, audio FEC and Opus packets run under AddressSanitizer through
   `scripts/fuzz.sh`, 30 seconds per target in Verify's `libFuzzer` job
   ([#123](https://github.com/Se7enbrc/glimmer/pull/123)). This addresses
   `dynamic_analysis` and strengthens `dynamic_analysis_unsafe` evidence around
   unsafe buffers and `Glimmer/Stream/CHelpers.h`. Still to do: ThreadSanitizer,
   once validated against the platform frameworks, and real streaming checks of
   playback, controller and concurrency lifecycles.
3. **Build repeatability: proved for the unsigned payload.** Two clean clones of
   the same commit build byte-identical `Glimmer.app` bundles
   (`scripts/compare-builds.sh`; first run 2026-10-10 with Xcode 27.0 on macOS
   27.0.1, 69 files identical), except that `Assets.car` is compared through
   `assetutil` because actool stamps it and names Icon Composer renditions after
   temporary files. The build stamp now records the commit time, Release
   binaries drop the debug map that named build paths, App Intents metadata is
   written in a fixed order, and the linker's UUIDs and ad-hoc signatures derive
   from content. [RELEASE](RELEASE.md) section 4 defines the boundary:
   signatures, profiles, the notarization ticket, dSYMs and the DMG and ZIP
   containers stay outside it, and `--normalize` binds a shipped bundle to the
   payload. Still to do: run the **Reproducible build** workflow on the hosted
   Xcode 26.6 runner for a release commit, and normalize a published Developer
   ID-signed candidate against a local rebuild on that same Xcode. An unsigned
   comparison must not be presented as proof that the whole distributed package
   is reproducible. Criteria: `build_repeatable`, `build_reproducible`.
4. **Source and release evidence: done.** Every tracked source file carries SPDX
   license and copyright notices, with upstream copyright lines on the 55 ported
   files ([#122](https://github.com/Se7enbrc/glimmer/pull/122));
   `scripts/check-spdx.sh` in `make check` keeps new files covered. This covers
   `copyright_per_file` and `license_per_file`. Public verification steps are in
   [SECURITY](SECURITY.md#verifying-a-download)
   ([#121](https://github.com/Se7enbrc/glimmer/pull/121)), tested on 2026-10-10.
   For `signed_releases`, the app in each of the last five releases' Sparkle
   ZIPs, 2026.10.2 to 2026.10.6, passes `codesign --verify --deep --strict`,
   `spctl` (Notarized Developer ID) and `stapler validate`, and each appcast
   item carries an Ed25519 signature; checked 2026-10-10. 2026.10.6 is the first
   release with a build attestation (`gh attestation verify` exits 0) and
   carries its `.intoto.jsonl` bundle. The DMG container is unsigned (the app
   inside is signed, notarized and stapled), and GitHub's generated source
   archives are not separately signed.

### Coverage results

`make test COVERAGE=1` and `make test-scripts COVERAGE=1` write the reports to
`build/coverage` through `scripts/coverage-report.py`; hosted Verify publishes
them on every run. Coverage results are refreshed from hosted Verify after each
coverage change.

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

### Sanitizer runs

`make test-asan` runs the parser and stream fuzz suites under AddressSanitizer,
and `scripts/fuzz.sh` runs the libFuzzer harnesses (`FUZZ_SECONDS` per target,
Docker required). Neither exercises playback, controller or concurrency
lifecycles; ThreadSanitizer remains open.

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

| Requirement                                                                        | Remaining work or constraint                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bus_factor`, `contributors_unassociated`, `two_person_review`                     | Establish at least two capable maintainers and two unassociated significant contributors. Retain evidence that a human other than the author reviews at least 50% of proposed modifications before release. A reviewer bot or an additional account cannot establish these facts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `governance`, `roles_responsibilities`, `access_continuity`                        | Done. [CONTRIBUTING](CONTRIBUTING.md#roles-and-continuity) records the maintainer's role, how contributors take part, and a designated successor with emergency access to the credentials for the repository, releases and update feed ([#119](https://github.com/Se7enbrc/glimmer/pull/119)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `code_of_conduct`                                                                  | Done. [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md), with a reporting address ([#119](https://github.com/Se7enbrc/glimmer/pull/119)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `small_tasks`                                                                      | Identify bounded contributor tasks and label them in the issue tracker.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `require_2FA`, `secure_2FA`                                                        | Stated. [CONTRIBUTING](CONTRIBUTING.md#roles-and-continuity) records that the maintainer's GitHub account uses a passkey for two-factor authentication and that only the maintainer has write access.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `know_secure_design`, `know_common_errors`                                         | Obtain truthful maintainer evidence of human expertise.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `documentation_roadmap`                                                            | Done. [ROADMAP](ROADMAP.md) records product direction and exclusions ([#120](https://github.com/Se7enbrc/glimmer/pull/120)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `build_floss_tools`, `build_standard_variables`, `installation_standard_variables` | Xcode and Apple's SDKs are required; the all-FLOSS build recommendation needs an honest qualification. Review compiler flag propagation and installation destination conventions against the supported Mac build, rather than claiming unsupported behavior.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `crypto_used_network`, `crypto_tls12`, `crypto_weaknesses`                         | `ControlTransport.swift` enforces TLS 1.2 minimum and certificate pinning. The [network paths matrix](SECURITY.md#network-paths) (2026-10-10) covers every path, discovery and Wake on LAN included. Stock Sunshine still uses pre-pairing HTTP, plaintext LAN video by default and unauthenticated audio CBC. Seek upstream or badge-criteria clarification. The current behavior does not establish Gold's secure-network requirement. Do not claim a LAN exemption or require a patched PC.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `hardened_site`                                                                    | Measured with `curl` on 2026-10-10, final hosts only. `github.com/Se7enbrc/glimmer` and the release download's first hop send CSP, HSTS (one year, preload), `nosniff`, `X-Frame-Options: deny` and `Referrer-Policy: no-referrer-when-downgrade`; the download then lands on `release-assets.githubusercontent.com`, which sends none of the five. The site and update feed now live at `https://se7enbrc.github.io/glimmer/` (GitHub Pages, no custom domain). Pages enforces HTTPS: plain HTTP answers 301 to the HTTPS URL, and `https://se7enbrc.github.io/glimmer/appcast.xml` answers 200 with HSTS (`max-age=31556952`, no preload). Pages sends no CSP, `nosniff`, `X-Frame-Options` or `Referrer-Policy` header and lets no site set response headers; that limit is recorded here. `index.html` sets a CSP and a referrer policy in `<meta>` tags. `frame-ancestors`, `nosniff` and `X-Frame-Options` cannot be set from a meta tag; meeting those needs a header-setting edge in front of Pages. Check against the [official details](https://www.bestpractices.dev/en/criteria?details=true&rationale=true). |

Record remaining owner-only answers and justified exceptions before submitting
each level. A badge claim must follow the evidence, including any prerequisite
that remains unresolved by the work above.
