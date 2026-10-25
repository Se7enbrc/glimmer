# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People with a Mac, iPhone or iPad and a gaming PC running Sunshine who want to
play their PC games on those devices. On the Mac, they use it in two scenes:

- at a desk on Ethernet, with the Mac as the PC's screen;
- away from the desk, usually on the couch with a MacBook on Wi-Fi.

Both matter. The couch on Wi-Fi is the harder case and gets design and tuning
attention first.

## Product Purpose

Glimmer streams games from the user's own PC to their Mac, so a gaming PC in the
other room feels plugged into the Mac. Success is a player forgetting it is a
stream, and someone using Glimmer mistaking it for something Apple shipped.

## Positioning

Native leads. Socket, decoder, display, audio and input all run in one Swift
process, with no external player and no C engine, and the app lives where Mac
apps live: Liquid Glass windows, the menu bar, Shortcuts, Siri, Spotlight and a
command line in the app binary.

Two claims back it up:

- **Fidelity first.** Pacing, bitrate, buffering and decode defaults are tuned
  against real-stream telemetry. Safeguards back off under stress and recover
  when it passes, and never give up for good.
- **The Mac side is handled.** Wake on LAN, the Wi-Fi stutter helper, the notch,
  the login item and updates are taken care of without the user learning how.

Sunshine is the server application on the PC. Moonlight is a separate client
that inspired Glimmer; it is not the protocol's name.

## Operating Context

- Pair a PC with a PIN, found by mDNS or entered by address (Tailscale works).
- Start a stream from the launcher, the menu bar, Shortcuts, Siri, Spotlight or
  the `glimmer` command; wake a sleeping PC first when Wake on LAN is set up.
- Play full screen, in a window, or in the mini player, with a controller or
  mouse and keyboard.
- Install from the Homebrew cask or the notarized DMG; the app updates itself
  with Sparkle.

## iPhone and iPad

The iPhone and iPad app requires iOS or iPadOS 26 or later. It shares the Mac
app's Swift engine and uses SwiftUI and UIKit for pairing, the launcher and
streaming. Menus work in portrait or landscape. iPhone streams use landscape;
iPad streams use their window in any orientation, including narrow windows. Both
use the same ordered choices: Native, 1080p 60 and 1080p 120. Native uses the
window's pixel size as its target and chooses the closest mode listed in
`docs/vdd/iphone-ipad.xml`. 1080p requests 1920 × 1080. All requests respect the
display's refresh limit and share the same codec, HDR and quality rules. A
connected external display can show the whole picture while the device keeps the
controls. Both support physical controllers. Disconnecting quits the game on the
PC by default. “Leave games running when you disconnect” enables continuation
for games and PCs that handle a screen-size change. Running games offer Resume
or Continue here and an explicit Quit action on both platforms.

Rotation and window resizing keep the current stream format, as iPhone does
today. Video fits the new bounds, never cropping when the aspect changes. A new
stream chooses a mode for the new window. No resize quits or relaunches the
game. The [window streaming contract](docs/IPAD_WINDOW_STREAMING.md) explains
mode selection, the 90-mode budget and PC setup requirements.

Distribution is internal TestFlight only so far, with no App Store release. tvOS
and visionOS are possible future ports.

## Capabilities and Constraints

- macOS 15.7 or later, Apple Silicon only. The platform value above is `ios`
  because the schema has no macOS value; it selects Apple HIG native guidance.
  The macOS HIG governs the Mac app; iPhone and iPad guidance (touch targets,
  tab bars, safe areas, edge swipes) governs the iOS app.
- Works against a current, unmodified Sunshine. No feature may require a patched
  PC.
- No analytics, tracking or third-party network calls. Glimmer talks only to the
  user's PC, the local network for discovery and Wake on LAN, and its update
  feed and update downloads.
- The renderer is AVSampleBufferDisplayLayer, not Metal. Fullscreen covers the
  whole screen, notch included, and supports macOS Game Mode; the player changes
  Game Mode in the system Game Overlay.
- UI copy follows the "UI and copy" rules in AGENTS.md, which are binding for
  every contributor.

## Brand Commitments

- Glimmer is free, now and always. Every feature belongs to every user.
- The name is Glimmer. The app icon (`docs/assets/icon-512.png`) is final.
- The purple accent is part of the identity; design works inside it.
- System controls only: SwiftUI and AppKit with Liquid Glass. A custom look is a
  style on a real control, never a drawn widget, and keeps native focus,
  keyboard and VoiceOver behaviour.

## Evidence on Hand

- `README.md`: features and install; `docs/assets/launcher-art-*.png`: the
  launcher art (rendered from the site); `docs/assets/launcher.png`: a real
  screenshot.
- `CHANGELOG.md`: every release as plain-language bullets.
- `docs/PROFILING.md` and per-session telemetry under `~/Library/Logs/Glimmer`
  back the tuning claims.
- There are no published benchmarks against Moonlight, no user counts and no
  testimonials. Future work must not invent them.

## Product Principles

1. Native first: when macOS has the control or behaviour, use it, and make any
   custom look a style on the real thing.
2. Design for the couch on Wi-Fi; the desk on Ethernet is the easy case.
3. Fidelity before convenience, and safeguards that recover rather than give up.
4. Handle the Mac side quietly, and say what happened in plain words when
   something needs the user.
5. The icon and the purple are the brand; everything else belongs to macOS.

## Accessibility & Inclusion

Every surface carries VoiceOver labels and full keyboard navigation, and motion
respects Reduce Motion.
