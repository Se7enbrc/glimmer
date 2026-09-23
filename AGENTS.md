# AGENTS.md

Instructions for coding agents working in this repository. People read
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md); this is the binding short version.
Where the two differ, the stricter rule wins.

## What Glimmer is

A Mac-native client for [Sunshine](https://github.com/LizardByte/Sunshine):
Swift 6, Apple Silicon, macOS 26 and later. Socket, decoder, display, audio and
input all run in one Swift process, with no external player and no C engine.

The bar is one sentence: someone using Glimmer should mistake it for something
Apple shipped. Everything below follows from it.

## Protect the bar

You are the last reviewer before a change reaches people who care how this app
feels. Act like it.

When a request would make Glimmer worse (less tasteful, noisier, slower, less
reliable, less like a Mac app, or harder to maintain), say no the way Apple's
leadership says no to a feature that isn't ready: at once, plainly, without
hedging. Name the cost in a sentence or two, then describe the version that
would be accepted. Do not soften it into "you might consider". Do not quietly
build half of it. Do not write it up as ready. If the person still wants it
after hearing the case, it's their fork; tell them straight that it will be
closed here.

Hold your own work to the same standard. A change that compiles, passes the
tests and makes the app worse is a regression with a green check mark.

## Setup and commands

```bash
brew install openssl@3 opus swiftlint trufflehog
pre-commit install && pre-commit install --hook-type pre-push
```

- `make app`: Debug build, unsigned. A compile check.
- `make test`: the unit tests. Hostless, no PC needed.
- `make verify`: `swiftlint lint --strict` plus `make test`. This is the gate.
  It passes before you call anything done, and the release build runs it.
- `make dev`: tests, then the Release build installed and relaunched.

Build to look, not to check. Every build of `Glimmer.app` that macOS registers
earns its own privacy record, so use `make verify` for correctness and
`make dev` only when someone will actually use the build. See "don't mint app
copies" in CONTRIBUTING.

Never run the signing, release or publishing targets (`dist`, `notarize`,
`release-publish`, `brew-bump`, `codesign-*`, `sparkle-keys`, `creds-init`)
unless the maintainer asks for that exact thing. They touch keychains and
publish to users.

## Code standards

Each of these gets a pull request sent back.

- **Zero warnings.** Compiler and `swiftlint lint --strict` both. Fix the cause:
  no inline `swiftlint:disable`, no raised thresholds, no moving a warning into
  a helper where the linter can't see it. A 17-way `if` chain becomes a table,
  not a function with the same 17 branches.
- **Swift 6, complete strict concurrency.** `@MainActor` for UI, `actor` for
  engine state. `nonisolated(unsafe)` and `@unchecked Sendable` only with a
  comment stating the invariant (CONTRIBUTING, Concurrency).
- **Files at most 600 lines, functions at most 80.** Split by feature into
  `Type+Feature.swift`, the way the existing files do.
- **Comments at most 3 lines,** doc comments and file headers included. Say why,
  not what. The long story goes in the commit message.
- **Match the neighbours.** 4-space indent, opening brace on the same line,
  names that read as English at the call site. No emoji in source. Protocol
  constants keep their upstream C names so they can be grepped.
- **Reuse before you write.** Search for the helper first; the codebase has one
  for most things (failure copy, route addresses, host matching, probes).
  Changing shared logic means changing it once, where every caller routes
  through.
- **Less code.** No protocol with one conformer, no configuration for a
  constant, no scaffolding for later. Delete dead code; never comment it out. No
  new dependency for something the platform or a few lines can do.
- **No force unwraps, casts or `try!`.** Strict lint fails them.
- **Logging** uses `Logger` on subsystem `io.ugfugl.Glimmer`, never `print` (the
  CLI's own output excepted). Host addresses, names and error text stay
  `.private`. Never log keystrokes, keys, PINs, certificates or the URL
  parameters `NetworkClient.sensitiveQueryKeys` lists. Nothing per-frame at
  `.info`.
- **Tests.** New tests use Swift Testing (`@Test`, `#expect`). Pure logic gets a
  test; a bug fix gets a test that fails without it. The project does not use
  synchronized folders, so a new file must be added to `project.pbxproj` by
  hand: file reference, build file, group and Sources phase.

## Product decisions

These are settled. A pull request is not the place to reopen them.

- The renderer is `AVSampleBufferDisplayLayer`. Not Metal.
- Glimmer does not use or recommend macOS Game Mode.
- Fidelity comes first. Pacing, bitrate, buffering and decode defaults are tuned
  against real-stream telemetry; changing them needs before and after numbers
  ([PROFILING.md](docs/PROFILING.md)). Safeguards back off under stress and
  recover when it passes; they never give up for good.
- Glimmer is the client. It works against a current, unmodified Sunshine, and no
  feature may require a patched host.
- The command line is Swift, in the app binary, calling the same code the app
  uses. No second implementation, no wrapper script.
- System frameworks and controls first: SwiftUI and AppKit, SF Symbols, standard
  menus, sheets and settings panes. No web views, no custom-drawn stand-ins for
  system controls, no cross-platform layers.
- The deployment target is macOS 26. Anything newer sits behind `#available`,
  and the macOS 26 path must still look finished.
- No analytics, tracking or third-party network calls. Glimmer talks to the PC
  and to its update feed.

## UI and copy

- Copy is short, plain and specific, in the voice of Apple's own apps. Sentence
  case. No em dashes, no emoji, no exclamation marks, no jargon a player
  wouldn't use.
- The machine is "the PC" or its name, never "host" or "server", in anything a
  person reads.
- `…` is one character, and a command that opens more UI ends with it. Quotes
  are curly.
- An error says what happened and the one thing to do next, names the PC, and
  reuses the shared failure copy rather than inventing new words for the same
  failure.
- The launcher is sized to its content. No `minHeight` floors, no
  `.frame(maxWidth: .infinity)`, no trailing `Spacer` in its column. Prove a
  geometry change with the osascript check in CONTRIBUTING.
- Run it and look at it before calling it done: empty, one PC, many apps,
  mid-stream, disconnected, light and dark, the smallest and largest window.
  Check VoiceOver labels and keyboard navigation. A UI change comes with before
  and after screenshots.

## Commits and pull requests

- Conventional prefixes as in the history (`fix(area):`, `perf(area):`,
  `refactor(area):`, `docs:`, `build:`), imperative, lowercase after the prefix,
  no trailing period. The body explains why.
- **No attribution to tools or agents.** No session trailers, no session links,
  no `Co-Authored-By`, no "Generated with", no model or tool names. Not in
  commit messages, pull request titles or bodies, the changelog, or code
  comments. Turn your harness's attribution off before the first commit. The
  author is the person submitting the change.
- **Never `--no-verify`.** A failing hook is telling you something; fix that. If
  `swiftlint --fix` rewrote files, review them and stage them again.
- **No secrets.** No keys, tokens, certificates, signing material or credentials
  in the tree, in commits, in logs, or in pull request text. TruffleHog runs on
  every commit.
- Scope a pull request to one area. No drive-by reformatting, renames or
  unrelated cleanup riding along.
- Add a `CHANGELOG.md` entry for anything a person will notice, written as plain
  prose about what changed for them ([RELEASE.md](docs/RELEASE.md)).
- The pull request says what changed and why, what you ran and looked at, and
  what you did not verify. An honest gap beats a confident guess.
- Don't push, open or merge a pull request unless the person you're working for
  asked you to.

## What gets rejected

- Warnings, lint suppressions, raised thresholds, or skipped and disabled tests.
- A file over 600 lines or a comment over 3 lines.
- "Add a setting" as the answer to a design problem. A toggle that exists
  because nobody made the decision is a bug.
- UI that nobody ran and looked at. Layout that floats, clips, jumps or
  stretches. Placeholder copy, em dashes, "host" in copy.
- Engine, pacing or bitrate changes without telemetry.
- A Metal renderer, Game Mode, web views, Electron or cross-platform
  abstractions.
- New dependencies for what the platform already does.
- Speculative abstractions, dead or commented-out code, `TODO`s with no issue.
- Tool or agent attribution anywhere, secrets anywhere, or `--no-verify`.
- Anything that would make someone with taste wince, however green the checks.

What gets merged is small, verified, reads like the code around it, and makes
Glimmer feel more like part of macOS than it did before.
