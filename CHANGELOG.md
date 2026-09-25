# Changelog

## 2026.9.8 - Unreleased

Steadier reconnects, a Cancel that also quits the game it started, lighter video
decoding, and an installer for the command line tool.

A stream that reconnects on its own after a network drop or sleep no longer ends
a moment later with a no-video or firewall error, and the Reconnecting banner
stays up until the connection resumes. Frames rebuilt after packet loss reach
the screen sooner, a stalled display recovers without flashing an old frame, and
audio comes back on its own if your speakers or headphones weren't ready when
the stream started.

Cancelling while Glimmer connects now quits the game it started on the PC, so
the next stream no longer asks you to take over your own session. Cancelling
just as a stream connects no longer leaves a connection running in the
background, and each stream frees its memory when it ends. Glimmer no longer
quits unexpectedly when the connection to the PC drops at the wrong moment.

H.264 and HEVC streams use less CPU per frame, most noticeably at 4K and high
frame rates. A click made during fast mouse movement is no longer sent after
movement that came later.

Gyro aiming no longer stops responding after about five minutes of play. The
light bar and player lights catch up when you return to a stream that changed
them while you were away. Generic controllers no longer keep Glimmer busy when
no stream is running, and Glimmer stops listening to them while its window and
menu are closed. Opening the controller test in Settings no longer lets a stream
in the background receive controller input, and recording a shortcut no longer
swallows typing in other Glimmer windows.

If the PC's firewall blocks port 48010, Glimmer says so in about 10 seconds
instead of failing with a generic error after 30. Pairing keeps a PC's saved
identity when it's interrupted, and PCs found on the network no longer drop out
of the pairing list while it's open. Wake and Connect starts the stream sooner
once the PC is ready, and Connect in a wake notification works after Glimmer has
quit.

A stream hidden behind other windows no longer keeps your Mac's display awake,
and AirDrop and Continuity come back promptly after a stream ends. Updates no
longer download while you're streaming; Glimmer checks again when the stream
ends. Turning off Open at login also removes a login item still waiting for
approval, and a failed registration no longer switches the setting off.

With diagnostics on, the session log records how each stream ended, the session
summary finds the worst second more accurately and keeps drop and byte totals
across reconnects, and a PC name with quotation marks no longer breaks it.
`glimmer stream --wait` reports its own stream's result even when another starts
right away.

Glimmer › Install Command Line Tool… puts the `glimmer` command on your PATH for
copies installed from the disk image. It asks for an administrator password
once, and says so if Homebrew already installed the command.

`glimmer list --csv` now prints the paired PCs as CSV, with a Name, Address and
Status header. Before, the flag only changed the list of a PC's apps.

The About pane now describes Sunshine as the game-streaming server on your PC
and Moonlight as the client that inspired Glimmer.

## 2026.9.7 - 2026-09-23

A command line and Shortcuts actions, safer pairing, streams from PCs that
require encryption, a way out of every stuck stream, ⌘ shortcuts and paste that
reach the PC, and video and audio that recover on their own.

Glimmer now has a command line. With the app linked as `glimmer`, you can run
`glimmer pair`, `glimmer list`, `glimmer wake`, `glimmer quit` and
`glimmer stream`, and each one reports its result in the exit code: 0 success, 1
failure, 2 usage, 3 unreachable, 4 not paired. Homebrew installs now get the
`glimmer` command. Existing installs pick it up with
`brew upgrade --greedy glimmer` (or `brew reinstall --cask glimmer`), because
the app updates itself outside Homebrew.

`glimmer stream <pc> [<app>]` checks the PC from the terminal, then starts the
stream in the one running Glimmer app, at the same bitrate a launcher click
would ask for. `--wait`, `--exit-after-first-frame` and `--json` connect timings
are there for scripts, and `--force` quits whatever the PC is already running.
`glimmer quit <pc>` ends the app running on a PC without streaming into it. If
this Mac is streaming from that PC, the stream stops cleanly instead of
reconnecting and relaunching the game.

Glimmer also has Shortcuts actions: Stream from PC, Wake PC and Quit App on PC.
You can use them in automations, and Spotlight and Siri offer "Stream … in
Glimmer" and "Wake … with Glimmer" for each paired PC, with its name filled in.
Stream from PC takes an optional app name, matched without regard to case or
accents. Left empty, it streams the app the Stream button shows, and it checks
the PC first so it picks the app the PC is running. Wake PC waits until the PC
is ready to stream; if the PC doesn't answer, it says so and gives the same
Tailscale hint as the launcher. Quit App on PC quits the app running on a PC,
and if this Mac is streaming from that PC, the stream ends the same way Stop
Streaming ends it.

More of macOS 27. If you set the controller Home button to defer to the app in
System Settings › Game Controllers, the PS button now works as Guide on the PC;
with the default setting, the Game Overlay behaves as before. Glimmer also asks
macOS which controllers it handles itself, so a generic controller from Sony,
Microsoft, Nintendo or Apple that macOS doesn't support now works, and a
supported controller is no longer read twice. The toolbar's PC picker and the
menu bar's PCs submenu mark the current PC again, menu bar rows highlight under
the pointer, and the round footer buttons keep their glass edge and hover state.

In full screen, shake-to-find is off and, on macOS 27, so are Hot Corners.

VoiceOver announces in-stream banners when they appear or change, and in
Settings › PCs it reads the default star as "Default PC" and says when it is
selected. With Differentiate Without Color on, warning and critical values in
Stream stats also turn semibold. In the menu bar panel, VoiceOver reads each
chart as a summary of the last minute, with Audio Graph and a per-second data
table, each big number reads as one element, for example "Bandwidth, 62 Mbps",
and card headers show up in the rotor.

A stream that never shows video now ends with a reason of its own: no video
arrived, or video arrived but couldn't be decoded. The generic "ended
unexpectedly" is no longer used for either.

The way out is always on screen. The hold banner now reads "Waiting for video…",
and if it or "Reconnecting…" stays up for 5 seconds it adds the Stop Streaming
shortcut, for example "Press ⌃⌥Q to stop streaming". That hint also shows on
your first three streams instead of once ever, starts again when you change the
shortcut or the controller chord, and isn't used up when the first frame arrives
while the stream window is in the background. Banners now fit narrow windows and
the mini player: a long one shortens with an ellipsis instead of losing both
ends.

While a stream connects, the pointer and the menu bar stay yours. The invisible
stream window lets clicks through to Cancel, and the cursor is only centred,
hidden and captured once the first frame fades in. Switching to another app
while it connects is respected: Glimmer no longer pulls you back 1.5 seconds
later, and a stream that ends just after its first frame no longer leaves the
launcher without a menu bar or Dock.

Connecting is quicker and easier to call off. Connects and in-place reconnects
are about 50 ms faster, and the first frame no longer waits for audio setup.
Cancel or Quit during the connection handshake takes effect immediately instead
of locking out new streams for up to 30 seconds. Stopping a stream during the
handshake with the Stop Streaming shortcut or the window's close button now
works like Cancel: no "Couldn't reach" banner, no "Stream ended" toast, and the
PC list keeps its order and ⌘ shortcuts. Esc cancels a connection that hasn't
started streaming yet; once the stream is live, Esc goes to the game as before,
including during a reconnect. A connection that fails before the stream starts,
for example to a sleeping or unpaired PC or after Cancel, now stops probing the
PC right away. Before, a loop kept opening connections to it.

Streams end the way you meant. Quitting the game on your PC, pressing Force Stop
in Sunshine, or another device taking over now ends the stream cleanly, and
Glimmer no longer relaunches the app or takes the session back. Quitting a
stream over a dead connection closes the stream window and brings back the
pointer right away, instead of leaving a frozen frame on screen for up to 5
seconds. Keys and modifiers you are still holding when you quit are released on
the PC before the connection closes.

Reconnects hold up. A stream that drops just before the Mac goes to sleep now
reconnects on wake instead of ending as unexpected, because the 30 second
reconnect window only counts time the Mac is awake. Unplugging a dock or
Ethernet mid-stream starts the reconnect right away instead of freezing for
about 10 seconds. A reconnect that comes back no longer leaves a red banner
behind.

Streams over a VPN, and streams started before Glimmer has worked out the route
to the PC, now ask for the same bitrate as in 2026.9.5. The Wi-Fi 1.5x boost
applies only when the route really is Wi-Fi, where the check on the radio's link
rate can still trim it. A reconnect after a route change or a wake asks for the
bitrate that fits the current connection, never more than an earlier quality
drop allowed, and Stream stats shows the new rate. Changing the preset, the
custom size or Bandwidth in Settings during a stream doesn't change the bitrate
a reconnect asks for: as the pane says, the change applies to the next stream.

Video recovers by itself. After a decode error Glimmer waits for the next
keyframe instead of feeding broken frames to the decoder, and a decode session
that stops producing frames is rebuilt within a few seconds. Before, the stream
could sit on "Holding…" until you reconnected. Requests for a fresh keyframe or
recovery frame after packet loss now leave at once instead of waiting up to 20
ms. When a PC's Sunshine settings limit the video packet size, packets rebuilt
after network loss now keep their real size, so the picture no longer breaks up
at the moment error correction should have saved it.

Pacing settles faster after a network hiccup. At 120 fps on a 120 Hz display,
the stream no longer carries about five frames of extra latency for half a
second afterwards: the catch-up burst is only held to play through when the
stream runs slower than the display and spare refreshes can drain it. The stall
watchdog no longer mistakes the burst of frames at the end of a network drought
for a frozen picture, which removes needless self-heals and recovery steps after
Wi-Fi gaps. When the frame-rate assist is covering for a throttled display, it
no longer hands the renderer a second frame inside the same refresh.

If the stream reconnects while its window is hidden, for example after the Mac
sleeps and wakes, Glimmer stops decoding video again after 2 seconds. Before, it
could decode every frame for hours with nothing on screen, even on battery.

Late video packets are held for a fixed 24 ms. The adaptive control that tried
to widen the hold is gone: the hold is only one packet deep, so the wider window
never came into play. Packets rebuilt by error correction no longer switch the
hold on.

On remote connections, the bitrate downshift now counts arriving packets rather
than whole frames when it decides whether reception is still alive, so it
responds when the path can't carry the bitrate. Its banner now reads "Weak
connection. Lowering quality to N Mbps…".

On Wi-Fi, Glimmer no longer stalls for about 13 ms every second to read the
radio's link rate. The read runs in the background now, which removes a
once-a-second hitch while idle and while streaming.

Audio holds up when devices change. Switching output devices no longer sets off
a burst of audio errors left behind by every earlier stream, because each stream
now lets go of its output-device listener when it ends, and its audio engine is
released when its connection stops. Unplugging a dock, handing AirPods off or
losing HDMI mid-stream can no longer crash Glimmer while the audio engine
restarts.

Audio stays with the picture and comes out of the right speaker. With 5.1 or 7.1
surround, each channel now plays from its own speaker. Before, a surround stream
sent sounds to the wrong speakers and pushed most of the rear and side channels
into the subwoofer. After a long dropout, audio no longer ends up about 200 ms
behind video: a gap longer than the audio buffer can cover no longer makes the
buffer deeper, and a burst of dropouts deepens it by at most one step. Clock
correction no longer winds up against the buffer trim and settles on the real
clock difference. Each output device's correction is remembered separately, so
switching speakers no longer starts the next stream with the wrong one.

Mute this Mac while streaming is now Play sound on the PC, and does just that:
the PC keeps the game's sound and only the stream is silent on the Mac. It no
longer changes the Mac's system volume or silences other apps, and flipping it
mid-stream changes nothing until your next stream.

Coming back from the mini player re-centres the cursor when it was left on
another display, so clicks can't land outside the stream.

A daily update check no longer shows its alert over a live stream or takes focus
from the game. The alert waits until the stream ends. Checks you start yourself,
and checks made when no stream is running, behave as before. The updater is now
Sparkle 2.10.0: the update window comes to the front when you check for updates
from the menu bar while the main window is closed, and the installer moves the
downloaded archive more safely. Glimmer no longer logs an update-check fault at
launch when the daily check is already running.

Fixes a crash when a stream's frame index wrapped past zero.

Whole wheel notches. A trackpad or Magic Mouse scrolls in fractions of a notch,
and a game that counts whole notches ignores fractions. Glimmer now adds them up
and sends whole notches. A mouse wheel's scroll goes to the PC exactly as macOS
reports it, so small wheel movements are no longer lost or carried into the next
scroll. With telemetry on, every wheel event is in the trace with what macOS
delivered and what was sent, so a wheel that a game ignores can be shown to have
reached the PC.

Controllers stay in step with the PC. Gyro and motion aiming reach the PC as
soon as the controller reports them, instead of being polled on a fixed timer.
Samples arrive evenly spaced and up to 10 ms fresher, and the Mac no longer
wakes 200 times a second to poll. A controller that stays connected through a
reconnect keeps its place on the PC, so the game doesn't see it unplug. If you
unplug or swap a controller while Glimmer is reconnecting, the PC no longer
keeps a phantom controller, and a different controller that takes the same place
shows up on the PC as the right kind. Glimmer now offers the PC rumble only for
controllers the Mac can actually rumble.

The Input Monitoring prompt for a generic controller no longer comes back every
time the controller reconnects: any answer quiets it for that controller until
Glimmer relaunches. Granting access from Glimmer's own prompt now turns on Extra
DualSense buttons right away, with no relaunch, and with them on, the PC now
knows a DualSense has a Mute button. You only need to relaunch after turning the
switch on by hand in System Settings, and the instructions now say so. The "use
this controller" prompt for an unrecognized gamepad has a Don't Ask Again
option, and both DualSense prompts, in the launcher and in Settings, now read
"Turn on Extra DualSense buttons?" with a Turn On button.

"Use ⌘ shortcuts inside the game" now does what it says. While the stream has
the pointer, ⌘-Tab, ⌘-Space, ⌘Q and the rest go to the PC instead of the Mac,
and ⌘-Tab no longer opens the Start menu on the PC. If macOS Zoom's shortcuts
are turned off, ⌥⌘8, ⌥⌘= and ⌥⌘- reach the PC too.

More of the keyboard reaches the PC. On UK and other ISO Mac keyboards, the key
left of 1 and the key next to left Shift now type the right characters. A PC
keyboard's Insert, Print Screen, Scroll Lock, Pause and Menu keys get through,
so Win+Print Screen and Game Bar captures work, and as in Moonlight, the F13,
F14 and F15 keys on Apple keyboards send Print Screen, Scroll Lock and Pause.
Japanese keyboards can type ¥, ろ and the keypad comma, and
the 英数 and かな keys reach the PC.

Keys stay in step with the PC. Caps Lock on the PC follows the Mac every time
you press it, and games that bind Caps Lock no longer see it held down. A Shift
or Ctrl held through a reconnect or sleep works with the next key, and a key
released while reconnecting no longer stays stuck. Glimmer's own shortcuts,
including Stop Streaming (⌃⌥Q), now work on Russian, Greek, Hebrew, Arabic and
other non-Latin keyboard layouts.

Paste into the PC as text. Edit › Paste, ⌘V (whenever ⌘ stays with the Mac) or
⌃⌥⇧V types the Mac clipboard on the PC as characters, so passwords, links, codes
and accented text arrive as written.

HDR has its own switch in Settings › Quality, on by default, and it applies to
every preset, so you can pick SDR and still use Native Retina or HiDPI. The
choice is now real: turning it off makes the PC send SDR. The "Your next stream"
summary shows HDR only when HDR is on and the display can show it.

Pairing is easier to follow. The pairing sheet names the PC instead of showing
its IP address, including when you choose Pair Again… for a saved PC. It tells
you to open Sunshine's web page and choose PIN, and can open that page on this
Mac. It waits up to five minutes for the code, a timeout gets its own message
separate from a rejected code, including a request the PC let expire, and Try
Again appears only after a failure and gives you a new code. If the PC is still
holding an earlier pairing request, pairing tells you so and explains how to
clear it, instead of saying the PC didn't accept the code. Pairing a new PC no
longer closes the sheet the instant the PIN is accepted, so the checkmark and
"Stream now" screen show as intended. When the PC won't accept this Mac, the
message now also says this Mac may be switched off on Sunshine's Troubleshooting
page, and Pair Again… fixes both cases. A PC still running NVIDIA GameStream is
spotted as soon as you pair with it or stream from it, and Glimmer says it needs
Sunshine on that PC instead of failing partway through connecting.

Adding a PC is more forgiving. You can paste Sunshine's web address into the
address field: the scheme, port and path are removed, and Continue stays off
until the address is valid. Discovery prefers a PC's IPv4 address and no longer
lists link-local addresses that stop working when the Mac changes networks. If
macOS has blocked Local Network access, the PC chooser says so and has a button
that opens the setting, and if the search finds nothing, it links to the PC
setup guide.

A device on your network can no longer skip pairing or plant its own
certificate. Glimmer ignores the pair status and certificate in a plain-HTTP
reply, always runs the PIN handshake, and refuses secure requests to a PC that
has no pinned certificate. A reply with an empty length header no longer crashes
Glimmer, and control replies are capped at 4 MiB and stopped at their deadline,
so a slow or oversized reply can't tie up the app.

Stream audio is now encrypted whenever the PC offers it, which Sunshine does by
default, and the stream's setup messages with the PC are encrypted too. Glimmer
now streams from a PC whose Sunshine encryption setting is Mandatory: the video
arrives encrypted and plays normally, where before the stream failed with a
misleading "Couldn't reach". The security notes now describe what the app does:
audio is encrypted whenever the PC offers it, video only when the PC requires
it, and any process running as you can read the pairing key.

Glimmer keeps up with your PCs. Games added or renamed in Sunshine show up
without pairing again: Glimmer refreshes a PC's app list when it first reaches
the PC after you switch to Glimmer, and again when the PC runs an app Glimmer
hasn't seen. When a PC gets a new address on your network, Glimmer finds it
again and confirms it's the same PC before saving the new address; before, it
showed as Asleep for good. A PC that also answers on a second network interface
keeps the address it was paired at. While the launcher window is closed, Glimmer
checks the PC every 20 seconds instead of every 10.

Wake on LAN also sends to Sunshine's streaming ports, as Moonlight does. When a
wake fails, the launcher and the menu bar say why in one line that fits, either
no answer from the PC or "Couldn't send the wake signal. Check this Mac's
network.", and hovering over it shows the Wake on LAN limits. A wake that
couldn't be sent no longer blames Tailscale, and says so at once instead of
after 90 seconds. While Glimmer waits, the Stream button reads Stop Waiting, and
stopping a wake and clicking Wake and Connect again while the first is still
sending no longer loses the waiting state. If you switch to another app while a
PC wakes, Glimmer posts a notification with Connect or Try Again instead of
opening the stream over that app. If Glimmer's notifications are off or set to
None, the stream opens as before.

The launcher's PC card tells the truth again. The readiness chip (Asleep, Trust
needed, Ready with round-trip time) is back after going missing in 2026.9.5, and
its re-pair control for a changed certificate is now a real button that keyboard
and VoiceOver can reach. For a PC busy with an app, the chip shows the app's
name and "running" (or "App running" when the app isn't in Glimmer's list) in a
neutral color instead of a blue "Streaming", since the PC can't tell whether
anyone is watching. Unpairing the selected PC shows the next PC's status
straight away, and the footer's PC-version note and the chip no longer show a
removed PC's details. Switching PCs from the menu bar with the launcher closed
uses that PC's own wired or Wi-Fi bitrate.

A failed connection offers the matching fix: Wake and Connect when the PC is
genuinely unreachable and Wake on LAN is set up for it, Pair Again… for a
pairing or certificate problem, including a PC whose certificate changed, and
Try Again otherwise. A failure after the PC started the app offers Try Again
instead of Wake and Connect, and a PC with "cert" in its name or address no
longer gets Pair Again… for a failure that has nothing to do with its
certificate. Failure messages say what went wrong. A stream port blocked by the
PC's firewall is named, for example "Tower answered, but the stream couldn't get
through. Check that the PC's firewall allows UDP 47999." A slow launch says the
PC took too long to start the app, an error from the PC shows Sunshine's own
message, and a stream that lost its connection says "Lost the connection to
Tower." The message for a PC whose secure port is stuck no longer ends with
transport jargon. Starting a stream that would end a running app on the PC now
asks with the app and PC in the title, says the app will quit and offers one
destructive Quit and Stream button, instead of a generic "Take over the stream?"
that implied an unexplained resume. During a reconnect, the Stream button and
the menu bar read "Reconnecting to" the PC on one line until the stream is back,
instead of switching to "Connecting to" as soon as the reconnect began. While
the stream is in the background, the Stream button's tooltip says it shows the
stream window, and the app items in its right-click menu keep their icons.

While a PC is running an app, the PC menu has a new item that quits it, named
for the app and the PC. If the PC refuses, the message is the same one
`glimmer quit` prints. You can't unpair or re-pair the PC you're streaming from.
When the PC hasn't reported a network address, the Wake on LAN switch says so in
its title, and the unpair message names the PC.

The menu bar panel matches the launcher. Its PC card uses the same status pill
(Ready, Asleep, Trust needed, Checking… and the rest), and its button follows
the PC: Wake and Connect for a sleeping PC, Waking… with Stop Waiting, Pair
Again… for a PC whose certificate changed, and Stream otherwise. Pair a PC… and
Pair Again… open the pair sheet in the main window. While a stream reconnects
the panel offers Stop Streaming, not Cancel Connection, and the attention card
offers Try Again only when a launch could work and can be dismissed. The
Controller card lists every pad the Mac sees, including raw-HID pads and pads
with no battery reading (shown as Connected), and shows charging for each pad.
The bandwidth chart is scaled to the bitrate the session actually asked for, and
the frames chart to the session's frame rate.

A stream started from the menu bar, or Settings opened from the gear, now gets a
Dock icon and a ⌘-Tab entry, so you can switch back to it after switching away.

Each PC tile in Settings › PCs has a ⋯ button with the same Rename, Codec, Wake
on LAN and Unpair items as its right-click menu. The Refresh paired PCs button
is gone, since it did nothing you could see.

The shortcut recorder no longer accepts ⇧ alone, ⌘ with Q, W, H or M, or a
shortcut that is already in use; it says why under the badge and waits for
another try. A controller chord now needs at least two buttons. If you pick a
chord that a DualSense can only fire with Extra DualSense buttons, such as the
Moonlight default or a custom chord with Create or Mute, an orange note under
the picker says so and has a Turn On button.

Open at login follows System Settings. If you remove Glimmer from System
Settings › General › Login Items, Open at login now turns off instead of Glimmer
adding itself back at the next launch. After an update or a move, the login item
is still repaired as before. The toggles are now called Open at login and Open
in the menu bar only.

Settings say what the app does, in one set of names: Stop Streaming for the
shortcut and the controller chord, Stream stats for the overlay, PC instead of
host, and Title Case buttons.

Glimmer no longer deletes login-keychain items labelled "Imported Private Key"
on first launch. That is the default label macOS gives many imported
certificates, so the old cleanup could remove a VPN, Wi-Fi (802.1X) or S/MIME
identity. The cleanup of Glimmer's own old keychain item now runs once instead
of on every launch.

The Wi-Fi stutter protection helper now uses the macOS code-signing check to
decide which apps may connect to it, so another client connecting and then
quitting can no longer turn AirDrop back on in the middle of a stream. It also
stopped repeating the same line in the session log every 5 seconds.

With diagnostics on, key codes are no longer written to the system log. Your
PC's address and name, your display's name and error details are kept out of it
too; the log in Settings › Diagnostics still shows them in full.

Late presents are split by cause. Telemetry rows now show how much of the
late-present count comes from the game's own uneven frame delivery, along with
the game's typical and 95th-percentile frame interval and how often neighbouring
frames were uneven. The rest is the pacer's share.

The input-to-photon estimate now adds the input's own legs on the Mac, half the
round trip up to the PC and half a game frame on top of glass-to-glass, so the
two are no longer the same number. The input legs and the rate of motion samples
are in the row too.

A Wi-Fi blackout can be traced to its cause: each row records whether AirDrop's
radio was parked and how many packets the kernel dropped at a full socket
buffer. Counts of late-packet holds taken and of the packets they rescued
replace the retired error-correction gauges. Diagnostics no longer treat a
sleeping or undocked stream as a bad Wi-Fi link.

Frames dropped while waiting for a keyframe or recovery frame are now counted,
and frame-drop records no longer blame the pacer for frames dropped while the
window was hidden. Loss recoveries, long video gaps and keyframe arrivals are
each logged once as an event, replacing one log line per discarded frame, and
the receipt adds how long each recovery took.

The configuration line records the stream's resolution, frame rate and codec,
and how the bitrate was chosen: the Bandwidth setting, the quality dial, the
codec and route multipliers and the Wi-Fi rate cap. Each row carries the audio
cushion cap for the actual link, dead-air under-runs and the raw DualSense
report rate. The handshake step between stream setup and the connection is now
labelled control setup rather than pairing.

Receipts cover one whole session across an in-place reconnect. Totals counted
before the reconnect are kept, the handshake shown is the first connect's with
the reconnect's steps listed separately, and the reconnect and wake counts start
at zero for each session.

A session that never received audio says so in its receipt, with the ping count.
A mid-stream audio blackout shows as 0 audio packets per second, and each row
gives the longest audio gap in that second. When the PC never starts sending
audio, the log keeps saying so at 30 seconds and every 10 minutes after that,
not just once at 3 seconds.

The A/V skew meter sets its reference only at a clean moment, so an audio
under-run or a keyframe recovery no longer leaves it reporting about 300 ms of
audio lag that wasn't there. Its 95th and 99th percentiles no longer collapse
onto the maximum.

Logs are kept in check with diagnostics off too. Glimmer deletes log files older
than 14 days at launch; before, the Logs folder was only pruned when a
diagnostics session started. Over the size budget, per-frame traces go first,
then 1 Hz files, and diagnostic logs and session receipts are only ever deleted
for age. In a long session the per-frame trace keeps the connect segment (first
frame, pacer lock-in and early loss) along with the newest segments, not just
the newest four.

Input trace lines are no longer built when telemetry is off, and gyro and
accelerometer trace lines are capped at 20 per second per sensor. What is sent
to the PC is unchanged. With telemetry on, a ⌃B bookmark now also lands in the
per-frame trace, on the same clock as the input rows, so you can read what was
sent just before it.

Package power no longer reads 0 W on ticks where the energy counters hadn't
updated, and the main thread has its own line in the per-thread CPU data instead
of being counted under "unnamed". The launcher's PC reachability check no longer
logs an "already cancelled" network fault every 10 seconds. Turning diagnostics
off after a session no longer leaves the adaptive jitter buffer stuck at that
session's last level until relaunch.

The README has a Command line section with the exit codes and a table comparing
Glimmer's commands to Moonlight's. It also says any HID gamepad works and calls
the controller chord Hold-to-stop. The profiling guide covers which input rows
the frame trace holds and which are only sampled, the actual log retention rule
(a 14-day age limit at launch and a 300 MB budget at each diagnostics session),
a recipe for capturing short Wi-Fi freezes, and a table of the defaults that
have no Settings row. The architecture notes cover the command-line entry point,
the raw-HID gamepad path, the DualSense side channel and the video queue's
one-packet reorder hold, and the contributing guide's build line now matches
`make app`.

## 2026.9.6 - 2026-09-20

More bits on every frame, a mini player that hands the aim back untouched, and
the input trace to settle the next mystery.

Leaving the mini player no longer moves your aim. Returning to full screen
re-centred the pointer while the game was already listening, so the jump arrived
on the host as one large mouse movement.

More bits per frame, by default. The bitrate dial was sized for a cautious Wi-Fi
link and the encoder was hitting its per-frame ceiling on every session, which
is what grain is. Settings › Quality has a new Bandwidth switch: Highest
quality, the default, is everything below; Bandwidth saver keeps the previous
ask. Wi-Fi now asks for half as much again under the same cap, and the ask is
held to a share of what the radio is actually doing: while the PC is selected,
Glimmer watches the Wi-Fi link's rate, and a weak or crowded link gets a smaller
ask before the stream starts rather than dropped frames after. When the Mac's
route to the PC is wired, Glimmer asks for twice as much under a higher cap, and
at connect it checks the other end too: a round trip of 2 ms or more means a
Wi-Fi hop is on the path somewhere, and the extra is taken back off before the
stream starts. The number on the launcher and in Settings follows the route. The
gain is per frame; the average bandwidth barely moves on a game that runs below
the requested refresh.

Input in the telemetry trace. With telemetry on, every mouse movement, pointer
position, controller state and motion sample that reaches the wire is recorded
with a timestamp, so a jump you did not make can be traced to what the Mac sent
or ruled out.

## 2026.9.5 - 2026-09-19

Wake the PC yourself, keep the game in view while you do something else, and a
keyboard that stops passing for a gamepad.

Wake on LAN, built in. When a PC is asleep, the Stream button and the menu bar
row become Wake and Connect: Glimmer sends the standard wake packets itself,
using the network address Sunshine reported, waits for Sunshine to answer and
connects. It is on for each PC by default and can be turned off in the PC's
right-click menu. It works on your home network; over a VPN it depends on your
router forwarding wake packets, and over Tailscale it cannot reach the PC. The
old power controls that needed a separate tool are gone.

A mini player. Press ⌃M during a stream (or choose Mini Player in the menu bar)
and the stream shrinks to a small window that floats over everything, including
other apps' full-screen Spaces, so a queue, a loading screen or an idle game
stays in view while you use the Mac. It opens a quarter of the screen wide in
the bottom-right corner, remembers where you drag it, and keeps the picture's
aspect as you resize it. Nothing about it takes your mouse until you click it: a
click puts the pointer in the game, holding Esc gives it back, and the keyboard
reaches the game while the mini player is the active window. Press ⌃M again,
choose Back to Stream, or double-click its top edge to return to full screen or
your window, whichever you had. The close button, shown when the pointer rests
on it, ends the stream like the window's red button. The chord can be changed in
Settings › Shortcuts.

Raw-HID pads no longer claim a keyboard's gamepad interface. Hall-effect
keyboards expose one for their analog mode; Glimmer was treating it as an
unknown gamepad, which Sunshine emulates as an Xbox 360 controller, so every
keypress drove a phantom pad and games flipped their button glyphs between Xbox
and PlayStation.

## 2026.9.4 - 2026-09-19

Controllers macOS doesn't know about, a mouse that feels like your Mac, a menu
bar item worth opening, and a catch-up with what Sunshine changed over the
summer.

Any HID gamepad now works. Glimmer used to see only the pads macOS itself
recognises (Xbox, PlayStation, Switch and MFi). Pads that show up as plain
DirectInput devices, like the 8BitDo Ultimate 2C over Bluetooth, were invisible.
Glimmer now reads those directly, using the same community controller mappings
Moonlight relies on, with rumble where the hardware offers force feedback,
battery level where it is reported, the quit chord, and a live readout in
Settings, Diagnostics. Pads macOS handles keep going through macOS. A pad that
needs the Input Monitoring permission is explained in the launcher before macOS
asks, never in the middle of a stream.

Two DualSenses now keep their own buttons, battery readings, lights and trigger
effects. A face-button press matches the pads up when needed; one pad still
works straight away.

The mouse keeps your speed. "Raw aim" used to switch the Mac's pointer to a mode
that also threw away your Tracking Speed, so the stream ran at roughly a quarter
of desktop sensitivity, and a crash could leave the desktop that way. It now
uses macOS's own linear scaling: no acceleration curve in the game, your speed
unchanged, restored the moment you leave. Settings, Input has a switch between
Linear scaling and Mouse acceleration; linear is the default.

The menu bar item is now a panel. While streaming it shows bandwidth, latency
and frames per second as big numbers over a one-minute chart (hover it to read
any second back), the mode you asked for, Back to Stream, Stop Streaming and a
stats-overlay switch. Otherwise it shows the selected PC with its readiness, a
Stream button, the PC's apps and PCs one level down, and Wake and Connect for an
asleep PC where luna is set up. Controllers show their name and a battery bar.
The mark itself reads idle, connecting, reconnecting, streaming or needs
attention, and attention opens to the reason and a Try Again.

The main Stream button now launches the Default action from Settings, the same
as the menu bar; an app the PC is already running still wins, and Retry repeats
the exact launch that failed.

Your Mac now pairs under its own name. Sunshine's pairing page used to list
Glimmer as "roth", a leftover from Moonlight's early days, and every Glimmer on
your network identified itself with the same fixed id. Each install now sends
its computer name and its own id to Sunshine. GFE hosts still get the shared id
they depend on.

Controller packets follow the host's channel grant. If a host opens fewer
control channels than Glimmer asks for, controller and sensor traffic now falls
back to the shared channel the way Moonlight does, instead of being sent into a
channel that was never opened.

Player indicator lights. Sunshine 2026.906 and later can tell the pad which
player it is; Glimmer now sets the controller's player index from that.

Holding both Shifts (or both Controls, or both Options) and letting go of one no
longer leaves the other stuck on the host. Each side is tracked on its own, and
a focus loss releases exactly the sides that were held. A key held from before
you pressed ⌘ is released when you let go of it, too.

Two crashes on the second stream of a run are gone. The DualSense reader freed a
buffer macOS still writes controller reports into, which corrupted memory and
took the app down later, and a telemetry lock was never initialised. Both were
found under Address Sanitizer, which the build now supports directly.

Clicking back into a stream no longer leaves the Mac's pointer drawn over the
game. macOS shows the pointer again for menu bar and menu interactions without
saying so, and the stream trusted its own record instead; it now hides it again
on every return.

Quieter, more careful edges from an end-to-end review: cancelling a connection
can no longer launch the game afterwards; quitting during a stream's teardown
waits for the same teardown instead of exiting past it; a reconnect keeps to its
30 second window on every request; a host that is streaming anything, known app
or not, asks before being taken over; pairing results can only land on the PC
that started them; opening the chord recorder or Diagnostics no longer takes the
controller away from a live stream; muting the Mac remembers which output it
silenced and puts that one back (also after a crash); and a Wi-Fi helper race
that could leave AirDrop's radio parked after a stream ended is closed. HDR
metadata updates are now handed to the decoder as one atomic snapshot.

When the Mac's Wi-Fi roams to another access point, or drops and comes back,
during a stream, the session log now says so in plain words next to the video
lines, so a hitch that lines up with it explains itself.

## 2026.9.3 - 2026-09-14

Fixes a crash after a stream ended, if you had visited the Custom resolution
fields in Settings. The fix for typing into those fields in 2026.9.1 tracked
keyboard focus, and macOS could later trip over that tracking while working out
a tooltip. The fields now keep a value of their own and only hand the settings a
number once it is complete and in range, which also means nothing ever rewrites
what you are typing.

## 2026.9.2 - 2026-09-13

Remote streams are judged by the path, not by the moment you pressed Play.

The connect-time latency check used to sample while the PC was busy launching
your game, and it took the worst sample as the verdict. A 10 ms fiber hop read
as 76 ms and got 28 Mbps instead of 80. It now samples before the launch, on an
idle host, and bands on the steady level: three quarters of the samples have to
agree before anything is trimmed, so a post-wake stall or a few Wi-Fi spikes
cannot cap a session by themselves. Paths under 20 ms get the full rate. Ten
seconds into every stream the log now grades that verdict against what the
stream itself measures.

## 2026.9.1 - 2026-09-13

Three fixes reported by an early user, all small, all real.

Command chords no longer leave a key held on the PC. macOS never tells an app
when a letter comes up while Command is held, so Command-D (Win-D on the host)
sent the press and never the release, and the PC kept typing d until the key was
pressed again on its own. Glimmer now catches those releases itself. This only
ever affected streams with "capture system keys" on.

Typing a custom resolution works again. The fields checked their limits on every
keystroke, so a height that began with 1 became 480 before you could finish, and
the rest of what you typed landed on top of that. The limits now apply when you
leave the field.

Watch stream's health shows from the first frame. The overlay was being shown
and hidden in the same instant at stream start and the hide won, so the stats
only appeared after two presses of the hotkey.

## 2026.9.0 - 2026-09-10

You can now stream in a window, and two full-screen dead ends are gone.

Pick the Custom preset in Settings, Quality and set "Show the stream" to Window.
The stream opens as a normal Mac window at your Custom resolution, pixel-mapped
on Retina panels, that you can drag, resize (the picture scales, it never
letterboxes) and send full screen with the green button, with the menu bar and
Dock left alone. Refresh is capped at what your display can actually show, and
the window remembers where you left it. Native Retina and HiDPI are panel-native
by definition, so they stay full screen and are untouched.

Moving the pointer onto the window hands your mouse to the game, cursor and all,
the way it works in anything that plays. Holding Esc for a moment takes it back
and the cursor reappears exactly where it left off, while a tap of Esc still
reaches the game's own menu. Switching apps hands it back too, and moving onto
the window again takes it, so there is nothing to click and nothing to remember.
Control-Option-R does either without moving the mouse, and closing the window
ends the stream.

Custom no longer asks you to set a bitrate. The toggle and the slider are gone,
and the figure now comes from the same measured recommendation the pane used to
print underneath them, following your resolution and refresh, and in a window
the refresh your display can actually show. On a 14-inch MacBook Pro at 120 Hz
that is about 85 Mbps where the old automatic setting asked for 100, so the
honest number is also the smaller one. What it landed on is still there to read
under Your next stream. The size shortcut beside the resolution fields is now a
labelled Presets button rather than a bare glyph, and it runs 720p upward.

Fill the notch now only appears on Macs that have a notch. Turning it off
quietly switched full screen into a macOS full-screen space, and on a Mac mini
that meant leaving the space through Mission Control left the picture nowhere
while the stream kept running. Leaving that space now lands you in a window
instead.

Quitting Glimmer mid-stream now waits, briefly, for the PC to be told the
session is over, so Sunshine never keeps a phantom session that blocks your next
launch.

## 2026.8.18 - 2026-09-02

Glimmer no longer polls your PC while the Mac is going to sleep.

The launcher checks the selected PC every ten seconds to keep the readiness chip
honest. If the Mac fell asleep in the middle of one of those checks, the PC was
left holding a half-finished secure connection, and Sunshine's secure listener
would wait on it forever: every later connection was refused until Sunshine was
restarted, and until 2026.8.17 Glimmer described that as a pairing problem. Any
client can trigger that on Sunshine's side; Glimmer now simply stops being the
one that does. The moment macOS announces sleep the poller stops, and it starts
again on wake with a fresh check.

## 2026.8.17 - 2026-09-02

Glimmer stops telling you to re-pair when the real problem is on the PC.

If Sunshine's secure port stopped accepting connections while its plain port
still answered, Glimmer read the plain reply as "this PC does not know you" and
asked you to pair again. That reading was never sound: Sunshine only reports
pairing over the secure connection and always says "not paired" on the plain
one. The failure itself is now what gets diagnosed. A refused secure port says
so, names the fix (restart Sunshine on the PC) and notes that quitting Glimmer
will not help; a 401 or a certificate rejection still means pair again; a
changed host certificate still points at the amber Trust needed chip.

## 2026.8.16 - 2026-08-30

Fixes a crash at the end of a stream when diagnostics are turned on.

With the optional diagnostics enabled, ending a stream could take the whole app
down. The system interface Glimmer reads processor and power statistics from
does not tolerate having its objects cleaned up the way its naming suggests it
should, and the cleanup at session end could land on memory that was no longer
valid. Glimmer now keeps that reader alive for the life of the app, the way
Apple's own power tools use the same interface, and simply resets its counters
between sessions. Diagnostics stay off by default and this changes nothing else.

## 2026.8.15 - 2026-08-30

The DualSense quit chord works, pairing a second PC works, Glimmer stops taking
things away from Moonlight, and Homebrew can install it.

The controller quit chord Start + Select + L1 + R1 never fired on a DualSense,
even with Extra DualSense buttons on and Input Monitoring granted. macOS binds
the DualSense's Create button to a system gesture (a long press starts a screen
recording), so GameController withheld the press from Glimmer while the chord
read Create from the raw report and L1/R1 from GameController, two views that
disagreed for as long as the chord was held. Glimmer now turns that gesture off
for the Create button when a pad attaches, reads every button of the chord from
one coherent source with the raw report's shoulder bits filling in for
GameController, ignores stray HID report IDs that could flip the decoded
buttons, and writes a short breadcrumb to the session log whenever a chord arms,
cancels, or only partially matches, so a chord that does not fire is diagnosable
from the log. The Settings footnote also now says the default is L3 + R3 rather
than off.

Pairing a second PC works again. After one successful pairing, opening the Pair
window again showed the "Paired" screen from last time, with a blank PC name and
no way back to the list of PCs on your network, until you quit and reopened
Glimmer. The result of a pairing is now tied to the pairing it came from, and
the window starts fresh every time you open it. The window also explains itself
before macOS does: choosing a PC starts a search of your local network, which
makes macOS ask for permission, and a line at the top of the list now says what
Glimmer is looking for and that the system will ask.

Glimmer no longer takes anything away from Moonlight. On first launch Glimmer
copies the client identity from an existing moonlight-qt install so you do not
have to pair your PCs again, and until now it also erased that identity from
Moonlight's own settings afterward. The intent was to avoid leaving a second
copy of a private key in a file Moonlight stores unprotected, but the cost was
that Moonlight quietly lost every host it had paired with the next time you
opened it. Copying is all Glimmer does now. Moonlight's settings are read and
never written, so both apps keep their identities and both stay paired.

If you had chosen Smooth or Maximum before those presets were replaced, Glimmer
no longer forgets which one. Those two settings were dropped in favour of Native
Retina and HiDPI, and the old choice couldn't be read any more, so the app
quietly fell back to Native Retina, the sharpest and most bandwidth-hungry
option, and then overwrote your saved setting so there was nothing left to
recover. Smooth now becomes HiDPI and Maximum becomes Native Retina, matching
what each one was for, and your preset is only ever saved when you actually
change it. In the same spirit, a first launch used to write a resolution,
refresh rate and bitrate into the Custom preset even for people who never open
it; Custom is now filled in when you actually switch to it.

Turning off automatic update checks now sticks. Glimmer switched them back on
every time it started, so the setting in the update window looked like it did
nothing. Automatic checks are still on by default, but if you turn them off,
they stay off. The update window also finally shows what changed: release notes
ride along with each update instead of a blank panel.

A PC that is taking too long to wake is no longer a dead end: the "Waking"
button now offers Cancel (Esc works too), which gives you the launcher back at
once. Your PC may still finish waking on its own.

Smaller things: the certificate mismatch error now points at the amber "Trust
needed" badge instead of a menu that does not exist, the menu bar no longer
claims to be connected to a PC it is only pointing at, the DualSense buttons
offer has a "Not Now" that means not now, the error banner can be dismissed, and
Get Info on the app says GPL rather than "All rights reserved". Glimmer can now
be installed with Homebrew (`brew install --cask se7enbrc/glimmer/glimmer`), and
the download disk image looks like one.

## 2026.8.14 - 2026-08-26

Switching audio devices no longer teaches the stream bad habits, a connection
that never shows a picture fixes itself, and Glimmer finally tells you about
updates.

Popping AirPods in or out mid-stream (or unplugging HDMI audio) used to be
silently counted as evidence of a bad connection: each switch nudged the audio
buffer a step deeper, and the app remembered that per PC - so audio delay crept
up across sessions for anyone who changes audio devices. Device switches are now
recognized for what they are and teach nothing.

A stream that connected but never showed a first frame used to sit on a black
screen until you cancelled it - the ten-second recovery everyone else gets
simply didn't apply before the first picture. It does now.

Internal health checks also now run on a clock that can't be moved by network
time syncs or daylight-saving changes, so a clock adjustment mid-stream can no
longer masquerade as (or hide) a real stall.

And updates: Glimmer used to only look for a new version when you opened the
app - which, if you leave it running for days, meant never. It now checks at
startup and once a day while running, and tells you when a release is waiting.
You can turn the automatic check off in the update window if you prefer quiet.

## 2026.8.13 - 2026-08-26

Hosts added by hostname stream now.

Adding a PC by hostname or fully-qualified domain name - a Tailscale MagicDNS
name, a local DNS record, anything that resolves - used to fail in the most
confusing way possible: pairing worked, the connection reported as established,
and then the stream died instantly, every time. Only the video and audio
channels ever saw the raw hostname; everything before them resolved it on their
own. Glimmer now resolves the name once, up front, and hands the same resolved
address to every part of the session - so names work everywhere an IP does, and
a name that doesn't resolve fails immediately with an error that says exactly
that.

Thanks to the excellent diagnosis in issue #70, which identified the root cause
down to the line.

## 2026.8.12 - 2026-08-21

A rare crash in long-running sessions is gone.

Glimmer could crash out of the blue after days of running - not while streaming,
but quietly in the background, typically some minutes after the Mac woke from
sleep. The cause sat in the bundled OpenSSL library: every secure check-in with
your PC leaves a little bookkeeping on whichever system worker thread happened
to run it, to be cleaned up when that thread is eventually discarded - sometimes
days later, by which point the cleanup could trip over stale memory and take the
app down. Glimmer now does that cleanup itself, immediately after each secure
call, so there is never anything old lying around for the system to trip over.

## 2026.8.11 - 2026-08-18

Glimmer no longer crashes when a stream wakes up from sleep.

If the Mac slept mid-stream, the audio hardware went away underneath the running
session - and about nine seconds after waking, Glimmer could crash outright
while trying to restart sound, because the system audio framework reports that
particular failure by throwing an error the app was structurally unable to
catch. Restarting playback now goes through a guard that catches those errors at
the boundary: if sound can't start yet, Glimmer simply stays quiet and retries
with each arriving packet until the audio hardware is back - a moment of silence
instead of a dead app. The same guard covers every other way the audio engine
can refuse to start.

## 2026.8.10 - 2026-08-17

Two ways a stream could freeze until you reconnected are gone, and unpairing a
PC no longer leaves its power controls aimed at the next one.

An audit of the whole streaming engine found two dormant failure modes with the
same shape as the audio bug fixed in 2026.8.7 - video kept arriving and decoding
perfectly while every frame was silently thrown away, forever, with nothing
noticing. One lived in the recovery path that re-enables smooth pacing after a
rough patch: if the display's renderer got stuck at exactly that moment, no
watchdog could see it. The other lived in the decoder's overload protection: if
Apple's video decoder genuinely hung, the recovery keyframe it asked for was
itself thrown away by the very gate that requested it, in a closed loop. Both
now self-heal within a couple of seconds - the first through the existing
recovery ladder, which can finally see this case; the second by rebuilding the
decoder in place with the arriving keyframe.

Also fixed: removing a paired PC left its Wake-on-LAN address behind, so a new
PC paired afterwards could inherit the old one's wake/sleep/shutdown target -
power buttons aimed at the wrong machine.

## 2026.8.9 - 2026-08-17

The rough first half-minute on Wi-Fi is gone.

A Wi-Fi stream's opening 30 seconds used to stutter - dropped frames, brief
picture freezes - and then settle down on its own. Captured in the numbers:
thirty-six freezes of a tenth of a second or more in the first half minute, then
none at all, on a strong 6GHz connection. The cause wasn't the network warming
up; it was Glimmer relaxing its radio-keepalive too early, letting the Mac's
Wi-Fi radio nap between packets while the access point was still settling its
power-management posture with the new stream. Glimmer now holds the radio awake
for the first 90 seconds of every Wi-Fi session unconditionally, and only then
begins economizing. Wired connections are unaffected, and the cost on Wi-Fi is a
trickle of tiny keepalive packets.

## 2026.8.8 - 2026-08-17

Your desktop mouse can no longer lose its acceleration to a streaming session.

While a stream is focused, Glimmer turns off the Mac's pointer-acceleration
curve so in-game aim is raw 1:1, and puts your setting back the moment you tab
away. A bookkeeping bug could get that restore wrong in unusual situations - two
copies of Glimmer running at once, or a session that ended mid-crash - and your
desktop pointer was then left with acceleration off entirely, surviving
relaunches, until you fixed it by hand in System Settings. The saved value is
now tracked in a way those situations can't corrupt: however a session ends, the
desktop always comes back to the curve you actually had.

## 2026.8.7 - 2026-08-12

Audio now survives being left alone.

A stream left running while the PC sat idle overnight came back with working
video and no sound - permanently, until you reconnected. During the long silence
the audio player had stopped consuming, and once sound resumed every arriving
packet was dropped at the buffer's own safety gates: received, decoded, and
thrown away, with nothing in the pipeline noticing. A watchdog now catches
"audio arriving, nothing playing" within a few seconds and rebuilds the output
path in place - one brief blip instead of a silent session. Long idle stretches
also no longer poison the audio clock's drift tracking when sound resumes, so
the buffer settles back to its normal depth instead of pinning deep.

## 2026.8.6 - 2026-08-04

Sharper picture on high-refresh displays.

Glimmer worked out its quality budget in a way that quietly penalised fast
monitors: every time the frame rate doubled, each individual frame got about 30%
fewer bits to work with. A 240Hz display therefore looked blockier than a 120Hz
one at the same resolution - the opposite of what you buy a fast panel for.
Streaming at 4K240 now gives each frame the same budget 4K120 gets, and 120Hz
modes gain a little too. Anything at 60Hz or below is unchanged.

Measured on a 4K240 HDR stream: each frame went from about 46 KB to 72 KB, with
no added latency and no dropped packets.

Because of this, high-refresh streams now ask your PC for more bandwidth than
before. On a local network that costs nothing; over a VPN or the internet
Glimmer still measures the connection first and asks for what it can carry.

## 2026.8.5 - 2026-08-02

You can browse your PC's apps while a stream is running again.

If a PC has more than five apps, the extras live in a dropdown at the end of the
row. That dropdown was being switched off along with the app tiles whenever a
session was live - which is right for the tiles, since tapping one would start a
second stream, but it also meant you couldn't so much as look at the list
mid-session. The dropdown now opens; only the launching is held back. Screen
readers also get a proper description of what it does.

## 2026.8.4 - 2026-08-02

The launcher sits at a comfortable size again, and every app on your PC is
reachable without it changing shape.

2026.8.3 pinned the window to its content, which left the host card nearly
touching the frame. There is proper breathing room around it again, and the
window is still a fixed size - nothing in the launcher grows, so being able to
drag it larger only ever added empty space.

If your PC has more than five apps, the extra ones now live in a dropdown at the
end of the row instead of being reachable only through the Stream button's
context menu. The menu opens over the window, so reaching a sixth app no longer
resizes anything. App tiles also respond across their whole area now, rather
than only where the icon sits.

## 2026.8.3 - 2026-08-02

Streaming over a VPN is far more reliable, a weak link no longer freezes the
picture indefinitely, and the launcher window no longer opens mostly empty.

If you stream to your PC over a tunnel - Tailscale, WireGuard, or similar -
Glimmer was sizing every video packet for a local network. Those packets are too
big for a tunnel, so each one had to be split in two on the way to you, and
losing either half lost the whole packet. On an already-marginal connection that
multiplied the damage: in one captured session the picture stopped entirely for
fifteen minutes while video kept arriving, because none of it could be
reassembled. Glimmer now measures the actual route to your PC when a stream
starts and sizes packets to fit it. Streaming on a local network is unchanged.

Glimmer now also checks the connection quality before a stream starts. During
the moment it already spends contacting your PC, it measures how long
round-trips are taking - not the best case, but the slow tail, which is what
actually causes stutter - and if your PC is far away or the path is congested,
it asks for a bitrate that path can realistically carry instead of the one your
resolution would want on a local network. Streaming on a local network is
unaffected, and if the measurement doesn't succeed for any reason, nothing is
capped.

And if a remote connection still can't carry the stream, Glimmer lowers the
quality and reconnects in place rather than holding a frozen frame forever:
you'll see a brief pause and a note that quality is being reduced, then the
picture returns. It steps down at most twice, never on a local network, and
never raises the quality back on its own.

The launcher window is now exactly as big as what's in it, and no longer
resizable in either direction. Nothing in it grows - one host card, a row of
chips, a button - so dragging it larger only ever added empty space.

## 2026.7.7 - 2026-07-22

Wake your PC from the couch - power controls appear when your setup supports
them, and a sleeping PC is recognized in seconds.

If your gaming PC is managed by UpSnap and the `luna` command-line tool is set
up on your Mac, Glimmer's host card now grows power controls: with the PC
asleep, the big stream button becomes **Wake & Connect** - one tap wakes the
machine (confirmed, not fire-and-forget), waits for Sunshine to answer, and
starts your stream; a quiet power menu in the corner offers plain Wake, and -
while the PC is online - Sleep, Restart, and Shut Down behind confirmations. No
luna, or a PC that UpSnap hasn't granted you? Nothing appears at all - no
buttons, no settings, zero clutter. Glimmer never touches your UpSnap
credentials; the identity check is the host's hardware address, learned
automatically while the PC is online.

Recognizing a sleeping PC is also much faster: opening the app used to sit on
"Checking…" for half a minute before admitting the host was asleep. A cold start
now reads Asleep after a single missed probe (about two seconds), while a
briefly-hiccuping online host keeps the old benefit of the doubt.

## 2026.7.6 - 2026-07-22

Streams open quiet, and packet reorders become a checked guarantee.

The audio cushion now remembers what it learned for days instead of hours. Its
per-connection memory used to fade out in about six hours, so any stream after a
day away re-learned its buffer depth the audible way - several small sound blips
across the first minute. The memory now holds for days, starts no shallower than
what the live connection indicates, and the opening minute no longer teaches the
buffer bad long-term habits.

Wi-Fi packet reordering is now tracked as a guarantee instead of a statistic. On
any shared airwave a small number of packets arrive slightly out of order -
that's radio physics, not a fault - and what matters is only that each one
arrives inside the window the stream already holds open for it. Glimmer now
measures exactly how late every reordered packet is, proves it landed inside the
window, and counts the only thing worth alarming on: one that didn't.

## 2026.7.5 - 2026-07-19

Mouse feel settles on honest and raw, drags match free aim again, and battery
streams stop chugging.

Click-and-drag aim now travels the same as free aim. The macOS 27 beta delivers
held-button mouse motion smaller than free motion for the same physical
movement - precision aim while holding a button felt heavy and under-traveled.
Glimmer now measures for this and scales drag motion back to parity.

The "magic" fast-flick traversal boost is now off by default. Field data settled
an honest question: at 4K, a quick combat aim-flick and a cross-screen traversal
flick are the same speed and size to any detector, so any automatic boost
eventually boosts your aim - felt twice as sudden sensitivity jumps. Raw,
predictable 1:1 aim everywhere wins. (The machinery remains for the adventurous
via hidden settings.)

Streams on battery stop chugging. When macOS throttles the display clock below
the stream's frame rate (common on battery, sometimes even plugged in), ~13
frames a second had nowhere to land and playback ran rough. The pacer now
detects content outrunning the display clock and fills the missing beats from
its own timer, holding steady until the display genuinely recovers.

Under the hood: a much deeper self-diagnosis toolkit - frame-delivery cadence
histograms at three pipeline stages, stutter and gap counters that name their
cause, audio-margin tracking that sees trouble before it is audible,
mouse-motion distributions, and battery/low-power state - so the next "something
feels off" gets answered from data in minutes.

## 2026.7.4 - 2026-07-05

No more stuck keys when something steals focus mid-game.

If another app grabbed the foreground while you were holding a key - say W,
walking forward - the key's release went to that app instead of the stream, so
the game kept the key pressed indefinitely: you walked on until you clicked back
in and pressed it again. The stream now releases every held key and mouse button
the moment its window loses focus, so a focus steal stops your character instead
of committing it to a wall. A key you're still holding when you click back in
picks up again on the next press.

## 2026.7.3 - 2026-07-05

A much smoother first half-minute, and audio that stops hoarding latency.

Streams used to open with a rough patch: the audio cushion started shallower
than the connection had already learned it needed, and the host feeds audio
slower than real time for its first seconds - so the opening of a session could
blip audibly several times over ~15 seconds while the buffer taught itself back
up. The cushion now starts at the link's real learned depth and tops itself up
the moment the connection type is confirmed, so a session opens with at most one
brief quiet moment instead of a cascade.

That same opening cascade also had a lasting cost: it taught the player a
falsely deep "floor," which quietly held audio a fifth of a second behind for
the rest of the session and carried over to the next one. Startup no longer
teaches the floor, and a floor that got stuck that way is now repaired on read,
so audio latency settles back down during quiet play the way it was always meant
to.

## 2026.7.2 - 2026-07-02

Smoother streams when macOS throttles the display clock, honest stutter
accounting, and audio that starts in sync.

macOS sometimes throttles the display callback below the rate the stream asked
for (commonly on battery); frames then slip a beat every few seconds - a subtle,
persistent judder. The pacer now notices the throttle within a second and fills
the missed beats from its own timer until the display clock recovers, so the
stream stays smooth through it.

The "felt stutter" telemetry signal now counts what you actually see: a screen
that visibly held while frames were still arriving (a bad network moment, a
decode stall). It previously required a rare double-fault and had never fired in
practice; the stutter badge's thresholds are unchanged.

Audio now remembers each PC's clock offset. Every computer's clock runs a hair
fast or slow, and the player learns the difference to keep audio buffered
tightly - but that learning restarted from zero every session, leaving the first
minutes prone to audio blips while it re-converged. The learned offset is now
saved per PC and applied from the first second of the next stream.

## 2026.7.1 - 2026-07-02

Internal naming cleanup - nothing you can see changes.

Glimmer's streaming engine has been first-party Swift for a while now, so the
app's core types no longer carry the "Moonlight" name they were first sketched
under. This release renames them to plainer, protocol-neutral names. Your paired
PCs, quality settings, and pairing all carry over untouched - there is nothing
to redo. Moonlight is still credited in About; the transport is ported from its
open-source code.

## 2026.7.0 - 2026-07-01

Smoothness reads honest at the desktop, and clearer pairing errors.

When no game is running, the desktop often sits at a low, sparse frame rate -
nothing is wrong, there just aren't many frames to pace. The stats overlay's
smoothness reading used to plummet in that state (as low as single digits) even
though the picture was perfectly steady, because it scored the long idle gaps
between frames as if the player had paced them late. It now recognizes a content
gap - no frame was waiting to be shown - as distinct from a genuine pacing miss,
so an idle or low-frame-rate desktop reads healthy while a running game that
actually drops its cadence still shows it. The "Stream stuttering" badge is
unchanged.

Pairing also tells you more when it can't connect: if the host is offline, at
the wrong address, or not on your network, the error now names the host and says
to check it's on and reachable - distinct from an actual pairing or PIN failure,
which stays a deliberately vague "try again."

## 2026.6.54 - 2026-06-30

Reliability + smoothness pass from a deep code review.

The adaptive jitter buffer is working again on the default install. It steers
the playout buffer deeper on a jittery link to absorb hitches, but it had
quietly gone dormant unless diagnostics were enabled - so a normal install sat
at the shallowest depth and never adapted. It now tracks live network jitter
directly, so a wifi or congested link gets the deeper buffer it needs.

Plus a batch of edge-case fixes: quitting mid-stream no longer leaves the Mac's
pointer acceleration overridden; audio recovers if the output device isn't ready
the instant you switch it; a connection that fails right as the stream window
opens can't steal focus or hide the cursor; waking on a high-latency link
reconnects faster; the pairing success screen's buttons are clickable again; a
stale error no longer names the wrong host after switching machines; and the
reconnect banner is announced to VoiceOver.

## 2026.6.53 - 2026-06-29

The "Stream stuttering" badge is now much harder to fool. On a healthy Wi-Fi
link with normal jitter, the player drops a stale frame and immediately shows
the freshest one - a catch-up you never see, not a stutter - yet the badge used
to count those and light up anyway. It now lights only when the screen actually
held on a frame (a real hitch), so a smooth-but-jittery stream stops getting
flagged. Genuine stutters - sustained dropped or held frames - still trip it.

## 2026.6.52 - 2026-06-29

Reliability pass from a full concurrency audit - a class of rare races that
could surface as a crash on disconnect, audio drift, held input after a
reconnect, or a stream coming up muted.

Closed a recurring pattern where a per-session object (the diagnostics log sink,
frame-timing tracker, telemetry event sink, decoder backend handle) could be
torn down on one thread while another was still reading it - the kind of
use-after-free that only bites under an unlucky disconnect. The audio
drift-corrector's internal state is now properly synchronized, the frame pacer's
real-time thread can no longer be orphaned if a stream stops the instant it
starts, input no longer stays stuck disabled after a silent reconnect, and
starting a new stream right after the last one can't leave it muted.

## 2026.6.51 - 2026-06-26

Magic resolution-aware mouse traversal - fast flicks cover the screen
consistently at any stream resolution while aim sensitivity stays exactly raw.
Automatic, no settings.

## 2026.6.50 - 2026-06-26

Robustness pass from a wide audit - several real "works until it doesn't" gaps.

Audio now recovers mid-stream. Switching output device while streaming (AirPods,
a USB DAC, unplugging HDMI, an OS sample-rate change) used to stop the audio
engine for good - sound gone until you reconnected. It now detects the change
and restarts the engine in place, and a stream that comes up with audio
genuinely failing now says so instead of going silently video-only.

Held controller inputs survive a reconnect. After a silent reconnect or a
wake-from-sleep, a held trigger/stick/button used to read as released on the
host until you moved it (ADS dropped, your character stopped, a charge
cancelled). The real held state is now re-sent on reconnect.

A host that crashes or drops now shows a distinct "ended unexpectedly" message
with Retry, instead of the same calm toast as a clean quit. A wedged launch now
gives up after ~22s (was ~55-65s) and Cancel bounces back immediately.

Under the hood: quitting mid-reconnect no longer leaks a background connection;
the per-session diagnostics trace is now size-capped and old logs are swept (it
could grow unbounded); release builds refuse to build from an uncommitted tree;
plus telemetry-accuracy fixes. No change to streaming/latency behavior.

## 2026.6.49 - 2026-06-26

Release-integrity gate: release builds are now refused from a dirty worktree,
and publishing asserts the committed version at the tag matches the built
bundle - so the GPLv3 source at a tag always reproduces the binary (closing the
2026.6.48 dirty-build gap). Adds a per-session diagnostic for why the 2026.6.47
real-time present scheduling never engages in the field, plus telemetry-accuracy
fixes: per-second metrics no longer emit a giant spike across a reconnect, the
real-time gauge no longer lies on reconnect, and the present on-time/late counts
are now honest per-window gauges instead of non-monotonic counters. No behavior
change.

## 2026.6.48 - 2026-06-26

Under the hood: confirms the 2026.6.47 real-time scheduling actually took (a
queryable flag) and splits any residual present-timing miss into "the timing
thread was starved" vs "the display didn't hand us a frame in time" - so the
rare remaining hitch has a precise, named cause instead of a guess. No behavior
change.

## 2026.6.47 - 2026-06-26

Kills the residual intermittent stutter on high-refresh displays. The
present-timing thread (added in 2026.6.32) could still be preempted by the
system under load, firing its display callback a couple of frames late - a brief
judder that read as dropped frames even though the connection and decode were
perfect (diagnosed precisely: the thread was being descheduled, not the panel
changing refresh). It now runs with real-time scheduling - the same class
CoreAudio's audio thread uses - so it gets a guaranteed slice every frame and
can't be shoved off the CPU. No added latency, negligible CPU cost.

## 2026.6.46 - 2026-06-26

Under the hood: a diagnostic that pinpoints why the present-timing tick
occasionally fires late on a high-refresh display - distinguishing the timing
thread being preempted from the OS coalescing the callback. No behavior change;
it tells the next release which fix is the right one.

## 2026.6.45 - 2026-06-26

Under the hood: new diagnostics, no change to behavior. Breaks stream-launch
time into its sub-steps (so a slow start is attributable to the right leg),
counts network-route changes (e.g. waking on a new Wi-Fi network) and input-path
backpressure, and adds a controller-delivery latency measure - making the next
wake/launch hiccup a one-query diagnosis.

## 2026.6.44 - 2026-06-26

Recovers fast when you wake the Mac mid-stream. Before, waking on a different
Wi-Fi network left the stream's connection stale with no wake handling at all -
and because the dead-connection timer pauses during sleep, recovery didn't even
start for ~10 seconds (the black-screen hang). Now, on wake, the app immediately
re-checks the link and - if the connection has gone silent - reconnects in place
within about two seconds instead of waiting it out. A healthy wake on the same
network is untouched.

## 2026.6.43 - 2026-06-26

Lowers standing audio latency on a clean wired link. Audio kept roughly 150ms
more buffer than a good wired connection needs - around a quarter-second of
avoidable lip-sync lag - because the buffer seeded deep whenever the network
came up "unknown" (e.g. right after waking on a new network) and never converged
back down. On a clean wired link whose clock is well-behaved, the buffer now
walks down to a tight, low-latency depth; a link that's actually struggling
(real underruns or large clock skew) keeps its deeper buffer untouched.

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
