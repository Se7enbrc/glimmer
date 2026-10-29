---
description: Evidence and remaining work toward higher OpenSSF badge levels.
icon: list-check
---

# Security roadmap

Check the evidence behind Glimmer's security work and the gaps still open.
Passing was achieved on 2026-10-09; Gold is the long-term target, without a
delivery date.

## Passing checkpoint

Read the [public assessment](https://www.bestpractices.dev/en/projects/15346) as
a scoped record, not an independent audit.

Higher levels include all preceding criteria:
[Passing](https://www.bestpractices.dev/en/criteria/0),
[Silver](https://www.bestpractices.dev/en/criteria/1) and
[Gold](https://www.bestpractices.dev/en/criteria/2). Badge gaps do not
themselves establish a known vulnerability.

### Cryptography assessment

Keep the Sunshine protocol limits attached to every cryptography claim.

| Criterion                                            | Recorded assessment, 2026-10-09                                                                                                |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `crypto_published`                                   | Met by maintainer review of published TLS/AES/RSA/SHA-256, pairing, pinning, nonce domains and parser checks.                  |
| `crypto_random`                                      | Met with system CSPRNGs for entropy and protocol-defined deterministic GCM counters, interpreted under NIST's uniqueness rule. |
| Known weaknesses and forward secrecy recommendations | Unmet with interoperability explanations.                                                                                      |

Evidence includes the
[Sunshine pairing advisory](https://github.com/LizardByte/Sunshine/security/advisories/GHSA-3hrw-xv8h-9499),
[Moonlight PIN advisory](https://github.com/moonlight-stream/moonlight-ios/security/advisories/GHSA-g298-gp8q-h6j3)
and
[NIST GCM guidance](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf#page=28).
The maintainer's interpretation is not an OpenSSF ruling. Pre-pairing HTTP,
four-digit PINs, default plaintext video and unauthenticated audio CBC remain
[documented limits](SECURITY.md#protocol-limits).

## Evidence already in the repository

Retain dated results for each release; a previous green run does not authorize a
new commit. Acceptance journeys retain their actual tested source and resume
only for pending or affected cases; they are not a mandatory repeat suite for
every push. Exact-source core and security gates remain separate.

### 2026.10.8 candidate checkpoint

[RC23](https://github.com/Se7enbrc/glimmer/releases/tag/2026.10.8-rc.23) and iOS
beta 13 use `3e59901396c3445c04e9fe73be3d3fafb1a30ce8`. Direct candidate
[Verify](https://github.com/Se7enbrc/glimmer/actions/runs/40937378057) and
[CodeQL](https://github.com/Se7enbrc/glimmer/actions/runs/40937384613) passed.
Mac delivery verified signed/notarized app and DMG artifacts, provenance and
update signatures. iOS delivery bound the reviewed archive and matching symbols
to the signed beta and successful upload receipt.

These are release-control results, not an independent security audit, new badge
assessment or full hardware acceptance. The
[acceptance checkpoint](release-acceptance/2026.10.8.md) records remaining gaps.

### Ongoing controls

| Area                 | Evidence                                                                                                                                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source and licensing | [License](https://github.com/Se7enbrc/glimmer/blob/main/LICENSE), [credits](https://github.com/Se7enbrc/glimmer/blob/main/CREDITS.md), per-file SPDX notices; [#122](https://github.com/Se7enbrc/glimmer/pull/122). |
| Build and tests      | `make verify`, [developer guide](CONTRIBUTING.md), per-component coverage reports.                                                                                                                                  |
| Static analysis      | Swift/Python/Actions CodeQL, extraction gate, Renovate and pinned package/build tools.                                                                                                                              |
| Boundaries           | [Security](SECURITY.md), [architecture](ARCHITECTURE.md), [release controls](RELEASE.md).                                                                                                                           |
| Governance           | [Roles and continuity](CONTRIBUTING.md#roles-and-continuity), [code of conduct](https://github.com/Se7enbrc/glimmer/blob/main/CODE_OF_CONDUCT.md); [#119](https://github.com/Se7enbrc/glimmer/pull/119).            |

[CodeQL run 37993312754](https://github.com/Se7enbrc/glimmer/actions/runs/37993312754)
passed all three languages for `1f2c3347d6b09a627b1c3f9fa1bdbaa288936db9` on
2026-10-09, with all 280 production Swift files extracted and no open CodeQL
alerts on that analyzed ref. Later candidates need their own evidence.

## Work that can ship through normal releases

Close measured gaps without removing hard-to-test components from the
denominator.

| Work             | Current state                                                                                                                             | Next evidence                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Coverage         | Hosted Swift/Python reports, no gate; [#124](https://github.com/Se7enbrc/glimmer/pull/124).                                               | UI tests, instrumented login item and installed helper; measure before targeting 80/90% criteria. |
| ASan/fuzzing     | Deterministic parser/stream tests in Verify; libFuzzer harnesses in a separate job; [#123](https://github.com/Se7enbrc/glimmer/pull/123). | Validate ThreadSanitizer and real playback/controller/concurrency lifecycles.                     |
| Reproducibility  | Local unsigned payload matched on 2026-10-10, Xcode 27.0/macOS 27.0.1, 69 files with catalog normalization.                               | Hosted Xcode 26.6 run and normalized published candidate comparison.                              |
| Source notices   | SPDX notices and retained upstream credits; enforced by `make check`.                                                                     | Audit contributor rights separately, including clean-room replacements and later contributions.   |
| Release evidence | [Verification commands](VERIFY_DOWNLOAD.md), [#121](https://github.com/Se7enbrc/glimmer/pull/121).                                        | Keep exact artifact/SHA and verification results for each release.                                |

The 2026-10-10 release check covered Sparkle ZIP apps 2026.10.2 through
2026.10.6: Apple signing/notarization/stapling passed and appcast signatures
existed. 2026.10.6 was the first release with hosted provenance. At that dated
checkpoint, DMG containers were unsigned. Current 2026.10.8 candidates sign,
notarize and staple the DMG separately; GitHub-generated source archives are not
the signed distribution artifacts.

### Coverage results

Read these as dated local measurements, not current hosted coverage or branch
coverage claims.

Both runs used Xcode 27.0 on an Apple Silicon Mac on 2026-10-10; hosted Verify
uses 26.6. Reports come from `make test COVERAGE=1` and
`make test-scripts COVERAGE=1` in `build/coverage`; hosted artifacts are
`coverage-swift` and `coverage-python`.

| Component / commit             | xccov lines            | llvm-cov lines         | Regions                |
| ------------------------------ | ---------------------- | ---------------------- | ---------------------- |
| App / `5ace115`                | 45.11% (25,080/55,599) | 44.92% (24,974/55,599) | 49.95% (9,537/19,095)  |
| Test-linked helper / `5ace115` | 43.72% (174/398)       | 43.72% (174/398)       | 44.32% (78/176)        |
| App / `1d10a89`                | 68.20% (37,747/55,350) | 68.01% (37,641/55,350) | 70.49% (13,511/19,167) |
| Test-linked helper / `1d10a89` | 57.79% (230/398)       | 57.79% (230/398)       | 61.71% (108/175)       |
| Login item / both              | 0% (0/36)              | Not executed           | Not executed           |

| Python tooling / commit | Statements           | Branches         |
| ----------------------- | -------------------- | ---------------- |
| `5ace115`               | 53.62% (652/1,216)   | 49.39% (241/488) |
| `1d10a89`               | 96.96% (1,180/1,217) | 91.39% (446/488) |

### Coverage limits

Keep unexecuted components and unavailable counters visible in the assessment.

The installed helper and its `main.swift` are not measured by the test-linked
copy. Swift emitted no branch counters; line/region counts are not statement or
branch counts. A zero denominator is not full coverage. See the
[Swift issue](https://github.com/swiftlang/swift/issues/81730).

Shell coverage is unmeasured. Python fixture copies outside `scripts/`,
including candidate tooling, can record no coverage. Initial app covered-line
counts varied from 25,080 to 25,083 across three runs. At that checkpoint, the
remaining app gap was mostly UI. Later render/UI and iOS coverage runs need
their own measured denominators; these old numbers are not current coverage.

### Sanitizer runs

Retain successful runs without treating parser tests as playback validation.

The first local ASan run passed 17 tests on 2026-10-09. `make test-asan` is
required for code changes; `scripts/fuzz.sh` adds coverage-guided harnesses with
Docker and `FUZZ_SECONDS`. The separate hosted libFuzzer job runs 30 seconds per
target. ThreadSanitizer and physical-device lifecycle checks remain open.

## Engineering evidence to sustain

Record a dated human security review with findings and their disposition.

Review trust boundaries, pairing, parsers, helper authorization, updates and
release tooling. Gold's review criterion needs human review within five years;
automated scanning cannot supply it. Preserve reviewer, SHA, regression tests,
analysis findings and release acceptance evidence.

Confirm actual report responses, vulnerability history, credential-leak history
and reporter credit before answering history-based criteria. Published targets
do not prove past performance. Do not mark unknown mandatory answers as met.

## Maintainer, contributor and upstream requirements

Resolve these people and platform constraints before claiming a higher badge.

| Area                | Remaining work or constraint                                                                                                                                            |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| People/review       | Two capable maintainers, two unassociated significant contributors, and another human reviewing at least 50% of changes. Bots/additional accounts do not count.         |
| Contributor support | Label bounded tasks and audit contribution rights; Passing itself does not require a DCO/CLA.                                                                           |
| Expertise           | Record truthful human secure-design/common-error knowledge.                                                                                                             |
| Governance/2FA      | Role/succession plan and sole maintainer's passkey are documented; retain evidence.                                                                                     |
| Build tools         | Xcode/Apple SDKs are required; qualify all-FLOSS and standard-variable criteria honestly.                                                                               |
| Network crypto      | Seek upstream/criteria clarification; current protocol behavior does not establish Gold's secure-network criterion. No assumed LAN exemption or patched-PC requirement. |
| Roadmap             | [Product direction](ROADMAP.md) is documented; [#120](https://github.com/Se7enbrc/glimmer/pull/120).                                                                    |

### Website hardening

Keep the 2026-10-10 header measurements distinct from controls the project can
configure.

| Endpoint                                              | Recorded headers/limits                                                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| GitHub repository and first download hop              | CSP, HSTS with preload, nosniff, frame denial and referrer policy.                                                                         |
| Final `release-assets.githubusercontent.com` download | None of those five headers.                                                                                                                |
| GitHub Pages site/feed                                | HTTP redirects to HTTPS; feed HTTPS 200 and HSTS `max-age=31556952`, without preload. No CSP, nosniff, frame or referrer response headers. |

The site supplies CSP/referrer meta tags, but those cannot supply
frame-ancestors, nosniff or X-Frame-Options. Pages does not let the site set
response headers; meeting those requirements needs a header-setting edge. Check
the
[current criteria](https://www.bestpractices.dev/en/criteria?details=true&rationale=true)
and remeasure before submitting a new assessment.
