# Changelog

## 2026.10.4 - Unreleased

- Quitting while Glimmer is reconnecting ends the game on the PC, instead of
  leaving it running and asking to take it over on the next connect.
- On a remote connection, a quality step-up that doesn't hold drops back to the
  quality that worked, instead of ending the stream or waiting on “Waiting for
  video…” for up to 20 minutes.
- After a Wi-Fi dropout, a paused game or a quiet PC, the audio delay no longer
  grows from one session to the next.
- Glimmer no longer lowers the audio delay back to a level that just stuttered.
- A failure's Wake and Connect or Pair Again… acts on the PC the message names,
  even if you picked another PC while it was connecting.
- Cancelling a slow start on one PC and then streaming from another no longer
  leaves the game running on the first.
- A change the PC sends during a Wi-Fi dropout of more than a second, such as
  switching HDR on, is no longer lost.

## 2026.10.3 - 2026-10-02

- Glimmer offers its Wi-Fi stutter protection the first time it opens on every
  Mac, whatever the network, and asks again each launch until it's on or you
  decline it for good. A MacBook first opened on Ethernet used to never see it.
- The Stream menu offers the same action as the launcher and the menu bar (Back
  to Stream, Wake and Connect, Stop Waiting or Pair Again…) instead of a
  greyed-out Stream.
- While a stream is hidden, its app button reads “Back to Stream”.
- Resolutions read the way players say them (4K, 1440p, 1080p) or as their size,
  never as a Mac model name.
- The empty “Glimmer Help” menu item is gone.
- Each step of connecting gives up after ten seconds and says the PC couldn't be
  reached, instead of leaving Glimmer on “Connecting…” until you cancel.
- When a PC falls asleep mid-stream and Glimmer can't get it back, the banner
  says it couldn't reach the PC and offers Wake and Connect, instead of “ended
  unexpectedly” and Try Again.
- Every way a stream can fail to start or end on its own says the one thing to
  do next, including Sunshine stopping the stream for protected content.
- Lower quality on a weak remote link no longer lasts the rest of the session.
  Moving to another network restores full quality on the next reconnect, and
  after five clean minutes Glimmer steps back up under a short “Connection
  improved” hold.
- Frames reach the screen sooner. On a 240 Hz stream, the share of frames that
  waited more than one refresh fell from about half to under a fifth.
- A short burst of frames no longer leaves every later frame waiting an extra
  refresh.
- A damaged audio packet is smoothed over instead of leaving a gap, and one
  stray packet no longer switches off audio repair for the rest of a stream.
- The extra audio delay a stutter adds on Wi-Fi settles back down sooner.
- An idle stream no longer wakes the Mac a thousand times a second to check for
  input.
- Session logs, telemetry files and Copy in the Diagnostics log show your PC's
  address and the PC's and Mac's names as short codes, so they're safe to attach
  to an issue.

## 2026.10.2 - 2026-10-02

- Some H.264 and HEVC streams that connected but never showed a picture, then
  ended after ten seconds, now show the picture. From mehmetcansahin.
- 5.1 and 7.1 sound now starts on every supported Mac. On some, macOS refused
  Sunshine's surround layout and the sound never started. From mehmetcansahin.

## 2026.10.1 - 2026-10-02

- Glimmer is signed with Apple's current Developer ID certificate, ahead of the
  older one's retirement in February. Updates, paired PCs and the permissions
  you've granted all carry over; there's nothing to do.

## 2026.10.0 - 2026-10-01

- While your stream is hidden behind other windows, the app you're streaming
  stays violet with a TV glyph, instead of every app turning grey beside a Back
  to Stream button. Click it or press Return to go back.
- Glimmer pairs with and talks to your PC using macOS's own encryption, and
  decodes sound with macOS's own Opus, instead of bundled OpenSSL and Opus. The
  app is smaller and its security fixes arrive with macOS updates.
- Waking the Mac can no longer leave a stream stuck on a keychain prompt,
  because the keychain never comes into the connection.

## 2026.9.13 - 2026-09-28

- Open at login keeps working after a Homebrew upgrade. The upgrade removed
  Glimmer's login helper while macOS still showed it as on; Glimmer now notices
  when it opens and sets the helper up again.

## 2026.9.12 - 2026-09-28

- With Open at login on, Glimmer starts the way you set it after a restart,
  including in the menu bar only. macOS's Reopen windows when logging back in
  used to relaunch it as an ordinary app, window and all.

## 2026.9.11 - 2026-09-28

- Reconnecting no longer brings back a Stream button under your apps. The app
  that's streaming shows a spinner while Glimmer reconnects; click it or press
  Escape to end the stream.

## 2026.9.10 - 2026-09-28

- A stream started from the menu bar hides the pointer again. Closing the menu
  bar panel as the picture came up, or choosing Back to Stream in the panel,
  left the cursor showing over the stream.

## 2026.9.9 - 2026-09-28

- Smooth out Wi-Fi stutter while streaming works again after updating Glimmer
  with Homebrew. The update could leave the setting on while the part that parks
  AirDrop's radio wasn't running, so Wi-Fi streams stuttered as they started.
- After your Mac wakes or a stream ends, the PC no longer shows as Asleep for a
  moment.
- Glimmer stops checking on the PC while your displays are asleep.
- Video comes back faster after a network dropout of a few seconds.
- Turning off Smooth out Wi-Fi stutter during a stream brings AirDrop and
  Continuity back right away.
- The launcher is one sheet of frosted glass, titled with your PC's name and its
  specs underneath. With more than one PC paired, click the name to switch.
- Each app is a large violet button that streams it, so there is no separate
  Stream button to find. Return streams the app you start with.
- While a slow connection is under way, the app you clicked shows a spinner;
  click it again or press Escape to cancel.
- A button appears under the apps only when the PC needs something else first:
  Wake and Connect, Back to Stream, or Pair Again.
- Settings reads more like System Settings: the pane you read is opaque, and
  each control explains itself in one line underneath.
- The Quality presets are named for what you get: Sharpest and Balanced.
- “Fill the notch” is now “Keep picture below the camera”, off by default as
  before.
- Fixed shortcuts show their keys as plain text, and PCs get a device glyph
  instead of initials.
- The menu bar panel shows Open Glimmer instead of hiding it in a menu.
- Every in-stream shortcut defaults to two keys: ⌃Q stops streaming, ⌃I shows or
  hides stats, ⌃P captures or releases the pointer, ⌃M opens the mini player,
  and ⌃V pastes as text, in place of ⌃⌥Q, ⌃⌥S, ⌃⌥R and ⌃⌥⇧V. Shortcuts you had
  already changed stay as you set them.
- A new Stream menu holds Stream, Mini Player and Stop Streaming, and lists your
  PCs with ⌘1 to ⌘9 to switch between them.
- The launcher's toolbar holds just the Settings button.
- The menu bar panel's Stream button matches the launcher's violet, and its
  cards are titled the way macOS's own panels are.
- A stream started from the menu bar panel closes the panel as the picture comes
  up, instead of leaving it over the stream.
- Smooth out Wi-Fi stutter sits next to Bandwidth in Settings › Quality.
- Open in the menu bar only appears once Open at login is on.
- Pairing errors say to choose Pair Again… without pointing at a menu the screen
  doesn't have.
- With Reduce Motion on, banners and notices fade in instead of sliding, and
  nothing bounces.
- VoiceOver reads each app button by its name, announces a newly recorded
  shortcut, and keeps its own keys while you record one.
- The log level picker in Diagnostics shows every level again.

## 2026.9.8 - 2026-09-25

- A stream that reconnects on its own after a network drop or sleep no longer
  ends a moment later with a no-video or firewall error, and the Reconnecting
  banner stays up until the connection resumes.
- Frames rebuilt after packet loss reach the screen sooner, and a stalled
  display recovers without flashing an old frame.
- Audio comes back on its own if your speakers or headphones weren't ready when
  the stream started.
- Cancelling while Glimmer connects quits the game it started on the PC, so the
  next stream no longer asks you to take over your own session.
- Cancelling just as a stream connects no longer leaves a connection running in
  the background, and each stream frees its memory when it ends.
- Glimmer no longer quits unexpectedly when the connection to the PC drops at
  the wrong moment.
- H.264 and HEVC streams use less CPU per frame, most noticeably at 4K and high
  frame rates.
- A click made during fast mouse movement is no longer sent after movement that
  came later.
- Gyro aiming no longer stops responding after about five minutes of play.
- The light bar and player lights catch up when you return to a stream that
  changed them while you were away.
- Generic controllers no longer keep Glimmer busy when no stream is running, and
  Glimmer stops listening to them while its window and menu are closed.
- Opening the controller test in Settings no longer lets a stream in the
  background receive controller input.
- Recording a shortcut no longer swallows typing in other Glimmer windows.
- If the PC's firewall blocks port 48010, Glimmer says so in about 10 seconds
  instead of failing with a generic error after 30.
- Pairing keeps a PC's saved identity when it's interrupted, and PCs found on
  the network no longer drop out of the pairing list while it's open.
- Wake and Connect starts the stream sooner once the PC is ready, and Connect in
  a wake notification works after Glimmer has quit.
- A stream hidden behind other windows no longer keeps your Mac's display awake.
- AirDrop and Continuity come back promptly after a stream ends.
- Updates no longer download while you're streaming; Glimmer checks again when
  the stream ends.
- Turning off Open at login also removes a login item still waiting for
  approval, and a failed registration no longer switches the setting off.
- With diagnostics on, the session log records how each stream ended.
- The session summary finds the worst second more accurately, keeps drop and
  byte totals across reconnects, and no longer breaks on a PC name with
  quotation marks.
- `glimmer stream --wait` reports its own stream's result even when another
  starts right away.
- Glimmer › Install Command Line Tool… puts the `glimmer` command on your PATH
  for copies installed from the disk image. It asks for an administrator
  password once, and says so if Homebrew already installed the command.
- `glimmer list --csv` prints the paired PCs as CSV, with a Name, Address and
  Status header. Before, the flag only changed the list of a PC's apps.
- The About pane describes Sunshine as the game-streaming server on your PC and
  Moonlight as the client that inspired Glimmer.

## 2026.9.7 - 2026-09-23

- Glimmer has a command line. With the app linked as `glimmer`, you can run
  `glimmer pair`, `glimmer list`, `glimmer wake`, `glimmer quit` and
  `glimmer stream`, and each reports its result in the exit code: 0 success, 1
  failure, 2 usage, 3 unreachable, 4 not paired.
- Homebrew installs get the `glimmer` command. Existing installs pick it up with
  `brew upgrade --greedy glimmer` (or `brew reinstall --cask glimmer`), because
  the app updates itself outside Homebrew.
- `glimmer stream <pc> [<app>]` checks the PC from the terminal, then starts the
  stream in the one running Glimmer app, at the same bitrate a launcher click
  would ask for.
- For scripts, `glimmer stream` has `--wait`, `--exit-after-first-frame` and
  `--json` connect timings, and `--force` quits whatever the PC is already
  running.
- `glimmer quit <pc>` ends the app running on a PC without streaming into it. If
  this Mac is streaming from that PC, the stream stops cleanly instead of
  reconnecting and relaunching the game.
- Glimmer has Shortcuts actions for your automations: Stream from PC, Wake PC
  and Quit App on PC.
- Spotlight and Siri offer “Stream … in Glimmer” and “Wake … with Glimmer” for
  each paired PC, with its name filled in.
- Stream from PC takes an optional app name, matched without regard to case or
  accents. Left empty, it checks the PC first and streams the app the Stream
  button shows, so it picks the app the PC is running.
- Wake PC waits until the PC is ready to stream. If the PC doesn't answer, it
  says so and gives the same Tailscale hint as the launcher.
- Quit App on PC quits the app running on a PC, and if this Mac is streaming
  from that PC, the stream ends the same way Stop Streaming ends it.
- On macOS 27, if you set the controller Home button to defer to the app in
  System Settings › Game Controllers, the PS button works as Guide on the PC.
  With the default setting, the Game Overlay behaves as before.
- On macOS 27, a generic controller from Sony, Microsoft, Nintendo or Apple that
  macOS doesn't support now works, and a supported controller is no longer read
  twice.
- On macOS 27, the toolbar's PC picker and the menu bar's PCs submenu mark the
  current PC again, menu bar rows highlight under the pointer, and the round
  footer buttons keep their glass edge and hover state.
- In full screen, shake-to-find is off and, on macOS 27, so are Hot Corners.
- VoiceOver announces in-stream banners when they appear or change.
- In Settings › PCs, VoiceOver reads the default star as “Default PC” and says
  when it is selected.
- With Differentiate Without Color on, warning and critical values in Stream
  stats also turn semibold.
- In the menu bar panel, VoiceOver reads each chart as a summary of the last
  minute with Audio Graph and a per-second data table, each big number as one
  element (“Bandwidth, 62 Mbps”), and card headers in the rotor.
- A stream that never shows video ends with a reason of its own instead of the
  generic “ended unexpectedly”: no video arrived, or video arrived but couldn't
  be decoded.
- The hold banner reads “Waiting for video…”, and if it or “Reconnecting…” stays
  up for 5 seconds it adds the Stop Streaming shortcut, for example “Press ⌃⌥Q
  to stop streaming”.
- The Stop Streaming hint shows on your first three streams instead of once
  ever, and again after you change the shortcut or controller chord. A first
  frame that arrives while the window is in the background no longer uses it up.
- Banners fit narrow windows and the mini player: a long one shortens with an
  ellipsis instead of losing both ends.
- While a stream connects, the pointer and the menu bar stay yours. Clicks reach
  Cancel, and the cursor is only centred, hidden and captured once the first
  frame fades in.
- Switching to another app while a stream connects is respected: Glimmer no
  longer pulls you back 1.5 seconds later.
- A stream that ends just after its first frame no longer leaves the launcher
  without a menu bar or Dock.
- Connects and in-place reconnects are about 50 ms faster, and the first frame
  no longer waits for audio setup.
- Cancel or Quit during the connection handshake takes effect immediately
  instead of locking out new streams for up to 30 seconds.
- Stopping a stream during the handshake with the Stop Streaming shortcut or the
  window's close button works like Cancel: no “Couldn't reach” banner, no
  “Stream ended” toast, and the PC list keeps its order and ⌘ shortcuts.
- Esc cancels a connection that hasn't started streaming yet. Once the stream is
  live, Esc goes to the game as before, including during a reconnect.
- A connection that fails before the stream starts, for example to a sleeping or
  unpaired PC or after Cancel, stops probing the PC right away instead of
  opening connections to it in a loop.
- Quitting the game on your PC, pressing Force Stop in Sunshine, or another
  device taking over ends the stream cleanly, and Glimmer no longer relaunches
  the app or takes the session back.
- Quitting a stream over a dead connection closes the stream window and brings
  back the pointer right away, instead of leaving a frozen frame on screen for
  up to 5 seconds.
- Keys and modifiers you're still holding when you quit are released on the PC
  before the connection closes.
- A stream that drops just before the Mac goes to sleep reconnects on wake
  instead of ending as unexpected, because the 30 second reconnect window only
  counts time the Mac is awake.
- Unplugging a dock or Ethernet mid-stream starts the reconnect right away
  instead of freezing for about 10 seconds.
- A reconnect that comes back no longer leaves a red banner behind.
- Streams over a VPN, and streams started before Glimmer has worked out the
  route to the PC, ask for the same bitrate as in 2026.9.5.
- The Wi-Fi 1.5x boost applies only when the route really is Wi-Fi, where the
  check on the radio's link rate can still trim it.
- A reconnect after a route change or a wake asks for the bitrate that fits the
  current connection, never more than an earlier quality drop allowed, and
  Stream stats shows the new rate.
- Changing the preset, the custom size or Bandwidth in Settings during a stream
  applies to the next stream, as the pane says, not to a reconnect.
- Video recovers by itself after a decode error, and a decoder that stops
  producing frames is rebuilt within a few seconds. Before, the stream could sit
  on “Holding…” until you reconnected.
- Requests for a fresh keyframe or recovery frame after packet loss leave at
  once instead of waiting up to 20 ms.
- When a PC's Sunshine settings limit the video packet size, the picture no
  longer breaks up at the moment error correction should have saved it.
- At 120 fps on a 120 Hz display, the stream no longer carries about five frames
  of extra latency for half a second after a network hiccup.
- The burst of frames at the end of a network drought is no longer mistaken for
  a frozen picture, which removes needless recoveries after Wi-Fi gaps.
- When the frame-rate assist is covering for a throttled display, it no longer
  hands the renderer a second frame inside the same refresh.
- If the stream reconnects while its window is hidden, for example after the Mac
  sleeps and wakes, Glimmer stops decoding video again after 2 seconds. Before,
  it could decode every frame for hours with nothing on screen, even on battery.
- On remote connections, lowering quality responds when the path can't carry the
  bitrate, and its banner reads “Weak connection. Lowering quality to N Mbps…”.
- On Wi-Fi, Glimmer no longer stalls for about 13 ms every second, while idle
  and while streaming.
- Switching output devices no longer sets off a burst of audio errors left
  behind by every earlier stream.
- Unplugging a dock, handing AirPods off or losing HDMI mid-stream can no longer
  crash Glimmer while the audio restarts.
- With 5.1 or 7.1 surround, each channel plays from its own speaker. Before,
  sounds went to the wrong speakers and most of the rear and side channels ended
  up in the subwoofer.
- After a long dropout, audio no longer ends up about 200 ms behind video, and a
  burst of dropouts adds at most one step of audio delay.
- Audio clock correction settles on the real clock difference, and each output
  device's correction is remembered separately, so switching speakers no longer
  starts the next stream with the wrong one.
- Mute this Mac while streaming is now Play sound on the PC, and does just that:
  the PC keeps the game's sound and only the stream is silent on the Mac.
- Play sound on the PC no longer changes the Mac's system volume or silences
  other apps, and flipping it mid-stream changes nothing until your next stream.
- Coming back from the mini player re-centres the cursor when it was left on
  another display, so clicks can't land outside the stream.
- A daily update check no longer shows its alert over a live stream or takes
  focus from the game; the alert waits until the stream ends. Checks you start
  yourself, and checks with no stream running, behave as before.
- The updater is now Sparkle 2.10.0. The update window comes to the front when
  you check for updates from the menu bar with the main window closed, and the
  installer moves the downloaded archive more safely.
- Glimmer no longer logs an update-check fault at launch when the daily check is
  already running.
- Glimmer no longer crashes when a stream's frame index wraps past zero.
- A trackpad or Magic Mouse scroll adds up its fractions and sends whole wheel
  notches, so games that count whole notches no longer ignore it.
- A mouse wheel's scroll goes to the PC exactly as macOS reports it, so small
  wheel movements are no longer lost or carried into the next scroll.
- With telemetry on, every wheel event is in the trace with what macOS delivered
  and what was sent, so a wheel that a game ignores can be shown to have reached
  the PC.
- Gyro and motion aiming reach the PC as soon as the controller reports them.
  Samples arrive evenly spaced and up to 10 ms fresher, and the Mac no longer
  wakes 200 times a second to poll.
- A controller that stays connected through a reconnect keeps its place on the
  PC, so the game doesn't see it unplug.
- Unplugging or swapping a controller while Glimmer reconnects no longer leaves
  a phantom controller on the PC, and a different controller that takes the same
  place shows up as the right kind.
- Glimmer offers the PC rumble only for controllers the Mac can actually rumble.
- The Input Monitoring prompt for a generic controller no longer comes back
  every time the controller reconnects: any answer quiets it for that controller
  until Glimmer relaunches.
- Granting access from Glimmer's own prompt turns on Extra DualSense buttons
  with no relaunch, and the PC then knows a DualSense has a Mute button.
- Turning Extra DualSense buttons on by hand in System Settings still needs a
  relaunch, as the instructions now say.
- The “use this controller” prompt for an unrecognized gamepad has a Don't Ask
  Again option.
- Both DualSense prompts, in the launcher and in Settings, read “Turn on Extra
  DualSense buttons?” with a Turn On button.
- “Use ⌘ shortcuts inside the game” does what it says. While the stream has the
  pointer, ⌘-Tab, ⌘-Space, ⌘Q and the rest go to the PC instead of the Mac, and
  ⌘-Tab no longer opens the Start menu on the PC.
- If macOS Zoom's shortcuts are turned off, ⌥⌘8, ⌥⌘= and ⌥⌘- reach the PC too.
- On UK and other ISO Mac keyboards, the key left of 1 and the key next to left
  Shift type the right characters.
- A PC keyboard's Insert, Print Screen, Scroll Lock, Pause and Menu keys reach
  the PC, so Win+Print Screen and Game Bar captures work.
- As in Moonlight, the F13, F14 and F15 keys on Apple keyboards send Print
  Screen, Scroll Lock and Pause.
- Japanese keyboards can type ¥, ろ and the keypad comma, and
  the 英数 and かな keys reach the PC.
- Caps Lock on the PC follows the Mac every time you press it, and games that
  bind Caps Lock no longer see it held down.
- A Shift or Ctrl held through a reconnect or sleep works with the next key, and
  a key released while reconnecting no longer stays stuck.
- Glimmer's own shortcuts, including Stop Streaming (⌃⌥Q), work on Russian,
  Greek, Hebrew, Arabic and other non-Latin keyboard layouts.
- Edit › Paste, ⌘V (whenever ⌘ stays with the Mac) or ⌃⌥⇧V types the Mac
  clipboard on the PC as characters, so passwords, links, codes and accented
  text arrive as written.
- HDR has its own switch in Settings › Quality, on by default, for every preset,
  so you can pick SDR and still use Native Retina or HiDPI. Turning it off
  really makes the PC send SDR.
- The “Your next stream” summary shows HDR only when HDR is on and the display
  can show it.
- The pairing sheet names the PC instead of showing its IP address, including
  when you choose Pair Again… for a saved PC.
- Pairing tells you to open Sunshine's web page and choose PIN, and can open
  that page on this Mac.
- Pairing waits up to five minutes for the code. A timeout, including a request
  the PC let expire, gets its own message apart from a rejected code, and Try
  Again appears only after a failure and gives you a new code.
- If the PC is still holding an earlier pairing request, pairing says so and
  explains how to clear it, instead of saying the PC didn't accept the code.
- Pairing a new PC no longer closes the sheet the instant the PIN is accepted,
  so the checkmark and “Stream now” screen show as intended.
- When the PC won't accept this Mac, the message also says this Mac may be
  switched off on Sunshine's Troubleshooting page, and Pair Again… fixes both
  cases.
- A PC still running NVIDIA GameStream is spotted as soon as you pair with it or
  stream from it, and Glimmer says it needs Sunshine on that PC instead of
  failing partway through connecting.
- You can paste Sunshine's web address into the address field when adding a PC:
  the scheme, port and path are removed, and Continue stays off until the
  address is valid.
- Discovery prefers a PC's IPv4 address and no longer lists link-local addresses
  that stop working when the Mac changes networks.
- If macOS has blocked Local Network access, the PC chooser says so and has a
  button that opens the setting. If the search finds nothing, it links to the PC
  setup guide.
- A device on your network can no longer skip pairing or plant its own
  certificate. Glimmer always runs the PIN handshake and refuses secure requests
  to a PC that has no pinned certificate.
- Replies from the PC are capped at 4 MiB and stopped at their deadline, so a
  slow or oversized reply can't tie up the app, and a reply with an empty length
  header no longer crashes Glimmer.
- Stream audio is encrypted whenever the PC offers it, which Sunshine does by
  default, and the stream's setup messages with the PC are encrypted too.
- Glimmer streams from a PC whose Sunshine encryption setting is Mandatory: the
  video arrives encrypted and plays normally, where before the stream failed
  with a misleading “Couldn't reach”.
- The security notes describe what the app does: audio is encrypted whenever the
  PC offers it, video only when the PC requires it, and any process running as
  you can read the pairing key.
- Games added or renamed in Sunshine show up without pairing again. Glimmer
  refreshes a PC's app list when it first reaches the PC after you switch to
  Glimmer, and when the PC runs an app Glimmer hasn't seen.
- When a PC gets a new address on your network, Glimmer finds it and confirms
  it's the same PC before saving the new address. Before, it showed as Asleep
  for good.
- A PC that also answers on a second network interface keeps the address it was
  paired at.
- While the launcher window is closed, Glimmer checks the PC every 20 seconds
  instead of every 10.
- Wake on LAN also sends to Sunshine's streaming ports, as Moonlight does.
- When a wake fails, the launcher and the menu bar say why in one line that
  fits, either no answer from the PC or “Couldn't send the wake signal. Check
  this Mac's network.”, and hovering over it shows the Wake on LAN limits.
- A wake that couldn't be sent no longer blames Tailscale, and says so at once
  instead of after 90 seconds.
- While Glimmer waits for a PC to wake, the Stream button reads Stop Waiting.
  Stopping a wake and clicking Wake and Connect again while the first is still
  sending no longer loses the waiting state.
- If you switch to another app while a PC wakes, Glimmer posts a notification
  with Connect or Try Again instead of opening the stream over that app. With
  Glimmer's notifications off or set to None, the stream opens as before.
- The launcher's PC card shows its readiness chip again (Asleep, Trust needed,
  Ready with round-trip time), missing since 2026.9.5. Its re-pair control for a
  changed certificate is a real button that keyboard and VoiceOver can reach.
- For a PC busy with an app, the chip shows the app's name and “running” (or
  “App running” when the app isn't in Glimmer's list) in a neutral color instead
  of a blue “Streaming”, since the PC can't tell whether anyone is watching.
- Unpairing the selected PC shows the next PC's status straight away, and the
  footer's PC-version note and the chip no longer show a removed PC's details.
- Switching PCs from the menu bar with the launcher closed uses that PC's own
  wired or Wi-Fi bitrate.
- A failed connection offers the matching fix: Wake and Connect when the PC is
  genuinely unreachable and has Wake on LAN set up, Pair Again… for a pairing or
  certificate problem, and Try Again otherwise.
- A failure after the PC started the app offers Try Again instead of Wake and
  Connect, and a PC with “cert” in its name or address no longer gets Pair
  Again… for a failure unrelated to its certificate.
- A stream port blocked by the PC's firewall is named, for example “Tower
  answered, but the stream couldn't get through. Check that the PC's firewall
  allows UDP 47999.”
- A slow launch says the PC took too long to start the app, an error from the PC
  shows Sunshine's own message, and a stream that lost its connection says “Lost
  the connection to Tower.”
- The message for a PC whose secure port is stuck no longer ends with transport
  jargon.
- Starting a stream that would end a running app on the PC asks with the app and
  PC in the title, says the app will quit, and offers one destructive Quit and
  Stream button, instead of a generic “Take over the stream?”.
- During a reconnect, the Stream button and the menu bar read “Reconnecting to”
  the PC on one line until the stream is back, instead of switching to
  “Connecting to” as soon as the reconnect began.
- While the stream is in the background, the Stream button's tooltip says it
  shows the stream window, and the app items in its right-click menu keep their
  icons.
- While a PC is running an app, the PC menu has an item that quits it, named for
  the app and the PC. If the PC refuses, the message is the same one
  `glimmer quit` prints.
- You can't unpair or re-pair the PC you're streaming from.
- When the PC hasn't reported a network address, the Wake on LAN switch says so
  in its title, and the unpair message names the PC.
- The menu bar panel's PC card uses the launcher's status pill (Ready, Asleep,
  Trust needed, Checking… and the rest).
- The menu bar panel's button follows the PC: Wake and Connect for a sleeping
  PC, Waking… with Stop Waiting, Pair Again… for a PC whose certificate changed,
  and Stream otherwise.
- Pair a PC… and Pair Again… in the menu bar panel open the pair sheet in the
  main window.
- While a stream reconnects, the menu bar panel offers Stop Streaming, not
  Cancel Connection, and its attention card offers Try Again only when a launch
  could work, and can be dismissed.
- The menu bar panel's Controller card lists every pad the Mac sees, including
  raw-HID pads and pads with no battery reading (shown as Connected), and shows
  charging for each pad.
- The menu bar panel's bandwidth chart is scaled to the bitrate the session
  actually asked for, and the frames chart to the session's frame rate.
- A stream started from the menu bar, or Settings opened from the gear, gets a
  Dock icon and a ⌘-Tab entry, so you can switch back to it after switching
  away.
- Each PC tile in Settings › PCs has a ⋯ button with the same Rename, Codec,
  Wake on LAN and Unpair items as its right-click menu.
- The Refresh paired PCs button is gone, since it did nothing you could see.
- The shortcut recorder no longer accepts ⇧ alone, ⌘ with Q, W, H or M, or a
  shortcut already in use; it says why under the badge and waits for another
  try.
- A controller chord needs at least two buttons.
- If you pick a chord that a DualSense can only fire with Extra DualSense
  buttons, such as the Moonlight default or a custom chord with Create or Mute,
  an orange note under the picker says so and has a Turn On button.
- Open at login follows System Settings: removing Glimmer from System Settings ›
  General › Login Items turns it off instead of Glimmer adding itself back at
  the next launch. After an update or a move, the login item is still repaired.
- The login toggles are called Open at login and Open in the menu bar only.
- Settings use one set of names: Stop Streaming for the shortcut and the
  controller chord, Stream stats for the overlay, PC throughout, and Title Case
  buttons.
- Glimmer no longer deletes login-keychain items labelled “Imported Private Key”
  on first launch. macOS gives many imported certificates that label, so the old
  cleanup could remove a VPN, Wi-Fi (802.1X) or S/MIME identity.
- The cleanup of Glimmer's own old keychain item runs once instead of on every
  launch.
- Wi-Fi stutter protection only lets apps that pass macOS's code-signing check
  connect to it, so another app connecting and then quitting can no longer turn
  AirDrop back on mid-stream.
- Wi-Fi stutter protection no longer repeats the same line in the session log
  every 5 seconds.
- With diagnostics on, key codes, your PC's address and name, your display's
  name and error details stay out of the system log. The log in Settings ›
  Diagnostics still shows them in full.
- Telemetry splits late presents by cause: the game's own uneven frame delivery,
  with its typical and 95th-percentile frame interval and how often neighbouring
  frames were uneven, and the pacer's share.
- The input-to-photon estimate adds the input's own legs on the Mac, half the
  round trip to the PC and half a game frame on top of glass-to-glass, so the
  two are no longer the same number.
- Telemetry records whether AirDrop's radio was parked and how many packets the
  Mac dropped at a full socket buffer, so a Wi-Fi blackout can be traced to its
  cause.
- Diagnostics no longer treat a sleeping or undocked stream as a bad Wi-Fi link.
- Frames dropped while waiting for a keyframe or recovery frame are counted, and
  frames dropped while the window was hidden no longer count against the pacer.
- Loss recoveries, long video gaps and keyframe arrivals are logged once each as
  an event instead of one line per discarded frame, and the receipt adds how
  long each recovery took.
- Telemetry records the stream's resolution, frame rate and codec, and how the
  bitrate was chosen: the Bandwidth setting, the quality dial, the codec and
  route multipliers and the Wi-Fi rate cap.
- Session receipts cover a whole session across an in-place reconnect, keeping
  the totals from before it and listing the reconnect's steps separately.
- A session that never received audio says so in its receipt, and a mid-stream
  audio blackout shows as 0 audio packets per second, with the longest audio gap
  in each second.
- When the PC never starts sending audio, the log keeps saying so at 30 seconds
  and every 10 minutes after that, not just once at 3 seconds.
- The A/V skew meter no longer reports about 300 ms of audio lag that wasn't
  there after an audio under-run or a keyframe recovery.
- Glimmer deletes log files older than 14 days at launch, with diagnostics off
  too. Over the size budget, per-frame traces go first, and diagnostic logs and
  session receipts are only ever deleted for age.
- In a long session, the per-frame trace keeps the connect segment (first frame,
  pacer lock-in and early loss) along with the newest segments.
- Input trace lines are no longer built when telemetry is off, and gyro and
  accelerometer lines are capped at 20 per second per sensor. What is sent to
  the PC is unchanged.
- With telemetry on, a ⌃B bookmark also lands in the per-frame trace, on the
  same clock as the input rows, so you can read what was sent just before it.
- Package power no longer reads 0 W on ticks where the energy counters hadn't
  updated, and the main thread has its own line in the per-thread CPU data.
- The launcher's PC reachability check no longer logs an “already cancelled”
  network fault every 10 seconds.
- Turning diagnostics off after a session no longer leaves the adaptive jitter
  buffer stuck at that session's last level until relaunch.
- The README has a Command line section with the exit codes and a table
  comparing Glimmer's commands to Moonlight's. It also says any HID gamepad
  works and calls the controller chord Hold-to-stop.
- The profiling guide covers the actual log retention rule (a 14-day age limit
  at launch and a 300 MB budget at each diagnostics session), a recipe for
  capturing short Wi-Fi freezes, and the defaults that have no Settings row.

## 2026.9.6 - 2026-09-20

- Leaving the mini player no longer moves your aim. Returning to full screen
  used to re-centre the pointer while the game was listening, which reached the
  PC as one large mouse movement.
- Every frame gets more bits by default, which means less grain. A new Bandwidth
  switch in Settings › Quality chooses between Highest quality, the default, and
  Bandwidth saver, which keeps the previous bitrate.
- On Wi-Fi, Glimmer asks for half as much again under the same cap, held to a
  share of what the radio is actually doing, so a weak or crowded link gets a
  smaller ask before the stream starts rather than dropped frames after.
- On a wired route, Glimmer asks for twice as much under a higher cap, and takes
  the extra back off if a round trip of 2 ms or more shows a Wi-Fi hop somewhere
  on the path.
- The bitrate on the launcher and in Settings follows the route. The gain is per
  frame: average bandwidth barely moves on a game that runs below the requested
  refresh.
- With telemetry on, every mouse movement, pointer position, controller state
  and motion sample sent to the PC is recorded with a timestamp, so a jump you
  didn't make can be traced or ruled out.

## 2026.9.5 - 2026-09-19

- Wake on LAN is built in. When a PC is asleep, the Stream button and the menu
  bar row become Wake and Connect: Glimmer sends the wake packets itself, waits
  for Sunshine to answer and connects.
- Wake on LAN is on for each PC by default and can be turned off in the PC's
  right-click menu. It works on your home network; over a VPN it depends on your
  router forwarding wake packets, and over Tailscale it can't reach the PC.
- The old power controls that needed a separate tool are gone.
- A mini player keeps a queue, a loading screen or an idle game in view while
  you use the Mac. Press ⌃M during a stream (or choose Mini Player in the menu
  bar) and the stream shrinks to a small window that floats over everything,
  including other apps' full-screen Spaces.
- The mini player opens a quarter of the screen wide in the bottom-right corner,
  remembers where you drag it, and keeps the picture's aspect as you resize it.
- The mini player takes your mouse only when you click it, and holding Esc gives
  it back. The keyboard reaches the game while the mini player is the active
  window.
- Press ⌃M again, choose Back to Stream, or double-click the mini player's top
  edge to return to full screen or your window, whichever you had. The chord can
  be changed in Settings › Shortcuts.
- The mini player's close button, shown when the pointer rests on it, ends the
  stream like the window's red button.
- Hall-effect keyboards with an analog mode no longer pass for a gamepad. Every
  keypress used to drive a phantom Xbox 360 controller, and games flipped their
  button glyphs between Xbox and PlayStation.

## 2026.9.4 - 2026-09-19

- Any HID gamepad now works, like the 8BitDo Ultimate 2C over Bluetooth, not
  only the Xbox, PlayStation, Switch and MFi pads macOS recognises. Glimmer
  reads them with the community mappings Moonlight relies on.
- Those pads get rumble where the hardware offers force feedback, battery level
  where it's reported, the quit chord and a live readout in Settings ›
  Diagnostics.
- A pad that needs the Input Monitoring permission is explained in the launcher
  before macOS asks, never in the middle of a stream.
- Two DualSenses keep their own buttons, battery readings, lights and trigger
  effects. A face-button press matches the pads up when needed; one pad still
  works straight away.
- The mouse keeps your Tracking Speed. “Raw aim” used to throw it away, so
  streams ran at roughly a quarter of desktop sensitivity, and a crash could
  leave the desktop that way.
- Linear scaling, the new default, uses macOS's own scaling: no acceleration
  curve in the game, your speed unchanged, and restored the moment you leave.
  Settings › Input switches between it and Mouse acceleration.
- The menu bar item is now a panel. While streaming it shows bandwidth, latency
  and frames per second over a one-minute chart; hover to read any second back.
- The streaming panel also shows the mode you asked for, Back to Stream, Stop
  Streaming and a stats-overlay switch.
- When you're not streaming, the menu bar panel shows the selected PC with its
  readiness, a Stream button, the PC's apps and PCs one level down, and Wake and
  Connect for an asleep PC where luna is set up.
- The menu bar panel shows each controller's name and a battery bar.
- The menu bar icon reads idle, connecting, reconnecting, streaming or needs
  attention, and attention opens to the reason and a Try Again.
- The main Stream button launches the Default action from Settings, the same as
  the menu bar. An app the PC is already running still wins, and Retry repeats
  the exact launch that failed.
- Your Mac pairs under its own name. Sunshine's pairing page used to list every
  Glimmer as “roth” with one fixed id; now each install sends its computer name
  and its own id.
- PCs running GeForce Experience still get the shared id they depend on.
- When a PC opens fewer control channels than Glimmer asks for, controller and
  sensor input falls back to the shared channel, the way Moonlight does, instead
  of going to a channel that was never opened.
- Controllers show their player indicator lights: Sunshine 2026.906 and later
  says which player each pad is, and Glimmer sets it.
- Holding both Shifts (or both Controls, or both Options) and letting go of one
  no longer leaves the other stuck on the PC, and losing focus releases exactly
  the sides that were held.
- A key held from before you pressed ⌘ is released when you let go of it.
- Two crashes on the second stream since opening Glimmer are gone.
- Clicking back into a stream no longer leaves the Mac's pointer drawn over the
  game.
- Cancelling a connection can no longer launch the game afterwards.
- Quitting while a stream is shutting down waits for it to finish instead of
  exiting past it.
- A reconnect keeps to its 30 second window on every request.
- Glimmer asks before taking over a PC that's streaming anything, a known app or
  not.
- Pairing results can only land on the PC that started them.
- Opening the chord recorder or Diagnostics no longer takes the controller away
  from a live stream.
- Muting the Mac remembers which output it silenced and puts that one back, also
  after a crash.
- AirDrop's radio can no longer be left parked after a stream ends.
- HDR metadata updates reach the decoder as one complete set.
- When the Mac's Wi-Fi roams to another access point, or drops and comes back,
  during a stream, the session log says so in plain words, so a hitch that lines
  up with it explains itself.

## 2026.9.3 - 2026-09-14

- Fixes a crash after a stream ended, if you had visited the Custom resolution
  fields in Settings.
- The Custom resolution fields never rewrite what you're typing. They hand
  Settings a number only once it's complete and in range.

## 2026.9.2 - 2026-09-13

- Remote streams are judged by the path, not by the moment you pressed Play. The
  connect-time latency check samples on an idle PC before your game launches,
  instead of while the PC is busy launching it.
- A 10 ms fiber hop used to read as 76 ms and get 28 Mbps instead of 80. Three
  quarters of the samples now have to agree before anything is trimmed, so a
  post-wake stall or a few Wi-Fi spikes can't cap a session.
- Paths under 20 ms get the full rate.
- Ten seconds into every stream, the log grades that verdict against what the
  stream itself measures.

## 2026.9.1 - 2026-09-13

- Command chords no longer leave a key held on the PC. Command-D (Win-D on the
  PC) used to leave the PC typing d until the key was pressed again. This only
  affected streams with “capture system keys” on.
- Typing a custom resolution works again. A height that began with 1 no longer
  becomes 480 before you finish: the limits apply when you leave the field.
- Watch stream's health shows from the first frame, instead of only after two
  presses of the hotkey.

## 2026.9.0 - 2026-09-10

- You can stream in a window: pick the Custom preset in Settings › Quality and
  set “Show the stream” to Window. It opens at your Custom resolution,
  pixel-mapped on Retina panels, with the menu bar and Dock left alone.
- The stream window can be dragged, resized (the picture scales, it never
  letterboxes) and sent full screen with the green button. Refresh is capped at
  what your display can show, and the window remembers where you left it.
- Native Retina and HiDPI stay full screen, unchanged.
- Moving the pointer onto the stream window hands your mouse to the game.
  Holding Esc takes it back with the cursor where it left off, while a tap of
  Esc still reaches the game's own menu.
- Switching apps hands the mouse back too, and moving onto the window takes it
  again. Control-Option-R does either without moving the mouse, and closing the
  window ends the stream.
- Custom no longer asks you to set a bitrate. It uses the measured
  recommendation the pane used to print, following your resolution and refresh
  (in a window, the refresh your display can show).
- On a 14-inch MacBook Pro at 120 Hz, Custom asks for about 85 Mbps where the
  old automatic setting asked for 100. What it landed on is still under Your
  next stream.
- The size shortcut beside the resolution fields is a labelled Presets button,
  from 720p upward.
- Fill the notch only appears on Macs that have a notch.
- Leaving a macOS full-screen space through Mission Control lands you in a
  window, instead of leaving the picture nowhere while the stream kept running.
- Quitting Glimmer mid-stream waits briefly for the PC to be told the session is
  over, so Sunshine never keeps a phantom session that blocks your next launch.

## 2026.8.18 - 2026-09-02

- Glimmer no longer checks on your PC while the Mac is going to sleep. A check
  cut off by sleep could leave Sunshine refusing every connection until it was
  restarted (any app can trigger this in Sunshine).
- The launcher's ten-second readiness checks stop the moment the Mac goes to
  sleep and start again on wake with a fresh check.

## 2026.8.17 - 2026-09-02

- Glimmer stops telling you to pair again when the problem is on the PC. When
  Sunshine stops accepting secure connections, Glimmer says so, names the fix
  (restart Sunshine on the PC) and notes that quitting Glimmer won't help.
- An authorization error or a rejected certificate still means pair again, and a
  changed PC certificate still points at the amber “Trust needed” chip.

## 2026.8.16 - 2026-08-30

- Fixes a crash at the end of a stream when diagnostics are turned on.
  Diagnostics stay off by default, and nothing else changes.

## 2026.8.15 - 2026-08-30

- The controller quit chord Start + Select + L1 + R1 fires on a DualSense.
  Glimmer turns off macOS's screen-recording gesture on the Create button when
  the pad attaches, which was holding the press back.
- When a quit chord arms, cancels or only partly matches, the session log says
  so, so a chord that doesn't fire can be diagnosed.
- The Settings footnote now says the default is L3 + R3 rather than off.
- Pairing a second PC works again. The Pair window starts fresh every time you
  open it, instead of showing the last “Paired” screen with a blank PC name and
  no way back to the list.
- Before macOS asks for local network permission, the Pair window says what
  Glimmer is looking for and that the system will ask.
- Glimmer no longer takes anything away from Moonlight. It used to erase the
  client identity it copied from moonlight-qt, so Moonlight lost every PC it had
  paired with.
- Glimmer still copies Moonlight's identity on first launch so you don't have to
  pair again, but never writes Moonlight's settings, so both apps stay paired.
- If you had chosen Smooth or Maximum, Glimmer no longer forgets it: Smooth
  becomes HiDPI and Maximum becomes Native Retina. It used to fall back to
  Native Retina, the most bandwidth-hungry, and overwrite your saved choice.
- Your preset is only saved when you change it, and the Custom preset is filled
  in when you switch to it rather than on first launch.
- Turning off automatic update checks sticks. They're still on by default.
- The update window shows release notes with each update instead of a blank
  panel.
- A PC that's taking too long to wake is no longer a dead end: the “Waking”
  button offers Cancel (Esc works too) and gives you the launcher back at once.
  Your PC may still finish waking on its own.
- The certificate mismatch error points at the amber “Trust needed” badge
  instead of a menu that doesn't exist.
- The menu bar no longer claims to be connected to a PC it's only pointing at.
- The DualSense buttons offer has a “Not Now” that means not now.
- The error banner can be dismissed.
- Get Info on the app says GPL rather than “All rights reserved”.
- Glimmer can be installed with Homebrew:
  `brew install --cask se7enbrc/glimmer/glimmer`.
- The download disk image looks like one.

## 2026.8.14 - 2026-08-26

- Switching audio devices mid-stream (AirPods in or out, unplugging HDMI audio)
  no longer counts as a bad connection. Each switch used to deepen that PC's
  audio buffer, so audio delay crept up across sessions.
- A stream that connects but never shows a picture gets the same ten-second
  recovery as any other, instead of sitting on a black screen until you cancel.
- A clock change mid-stream, from a network time sync or daylight saving, can no
  longer pass for a real stall or hide one.
- Glimmer checks for updates at startup and once a day while running, not only
  when you open it, and tells you when a release is waiting. You can turn the
  automatic check off in the update window.

## 2026.8.13 - 2026-08-26

- PCs added by name instead of IP address stream now. A Tailscale MagicDNS name,
  a local DNS record or any name that resolves used to pair and connect, then
  die the instant the stream started.
- Names work everywhere an IP address does, and a name that doesn't resolve
  fails at once with an error that says exactly that.
- Thanks to the excellent diagnosis in issue #70, which found the cause down to
  the line.

## 2026.8.12 - 2026-08-21

- A rare crash is gone. After days of running, Glimmer could crash in the
  background, not while streaming, typically minutes after the Mac woke from
  sleep.

## 2026.8.11 - 2026-08-18

- Glimmer no longer crashes about nine seconds after the Mac wakes from sleeping
  mid-stream. If sound can't start yet, Glimmer stays quiet and keeps trying
  until the audio hardware is back: a moment of silence instead of a crash.
- Every other way audio can refuse to start is handled the same way.

## 2026.8.10 - 2026-08-17

- Two ways a stream could freeze until you reconnected are gone: one after a
  rough patch, one when the Mac's video decoder hung. Both now recover on their
  own within a couple of seconds.
- Removing a paired PC no longer leaves its Wake on LAN address behind, so a PC
  paired afterward can't inherit the old one's wake, sleep and shutdown buttons.

## 2026.8.9 - 2026-08-17

- The stutter in a Wi-Fi stream's first 30 seconds is gone. On a strong 6GHz
  connection, that half minute used to bring 36 freezes of a tenth of a second
  or more, then none at all.
- Glimmer keeps the Mac's Wi-Fi radio awake for the first 90 seconds of every
  Wi-Fi stream, at the cost of a trickle of tiny keepalive packets. Wired
  connections are unaffected.

## 2026.8.8 - 2026-08-17

- Your desktop mouse can no longer lose its acceleration to a stream. However a
  session ends, even with two copies of Glimmer running or a crash, the desktop
  gets back the curve you had.
- Glimmer turns acceleration off while a stream is focused. Before, a bad
  restore could leave the desktop without it, across relaunches, until you fixed
  it in System Settings.

## 2026.8.7 - 2026-08-12

- Audio survives a stream left alone. A stream left running overnight on an idle
  PC used to come back with no sound until you reconnected; now sound returns
  within a few seconds, after one brief blip.
- After a long silence, the audio delay settles back to normal instead of
  staying deep.

## 2026.8.6 - 2026-08-04

- High-refresh streams get a sharper picture. Each frame used to get about 30%
  fewer bits every time the frame rate doubled, so 240Hz looked blockier than
  120Hz at the same resolution.
- 4K240 gives each frame the same budget as 4K120, and 120Hz modes gain a little
  too. Anything at 60Hz or below is unchanged.
- On a 4K240 HDR stream, each frame went from about 46 KB to 72 KB, with no
  added latency and no dropped packets.
- High-refresh streams ask your PC for more bandwidth. On a local network that
  costs nothing; over a VPN or the internet Glimmer still measures the
  connection first and asks for what it can carry.

## 2026.8.5 - 2026-08-02

- You can browse your PC's apps while a stream is running again. The dropdown
  for apps beyond the first five opens mid-session; only launching is held back.
- Screen readers get a proper description of the apps dropdown.

## 2026.8.4 - 2026-08-02

- The launcher has proper breathing room around the PC card again, and stays a
  fixed size.
- Apps beyond the first five live in a dropdown at the end of the row instead of
  only in the Stream button's context menu. It opens over the window, so
  reaching a sixth app no longer resizes anything.
- App tiles respond across their whole area, not only where the icon sits.

## 2026.8.3 - 2026-08-02

- Streaming over a VPN such as Tailscale or WireGuard is far more reliable.
  Glimmer sizes video packets to fit the route to your PC; packets sized for a
  local network once froze a captured session's picture for fifteen minutes.
- Before a stream starts, Glimmer measures round trips to your PC, the slow tail
  that causes stutter, and on a distant or congested path asks for a bitrate the
  path can carry. If the measurement fails, nothing is capped.
- A remote connection that can't carry the stream lowers quality and reconnects
  in place instead of holding a frozen frame: a brief pause, a note that quality
  is being reduced, then the picture returns.
- Quality steps down at most twice, never on a local network, and never goes
  back up on its own.
- Streaming on a local network is unchanged.
- The launcher window is exactly as big as what's in it, and no longer
  resizable.

## 2026.7.7 - 2026-07-22

- When UpSnap manages your PC and the `luna` tool is set up on your Mac, the
  PC's card shows power controls. While the PC sleeps, the stream button becomes
  “Wake & Connect”: it wakes the PC, confirms it woke, waits for Sunshine and
  starts your stream.
- A power menu in the corner of the card offers Wake and, while the PC is
  online, Sleep, Restart and Shut Down, each behind a confirmation.
- Without `luna`, or for a PC UpSnap hasn't granted you, nothing appears: no
  buttons and no settings.
- Glimmer never touches your UpSnap credentials. It recognises the PC by its
  hardware address, learned automatically while the PC is online.
- A sleeping PC reads Asleep after one missed check (about two seconds) instead
  of sitting on “Checking…” for half a minute. A PC that briefly stops answering
  while online still gets the benefit of the doubt.

## 2026.7.6 - 2026-07-22

- The audio cushion remembers what it learned about each connection for days
  instead of about six hours, so a stream after a day away no longer opens with
  several small sound blips across the first minute.
- The audio cushion starts no shallower than the live connection needs, and the
  opening minute no longer teaches it bad long-term habits.
- Diagnostics measure how late every out-of-order Wi-Fi packet arrives and count
  the only kind worth worrying about: one that missed the window the stream
  holds open for it.

## 2026.7.5 - 2026-07-19

- Click-and-drag aim travels the same as free aim. The macOS 27 beta reports
  mouse motion with a button held as smaller, so aiming while holding a button
  felt heavy; Glimmer now measures this and scales it back.
- The fast-flick traversal boost is off by default, for raw, predictable 1:1
  aim. At 4K an aim flick and a cross-screen flick look alike, so it also
  boosted aim, felt twice as sudden sensitivity jumps. It's in hidden settings.
- Streams on battery no longer chug when macOS slows the display below the
  stream's frame rate (sometimes plugged in, too). About 13 frames a second had
  nowhere to land; Glimmer now fills the gaps until the display recovers.
- Diagnostics go much deeper: frame delivery timing at three stages, stutter and
  gap counters that name their cause, audio margin tracking that sees trouble
  before it's audible, mouse motion, and battery and low-power state.

## 2026.7.4 - 2026-07-05

- Held keys and mouse buttons are released the moment the stream window loses
  focus. If another app took over while you held W, your character used to keep
  walking until you clicked back in and pressed it again.
- A key you're still holding when you click back in picks up again on the next
  press.

## 2026.7.3 - 2026-07-05

- Streams open with at most one brief quiet moment instead of several audio
  blips over about 15 seconds, because the audio cushion starts at the depth the
  connection has already learned.
- Audio no longer stays a fifth of a second behind for the rest of a session
  after a rough start, or into the next one. A delay already stuck that way is
  repaired and settles back down during quiet play.

## 2026.7.2 - 2026-07-02

- Streams stay smooth when macOS slows the display clock (commonly on battery).
  Frames used to slip a beat every few seconds; Glimmer now notices within a
  second and fills the missed beats until the clock recovers.
- The “felt stutter” telemetry signal counts what you actually see: a screen
  that visibly held while frames were still arriving. It used to need a rare
  double fault and never fired. The stutter badge's thresholds are unchanged.
- Audio remembers each PC's clock offset and uses it from the first second of
  the next stream, instead of relearning it every session with audio blips in
  the first minutes.

## 2026.7.1 - 2026-07-02

- An internal rename with nothing you can see: Glimmer's core no longer carries
  the Moonlight name, and paired PCs and settings carry over untouched.
  Moonlight is still credited in About; the transport is ported from its code.

## 2026.7.0 - 2026-07-01

- The stats overlay's smoothness reading stays healthy on an idle or
  low-frame-rate desktop, where it fell to single digits. A game that drops its
  cadence still shows it, and the “Stream stuttering” badge is unchanged.
- When pairing can't reach the PC (offline, at the wrong address or not on your
  network), the error names the PC and says to check it's on and reachable. A
  real pairing or PIN failure still just says to try again.

## 2026.6.54 - 2026-06-30

- The stream's buffer adapts again on a normal install, so a Wi-Fi or congested
  link gets the deeper buffer it needs to absorb hitches. It had stopped
  adapting unless diagnostics were on.
- Quitting mid-stream no longer leaves the Mac's pointer acceleration
  overridden.
- Audio recovers if the output device isn't ready the instant you switch to it.
- A connection that fails just as the stream window opens can't steal focus or
  hide the cursor.
- Waking on a high-latency link reconnects faster.
- The pairing success screen's buttons are clickable again.
- An old error no longer names the wrong PC after you switch PCs.
- VoiceOver announces the reconnect banner.

## 2026.6.53 - 2026-06-29

- The “Stream stuttering” badge lights only when the screen actually held on a
  frame, not when the player drops a stale frame on healthy Wi-Fi to show the
  freshest one. Sustained dropped or held frames still trip it.

## 2026.6.52 - 2026-06-29

- A rare crash on disconnect is fixed, where part of a session (diagnostics,
  frame timing, telemetry or the decoder) could be torn down while still in use.
- Audio drift correction no longer goes wrong from a rare timing race.
- Input no longer stays disabled after a silent reconnect.
- Starting a new stream right after the last one can't leave it muted.

## 2026.6.51 - 2026-06-26

- Fast mouse flicks cover the screen consistently at any stream resolution,
  while aim sensitivity stays exactly raw. It's automatic, with no settings.

## 2026.6.50 - 2026-06-26

- Audio recovers mid-stream when you switch output devices (AirPods, a USB DAC,
  unplugging HDMI, a sample-rate change) instead of going silent until you
  reconnect.
- A stream whose audio genuinely fails says so instead of quietly playing video
  only.
- Held controller inputs survive a silent reconnect or a wake from sleep. A held
  trigger, stick or button used to read as released on the PC until you moved
  it, so ADS dropped, your character stopped or a charge cancelled.
- A PC that crashes or drops shows a distinct “ended unexpectedly” message with
  Retry, instead of the same calm message as a clean quit.
- A stuck launch gives up after about 22 seconds instead of 55 to 65, and Cancel
  returns at once.
- Quitting mid-reconnect no longer leaves a connection running in the
  background.
- The per-session diagnostics trace is capped in size and old logs are cleared
  away; it could grow without limit.
- Telemetry is more accurate. Streaming and latency behavior is unchanged.

## 2026.6.49 - 2026-06-26

- A release-integrity and diagnostics update with no change in behavior: the
  GPLv3 source at each release tag now always reproduces the app (closing the
  2026.6.48 gap), and telemetry stays accurate across a reconnect.

## 2026.6.48 - 2026-06-26

- Diagnostics only, with no change in behavior: they confirm 2026.6.47's
  real-time frame timing took effect and name the cause of any remaining
  frame-timing miss.

## 2026.6.47 - 2026-06-26

- The last intermittent stutter on high-refresh displays is gone. The thread
  that times each frame could be pushed aside under load and run a couple of
  frames late; it now gets real-time priority, at negligible CPU cost.

## 2026.6.46 - 2026-06-26

- Diagnostics only, with no change in behavior: they find out why frame timing
  sometimes runs late on a high-refresh display, so the next release can pick
  the right fix.

## 2026.6.45 - 2026-06-26

- Diagnostics only, with no change in behavior: stream launch time is split into
  its steps, network route changes (such as waking on a new Wi-Fi network) and
  input backlog are counted, and controller delivery latency is measured.

## 2026.6.44 - 2026-06-26

- Waking the Mac mid-stream, even on a different Wi-Fi network, reconnects in
  place within about two seconds instead of sitting on a black screen for about
  10 seconds first. A healthy wake on the same network is untouched.

## 2026.6.43 - 2026-06-26

- On a clean wired link, audio settles to a tight, low-latency buffer instead of
  holding roughly 150 ms extra (around a quarter-second of lip-sync lag), such
  as after waking on a new network. A struggling link keeps its deeper buffer.

## 2026.6.42 - 2026-06-26

- Audio comes back after a silent mid-stream reconnect, such as waking on a
  different Wi-Fi network. The picture used to resume with no sound.
- Diagnostics flag a stream whose audio has gone silent at a glance.

## 2026.6.41 - 2026-06-25

- The default controller exit chord is L3 + R3 (click both sticks). The old
  L1+R1+L2+R2 leaked to the PC as you pressed it, opening Steam Big Picture's
  on-screen keyboard; it's still selectable in Settings.
- The “Stream stuttering” pill lights only on real dropped or late frames, not
  when a high-refresh display repeats frames because the PC sends fewer than it
  refreshes. It used to light constantly at a smooth 4K 240.

## 2026.6.40 - 2026-06-25

- Diagnostics only, with no change to streaming: they time the hardware
  decoder's startup and record why it's rebuilt mid-stream.

## 2026.6.39 - 2026-06-25

- The “Stream stuttering” badge judges how evenly frames reach the screen, so it
  stays dark on an even stream at any frame rate and still catches real judder.
  It used to light nonstop on a 240 Hz panel fed about 130 fps at 4K.
- If your stream looks soft at 4K 240, the PC likely can't encode it: try 4K 120
  or a lower resolution. The picture is genuinely smooth at the rate it's
  delivering.

## 2026.6.38 - 2026-06-25

- On a confirmed wired connection, the Wi-Fi helper no longer asks to be turned
  on or parks the AirDrop radio during a stream, which only turned off AirDrop
  system-wide. Wi-Fi sessions are unchanged.
- The bitrate chip and codec checkmark update as soon as you change a PC's
  codec.
- A launch app that isn't on the selected PC is labelled “(not on …)” with the
  PC's name.

## 2026.6.37 - 2026-06-25

- The in-app input latency figure measures felt latency. It used to measure the
  time to the next frame and read several times too low.
- The A/V skew figure shows true sync instead of mostly audio buffer depth.
- A new click-to-first-frame figure times the whole launch, where the old timer
  started after the launch handshake. Streaming itself is unchanged.

## 2026.6.36 - 2026-06-25

- On a quiet, healthy wired link, audio drains to a tight, low-latency buffer
  instead of holding roughly 150 ms extra (about a quarter-second of A/V lag). A
  struggling link keeps its cushion; Wi-Fi is unchanged.

## 2026.6.35 - 2026-06-25

- The controller exit chord works on every gamepad: it's now a hold of all four
  shoulder buttons and triggers, shown in the in-stream hint. It used to need
  the DualSense Create button, which macOS doesn't expose.
- Network and round-trip telemetry no longer go blank after a silent reconnect.
- A rare hang when a stream's frame timing is slow to start is fixed.
- The A/V skew figure is computed once, so its two readouts can't disagree.
- Controller input reaches the PC sooner: macOS can no longer hold back each
  send by up to a full millisecond.
- The in-stream degradation pill shows only on sustained hitching and fades out
  cleanly instead of flickering.

## 2026.6.34 - 2026-06-25

- The bitrate chip and spec summary show what the stream actually sends: on AV1
  and HEVC, about 20% less than the H.264 figure. They read 84 Mbps, for
  example, while sending 67.

## 2026.6.33 - 2026-06-25

- The “Stream stuttering” pill waits out a game's launch and shows only for
  hitching clearly above a high-refresh stream's normal level, so it stays dark
  on a healthy session and means something when it appears.

## 2026.6.32 - 2026-06-25

- High-refresh displays drop fewer frames. Frame timing has its own
  high-priority thread, with no added latency; on the busy main thread macOS
  could starve it, causing about 73% of dropped frames on a clean link.

## 2026.6.31 - 2026-06-25

- The in-stream degradation badge, renamed “Stream stuttering”, lights when the
  picture actually stutters (dropped, late or repeated frames), not on Wi-Fi
  blips that error correction already absorbs.

## 2026.6.30 - 2026-06-25

- The in-stream “Network degraded” pill appears only for sustained trouble,
  ignores a momentary Wi-Fi blip, and reliably fades out when the link clears
  instead of sometimes staying stuck on.

## 2026.6.29 - 2026-06-25

- The choppiness 2026.6.28 brought is gone: one of its frame-pacing changes made
  frames miss their display refresh on a clean link, and it's reverted. The
  telemetry that caught it stays.

## 2026.6.28 - 2026-06-25

- Audio latency is lower and lip-sync tighter on a good connection: drift
  correction keeps its clock estimate across buffer drains and corrects several
  times faster, and the cushion no longer ratchets deep on a clean link.
- When the stream's frame rate matches the display's refresh rate, nothing trims
  a few frames a second any more, so rendered frames match decoded on a clean
  link.
- A connection no longer hangs if the PC goes silent mid-reply; it fails fast
  and recovers.
- The connection handshake has an overall timeout, more kinds of disconnect are
  treated as recoverable, and connecting no longer blocks the session.
- Existing installs see their paired PCs again: this update carries pairings and
  trust over from before the move to an unsandboxed app.
- A banner shows over the frozen frame while reconnecting or holding.
- A PC whose certificate changed is flagged with a real way to pair it again,
  instead of a false “Ready”.
- Taking over a PC that's already streaming asks first.
- A hint on your first stream shows how to leave full screen.
- A “Network unstable” pill appears on a degrading link.
- The Wi-Fi helper engages on the first stream after you turn it on.
- Decode latency telemetry is measured instead of estimated, disconnect reasons
  are counted durably, GPU power counts toward the power figure, and smaller
  fixes bring the release to 39.

## 2026.6.27 - 2026-06-25

- The Wi-Fi helper holds the AirDrop and Continuity radio down harder during a
  stream, catching macOS raising it the instant it happens, so it has far less
  chance to hop channels and stutter your stream.
- Telemetry records how often macOS brought the radio back up, and the log says
  whether the helper engaged for each stream.

## 2026.6.26 - 2026-06-24

- Audio no longer crackles on a PC whose audio clock runs off by a few hundred
  parts per million. Drift correction now absorbs the skews real PCs show, with
  margin to spare, and the rate change stays inaudible.

## 2026.6.25 - 2026-06-24

- Longer sessions no longer get the occasional audio crackle when the PC's and
  Mac's clocks drift apart. Glimmer catches the drift about twice as fast, so
  the audio cushion no longer briefly drains, and pitch changes stay inaudible.

## 2026.6.24 - 2026-06-24

- Glimmer no longer freezes when the PC cuts a stream at just the wrong instant
  during audio playback. That rare hang left Glimmer unable to reconnect until
  you force-quit and relaunched it.

## 2026.6.23 - 2026-06-24

- AV1 streams get more headroom: 2026.6.22 gave them a third less than H.264,
  and now about 20% less, like HEVC. Busy, high-motion scenes keep more room
  while still using less bandwidth than H.264.

## 2026.6.22 - 2026-06-24

- AV1 and HEVC streams use less bandwidth at the same picture quality. Glimmer
  no longer gives them the budget H.264 needs: roughly 20-33% fewer bytes
  against a capable PC, with no visible change.
- A Custom bitrate is always sent exactly as you set it.

## 2026.6.21 - 2026-06-22

- When macOS keeps a stuck background item after an update and won't install the
  Wi-Fi helper, Glimmer explains what happened and links to Apple's Login Items
  & Extensions guide, instead of the false “helper not found in the app bundle”.

## 2026.6.20 - 2026-06-22

- The DualSense chord tip and the quit-chord hint point to Settings > Input,
  where those controls live now.
- The mute-while-streaming toggle leads with what it does, with a clearer
  footnote.
- The Custom resolution helper is a “Use native resolution” button.
- The empty launcher settles on a single “Pair a PC.”

## 2026.6.19 - 2026-06-21

- The “Match my display” quality preset is now “Native Retina”: every pixel of
  the Mac's panel.
- A new HiDPI preset streams at the Mac's default Retina scale, a crisp picture
  at roughly a quarter of the bandwidth.
- The Smooth and Maximum presets, rarely the right choice, are gone.
- Notch coverage is a single-line toggle right under the resolution picker.
- The stats overlay can sit top center, clear of the camera notch, or bottom
  center.
- The raw-mouse aim toggle moves to Input, and Wi-Fi stutter smoothing moves to
  Quality.
- Troubleshooting and Diagnostics are one pane. The controller test and logs
  stay in plain sight; telemetry appears when you Option-click the version line.
- The DualSense player-number lights match its controller slot.
- The Home/Guide quit chord is gone, because macOS reserves that button.
  Options + Create + L1 + R1 still quits.
- Glimmer guards against a layout crash when the display changes.

## 2026.6.18 - 2026-06-20

- Controller input no longer dies after you record a custom quit chord. Closing
  the recorder used to leave the controller dead until the stream restarted;
  input now reconnects whenever the stream window comes back into focus.
- The Mac's mouse acceleration turns off while a stream is focused, so only the
  game's sensitivity shapes your aim. It's on by default, for mice only (the
  trackpad is untouched), with a toggle in Settings > General > Mouse.
- Audio on a fresh, jittery or remote connection starts at the right buffer
  instead of working up to it through a few audible blips.
- Telemetry shows how much loss-recovery headroom each frame had, including how
  close it came to being unrecoverable.

## 2026.6.17 - 2026-06-18

- Frame skipping on high-refresh displays is gone (easy to see on
  testufo.com/frameskipping). Glimmer holds the refresh rate steady instead of
  renegotiating it every couple of seconds and dropping a frame each time, still
  up to the panel's top rate.
- Clock drift between the PC and the Mac is corrected smoothly instead of by
  inserting silence, so audio plays more evenly.
- The launcher's main button says “Stream” and the app's name, instead of the
  misleading “Resume”.
- Glimmer's control connection to the PC requires TLS 1.2 or later.

## 2026.6.16 - 2026-06-18

- The PC no longer stops trusting this Mac after the Mac sleeps. Glimmer no
  longer depends on the login keychain, which locked on sleep; the PC's
  certificate is pinned as before. This replaces 2026.6.15's stopgap.

## 2026.6.15 - 2026-06-18

- Streams no longer fail after the Mac sleeps with a message that the PC doesn't
  recognize it. The pairing was fine; the login keychain had locked. Glimmer now
  reloads its identity and recovers without a restart.

## 2026.6.14 - 2026-06-17

- The Wi-Fi helper logs each time macOS turns AirDrop's radio back on mid-stream
  and the helper parks it again, so a hitch can be checked against the log. Only
  the helper changed.

## 2026.6.13 - 2026-06-17

- A developer workflow change: `make dev` runs the tests before building, and
  releases go through a pull request. Nothing changes in the app.

## 2026.6.12 - 2026-06-17

- Documentation only: a shorter release runbook. Nothing changes in the app.

## 2026.6.11 - 2026-06-17

- Wi-Fi freezes during a stream are smoothed out. AirDrop and Continuity share
  the Mac's Wi-Fi radio and can grab it mid-stream for seconds at a time, so
  Glimmer parks that radio only while you stream and restores it when you stop.
- Turn the Wi-Fi helper on in Settings > General > Network, then approve the
  one-time prompt macOS shows.
- The Wi-Fi helper survives app updates, instead of an update silently switching
  it off until you toggled it again.
- Glimmer asks the PC for your Mac's exact native resolution and refresh rate.
- [docs/HOST_SETUP.md](docs/HOST_SETUP.md) and a sample
  [`vddsettings.xml`](docs/vddsettings.xml) cover the Sunshine and Virtual
  Display Driver setup the PC needs to offer those modes.
- Glimmer is no longer sandboxed, which the Wi-Fi helper requires. Your identity
  and pinned PC certificates move to `~/Library/Application Support/Glimmer/` on
  first launch, with no re-pairing. [docs/SECURITY.md](docs/SECURITY.md)
  explains why and what protects the app instead.
- Release builds turn library validation back on, so Glimmer loads only
  libraries signed as its own.
- Fuzz testing of everything Glimmer reads from the PC found and fixed an
  out-of-bounds read in packet-loss recovery.

## 2026.6.10 - 2026-06-16

- Maintenance: an automated suite of 120 unit tests and a lint cleanup. Nothing
  changes in the app.

## 2026.6.9 - 2026-06-16

- Maintenance: Glimmer's identity stays in files only your account can read,
  rather than the keychain, which would need a provisioning profile a Developer
  ID app can't ship. Nothing changes in the app.

## 2026.6.8 - 2026-06-16

- Glimmer checks for updates when it launches, as well as once a day in the
  background.

## 2026.6.7 - 2026-06-16

- A test release for updating in place from 2026.6.6, with source and docs
  cleanup only. Nothing changes in the app.

## 2026.6.6 - 2026-06-16

- A test release for updating in place, identical to 2026.6.5.

## 2026.6.5 - 2026-06-16

- Glimmer updates itself. It checks once a day in the background, and “Check for
  Updates…” is in the app menu and the menu bar menu. Updates are signed and
  notarized, and only a newer release is ever offered.
- This version is installed by hand; every release after it updates in place.
- Playback stays smooth through Wi-Fi gaps over 50 ms: the frames that arrive in
  a rush afterward play instead of being thrown away, ending the roughly 20%
  frame drop and the stutter after each gap.

## 2026.6.4 - 2026-06-13

- On a lossy link, the mouse no longer keeps turning after you've stopped.
  Glimmer waits when the PC falls behind and sends one catch-up move instead of
  a backlog, as Moonlight does. No mouse motion is dropped.
- Controller motion (gyro and accelerometer) is sent as Moonlight sends it: a
  lost sample is dropped rather than resent, so it never holds up the rest of
  your input. A “sensors stopped” signal always gets through.

## 2026.6.3 - 2026-06-13

- Locking or signing in on Windows no longer ends the stream. When Sunshine
  restarts its capture, or a brief network blip drops the link, Glimmer holds
  the last frame and reconnects in place instead of dropping to the launcher.
  (#20)
- PCs that encode HEVC or H.264 work alongside AV1. Glimmer picks AV1, then
  HEVC, then H.264, with a codec override per PC, so a GPU without AV1 (such as
  an RTX 3080) streams cleanly. (#19)
- 4K at 240 Hz takes less work to receive, because Glimmer reads video packets
  in batches. (#24)
- Glimmer runs on a clean Mac without Homebrew installed. (#18)
- Opt-in performance telemetry records per-second stream metrics on a local
  Prometheus endpoint and an NDJSON scorecard for each session, labeled by Mac,
  PC and codec. (#23)
- Telemetry is off by default and can also send to a remote Prometheus or Loki.
- A PC's status no longer flips to “Checking…” after one missed check, and keeps
  updating when Glimmer isn't in front instead of sticking on “Checking…”.
- Pairing no longer fails because a PC's discovered name kept a
  network-interface suffix.

## 2026.6.2 - 2026-06-11

- A bug hunt before release found 36 problems, 8 of them serious enough to hold
  the release. All are fixed.
- Audio no longer swings back and forth in its playback delay: Glimmer remembers
  the right buffer for each PC, and starts without throwing away a fixed 500 ms.
- Audio repair for lost packets works again. A bug had been switching it off
  mid-session.
- Audio corrects for slight clock drift (−40 ppm) between the PC and the Mac.
- Frame pacing holds up when macOS throttles display timing, recovers when the
  display rejects a frame, and no longer resets the refresh rate in bursts or on
  minor screen changes.
- While the stream window is hidden, Glimmer stops decoding video but keeps
  playing audio, and the picture resyncs when you come back.
- A memory-safety bug when a stream's connection closes is fixed, along with
  smaller fixes to the connection with the PC.
- Controllers rumble, triggers included, and the RGB lightbar, motion sensors
  and battery level all work. Every capability Glimmer advertises to the PC now
  does something.
- The controller quit chord needs the hold it promises, and the cursor hides
  again when you return to the stream from the Dock.
- The launcher's status line reflects how the PC is reached.
- The launcher offers “Resume” with the game's name when one is running, and
  Return starts a stream.
- Connecting gets a calm 400 ms transition, and a short summary appears when a
  session ends.
- A new Quality pane in Settings gives measured bitrate guidance in two tiers.
- Settings labels say what you'll get, your launch choice is remembered, and the
  battery display is honest about what it knows.
- Glimmer has its own icon, Eclipse, with matching menu bar icons and a retuned
  window.
- Glimmer presents itself as a Sunshine client first, and has a support link.

## 2026.6.1 - 2026-06-05

- Glimmer streams with its own engine, written entirely in Swift, in place of
  the `moonlight-common-c` library. It handles the encrypted connection, video
  and audio with loss recovery, AV1, HEVC, H.264, HDR, Opus, and keyboard,
  mouse, controller and DualSense input.
- The new engine is verified end to end against Sunshine 7.1.431.
- Streams no longer die silently after about 16 to 18 seconds. Glimmer batches
  input about every millisecond and paces it, so Sunshine's control connection
  doesn't time out.
- Glimmer notices a PC that has gone silent within 10 seconds.
- Glimmer is now licensed under GPLv3 instead of MIT, because its engine is a
  port of the GPLv3 `moonlight-common-c`. See `LICENSE` and `CREDITS.md`.

## 2026.6.0 - 2026-06-01

- Pairing no longer fails when Sunshine reports success. Glimmer stops checking
  the PC's status while pairing, which had been jamming Sunshine's pairing.
- Pairing waits long enough for you to type the PIN on the PC, instead of timing
  out within seconds.
- A newly paired PC is saved with its apps and stays in your list.
- “Pair a new PC” shows the PCs found on your network. Pick one and pairing
  starts as the code appears; the sheet floats above other windows and closes
  itself when pairing succeeds.
- You can still type an address when discovery finds nothing.
- Right-click a PC, in the launcher or in Settings > PCs, to rename or unpair
  it. Unpairing leaves nothing behind.

## 2026.5.3 - 2026-05-30

- The Mac and its display stay awake for the whole stream, so the screen no
  longer dims or sleeps during controller-only play.
- The quality preset defaults to “Match my display” (the panel's native
  resolution and refresh rate), at the top of the list.
- The launcher shows “last played” once, below the Stream button, instead of
  twice with values that could disagree.
- Toggling “Launch minimized” no longer closes Settings.
- Glimmer's identifier is now `io.ugfugl.Glimmer`, so after upgrading you set up
  your paired PCs and approve the login item once more.

## 2026.5.2 - 2026-05-28

- Two crashes when a stream ends mid-decode are fixed, one in video and one in
  audio.
- An SDR stream can no longer get stuck in HDR color.
- Stream errors always say what happened, instead of “The operation couldn't be
  completed. (Glimmer.StreamError error 0.)”
- Reduce Motion is respected everywhere: the pulses, the connect animation, the
  Stream button's bounce and the stream window's fade-in all settle instantly.
- VoiceOver reads the pairing code as one element, digit by digit, instead of
  four “PIN digit” stops, and explains why the Stream button is disabled or
  busy.
- The accent color has light and dark versions tuned for contrast, instead of
  one bright violet that failed WCAG AA on white.
- The default quality preset is Smooth, capped at 1440p, for a smoother first
  stream on typical Wi-Fi.
- 5K and 6K displays get a properly scaled bitrate instead of about half the
  bits per pixel; the budget no longer tops out at 4K.
- The Wake-on-LAN button, which didn't work, is gone.
- Stream summaries no longer name the codec, which could disagree with the one
  in use.
- “Stream now” after pairing finds the PC by any of its names or addresses, so
  pairing by IP address no longer fails to launch.
- Muting the Mac while streaming works. Before, it silently did nothing.
- Finding PCs on your network works with the local network privacy check in
  macOS 15 and later.

## 2026.5.1 - 2026-05-27

- A round of thread-safety and leak fixes makes streaming sturdier, and early
  connection progress is no longer lost.
- The app no longer refreshes its state four times a second for nothing.
- AV1 streams are set up from the stream's actual format (chroma, bit depth,
  profile) instead of a fixed guess.
- Glimmer asks only for codecs the Mac can decode in hardware, so Intel Macs no
  longer request AV1.
- Glimmer respects the color information a stream carries, and Sunshine's HDR
  streams labeled BT.709 no longer look washed out.
- An SDR stream after an HDR one no longer inherits stale HDR settings.
- Latency no longer builds up under load: frames the display can't take are
  dropped, and after three in a row Glimmer asks the PC for a fresh frame.
- Glimmer's frame watchdog counts decoded frames rather than received bytes, and
  logs when the PC sends video the Mac can't decode.
- Decoding is about 8 ms quicker at 120 Hz, and frames are timed by the PC's
  clock.
- On a local network, video travels in larger packets (1392 bytes instead of
  1024).
- The stats overlay updates once a second over a one-second window, so the frame
  rate no longer jitters by ±1 at 60 Hz.
- Glimmer runs in the App Sandbox, with the Hardened Runtime on in Developer ID
  builds.
- Pinned PC certificates move from shared preferences to private files, and
  Glimmer's identity stays in private files inside its sandbox.
- If you used Moonlight, Glimmer imports its identity once and then deletes
  Moonlight's copies of the keys.
- A PC's certificate is pinned only after pairing fully succeeds, so a new
  pairing never trusts a certificate on first sight.
- Pairing failures show one “Pairing failed” message; the specific cause goes
  only to the private log.
- Video, audio and input are all encrypted by default (AES-128-GCM), not just
  audio.
- Screenshots and screen recordings, including Command-Shift-5, see the stream
  window as black.
- Keystrokes, passwords included, no longer appear in the system log.
- Session keys and PC IDs are removed from logged URLs.
- When a PC's certificate changes, a new sheet compares the fingerprints side by
  side, with copy buttons and differences highlighted, and reminds you to check
  them over a trusted channel before you accept.
- The stream window fades in over 350 ms once the first frame is ready, and the
  menu bar and Dock hide only after it's fully visible. No more letterbox flash
  while connecting.
- Command-Tab or a click on the launcher brings back the menu bar and Dock, and
  returning to the stream hides them again. The launcher no longer floats on a
  letterboxed desktop.
- Disconnecting fades the stream out over 250 ms and shows “Stream ended” in the
  launcher.
- Clicking the Dock icon while streaming goes straight back to the stream.
- The stats overlay is redesigned: a symbol for each row, right-aligned values,
  white, yellow or red by severity, and dividers between sections.
- The overlay has three presets: Micro (PC, render and network frame rate,
  latency, jitter, drops and bitrate), Extended (every stream metric) and Custom
  (rows you pick in Settings > Streaming).
- You set the overlay's colors in Settings > Streaming > Color thresholds, with
  warning and critical levels per metric and a Restore Defaults button. Changes
  apply live during a stream.
- The default thresholds mark when a stream feels bad: frame rate under 60 or
  30, latency over 50 or 100 ms, jitter over 10 or 25 ms, drops over 0.5% or 2%.
- A new Mac section in Custom shows the Mac's CPU, memory and battery, with a
  charging symbol.
- Jitter has its own row, separate from round-trip variance (for now the same
  value).
- You pick the overlay's corner in Settings, since the mouse belongs to the PC
  during a stream.
- The overlay can be set up while it's turned off.
- Frames dropped because the display was busy show as `(+N RB)` on the Decoder
  drops row, only when there are any.
- The Quick Settings drawer is gone. Its controls (quality preset, default app,
  mute while streaming, stats overlay) live in Settings.
- The toolbar joins the PC picker and the Settings gear in one control, shown
  even with one paired PC. With none, the gear stands alone.
- The menu bar icon shows whether Glimmer is idle, streaming or has hit an
  error.
- The app icon has its own small-size version that stays readable in Finder
  lists, About and a small Dock.
- Connecting reads clearer: “Choose a PC” when none is selected, no Stream
  button while the stream is in front (instead of a disabled “Streaming…”), and
  connecting text that names each stage.
- Each PC keeps the same color every launch.
- A plain description of the app replaces the marketing tagline.
- “Trust new cert and re-pair…” is now “Compare fingerprints…” and opens the
  comparison sheet.
- A controller quit chord in Settings > Shortcuts quits the stream when you hold
  it, like the keyboard shortcut. Choose L1+R1, L1+R1+L2+R2, L3+R3, Select+Start
  or Home/Guide; it's off by default.
- “Launch minimized” in Settings > General opens Glimmer to the menu bar only.
  Click the Dock icon or choose “Open Glimmer” from the menu bar to bring the
  window back.
- The controller battery row is gone: macOS reports most pads' battery as
  unknown, so it showed “-” forever.
