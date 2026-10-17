# Record an iPhone test

In Settings → Diagnostics, turn on **Record diagnostics**, then start a new
stream. Development builds enable it by default; production builds default to
off. The choice is saved. Recording uses the shared engine's existing diagnostic
log, performance samples, frame traces and session report. Nothing is uploaded.
Its metrics listener is loopback-only, even if a LAN preference exists.

To investigate silent audio or rumble that stops:

1. Start a game or other PC source that is definitely producing sound.
2. Note the selected iPhone output, volume, stream format and controller mode.
3. Play for 30–60 seconds. Note when audio or rumble fails, and whether Menu
   mouse mode, unplugging, backgrounding or changing audio output preceded it.
4. Disconnect in Glimmer so the recorder flushes its files. Leave the PC game
   running. Connect the unlocked iPhone directly to the Mac to retrieve the
   files.

With Xcode command-line tools, copy only Glimmer's diagnostic directory:

```sh
xcrun devicectl device copy from --device YOUR_DEVICE_ID \
  --domain-type appDataContainer --domain-identifier io.ugfugl.Glimmer.iOS \
  --source Library/Application\ Support/Diagnostics --destination ./iphone-diagnostics
```

Files include `glimmer-*.log`, `telemetry-*.ndjson`, frame traces and
`telemetry-session-*.json`, plus `controller-capabilities.json` with the
controller kind, original face symbols and advertised rumble/touchpad
capability. Private log fields are redacted and PC identifiers in telemetry are
pseudonyms. Do not copy the app's identity or pairing storage. The shared
recorder applies its existing retention and size limits. Disable recording for
an overhead comparison after the problem is understood.

Audio samples distinguish packet arrival, decoding, buffering, render progress,
output state and volume. Controller logs include rumble activation, input
ownership changes, native engine stop/reset and retry events. They do not record
button presses or audio content. Missing platform-specific measurements remain
unavailable; Mac Wi-Fi, GPU and power probes are not supplied by this iPhone
adapter.

This records evidence; it does not establish that missing audio or rumble is
fixed. Correlate the iPhone files with Sunshine's logs and the player's notes.

Some devicectl versions truncate ISO timestamp filenames at colons during a
folder copy. Copy each file by its complete name instead, for example
`Library/Application Support/Diagnostics/glimmer-2026-10-15T02:20:24Z.log`. Use
a destination filename without colons. The full names follow the session's start
timestamp; the session report uses its end timestamp.
