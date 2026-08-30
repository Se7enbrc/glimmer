# Contributing

## Setup

Required:

- macOS 26 or newer
- Xcode 26 (full toolchain - Swift 6 strict concurrency, `swiftc`, `xcodebuild`,
  `xcrun`)
- Homebrew

Brew prerequisites:

```bash
brew install openssl@3 opus swiftlint trufflehog
```

`openssl@3` and `opus` are the Swift streaming engine's two link-time
dependencies: OpenSSL for identity / pairing / network crypto, Opus for audio
decode. There are no submodules and no vendored C library. `swiftlint` and
`trufflehog` back pre-commit hooks and the commit fails without them.

Clone:

```bash
git clone https://github.com/Se7enbrc/glimmer.git
cd glimmer
```

Install pre-commit hooks:

```bash
pre-commit install                      # lint + secret scan, per commit
pre-commit install --hook-type pre-push # `make test`, per push
```

## Build

```bash
make app        # compile-only check (Debug), no signing
make test       # unit tests
make            # notarized Release build, installed to /Applications
make open       # same, then open it
```

`make` and `make open` run the full shipping pipeline: Developer ID signing,
notarization, strict library validation. That is deliberate. There is no
adhoc/Debug divergence in daemon registration, TCC, or library validation to
chase, because you are always running what ships. Without a Developer ID cert on
the machine it falls back to an adhoc Release build (un-notarized, and TCC
re-prompts).

The canonical xcodebuild invocation (what `make app` runs) is:

```bash
xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
    -xcconfig Glimmer/StreamLib.xcconfig \
    OPENSSL_PREFIX=$(brew --prefix openssl@3) \
    OPUS_PREFIX=$(brew --prefix opus) \
    -derivedDataPath ./build -destination 'platform=macOS' build
```

For an inner-loop edit cycle, either use `make dev` (unit tests, then the
notarized Release build, installed and relaunched - same signing path as
`make install`), or work in Xcode against `Glimmer.xcodeproj`:

1. Set the Glimmer scheme's Run xcconfig to `Glimmer/StreamLib.xcconfig` (Edit
   Scheme → Run → Info). It supplies the OpenSSL/Opus search paths and the
   version from `Glimmer/Version.xcconfig`; nothing needs prebuilding.
2. Build and run.

Useful log tails:

```bash
log stream --predicate 'subsystem == "io.ugfugl.Glimmer"' --level info
```

See [PROFILING.md](PROFILING.md) for per-category predicates.

### Build hygiene - don't mint app copies

**Build once per thing you actually want to look at.** Not once per edit.

macOS gives every distinct copy of the bundle its own privacy identity. Anything
that registers a `Glimmer.app` with LaunchServices - and `make app` re-registers
its Debug bundle on _every_ run - earns a separate row under **System Settings →
Privacy & Security → Local Network**. Those rows are TCC records: they survive
deleting the app, and they survive a reboot.

One session of rebuild-on-every-edit produced **nine** registered copies (two
checkouts' `build/`, two DerivedData trees, `/Applications`, Trash, Downloads)
and eight Local Network entries. The app then could not reach a host on the LAN,
and the failure surfaced as `Couldn't reach <ip>` - which reads as a network
problem and is not one.

Keep the inner loop cheap and batch the install:

```bash
make app     # compile-only check - fast, no install
make test    # unit tests
make dev     # ONLY when you want to actually use the build
```

Clean up copies you created:

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -dump | grep -oE '/[^ ]*Glimmer\.app' | sort -u   # what macOS knows about
"$LSREG" -u /path/to/stale/Glimmer.app                      # unregister one
rm -rf build ~/Library/Developer/Xcode/DerivedData/Glimmer-*
```

Unregistering does **not** retract the privacy grants. Only this does, and only
the user can run it:

```bash
sudo tccutil reset All io.ugfugl.Glimmer
```

`tccutil reset LocalNetwork <bundle-id>` is rejected - `LocalNetwork` is not a
service name `tccutil` accepts. `All` is the working form, and it also clears
Input Monitoring (the DualSense raw-HID grant), so expect to re-approve that.

## UI changes

The launcher window is **sized to its content and not resizable**
(`.windowResizability(.contentSize)` in `GlimmerApp`). That only holds while
every view in the column states a _definite_ size, which makes ordinary SwiftUI
idioms load-bearing in a way that is easy to miss:

- `minHeight:` / `minWidth:` are **floors, not sizes**. A view with a floor
  accepts any larger size it is offered, so one of them anywhere in the column
  hands the window something to grow into - the window becomes resizable again
  and the offending view stretches to fill whatever the user drags out.
- `.frame(maxWidth: .infinity)` has no size of its own to measure.
- A trailing `Spacer()` exists to push content against a container taller than
  itself. In a content-sized window there is no such space, so it can only
  invent some.
- `ConnectSurface` and `EmptyPairingState` therefore end in
  `.fixedSize(horizontal: false, vertical: true)` - they take their ideal height
  rather than the offered one. Keep it that way.

The window's `minWidth` in `GlimmerApp` must equal the connect surface's real
width (card width + 2x its horizontal padding). A floor _below_ the true content
width leaves the window that much range to be dragged through, and it opens at
the bottom of that range with the margins squeezed flat.

**Verify geometry against the running app, not the source.** Every one of the
above was shipped at least once on a source reading that looked right. Build,
install, launch, then ask the window what it actually did:

```bash
osascript <<'EOS'
tell application "System Events"
  tell process "Glimmer"
    set w to first window
    set s0 to size of w
    set out to "opens at " & ((item 1 of s0) as integer) & "x" & ((item 2 of s0) as integer)
    try
      set size of w to {1200, 900}
    end try
    delay 0.7
    set s1 to size of w
    return out & "  after_grow=" & ((item 1 of s1) as integer) & "x" & ((item 2 of s1) as integer)
  end tell
end tell
EOS
```

If `after_grow` differs from the opening size, something in the column is still
flexible. This takes about a minute and is not optional for a geometry change -
a resize regression once survived two releases because it was only ever read,
never run.

A UI pull request should say which of these it touches, and include a
before/after screenshot at the smallest and largest window the change allows.
"Builds clean" is not evidence about layout.

## Lint

`swiftlint` runs as a pre-commit hook over `Glimmer/` only; `scripts/` is
build-time tooling and is not held to the product lint bar. The baseline is
intentionally non-strict: warnings are surfaced for review but only errors block
the commit. Thresholds worth knowing from `.swiftlint.yml`:

- `force_unwrapping`, `force_cast`, `force_try` - warning only.
- File length and type body warn at 600, function body at 80. The errors sit at
  1500 / 1500 / 250, well above the current largest case.
- `line_length` warns at 140, errors at 280, ignoring URLs and comments.

The pre-commit wrapper runs `swiftlint --fix` first; if it modifies any staged
file, the commit is **refused** and you are told to re-stage the diff.
Auto-staging by the hook is avoided so you see what changed.

`swift-format` is intentionally NOT enforced - Apple's formatter reflows the
codebase's trailing-aligned function arguments into a noisier style.

A `trufflehog` secret scan runs per commit against verified detectors, and
`prettier`, `markdownlint`, and `yamllint` cover the non-Swift files.
Credentials never belong in the tree; see [SECURITY.md](SECURITY.md).

## Style

- 2-space indent, opening brace on the same line, trailing newline. Match
  neighbouring files.
- File / type names match the load-bearing type they contain
  (`VideoDecoder.swift` → `class VideoDecoder`). Extensions split out by feature
  (`VideoDecoder+HDR.swift`, `VideoDecoder+Bitstream.swift`).
- Protocol constants mirror their upstream C names verbatim
  (`COLORSPACE_REC_2020`, `DR_NEED_IDR`) so a reader can grep the spec.
  `identifier_name.allowed_symbols: ["_"]` exists for exactly that.
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
  `AVSampleBufferDisplayLayer` configuration, or SwiftUI bindings.
  `VideoDecoder`, `InputForwarder`, `StreamWindow`, and `AppModel` are all
  `@MainActor`-isolated at the class level.
- **`actor`** for engine subsystems with non-trivial cross-thread state:
  `StreamSession`, `NetworkClient`, `PairingClient`, `IdentityManager`.
- **`@unchecked Sendable` with a documented lock** when a system framework
  forces callbacks onto its own threads:
  - `AudioDecoder` (AVAudioEngine callbacks on Core Audio threads, internal
    state lock-guarded).
  - `StatsCollector` (touched from the engine's receive thread, the VT
    decode-queue, AND the main actor; guarded by an internal `os_unfair_lock`).
  - `StreamBridgeContext` (the receive-thread callback target).

### `nonisolated(unsafe)`

`nonisolated(unsafe)` IS acceptable in this codebase, and there are currently 74
of them. Every use must document the invariant in a comment on the property:
what the synchronisation discipline is, and why a regular actor or lock isn't
viable.

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
- Anything with a Sendable-incomplete type behind it (`CALayer`,
  `AVSampleBufferDisplayLayer`). Wrap with an `NSLock` around the load/store
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

- Subsystem: **`io.ugfugl.Glimmer`** (capital G). Every `Logger` in the app uses
  this string; no `.Stream` suffix on the subsystem. The privileged AWDL helper
  is a separate process and uses `io.ugfugl.glimmer.helper`.
- Category: per-file, dotted form `Stream.<Area>` for streaming-engine files.
  The current list is in [PROFILING.md](PROFILING.md#unified-log); add to it
  when you add a file, don't reuse a neighbour's category. Signposts sit on the
  same subsystem with their own categories (`Stream.Decode`, `Stream.Render`,
  `Stream.Network`, `Stream.Pairing`, `Stream.Audio`) in
  `Glimmer/Stream/Signposts.swift`.
- Privacy:
  - `privacy: .public` for non-sensitive diagnostic data (stage names, decode
    timings, codec format ints, error codes).
  - `privacy: .private` (the default) for anything PII-adjacent: host addresses,
    host names, error message strings, host versions.
  - Never log:
    - Key characters from `keyDown` events (a later change fixed the regression
      where chars=... leaked at `.public`).
    - URLs carrying `rikey`, `rikeyid`, `gcmkey`, `gcmkeyid`, `uuid`, or
      `uniqueid`. `NetworkClient.sensitiveQueryKeys` is the set; the redaction
      that consumes it lives in `NetworkClient+Endpoints.swift`.
    - Cert PEMs or fingerprints at `.public` (see the hostile-log-scraping
      comment in `ControlTransport.swift`).
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

**No `Co-Authored-By` trailer.** Hard rule of repo policy, and the same goes for
any "Generated with Claude" attribution. No emoji in commit messages either.

## The bar

**"It builds clean" is table stakes, not evidence.** Neither is "the tests
pass". Both are necessary; neither says anything about whether the thing is any
good.

The bar for anything a user can see or feel is: **would someone with taste,
looking at this for two seconds, be appalled?** If you would not put it in a
demo, it is not done - however green the checks are.

This is not hypothetical. Glimmer shipped a launcher whose host card floated in
several hundred points of empty window. It compiled without a warning, the tests
passed, SwiftLint was clean, and it was obviously wrong to anyone who opened it.
Walking it back took the rest of a release train: 2026.8.3 pinned the window to
its content and left the card nearly touching the frame, and 2026.8.4 put the
margins back. Each attempt had been validated by reading the diff instead of
looking at the app.

Practically, before you call something done:

- **Run it.** Not the test suite - the app, the way a user meets it.
- **Look at it**, in the states a user will hit: empty, one host, many apps,
  mid-stream, disconnected, the smallest and largest window you allow.
- **Prove the claim you are making.** If the claim is "no longer resizable",
  drive the window and read the size back (see [UI changes](#ui-changes)). If it
  is "reconnects cleanly", pull the cable. A claim you have not exercised is a
  guess with a commit message.
- **Say what you did NOT verify.** An honest "the dropdown has never rendered
  with more than two apps" is worth more than silence, and it is what lets the
  next person aim their attention.

## Pull requests

- `main` is the active development branch; releases are tags on it.
- PR against `main`. Keep them scoped to one area, so they can land
  independently.
- Bump `Glimmer/Version.xcconfig` and add a CHANGELOG entry in the same PR. See
  [RELEASE.md](RELEASE.md).
- Before you ask for a merge, run the thing and look at it. [The bar](#the-bar)
  is the checklist.
