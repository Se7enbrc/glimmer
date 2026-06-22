# Contributing

## Setup

Required:

- macOS 26 or newer
- Xcode 26 (full toolchain - Swift 6 strict concurrency, `swiftc`, `xcodebuild`,
  `xcrun`)
- Homebrew

Brew prerequisites:

```bash
brew install openssl@3 opus swiftlint
```

(`swiftlint` is required for the pre-commit hook; `openssl@3` and `opus` are the
Swift streaming engine's two link-time dependencies - OpenSSL for identity /
pairing / network crypto, Opus for audio decode. There are no submodules and no
vendored C library.)

Clone:

```bash
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
```

Install pre-commit hooks:

```bash
pre-commit install
```

## Build

```bash
make            # Debug build
make release    # Release build
make install    # copy to /Applications/Glimmer.app, adhoc re-sign
make open       # install + open
```

The canonical xcodebuild invocation (what `make app` runs) is:

```bash
xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
    -xcconfig Glimmer/StreamLib.xcconfig \
    OPENSSL_PREFIX=$(brew --prefix openssl@3) \
    OPUS_PREFIX=$(brew --prefix opus) \
    -derivedDataPath ./build -destination 'platform=macOS' build
```

For an inner-loop edit cycle, either use `make dev` (Release build with a stable
self-signed dev signature so TCC grants survive rebuilds - see the Makefile
comments), or work in Xcode against `Glimmer.xcodeproj`:

1. Set the Glimmer scheme's Run xcconfig to `Glimmer/StreamLib.xcconfig` (Edit
   Scheme → Run → Info). It supplies the OpenSSL/Opus search paths and the
   version from `Glimmer/Version.xcconfig`; nothing needs prebuilding.
2. Build and run.

Useful log tails:

```bash
log stream --predicate 'subsystem == "io.ugfugl.Glimmer"' --level info
```

See [PROFILING.md](PROFILING.md) for per-category predicates.

## Lint

`swiftlint` runs as a pre-commit hook. The baseline is intentionally non-strict:
warnings are surfaced for review but only errors block the commit. Custom rules
in `.swiftlint.yml`:

- `no_coauthor_trailer` - bans `Co-Authored-By:` (error).
- `no_claude_attribution` - bans `Generated with .*Claude` (error).
- `force_unwrapping`, `force_cast`, `force_try` - warning only.
- File / type body / function body lengths warn at ~600 / 600 / 80, error well
  above the current largest case.

The pre-commit wrapper runs `swiftlint --fix` first; if it modifies any staged
file, the commit is **refused** and the user is told to re-stage the diff.
Auto-staging by the hook is explicitly avoided so the user sees what changed.

`swift-format` is intentionally NOT enforced - Apple's formatter reflows the
codebase's trailing-aligned function arguments into a noisier style.

A `trufflehog` secret-scan also runs per commit via pre-commit (install it with
`brew install trufflehog` if the hook complains) - credentials never belong in
the tree; see [SECURITY.md](SECURITY.md).

## Style

- 2-space indent, opening brace on the same line, trailing newline. Match
  neighbouring files.
- File / type names match the load-bearing type they contain
  (`VideoDecoder.swift` → `class VideoDecoder`). Extensions split out by feature
  (`VideoDecoder+HDR.swift`, `VideoDecoder+Bitstream.swift`).
- C-FFI callbacks are named `c_<callbackName>` (e.g. `c_submit`,
  `c_decodeAndPlaySample`). Allowed by `identifier_name.allowed_symbols`.
- Comments earn their keep: short for obvious code, expansive when documenting a
  non-obvious decision. The HDR pipeline comments in `VideoDecoder.swift` and
  the bridge-lifetime comment in `StreamSession.swift` are the bar - if a future
  maintainer would have to dig through a `moonlight-qt` PR thread to understand
  why a line exists, the comment goes in the source.
- No emoji in source files.

## Concurrency

Swift 6 strict concurrency mode is on. The codebase is `@MainActor`-heavy on UI
code and `actor`-heavy in the streaming engine.

Rules:

- **`@MainActor`** for anything that touches `NSWindow`, `NSEvent`,
  `CAMetalLayer`, `AVSampleBufferDisplayLayer` configuration, `@Published`, or
  SwiftUI bindings. `VideoDecoder`, `InputForwarder`, `StreamWindow`,
  `MoonlightManager` are all `@MainActor`-isolated at the class level.
- **`actor`** for engine subsystems with non-trivial cross-thread state:
  `StreamSession`, `NetworkClient`, `PairingClient`, `IdentityManager`.
- **`@unchecked Sendable` with a documented lock** when a system framework
  forces callbacks onto its own threads:
  - `AudioDecoder` (AVAudioEngine callbacks on Core Audio threads, internal
    state lock-guarded).
  - `StatsCollector` (touched from the moonlight receive thread, the VT
    decode-queue, AND the main actor; guarded by an internal `os_unfair_lock`).
  - `StreamBridgeContext` (C-thread callback target).

### `nonisolated(unsafe)`

`nonisolated(unsafe)` IS acceptable in this codebase. It's used ~30 times. Every
use must document the invariant in a comment on the property - what the
synchronisation discipline is and why a regular actor / lock isn't viable.

Acceptable patterns:

- **Receive-thread callback bridging.** The native engine hands us frames and
  control events on its own receive threads, on hot paths that can't afford an
  actor hop per frame. The weak refs on `StreamBridgeContext` are
  `nonisolated(unsafe)` because Swift weak storage is atomic per spec and the
  engine serialises its callbacks per-stream - Swift 6 strict-concurrency can't
  see through to that guarantee, but the load is sound.
- **VT decode-queue state.** `decompressionSession`, `formatDescription`, SPS /
  PPS / VPS, stream parameters in `VideoDecoder.swift` are touched from the
  engine's receive thread (submit) and the VT output callback (decode). They
  live on `decodeQueue` (a serial `DispatchQueue`) and are serialised by it.
- **Single-writer-from-MainActor reads-from-anywhere.**
  `VideoDecoder.hdrEnabled` is written on the main actor, read by the VT output
  callback. A Bool load/store is naturally atomic on every supported arch; the
  eventually-consistent read is correct here (HDR-flip → next-frame fallback
  colorspace).
- **MainActor-only `Foundation.Timer` slots on an actor.**
  `StreamSession.statsOverlayTimer` is allocated and invalidated on the main
  actor (the only thread that may touch a `Timer`), but the _actor_ needs to
  schedule those mutations via `await MainActor.run`. The actual mutation only
  ever runs on the main thread.

NOT acceptable:

- "It compiled" without an invariant comment.
- Multi-writer races. If two threads can write the same slot,
  `nonisolated(unsafe)` is wrong - use a lock or hop to an actor.
- Anything with a Sendable-incomplete type behind it (CALayer, CAMetalLayer,
  AVSampleBufferDisplayLayer). Wrap with an `NSLock` around the load/store
  (`VideoDecoder._displayLayer` is the reference pattern).

### Event-yield discipline

The canonical place to surface a stream event to the consumer is
`StreamBridgeContext.eventContinuation?.yield(_:)`. `AsyncStream.Continuation`
is `Sendable` and FIFO-ordered, so yielding from the engine's receive thread
preserves the order the native engine delivered them in. The previous
`Task { await deliver(...) }` pattern lost ordering because consecutive Tasks
land on the global concurrent executor without inter-Task happens-before - see
the comment at `StreamBridgeContext.eventContinuation` (in
`StreamBridgeContext.swift`) for the motivating regression.

## Logging

`Logger` from `os`, never `print`, never `os_log`.

- Subsystem: **`io.ugfugl.Glimmer`** (capital G). Per-file `Logger` instances
  all use this string; no `.Stream` suffix on the subsystem.
- Category: per-file, dotted form `Stream.<Area>` for streaming-engine files.
  Current categories:
  - `MoonlightManager`
  - `HostsStore`
  - `Stream.Audio`
  - `Stream.Discovery`
  - `Stream.Identity`
  - `Stream.Input`
  - `Stream.Network`, `Stream.Network.TLS`
  - `Stream.Pairing`
  - `Stream.Session`
  - `Stream.VideoDecoder`
  - `Stream.Window`
  - Signposts: `Stream.Decode`, `Stream.Render`, `Stream.Network`,
    `Stream.Pairing`, `Stream.Audio` (see `Glimmer/Stream/Signposts.swift`).
- Privacy:
  - `privacy: .public` for non-sensitive diagnostic data (stage names, decode
    timings, codec format ints, error codes).
  - `privacy: .private` (the default) for anything PII-adjacent: host addresses,
    host names, error message strings, host versions.
  - Never log:
    - Key characters from `keyDown` events (a later change fixed the regression
      where chars=... leaked at `.public`).
    - URLs containing `rikey`, `rikeyid`, `gcmkey`, `gcmkeyid`, host UUIDs (the
      redaction helper in `Network.swift` strips them).
    - Cert PEMs or fingerprints at `.public` (see the TLS-delegate comment about
      hostile log-scraping).
    - PIN values, AES keys, signed pairing-secret bytes.

The current Swift 6 strict-concurrency posture means
`Logger.info("\(value, privacy: .public)")` is the standard form. Logging on
long-running paths (per-frame, per-mouseMoved) is gated behind explicit
conditions - never log per-frame at `.info`.

## Commits

CalVer for releases (`YYYY.M.MICRO`). See [RELEASE.md](RELEASE.md).

Conventional-commit-style prefixes are used in the repo's history; match what's
there. Common prefixes:

- `fix(area)` - bug fix scoped to a subsystem
- `perf(area)` - performance fix
- `refactor(area)` - non-behavioural rework
- `concurrency` - Swift 6 isolation cleanup
- `security` - anything in the threat-model surface
- `build` - Xcode / Makefile / scripts
- `chore` - repo hygiene
- `docs(area)` - these files

Subject line: imperative mood, lowercase after the prefix, no trailing period.
Body wrapped at ~72 columns when one's needed.

**No `Co-Authored-By` trailer.** Hard rule, enforced by the
`no_coauthor_trailer` swiftlint rule on source files and by repo policy on
commits. Same for any "Generated with Claude" attribution.

## Pull requests

- `main` is the active development branch; releases are tags on it.
- PR against `main`.
- Smoke-test checklist before tagging is in
  [RELEASE.md](RELEASE.md#3-pre-tag-smoke-test-checklist).
- All four parallel-developable areas (codec, concurrency, security, hygiene)
  have landed independently - keep PRs scoped so they can do the same.
