# Glimmer for iPhone and iPad

Your PC games, on your iPhone or iPad. Native controls. No accounts or tracking.

**This is an early development build.** The app finds nearby PCs running
Sunshine, pairs with a PIN, lists their apps and connects a landscape video and
stereo audio stream. Controller input forwarding is still being built.

The initial stream is H.264, 1920 × 1080 at 60 fps, SDR and 20 Mbps.
Disconnecting or backgrounding the app stops the local stream and leaves the
game on the PC. Real-PC playback and physical-device behavior still need
validation.

- Requires iOS or iPadOS 26 or later.
- Built for physical controllers, including Backbone One.
- Streaming uses Sunshine on the PC.

Want to build or help? Start with [CONTRIBUTING.md](CONTRIBUTING.md). See the
[engine roadmap](https://github.com/Se7enbrc/glimmer/blob/engine/spm/docs/IOS_ENGINE_ROADMAP.md)
for what comes next. Free software under [GPLv3](LICENSE).
