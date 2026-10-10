# Roadmap

Glimmer is a Mac-native client for Sunshine, for people with a Mac and a gaming
PC who want to play their PC games on the Mac, at a desk on Ethernet or on the
couch on Wi-Fi. Success is a player forgetting it is a stream, and the app
feeling like part of macOS ([PRODUCT](../PRODUCT.md)).

This page covers at least the next year. It states direction, not promises: no
item has a date, and any item may change with a release.

## Next year

Each item names the evidence it comes from.

- **Stream fidelity on Wi-Fi.** Keep tuning pacing, audio buffering and quality
  recovery against real-stream telemetry, with the couch on Wi-Fi as the harder
  case. Source: [PRODUCT](../PRODUCT.md) users and principles; recurring Wi-Fi,
  pacing and audio fixes in [CHANGELOG](../CHANGELOG.md) 2026.10.3 to 2026.10.6.
- **Clear failures and recovery.** Every way a stream fails says what happened
  and the one thing to do next, and safeguards recover rather than give up.
  Source: CHANGELOG 2026.10.3 and 2026.10.4.
- **Keep pace with Sunshine, macOS and dependencies.** Track current, unmodified
  Sunshine and new macOS releases, and keep dependencies updated through
  Renovate. Source: [AGENTS](../AGENTS.md) product decisions; issue #42.
- **Test coverage.** Measure per-component coverage before setting any gate,
  then add tests for missing paths. Source:
  [security roadmap](SECURITY_ROADMAP.md) item 1.
- **Sanitizers and fuzzing.** Keep the protocol fuzz tests running under
  AddressSanitizer in `make verify` and retain hosted results for each release.
  Source: security roadmap item 2.
- **Reproducible builds.** Make release metadata deterministic and compare two
  independent clean builds. Source: security roadmap item 3.
- **Source and release evidence.** Per-file copyright and licence notices, and
  documented verification steps for every distributed artifact. Source: security
  roadmap item 4.
- **Network protocol assessment.** Document what stock Sunshine encrypts and
  what it does not, without requiring a patched PC. Source: security roadmap,
  `crypto_used_network`.

- **Apple TV, and possibly iPhone.** Bring the same native streaming engine to
  Apple TV, and consider an iPhone client, which Moonlight already offers there.
  Source: maintainer direction.

## Out of scope

These are settled decisions. A pull request is not the place to reopen them.

- A Metal renderer. The renderer is `AVSampleBufferDisplayLayer`.
- Controlling Game Mode through private APIs or by rewriting the signed
  Info.plist. macOS owns the Game Mode switch.
- Any feature that needs a patched or modified Sunshine on the PC.
- NVIDIA GameStream. Glimmer supports Sunshine only and tells the player when a
  PC still runs GameStream (CHANGELOG 2026.9.7).
- Web views, Electron or cross-platform UI layers.
- Analytics, tracking or third-party network calls.
- A second command-line implementation or wrapper script. The `glimmer` command
  lives in the app binary.
- Intel Macs and macOS versions before 26. On the Mac, Glimmer is Apple Silicon
  only, macOS 26 and later.
- Paid features. Glimmer is free, and every feature belongs to every user.

## How this changes

The maintainer updates this page with any release that changes direction, and
reviews it at least once a year. Proposals start as issues the maintainer agrees
to; see [CONTRIBUTING](CONTRIBUTING.md).
