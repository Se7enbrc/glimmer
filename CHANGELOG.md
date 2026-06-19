# Changelog

## 2026.6.17 - 2026-06-18

Fixes visible frame-skipping on high-refresh displays. The present-pacing floor
was re-pinning the display's refresh rate every couple of seconds to chase
content cadence, and each renegotiation dropped a frame (reproducible on
testufo.com/frameskipping). The floor now holds the requested refresh steady -
skipping gone, and the top end is preserved (the panel max is still honored).

Also in this release: audio drift is now corrected by a continuous resampler
instead of the old silence-insertion stretch, so playback stays smoother under
host/Mac clock skew; the launcher's primary button reads "Stream &lt;app&gt;"
instead of the misleading "Resume &lt;app&gt;"; and the control channel is
floored at TLS 1.2.

## 2026.6.16 - 2026-06-18

Root-fixes the "host suddenly stops trusting this Mac after sleep" problem. The
control channel (pairing, launch, resume) now runs on Glimmer's own OpenSSL
mutual-TLS client instead of URLSession - which had forced the client identity
through the login keychain, the thing that locked on sleep and broke the
connection. The cert + key now load straight from the on-disk PEM, with the host
cert pinned exactly as before, so there's no keychain in the path to lapse on
wake. (2026.6.15 was a stopgap that re-imported on demand; this removes the
cause.)

## 2026.6.15 - 2026-06-18

Fixes streams suddenly failing with "host doesn't recognize this Mac" after the
Mac sleeps. The client TLS identity is imported into the login keychain, which
locks on sleep/idle; the long-running app kept using the now-unusable cached
identity, so the next stream's mutual-TLS handshake couldn't sign - and that was
misreported as a lost pairing. Glimmer now re-imports the identity on demand
when its key can't sign, so it self-heals instead of needing a restart.

## 2026.6.14 - 2026-06-17

The AWDL helper now logs each time macOS re-raises `awdl0` mid-stream and it
re-suppresses - recent macOS auto-enables `awdl0` for AirDrop/Continuity even
while it's parked, and each re-enable is a brief contention window that can
hitch the stream. Logged at a level that persists, so a hitch can be checked
against it. Helper-only; no app changes.

## 2026.6.13 - 2026-06-17

`make dev` now runs the test suite before building, and releases go through a
PR. Dev-workflow only; no app changes.

## 2026.6.12 - 2026-06-17

Docs only - trimmed the release runbook. No app changes.

## 2026.6.11 - 2026-06-17

Smooths out Wi-Fi freezes during a stream, and moves Glimmer to an unsandboxed
app to make that possible.

### Streaming

- **Wi-Fi-stutter helper.** AirDrop / Continuity share the Mac's Wi-Fi radio
  (AWDL) and can grab the channel mid-stream, causing multi-second freezes.
  Glimmer now suppresses `awdl0` for the life of a stream and restores it when
  you stop. Stream-scoped: it only parks the radio while you're actually
  streaming. The suppression runs through a privileged `SMAppService` daemon;
  enable it with a toggle in **Settings > General > Network**, and approve the
  one-time launch prompt macOS shows the first time.
- **Host display setup.** Glimmer requests your Mac's exact native resolution +
  refresh; [docs/HOST_SETUP.md](docs/HOST_SETUP.md) and a sample
  [`vddsettings.xml`](docs/vddsettings.xml) document the Sunshine +
  Virtual-Display-Driver setup the host needs to present those modes.

### Security

- **Hardened Runtime library validation is back on** for release builds. The
  embedded OpenSSL/Opus dylibs are re-signed under the team ID at build time, so
  the app no longer ships with library validation disabled - the compensating
  control now that there's no sandbox. See [docs/SECURITY.md](docs/SECURITY.md).
- **Fuzzed the stream-transport parsers** (Annex-B / RTP / FEC / RTSP / ENet /
  AES-GCM) - the bytes a host sends that the client has to parse. It surfaced
  and fixed an out-of-bounds read in the Reed-Solomon FEC decoders.

### Internal

- **Glimmer is now an unsandboxed app.** Required to install and run the root
  AWDL helper (a sandboxed app cannot register a system daemon). Identity and
  pinned-cert files migrate from the old sandbox container to
  `~/Library/Application Support/Glimmer/` on first launch; no re-pairing. See
  [docs/SECURITY.md](docs/SECURITY.md) for the full rationale and the
  compensating controls.
- **The AWDL helper survives app updates.** Its privileged registration now
  self-heals on launch, so an auto-update no longer leaves the Wi-Fi-stutter
  suppression silently disabled until you toggle it again.

## 2026.6.10 - 2026-06-16

Hygiene. Adds an automated unit-test suite (120 tests across the wire codecs,
Reed-Solomon / audio FEC, input encoders, RTSP/SDP, the AES-GCM stream crypto,
and the pairing/identity crypto) plus a SwiftLint cleanup. No app-behavior
changes.

## 2026.6.9 - 2026-06-16

Hygiene. The client identity stays in mode-0600 sandbox-container files - we
evaluated the keychain and deliberately stayed on files (the data-protection
keychain needs a provisioning profile a Developer-ID app can't ship, and the
0600 sandbox files already beat the reference client's plaintext plist). No
user-visible change.

## 2026.6.8 - 2026-06-16

### Updates

- **Checks for updates on launch**, in addition to the once-a-day background
  check.

## 2026.6.7 - 2026-06-16

Auto-update test release - exercises the Sparkle in-place update from 2026.6.6.
Source and docs cleanup only (punctuation normalized to ASCII; dependency docs
corrected); no app-behavior changes. (Build stamp `20260618`.)

## 2026.6.6 - 2026-06-16

Auto-update validation release - no functional changes vs 2026.6.5; cut to
exercise the Sparkle in-place update path. (Build stamp `20260617` so it sorts
strictly after 2026.6.5's same-day `20260616`.)

## 2026.6.5 - 2026-06-16

Self-updating, plus a wifi smoothness fix for bursty links.

### Updates

- **Glimmer now updates itself.** Built-in auto-update (Sparkle): a daily
  background check plus a "Check for Updates..." item in both the app menu and
  the menu-bar dropdown. Updates are EdDSA-signed and notarized. This first
  auto-update-capable build is installed manually; every release after it
  updates in place. Background checks run only on release builds, and an update
  is offered only when a strictly-newer release exists - local/dev builds are
  never nagged.

### Streaming

- **Smoother playback through brief wifi delivery gaps.** When a >50ms gap
  drains the frame buffer on a bursty link, the bunched catch-up now plays
  _through_ instead of being discarded - killing the ~20% frame-drop and the
  persistent stutter that trailed each gap. Sparse gaps were already fine; this
  fixes the sustained-burst case.

## 2026.6.4 - 2026-06-13

Input resilience on lossy links (driven by play-testing on a lossy 25-50ms link
with real packet loss), matching Moonlight's input posture.

### Input

- **Mouse stops "spinning until it recovers" on a lossy link.** Reliable input
  used to pile up behind a dropped packet and the host would burst-apply the
  backlog after you'd already stopped turning. The merged-input flush now backs
  off on the count of un-ACKed reliable commands (the host falling behind), not
  just the local socket queue - so a stall coalesces into a single catch-up
  instead of a spin. Mirrors Moonlight's 10ms ack-wait. Relative mouse stays
  reliable (no dropped motion).
- **Controller motion (gyro/accel) now ships unreliable**, matching current
  Moonlight - a superseded sensor sample is worthless, so a lost one is dropped
  rather than retransmitted and never head-of-line-blocks the reliable input
  stream. A null gyro (0,0,0) stays reliable so "sensors stopped" can't be lost.

## 2026.6.3 - 2026-06-13

Host-resilience release: survive a Windows lock/sign-in, stream to non-AV1
hosts, ship as a self-contained app, and opt-in performance telemetry.

### Streaming

- **Survive a Windows lock / sign-in transition.** When the host (Sunshine)
  restarts its capture across a secure-desktop switch - or a brief network blip
  drops the link - the stream now holds the last frame and silently reconnects
  in place, resuming when the desktop returns, instead of dropping to the
  launcher and freezing. Generalizes to short blips, not just lock screens.
  (#20)
- **HEVC (and H.264) hosts supported.** Native HEVC/H.264 depacketization
  alongside AV1, with an intelligent AV1 → HEVC → H.264 default and a per-host
  codec override - so a non-AV1 GPU (e.g. an RTX 3080) streams cleanly. (#19)
- **Lower 4K240 receive overhead.** Batched UDP receive via Darwin's `recvmsg_x`
  cuts the per-packet syscall floor at high frame rates. (#24)

### Packaging

- **Self-contained app.** Every Homebrew dylib reference is rewritten by
  inspection and gated on a self-containment check, so Glimmer runs on a clean
  Mac without Homebrew installed. (#18)

### Diagnostics / telemetry (opt-in)

- **Opt-in performance telemetry.** Per-second stream metrics over a local
  Prometheus endpoint plus an NDJSON session scorecard, labeled by client and
  host. Off by default; can optionally push to a remote Prometheus/Loki sink.
  Metrics carry the negotiated codec. (#23)

### Fixes

- Host-status chip no longer flaps to "Checking..." on a transient miss, and now
  polls continuously regardless of window focus (it used to stick on
  "Checking..." whenever Glimmer wasn't frontmost).
- Resolved-host mDNS name no longer keeps an interface-zone suffix that broke
  pairing. (#21)

### Build

- Headless, self-healing Developer ID signing via a dedicated keychain
  (credentials pulled from 1Password), so `make dist` / `make install` never
  prompt - from any session.

## 2026.6.2 - 2026-06-11

The convergence release: three telemetry-driven engineering passes, a
pre-release adversarial bug hunt (36 confirmed findings, 8 release blockers -
all fixed), and the first original visual identity.

### Streaming engine

- Audio: playout limit-cycle eliminated (learned per-host cushion memory with
  ambient loss floor), audio FEC revived after a header-size bug had silently
  disabled it mid-session, −40 ppm clock-drift micro-compensation, backlog-aware
  startup (no more fixed 500 ms drop)
- Pacing: tick-deficit failsafe ladder against macOS display-link throttling,
  renderer-reject recovery (flush+IDR, pacer kept), floor re-pin storms fixed
  (clamp-before-compare + deadband + dwell), screen- change rebinds gated on
  material change
- Decode gating while hidden (audio keeps playing; refocus resyncs via a single
  IDR), suppression-state correctness end to end
- Control channel: connection lock (teardown use-after-free closed), per-channel
  reliable dedup, RTT token map bounded, RFI cooldown wrap-safety

### Controllers

- Rumble implemented (host events → per-locality Core Haptics with proper
  sharpness), trigger rumble, RGB lightbar, motion (gyro/accel uplink), battery
  reporting - every advertised capability now backed by code
- Clean teardown of raw-HID/haptics/motion/battery registrations; quit chord
  gains its promised hold; cursor re-hides on Dock-click refocus

### App

- Launcher: route-aware status line, state-aware "Resume <game>" action,
  Enter-to-play, calm 400 ms connect treatment, session-receipt toast
- Settings: Quality pane with measured two-tier bitrate guidance,
  outcome-phrased labels, persisted launch choice, honest battery UI
- Original Glimmer Eclipse icon + menu-bar marks; window tuned
- Sunshine-first identity; support link

### Infrastructure

- make dist is fully non-interactive after a one-time credentials file
  (self-bootstrapping preflight); CI workflow; docs rewritten for the pure-Swift
  architecture

## 2026.6.1 - 2026-06-05

### The Swift-native streaming engine is now the engine

- The GameStream/Sunshine transport is a **pure-Swift implementation**
  (`Glimmer/Stream/Native/`): encrypted RTSP/SDP handshake, ENet-subset reliable
  control channel with AES-GCM control encryption, RTP video/audio receive with
  Reed-Solomon FEC, reference-frame-invalidation loss recovery, AV1/HEVC/H.264 +
  HDR decode, Opus audio, and the full input uplink (keyboard / mouse / gamepad
  / DualSense) with ~1ms input batching. Verified end-to-end against Sunshine
  7.1.431. The previously-linked `moonlight-common-c` static library and its
  submodule are gone from the build.
- Stability work that shipped with it: input batching/rate-limiting (fixes a
  host-side control-channel timeout that silently killed streams at ~16-18s),
  dedicated-thread keepalives, send/receive queue split with backpressure, and
  10s dead-peer detection.

### License

- **Relicensed MIT → GPLv3.** The native engine is a port of GPLv3
  `moonlight-common-c` - a derivative work - so Glimmer ships under the same
  license as the code it was ported from. See `LICENSE` and `CREDITS.md`.

## 2026.6.0 - 2026-06-01

### Pairing

- Fixed pairing failures where the host reported success but Glimmer didn't: the
  background reachability poller was hitting the host concurrently during
  pairing, wedging Sunshine's single-session pairing handshake. The poller now
  pauses for the duration of pairing.
- Pairing now waits a full human-scale window for you to enter the PIN on the
  host (previously it could time out in a few seconds, before you'd finished
  typing the code).
- A freshly-paired PC is now saved properly (with its app list), so it persists
  in your PC list instead of disappearing.

### Pairing & PC management UX

- New discover-first pairing flow: the "Pair a new PC" sheet shows PCs found on
  your network - pick one and pairing starts as the code appears, then the sheet
  closes itself on success and floats above other windows while open. A manual
  address entry remains for networks where discovery is quiet.
- Right-click a PC (in the launcher or in Settings → PCs) to **Rename** or
  **Unpair** it. Unpair leaves a fully clean state.

### Build / distribution

- Added a CI-grade, non-interactive code-signing setup so Developer-ID builds
  don't prompt for the keychain password repeatedly.
- The app version now lives in a single source of truth
  (`Glimmer/Version.xcconfig`) read by both the Info.plist and the Makefile (DMG
  name + release tag), so a release is a one-line bump instead of editing the
  version in several places.

## 2026.5.3 - 2026-05-30

### Streaming

- The Mac (and its display) now stays awake for the whole stream - a power
  assertion is held for the session lifetime so the screen no longer dims or
  sleeps mid-game during controller-only sessions.
- Quality preset defaults to **Match my display** (panel-native resolution +
  refresh), shown at the top of the preset list.

### Launcher / Settings

- Fixed the duplicate "last played" line in the host hero - the footer below the
  Stream button is now the single source (the hero copy could show a stale or
  over-fresh value).
- Toggling "Launch minimized" no longer dismisses the Settings window.

### Under the hood

- App namespace migrated to `io.ugfugl.Glimmer` (bundle id, logging subsystem,
  copyright, security contact). Note: the new sandbox container means paired
  hosts and login-item approval must be set up once on upgrade.

## 2026.5.2 - 2026-05-28

Ultra-premium polish pass: correctness, accessibility, and reliability.

### Reliability / correctness

- Fixed a VideoToolbox decode-callback use-after-free: the output callback now
  holds a retained reference to the decoder (`passRetained` + balanced release
  at every session-invalidation site) so a decode in flight can never outlive
  the decoder during teardown.
- `AudioDecoder` is now actually thread-safe: an `NSLock` + `isShutdown` guard
  serializes the opus decoder / AVAudioEngine lifecycle against the per-sample
  decode path, closing a use-after-free between `decodeAndPlay` and `shutdown`.
- HDR on/off is applied in callback order via the main queue instead of an
  order-racing unstructured `Task`, so the decoder can't get stuck in PQ on an
  SDR stream.
- Stream errors now always show a human-readable message. `StreamError` gained
  `LocalizedError` conformance - previously some paths surfaced the generic "The
  operation couldn't be completed. (Glimmer.StreamError error 0.)".

### Accessibility

- Reduce Motion is respected throughout: the empty-state pulse, readiness-chip
  pulse, hero connect scale-up, stream-button bounce, and the stream-window
  fade-in all settle instantly when the setting is on.
- VoiceOver: the pairing code is read as one element ("Pairing code", spoken
  digit-by-digit) instead of four separate "PIN digit" stops; the Stream button
  exposes a hint explaining why it's disabled or busy.
- Accent color now has distinct light/dark variants tuned for contrast
  (violet-700 light, violet-400 dark) instead of one electric value that failed
  WCAG AA on white.

### UX / quality

- Default quality preset is now Smooth (1440p-capped) rather than panel-native -
  a smoother first stream over typical Wi-Fi.
- Bitrate budgeting no longer saturates at 4K; 5K/6K displays get a correctly
  scaled bitrate instead of ~half the bits per pixel.
- Removed a non-functional Wake-on-LAN button and the codec name from
  user-facing stream summaries (it could disagree with the negotiated codec).
- "Stream now" after pairing matches the host across all identifiers
  (case-insensitive), so pairing by IP no longer silently fails to launch.

### Platform

- System-mute-while-streaming reimplemented on CoreAudio (the previous
  `osascript` path was a silent no-op under the App Sandbox).
- Added local-network usage description + Bonjour service declarations so host
  discovery works under the macOS 15+ local-network privacy gate.

## 2026.5.1 - 2026-05-27

Polish release covering reliability, performance, security hardening, and a
launcher rebuild. ~95 commits since 2026.5.0.

### Reliability

- Swift 6 strict concurrency enabled on the target. Sendable conformances,
  actor-isolation cleanup, and explicit `nonisolated(unsafe)` audit (kept 31,
  replaced 1 with `NSLock`-guarded slot) across `StreamSession`, `VideoDecoder`,
  `StatsCollector`, and `MoonlightManager`.
- Early-stage stream events (`stageStarting` / `stageComplete`) no longer
  silently dropped. The `AsyncStream<StreamEvent>` continuation is built before
  `LiStartConnection`, and C-callback events yield directly through it so
  ordering is preserved.
- `StatsCollector` FIFO no longer leaks `OSSignpostIntervalState` tokens on
  eviction.
- `VideoDecoder.displayLayer` reads on the decode queue are now
  `NSLock`-protected; explicit `deinit` teardown safety net for VT session
  invalidation.
- `MoonlightManager` `NotificationCenter` observers drained in `deinit` to
  prevent stray fires post-teardown.

### Performance

- `MoonlightManager` migrated from `ObservableObject` + `@Published` + manual
  `objectWillChange.send()` to the `@Observable` macro. The 4 Hz republish
  hammer is gone; a `displayInfoRevision` sentinel handles the one
  `NSScreen.main`-reading computed property.
- AV1 sequence-header OBU parser. Real `av1C` config record built from the
  bitstream (chroma subsampling, bit depth, profile, tier), not hardcoded 4:2:0
  Main.
- SCM bitmask sent to the host is now built from `VTIsHardwareDecodeSupported`
  probes at type-load time - Intel Macs no longer advertise AV1 they can't
  decode.
- VUI override only when the bitstream is untagged; tagged streams have their
  color metadata respected, with the original `(10-bit + hdrEnabled) → PQ`
  Sunshine workaround restored before the VUI honoring path so Sunshine's
  mistagged-BT.709 HDR streams render correctly.
- HDR metadata caches (`cachedMasteringDisplay`, `cachedContentLightLevel`,
  `lastColorSpace*`, `hdrEnabled`, first-frame probe flags) cleared in
  `teardown()`. No more SDR-after-HDR session inheriting stale state.
- `AVSampleBufferDisplayLayer.isReadyForMoreMediaData` backpressure with
  IDR-request after 3 consecutive drops. Bounded enqueue queue, latency doesn't
  accumulate under load.
- Frame watchdog gates on decoded output (`recordDecodedFrame`) rather than byte
  reception. Logs `bytes received but no decoded output` at `.public` when the
  host sends packets we can't decode.
- `_EnableTemporalProcessing` flag dropped from VT decode (~8 ms saved at 120
  Hz). LAN `packetSize` 1024 → 1392. PTS sourced from `du.rtpTimestamp` (90 kHz
  host clock) instead of `mach_absolute_time()`.
- Stats overlay 1 Hz cadence with 1 s rolling window - no more ±1 fps jitter at
  60 Hz.
- `LiRequestIdrFrame` no longer wrapped in `Task.detached` (drop a scheduler hop
  from the enqueue hot path).

### Security

- App Sandbox enabled (`com.apple.security.app-sandbox = true`). Hardened
  Runtime in project config; Xcode auto-disables it for adhoc signing and
  activates it under Developer ID.
- Identity files moved into the sandbox container; mode-0600 preserved.
  Migration from moonlight-qt's preference plist is one-shot and unconditionally
  wipes the source PEMs after a successful import.
- Pinned host certs moved out of `UserDefaults` to mode-0600 files at
  `~/Library/Containers/.../Library/Application Support/Glimmer/PinnedHosts/<UUID>.pem`.
  `cfprefsd` is shared across same-UID processes; a mode-0600 file is not.
- Pin commit timing fixed - only happens AFTER the final pairchallenge
  validates. Pin storage key normalized to the host's serverinfo UUID so fresh
  pairs aren't going through TOFU.
- Pairing failure errors collapsed to a uniform "Pairing failed" surface;
  specific causes (wrong PIN, MITM, host mid-pair) logged at `.private` only.
- Encryption default flipped from `.audioOnly` to `.all` (video + audio + input
  AES-128-GCM).
- `NSWindow.sharingType = .none` on the stream window. ScreenCaptureKit,
  `screencapture(1)`, and Cmd-Shift-5 see a black surface.
- Key characters stripped from `keyDown` log lines (was leaking every keystroke
  including passwords to the unified log at `.public`).
- Session keys (`rikey` / `rikeyid` / `gcmkey` / `gcmkeyid`) and host UUIDs
  redacted from URL log lines via a shared helper.
- `FingerprintCompareSheet` for cert-change re-pair flow - side-by-side SHA-256
  fingerprints with copy buttons, mono diff highlighting, secure- channel
  verification hint, destructive-styled accept button.

### Stream UX

- **Smooth fade-in connection.** Stream window starts at `alphaValue 0` and
  fades in over 350 ms `easeInEaseOut` after the first decoded frame has been
  enqueued (with a 50 ms vsync cushion). `NSApp.presentationOptions` deferred to
  the fade-completion handler so the menu bar / Dock never visibly vanish ahead
  of the window becoming opaque. No more letterbox flash mid-connection.
- Stream window now correctly restores `presentationOptions` on `didResignKey`
  (Cmd-Tab away, click launcher) and re-applies on `didBecomeKey` - eliminates
  the "launcher floating on a letterboxed desktop" bug where menu bar + Dock
  stayed hidden after Cmd-Tab.
- Disconnect: 250 ms `alphaValue` fade-out + "Stream ended" toast in the
  launcher.
- Dock-click while streaming routes straight back to the stream window
  (`applicationShouldHandleReopen`).
- HDR override restored over VUI tags for `(10-bit + hdrEnabled)` - Sunshine HDR
  streams tagged BT.709 no longer render washed-out.

### Stats overlay

- Complete redesign: SF Symbol icons per row, monospaced right-aligned values,
  per-metric color states (white / yellow / red), section dividers between
  groups. One `CATextLayer` per row with attributed strings; diff-update only
  changed rows per 1 Hz tick.
- Three presets: **Micro** (Host / Render / Network FPS, Latency, Jitter, Drops,
  Bitrate - the at-a-glance set), **Extended** (every stream-side metric),
  **Custom** (per-row checkboxes grouped by section in Settings → Streaming).
- **Color thresholds are user-configurable.** Settings → Streaming → Color
  thresholds. Per-metric warn + critical pairs with steppers and a
  Restore-defaults button. New defaults tuned to "when does this actually feel
  bad" - FPS <60 warn / <30 crit (absolute), latency >50ms / >100ms,
  jitter >10ms / >25ms, drops >0.5% / >2%. Live-applied during a stream on the
  next 1 Hz tick.
- New **Mac** section (Custom-only opt-ins): Mac CPU, Mac RAM, Mac battery (% +
  charging glyph from `battery.0/25/50/75/100/100.bolt`). Sampled via
  `host_statistics` (Mach), `host_statistics64`, `sysctl hw.memsize`, and
  IOPowerSources - sandbox-safe APIs only.
- Jitter row surfaced separately from RTT variance (same underlying value today,
  ready for a future plumbed-through RTP inter-arrival jitter signal).
- Stats overlay corner picker moved to Settings (mouse events during a stream
  belong to the host; right-click on the overlay layer wasn't viable).
- Configuration (preset picker, position, per-row toggles) is editable even when
  the overlay is off - preconfigure without flipping the display toggle.
- Renderer-backpressure drops surface as a `(+N RB)` suffix on the Decoder drops
  row when non-zero; healthy streams stay uncluttered.

### Launcher UX

- **Quick Settings drawer removed.** Every control it carried (quality preset,
  default-launch app, mute-while-streaming, stats overlay toggle) lives in the
  main Settings window. The slider-toggle button is gone with it.
- **Toolbar pill merges host dropdown + Settings gear** via `ControlGroup`. Host
  picker on the left, gear on the right, one visual pill on the Liquid Glass
  toolbar. Shows with a single paired host now (previously gated on `> 1`); zero
  hosts collapses to a standalone gear so Settings stays reachable.
- Three-state menu bar icon: `moon.stars` (idle) / `play.fill` (streaming) /
  `exclamationmark.triangle.fill` (error).
- App icon at 16/32 pt got a dedicated small-size render path - silhouette
  readable at Finder list-view / About-pane / Dock small sizes.
- Connect state machine tightened: "Choose a PC" CTA when no host is selected;
  StreamButton hides entirely while the stream is foreground (vs. disabled
  "Streaming..."); connecting subtext sourced from the C-side stage strings.
- Host tint colors now deterministic via FNV-1a - same host shows the same hue
  every launch (Swift's `hashValue` randomizes per process).
- Marketing tagline replaced with a plain utility-app description.
- "Trust new cert and re-pair..." affordance renamed to "Compare
  fingerprints..." and routed through the new comparison sheet.

### Controller

- **Controller quit chord** in Settings → Shortcuts. Hold the configured combo
  on the gamepad to quit the stream - fires the same path as the keyboard
  hotkey. Presets: L1+R1, L1+R1+L2+R2, L3+R3, Select+Start, Home/Guide. Default
  `None` so the keyboard chord stays primary.

### App lifecycle

- **Launch minimized** toggle in Settings → General. Uses SwiftUI's
  `defaultLaunchBehavior(.suppressed)` so the main window doesn't auto-show -
  only the menu bar charm. Reopen via Dock click or the menu bar's "Open
  Glimmer" entry.
- Dead `quitChord` / `statsChord` locals in `stream(app:on:)` cleaned up.

### Files

- `MoonlightManager` 1464 → 719 lines (split into `Models/Host.swift`,
  `HostsStore.swift`, `QualityCalculator.swift`, `HostStatusPoller.swift`).
- `VideoDecoder` 2132 → 1095 lines (split into `VideoDecoder+HDR.swift`,
  `VideoDecoder+Bitstream.swift`, `StatsCollector.swift`).
- `InputForwarder` 1543 → 1109 lines (split into `KeyboardScanMap.swift`,
  `StreamInputView.swift`, `ControllerForwarder.swift`).
- New: `MacSystemStats.swift`, `StatsOverlaySettings.swift`,
  `StreamingState.swift`.
- Logging subsystem canonicalized to a single reverse-DNS subsystem; `os_log`
  retired in favor of `Logger`. (The app namespace settled on
  `io.ugfugl.Glimmer` in 2026.5.3.)
- `swiftlint` `file_length` tightened to `warning: 600 / error: 1500`
  post-splits.

### Docs

- `ARCHITECTURE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `PROFILING.md` rewritten
  to match the post-refactor reality (AVSampleBufferDisplayLayer pipeline,
  `StreamBridgeContext`, Swift 6 strict mode posture, mode-0600 identity
  storage, capital-G logging subsystem predicates).

### Bug fixes

- Controller battery row removed entirely - `GCController.battery` reports
  `.unknown` for most attached pads on macOS (wired DualShock 4, several MFi
  pads), leaving the row showing `-` indefinitely. Net signal was negative.
- Pre-existing dead code purged: `StreamSession.interrupt()`, `HostPickerBar`,
  `StreamSpecLine`, unused `configError`, `Discovery` (unwired mDNS browser),
  `if win.firstResponder == nil { }` empty block, `@available(macOS 13.0, *)`
  checks in a macOS-26-only project.
