# Glimmer for iPhone and iPad

Play your PC games through a native Sunshine client with controller layouts,
touch controls, keyboard and mouse input, and the same streaming engine as
Glimmer for Mac. No accounts or tracking. Free software under [GPLv3](LICENSE).

The app is available through TestFlight beta and requires iOS or iPadOS 26 or
later. App Store availability is still ahead. See
[installation and beta access](../docs/INSTALL.md#iphone-and-ipad).

## Start playing

1. Set up [Sunshine and the mobile display modes](../docs/HOST_SETUP.md) on the
   PC.
2. Open Glimmer and pair the PC with the PIN shown in the app. If discovery
   cannot find it, use Settings › PCs › Add PC by address….
3. Connect a controller, or use the on-screen controls, then choose a game.

Settings holds paired PCs, stream quality and input preferences. The launcher
remembers the last PC and offers Buttons or Covers using artwork from the PC. To
remove a pairing, disconnect first, then choose Settings › PCs › Forget…. A
changed PC certificate requires deliberate re-pairing; it is never accepted
silently.

## Controls that fit your device

- Use physical controllers, including Backbone One, with per-game button layouts
  and remappable Stop/Stats shortcuts. Ordinary Start reaches the game
  immediately; holding Menu for two seconds and releasing opens stream controls.
- Press Circle/B or tap outside the stream menu to dismiss it. Touch, controller
  and keyboard actions remain available together.
- Edit the touch gamepad's position, size, visibility and opacity. When a
  controller is connected, choose “Show touch controls” to add a touch player.
- Use the free video area as a mouse, or connect a keyboard and pointing device.
  Three-finger tap and Control-/ open stream controls.

See [controller and touch setup](../docs/guides/CONTROLLERS.md) and
[keyboard and mouse controls](../docs/guides/KEYBOARD_MOUSE.md).

## Picture and sound

The iPhone launcher and Settings support portrait and landscape; streams use
landscape. iPad streams use the available window in either orientation,
including Split View and Stage Manager. Video fills the surface, so mismatched
PC and device aspect ratios can crop the picture. Match the PC's display modes
to the requested stream for the best result.

Hardware capabilities determine codec and HDR availability. Stereo audio,
external-display presentation and window resizing use native platform adapters.
See [display choices](../docs/guides/STREAMING.md),
[video fidelity checks](docs/VIDEO_FIDELITY.md) and
[external-display validation](docs/EXTERNAL_DISPLAYS.md) for setup and the
hardware evidence still needed. Feature availability is not a claim that every
codec, display or device combination has completed sustained testing.

## Disconnect and return

Save before disconnecting: Glimmer quits the PC game by default. Enable “Leave
games running when you disconnect” in Settings › General to keep it running.
Explicit Quit still quits the game.

Brief app switches can retain the session for up to 15 seconds with input
released. iOS may end that grace period earlier; screen lock disconnects
immediately. Returning after teardown requires a new connection.

Neither beta nor production builds record custom diagnostics. For a problem,
note the time and steps, then use [Apple logs and reports](docs/DIAGNOSTICS.md).
Review reports before sharing them and never include pairing files or PINs.

## Develop and contribute

Both clients consume the root `GlimmerEngine` source. Start with
[repository ownership](../docs/APPLE_REPOSITORY.md) and
[iOS contributing](CONTRIBUTING.md). The
[shared-engine roadmap](../docs/IOS_ENGINE_ROADMAP.md) separates implemented
features from remaining validation and future work.

Next: [pair your PC and start a stream](../docs/GETTING_STARTED.md).
