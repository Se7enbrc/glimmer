# CI and release tooling migration decision

**NO-GO under the owner's three-minute threshold.** Keep this migration planned,
but prioritize build reuse. Security re-review is treated as zero cost.

## Measured costs and expected saving

| Component                                                | Evidence                                                                    | Removable by Go                                                                                                                         |
| -------------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Production Python dependency installation                | Release/CI scripts import the standard library only                         | 0 seconds                                                                                                                               |
| Python/tool preparation                                  | Sampled Verify jobs: 19, 24 and 29 seconds, including scanners and coverage | At most 29 seconds; most tools remain necessary                                                                                         |
| Interpreter plus representative standard-library imports | 30 local starts: 1.139 seconds, about 38 ms each                            | About 1.14 seconds per 30 calls                                                                                                         |
| Swift extraction coverage step                           | Sampled jobs: 15, 19 and 28 seconds                                         | Mostly external CodeQL query/pack work, which remains; 28 seconds is a deliberately loose upper bound                                   |
| Script fixture suite                                     | Hosted #195: 473 tests, 364.019 seconds                                     | Not production interpreter overhead; fixtures invoke Git, shell tools and child processes                                               |
| Local fixture profile sample                             | 274.26 seconds total, 259.48 waiting in poll, 3.16 forking                  | Less than 15 seconds in the parent interpreter, including imports and I/O; sample interrupted after implementation edits invalidated it |

The measured categories support a conservative **under-one-minute upper bound**
for language-related work on the PR critical path, and a likely saving of only
seconds. Portable fixtures run beside the Mac builds, so accelerating their
interpreter normally saves **zero PR wall-clock minutes**. GitHub evidence
reads, Apple processing/notarization, compiler work, hashing and artifact
transfer remain in either language. There is no measured saving over three
minutes for RC or TestFlight either. Do not count their API wait time as a Go
improvement.

## Inventory and order if future measurements cross the threshold

1. Port deterministic transforms: verify-changed, codeql-swift-changed,
   changelog, build-policy-page, release_validation, release_candidate_kind,
   check-ios-diagnostics, check-engine-boundary, check-ios-boundary and
   gen-gamecontrollerdb. Preserve command lines, diagnostics and exit codes.
2. Port artifact/data handling: release_artifact, release_symbols,
   ios-testflight-artifact, provisioning, coverage-report, codeql-coverage,
   release_download and release_summary. Preserve symlink/path traversal,
   digest, archive size, identity and malformed-input rejection rules.
3. Port read-only authorization: release-checks, github_signed_commit and
   tap_cache. Preserve exact SHA/ref/run/attempt joins, bounded retries,
   pagination limits, SARIF receipts, alert checks and fail-closed behavior.
4. Port state transitions: candidate_reservation, candidate_delivery,
   release-candidate, ios-testflight and ios-testflight-sign. Preserve atomic
   leases, fencing, delivery claims, flavour/CalVer identity, credential
   boundaries and cleanup on every exit.
5. Port publication: promote-release, release_publication and update-appcast.
   Preserve immutable accepted bytes, idempotency, signatures, promotion
   ancestry and partial-publication recovery. Replace test-scripts orchestration
   last; keep the Python suite as an independent oracle through acceptance.

Shell build/signing wrappers remain separate entry points initially. Inventory
all their Python calls before switching a phase; no partial fallback may
silently change which gate authorizes delivery.

## Equivalence and distribution

Run the current Python tests against both implementations through a thin command
adapter. Feed identical recorded API responses, filesystem trees, clocks and
subprocess outcomes to each; compare exit status, canonical JSON, stdout/stderr,
Git updates, artifact bytes/modes/links and the ordered side-effect transcript.
Use isolated repositories and inert signing/upload tools. Add generated
malformed inputs and interruption points, including concurrent
reservation/admission races, partial reruns, moved refs, empty/truncated pages
and secret cleanup. Timing budgets and network authorization semantics must
match, not merely happy outputs.

Build a single CGO_ENABLED=0 binary once for Linux amd64 and Darwin arm64 with a
pinned Go toolchain. Key caches by toolchain, platform, go.mod/go.sum and source
SHA; publish checksummed artifacts only from trusted builds. PRs cannot replace
a main binary. Keep source provenance and exact-ref gates around the binary
itself. Shadow read-only operations first. Before each mutating phase switches,
complete the independent security review, verification and fixes, then exercise
the same hosted recovery scenarios as the Python implementation. Revert by
restoring the prior entry point, without replaying publication or replacing
accepted bytes.

Next: use [CI timings](CI_PERFORMANCE.md) to revisit the threshold after hosted
build-cache measurements.
