# Working on Glimmer for iOS

Read [the repository rules](../AGENTS.md), [DESIGN.md](../DESIGN.md),
[PRODUCT.md](../PRODUCT.md), and the
[engine roadmap](../docs/IOS_ENGINE_ROADMAP.md) first. Shared rules apply; the
root AGENTS.md wins conflicts. This file adapts Mac presentation rules to iOS.
The engine always comes from this same checkout's root package.

- Swift 6, complete strict concurrency. UI belongs on `@MainActor`; engine state
  belongs in the engine. Zero compiler warnings and strict SwiftLint, 120
  columns.
- Files at most 600 lines, functions at most 80. Split by feature. Comments at
  most three lines and explain why. Preserve load-bearing comments and
  diagnostics.
- Search for an existing engine helper before writing one. No copied engine, new
  dependency, single-conformer protocol, or setting in place of a design
  decision. Test seams are defaulted closures or parameters. No force unwraps or
  casts.
- New behavior and fixes need Swift Testing tests that fail without the change.
  New source files need SPDX headers and unique Xcode file, build, group and
  Sources entries. Search existing IDs before choosing new ones.
- Use SwiftUI, UIKit, SF Symbols and system controls. Custom looks are styles on
  native controls. Preserve keyboard, focus, VoiceOver and Dynamic Type
  behavior. No web views, continuous animations or extra launch network
  requests.
- Copy uses sentence case, “the PC”, curly quotation marks, straight
  apostrophes, a single-character ellipsis, and no em dashes or emoji.
- `Logger` uses `io.ugfugl.Glimmer`. Names, addresses and error text are
  private. Never log credentials, PINs, certificates or keystrokes. No per-frame
  info logs.
- iOS/iPadOS 26 minimum, iPhone first. Baseline hardware is iPhone 17 Pro with
  Backbone One; identify controller capabilities, never vendor names.
- iPhone streams use both landscape orientations. iPad streams use the whole
  window in any orientation. Video fills behind cutouts, hides status and home
  indicators with public APIs, and keeps controls safe. Use
  `AVSampleBufferDisplayLayer`; no Metal renderer or private receive APIs.
- ProMotion permission is not a promise of 120 fps. Start real streaming at SDR
  60 fps and stereo; higher modes need sustained hardware measurements.
- Leaving the foreground releases input immediately. A finite background task
  allows at most 15 seconds to return before local teardown; lock, system
  expiration or denied execution ends it earlier. Teardown quits the game by
  default; “Leave games running when you disconnect” preserves it. Explicit Quit
  always remains available. Add no ongoing background streaming, polling or
  telemetry service.
- Run `make app`, `make test`, `make check`. See CONTRIBUTING.md for Simulator
  and device verification. All Make targets are unsigned and never install the
  app. Do not sign, provision, install, publish or change keychains without
  permission.
- Run and inspect UI before claiming visual acceptance. Report missing Simulator
  or hardware evidence honestly. Keep changes scoped; no tool attribution.
