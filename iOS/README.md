# Glimmer for iPhone and iPad

Your PC games, on your iPhone or iPad. Native controls. No accounts or tracking.

**This is an early development build.** The app finds nearby PCs running
Sunshine, pairs with a PIN, lists their apps and connects a video and stereo
audio stream. Physical controllers and simple touch use the shared input engine.
See the fixed [input mapping](docs/INPUT.md).

Use the iPhone launcher, Settings and pairing screens in portrait or landscape.
iPhone streams stay in landscape; menus can rotate again after disconnecting.
iPad streams start in either orientation and fill the whole window, including
Split View and Stage Manager. This build keeps the initial stream size after a
window resize, matching iPhone rotation. The picture fills the new window and
can crop at the edges. The app opts into iOS Game Mode; the system controls its
activation.

The launcher shows the PC, its requested stream settings and its app buttons.
The last connected PC loads automatically, including after disconnecting. With
no previous connection, a single paired PC is selected. Use the PC name to
switch PCs; pairing, quality, controller preferences and diagnostics live in
Settings. Settings → General offers Buttons or Covers. Both layouts adapt to the
screen and text size; Covers uses artwork supplied by the PC, with a glyph
fallback.

To remove a saved pairing, open Settings → PCs, choose Forget… next to the PC,
and confirm Forget PC. This removes the local pairing and its remembered
selection; it leaves the game running on the PC. Pair again through discovery or
Add PC by address…. If Sunshine's identity changed because you reset it, use
this recovery path instead of accepting a changed certificate automatically.
Disconnect your stream before forgetting a PC.

Native is the default, followed by 1080p 60 and 1080p 120 in Settings. Install
[the iPhone and iPad display modes](../docs/HOST_SETUP.md#pick-your-file) on the
PC. Both devices request only modes from that file. Native chooses the closest
listed size to the window's pixels; 1080p always requests 1920 × 1080. The
choice is saved. Requests use the listed refresh rate up to the profile and
display maximum, so window modes generally run at 60 fps. All three choices use
H.264, SDR, stereo and 20 Mbps for the initial device tests. Video fills behind
cutouts. A different aspect crops edges; a lower resolution loses detail. The PC
and game must use the requested aspect to avoid black bars inside the video. If
discovery cannot find the PC, choose Settings → PCs → Add PC by address… and
enter its IP address or hostname. Pairing and certificate verification use the
same connection flow. Development builds keep the display awake throughout the
active app. Release builds do so only during a stream. Leaving the app restores
ordinary auto-lock; manually locking still stops a stream. Disconnecting stops
the local stream immediately. Brief app switches preserve it for up to 15
seconds, with input released; staying away longer disconnects. iOS may end this
grace period earlier. Screen lock disconnects immediately. All of these actions
leave the game running on the PC. Real-PC playback and physical-device behavior
still need validation.

- Requires iOS or iPadOS 26 or later.
- Built for physical controllers, including Backbone One.
- Streaming uses Sunshine on the PC.

Want to build or help? Start with [CONTRIBUTING.md](CONTRIBUTING.md). See the
[engine roadmap](../docs/IOS_ENGINE_ROADMAP.md) for what comes next. Free
software under [GPLv3](LICENSE).

See [PC setup](docs/HOST_SETUP.md) for Sunshine and native display modes, and
[diagnostics](docs/DIAGNOSTICS.md) for recording a physical iPhone test.
