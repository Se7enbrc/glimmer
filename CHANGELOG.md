# Changelog

## 2026.6.42 - 2026-06-26

Fixes audio dying after a mid-stream reconnect. When the stream silently
reconnected (a network blip - e.g. waking on a different Wi-Fi network - drops
and re-establishes the connection underneath you), the audio decoder's shutdown
flag was set during teardown and never cleared on the rebuild, so audio came
back muted: the picture resumed but sound didn't, with packets arriving and
nowhere to play. The flag is now reset on every rebuild, the audio graph
re-initializes cleanly, and a new diagnostic surfaces a silent-audio state at a
glance.

## 2026.6.41 - 2026-06-25

Two controller/overlay fixes.

The controller exit chord no longer pops the host's on-screen keyboard. The old
default (L1+R1+L2+R2) leaks the partial combo to the host as you press into it,
and Steam Big Picture reads that as its show-keyboard shortcut. The default is
now L3 + R3 (click both sticks) - native on every controller, and its partials
collide with nothing. (The old chord is still selectable in Settings.)

The "Stream stuttering" pill is now conservative: it lights only on real dropped
or late frames, not on the normal frame-repeats a high-refresh display does when
the host sends fewer fps than the panel refreshes - which was lighting it
constantly at 4K 240 where the picture was actually smooth.

## 2026.6.40 - 2026-06-25

Under the hood, no change to streaming behavior: added diagnostics for the
hardware decoder's session-create time and the cause of any mid-stream decoder
rebuilds, plus a debug-build safety check on the present-timing thread's
shutdown.

## 2026.6.39 - 2026-06-25

Fixes the "Stream stuttering" badge firing constantly at high refresh. When the
display refreshes faster than the host can send frames - e.g. a 240Hz panel with
a host that can only encode ~130fps at 4K - the panel re-shows each frame to
fill the idle refreshes. That's normal and looks smooth, but the badge counted
those structural repeats as stutter and lit nonstop. It now judges smoothness by
how EVENLY frames actually reach the screen (present cadence), so it stays dark
on an even stream at any frame-rate-to-refresh ratio, and still catches real
judder and dropped frames. (If your stream looks soft at 4K 240, the host likely
can't encode it - try 4K 120 or a lower resolution; the picture is genuinely
smooth at the rate it's delivering.)

## 2026.6.38 - 2026-06-25

Launcher polish, and the Wi-Fi helper now stays out of the way on Ethernet.

On a confirmed-wired connection the network helper no longer prompts you to
enable it AND no longer parks the AirDrop/Continuity radio during a stream -
which did nothing for a wired session but disabled AirDrop system-wide. Wi-Fi
sessions are unchanged (that's where it helps).

The bitrate chip and the codec checkmark now update immediately when you change
a host's codec (they could lag the actual setting). A configured launch app that
isn't on the selected host is labelled "(not on <host>)". Plus a telemetry
cardinality cleanup for per-thread CPU.

## 2026.6.37 - 2026-06-25

Under the hood: a batch of telemetry-accuracy fixes, no change to streaming
behavior. The in-app latency and A/V-sync figures now reflect reality - the
"input latency" estimate was measuring time-to-next-frame rather than felt
latency (reading several times too low), and the "A/V skew" number was dominated
by audio-buffer depth instead of true sync. Adds an honest click-to-first-frame
measure (the old timer started after the launch handshake) and a few new
diagnostic counters.

## 2026.6.36 - 2026-06-25

Cuts standing audio latency on a wired link. The audio buffer was holding
roughly 150ms more cushion than a clean wired connection needs - about a
quarter-second of avoidable A/V lag - because its learned safety floor had been
trained up to its ceiling by clock-skew corrections (not real audio loss) and
then couldn't ease back down. On a quiet, healthy wired link the floor now walks
back down so the buffer drains to a tight, low-latency depth; a link that's
actually struggling keeps its cushion, and Wi-Fi is unchanged (it needs the
deeper buffer).

## 2026.6.35 - 2026-06-25

Six fixes from a deep audit.

The controller exit chord now works on every gamepad. The default leave-stream
chord required a button (the DualSense Create button) that macOS doesn't expose,
so on a DualSense it silently never fired. It's now a four-shoulder/trigger hold
that's native to every controller, and the in-stream leave hint shows it.

Three correctness fixes: the stream's network/RTT telemetry no longer goes blank
after a silent reconnect; a rare main-thread stall when the present-timing
thread is slow to start is closed; and an A/V-skew metric that could disagree
between its two outputs is now computed once.

Lower input latency - the controller-to-host send no longer lets macOS defer
each flush by up to a full millisecond.

The in-stream degradation pill is much harder to flicker: it shows only on
sustained hitching and drains out cleanly.

## 2026.6.34 - 2026-06-25

Fixes the bitrate shown under the hero. The spec chip displayed the nominal
H.264 quality figure, but on AV1/HEVC the stream actually sends ~20% fewer bits
(the codec-aware budget from 2026.6.22) - so it read e.g. 84 Mbps while the wire
carried 67. The chip and the spec summary now show the real codec-aware bitrate
the engine sends.

## 2026.6.33 - 2026-06-25

Stops the in-stream "Stream stuttering" pill from crying wolf. It had no startup
grace, so a game's brief launch stutter (loading + display-mode negotiation)
flashed it immediately, and its thresholds sat close enough to the normal
high-refresh floor that an occasional dip could trip it. It now waits out the
launch transient and only shows for hitching clearly above that floor - so it
stays dark on a healthy session and means something when it appears.

## 2026.6.32 - 2026-06-25

Drops fewer frames on high-refresh displays. The present-timing tick ran on the
main thread, where the macOS frame-rate governor could starve it whenever the
thread was busy - the display link missed callbacks, frames piled up, and the
pacer trimmed them. On a clean link that was the biggest source of micro-stutter
(~73% of the dropped frames). The tick now runs on its own high-priority thread
so it fires on time, at no added latency.

## 2026.6.31 - 2026-06-25

Makes the in-stream degradation badge honest. It was driven by a link-contention
signal (Wi-Fi AWDL co-gaps) that the error-correction quietly absorbs - so it
lit when nothing was wrong and missed the actual picture stutter. It now fires
on perceived present-side hitching (dropped, late, or repeated frames), so it
lights when the picture actually stutters and stays dark when the link blips
harmlessly. Relabeled "Stream stuttering". The link-health signal it used to
read is still recorded in telemetry.

## 2026.6.30 - 2026-06-25

Fixes the in-stream "Network degraded" pill. A brief Wi-Fi co-gap blip could
flash it, and once shown it could stay stuck on even after the link recovered.
It now appears only for SUSTAINED degradation - a momentary blip is ignored -
and reliably fades back out when the link clears.

## 2026.6.29 - 2026-06-25

Fixes the choppiness in 2026.6.28. One of that release's frame-pacing changes
misread the present pacer's normal steady-state release as a defect and
suppressed it, and over-tightened the due-gate timing - so frames missed their
display tick, the present hold tripled, and the picture repeated and dropped
frames on a clean link. That behavior change is reverted; the new pacing
telemetry it added (which is how the regression was caught in a single session)
is kept.

## 2026.6.28 - 2026-06-25

A broad polish release - 39 fixes across the engine, the interface, and the
instrumentation.

Lower audio latency and tighter lip-sync. The drift resampler now keeps its
clock-offset estimate across buffer drains and corrects skew several times
faster, and the playout cushion no longer ratchets to a deep buffer on a clean
link - together cutting a large chunk of standing audio delay on a good
connection.

Smoother frames. At fps == display refresh the pacer no longer trims a few
frames a second it shouldn't, so rendered frame rate matches decoded on a clean
link.

Sturdier connection. A control-channel read could hang indefinitely if the host
went silent mid-reply - it now fails fast and recovers; the handshake has an
overall timeout, more disconnect causes are treated as recoverable, and
connecting no longer blocks the session.

Keeps your setup across this update. The earlier move to an unsandboxed app left
existing installs unable to see their paired PCs - this release migrates them
forward so pairings and trust carry over.

Clearer in-stream feedback. A banner shows over the frozen frame while
reconnecting or holding; a host with a changed certificate is flagged with a
real re-pair action instead of a false "Ready"; taking over a PC that's already
streaming asks first; a first-stream hint shows how to leave fullscreen; and a
"Network unstable" pill appears on a degrading link.

Under the hood: honest decode-latency telemetry (the old p95/max were
estimates), a durable disconnect-reason counter, Wi-Fi AWDL suppression that
engages on the first stream after you enable it, GPU power folded into the power
metric, and a batch of smaller correctness and observability fixes.

## 2026.6.27 - 2026-06-25

Tightens the Wi-Fi network helper so it holds awdl0 down harder during a stream.
macOS re-raises the AirDrop/Continuity radio on its own schedule; the helper now
catches that the instant it happens (a kernel routing socket rather than a
slower poll), strips the interface's IPv6 address, and verifies it actually went
down - so the radio gets far less chance to hop off your stream's channel and
stutter it. It also now records how often macOS fought the radio back up
(visible in telemetry) and logs clearly whether it engaged for each stream.

## 2026.6.26 - 2026-06-24

Holds audio together on hosts whose clock drifts hard. The drift resampler's
correction ceiling was set for a near-perfect clock and could be hit by a host
whose audio clock runs off by a few hundred parts-per-million - once pinned, it
could no longer keep the buffer full and the audio would crackle. The ceiling is
now high enough to absorb the skews real hosts actually show, with margin to
spare; the rate change stays inaudible.

## 2026.6.25 - 2026-06-24

Smoother audio when the host and Mac clocks drift apart. The drift-tracking
resampler now catches a clock-skew onset about twice as fast, so the audio
cushion no longer briefly drains during the catch-up - which is what produced
the occasional crackle on longer sessions. Pitch movement stays inaudible.

## 2026.6.24 - 2026-06-24

Fixes a rare freeze when a stream drops. If the host cut the connection at just
the wrong instant - mid audio-playout - the app's audio teardown could deadlock
against the audio engine, hanging Glimmer so it couldn't reconnect until it was
force-quit and relaunched. The drift resampler now applies its rate change off
the audio completion handler, removing the lock-order inversion that caused it.

## 2026.6.23 - 2026-06-24

Restores headroom on AV1 streams. 2026.6.22's codec-aware budget trimmed AV1
sessions a bit aggressively (a third off the H.264 figure); this softens that to
match HEVC (~20% off), so busy, high-motion scenes keep more room before the
encoder feels it - while still using less bandwidth than H.264 at the same
quality.

## 2026.6.22 - 2026-06-24

Uses less bandwidth on modern codecs at the same picture quality. The bitrate
budget is now codec-aware: AV1 and HEVC sessions need fewer bits than H.264 for
the same result, so Glimmer no longer spends the H.264-sized budget on them
(roughly 20-33% fewer bytes against a capable host, with no visible change). An
explicit Custom bitrate is always sent as-is.

Under the hood: the audio and video FEC decoders now share one Reed-Solomon
solver (and a copy-on-write allocation was removed from the loss-recovery hot
path), the frame pacer's state was regrouped into cohesive structs behind the
same single lock, and the release tooling now pins the source tag to the exact
built commit and stamps the appcast in UTC. A link-state FEC arming-bias
experiment is present but off by default.

## 2026.6.21 - 2026-06-22

Clearer recovery when the Wi-Fi helper won't install. macOS occasionally keeps a
stuck background-item record after an app update and refuses to register the
helper - the app used to report this as "helper not found in the app bundle,"
which was both false and a dead end. It now explains what actually happened and
links straight to Apple's own Login Items & Extensions guide for managing it.

## 2026.6.20 - 2026-06-22

A maintenance pass. Fixes a couple of stale in-app pointers left by the
Troubleshooting/Diagnostics merge - the DualSense chord tip and the quit-chord
hint now send you to Settings > Input, where those controls actually live. The
mute-while-streaming toggle reads outcome-first with a clearer footnote, the
Custom resolution helper is now a "Use native resolution" button, and the
empty-state copy settles on a single "Pair a PC."

Everything else is under-the-hood housekeeping: stale comments and docs brought
back in line with the code - notably the security notes, which now describe the
current OpenSSL certificate-pinning path - and internal planning shorthand
scrubbed out of the source.

## 2026.6.19 - 2026-06-21

A polish pass across Settings, the controller, and stream robustness.

The Quality presets are simpler and truer to these displays: "Match my display"
is now "Native Retina" (every pixel of the Mac's panel), the rarely-right Smooth
and Maximum presets are gone, and a new HiDPI preset streams at the Mac's
default Retina scale - a crisp picture at roughly a quarter of the bandwidth.
Notch coverage is now a single-line toggle right under the resolution picker,
and the in-stream stats overlay can sit top-center (clear of the camera notch)
or bottom-center.

Settings are also reorganized: the raw-mouse aim toggle moved to Input, Wi-Fi
stutter-smoothing moved to Quality, and the Troubleshooting and Diagnostics
panes merged into one - the controller test and logs stay in plain sight, while
the telemetry wires reveal with the usual option-click on the version line.

On the controller, the DualSense player-number LEDs now light to match its slot,
and the unreliable Home / Guide quit chord - macOS reserves that button - was
removed (the Options + Create + L1 + R1 chord remains).

Under the hood: a SwiftUI layout-engine crash is hardened by making the
display-change recompute idempotent; the video receive path falls back
gracefully if a future macOS ever drops its private batched-receive syscall; and
a handful of defensive guards round it out.

## 2026.6.18 - 2026-06-20

Fixes controller input dying after you record a custom quit chord. Recording a
chord temporarily borrows the gamepad's input handlers, and dismissing the
recorder left them detached - so controller input stayed dead until the stream
was restarted. Input now re-attaches automatically whenever the stream window
regains focus, so it recovers on its own.

Also in this release: the Mac's own mouse acceleration is now turned off while a
stream is focused, so only the game's sensitivity shapes your aim instead of the
Mac's pointer curve stacking on top of it - on by default, with a toggle in
Settings > General > Mouse (mice only; the trackpad is untouched). Audio on a
fresh, jittery, or remote connection starts at a smarter playout cushion instead
of walking up to it through a few audible blips. And the telemetry now surfaces
the FEC loss-recovery headroom - including how close each frame came to
unrecoverable - for better visibility into marginal links.

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
