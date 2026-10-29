# iOS audio output

`IOSAudio.platform(environment:)` supplies the public engine `AudioPlatform`
contract. The caller supplies its measured PC/link environment and constructs
`AudioDecoder(platform:)`, then passes it to `StreamSession.PreparedMedia` as
its audio decoder. The connection's audio configuration starts at stereo. The
launcher starts the shared session; the audio adapter does not initiate a
stream.

The engine owns Opus decode, buffering, drift correction, render storage and C
callbacks. Each `AudioOutput` owns one `IOSAudioOutput` graph: engine render
callback, varispeed, multichannel mixer, RemoteIO. The mixer adapts stereo PCM
to the actual output's mono or stereo channels. Source formats beyond stereo
fail explicitly. The adapter never copies decoded samples or wraps render
callbacks in Swift closures.

`AVAudioSession` uses playback/default mode without mixing other audio. It
requests the source sample rate, then validates the session's actual route,
sample rate, channel count and I/O duration. RemoteIO's hardware format owns the
graph's output rate and channel count. Reported latency is a system-reported
estimate: hardware output latency plus one output I/O duration plus varispeed
and mixer processing latency. RemoteIO's own unit latency is not added, avoiding
a second device/buffer term. Preferred values are never reported as actual
measurements.

The SDK describes `AVAudioSession.outputLatency` as hardware output latency and
`ioBufferDuration` separately as hardware I/O duration. Its
`kAudioUnitProperty_Latency` documentation defines each unit's processing delay,
and `kAudioUnitProperty_PresentationLatency` describes device/buffer delay plus
downstream processing. This supports the sum above; it does not establish
measured acoustic latency or expose every route's safety offset. Bluetooth and
physical output timing still require hardware measurement. See Apple's
[hardware output latency](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputlatency)
and
[I/O duration](https://developer.apple.com/documentation/avfaudio/avaudiosession/iobufferduration)
API descriptions.

Session and AudioUnit hooks run off the render thread. The adapter adds no
polling or timers. Notifications first enter a serial event queue so a
synchronous system notification cannot reenter a locked session call. Route,
interruption and media-services events invalidate graph generations and queue
the engine's existing configuration-change callback. Interruption end resumes
only with `shouldResume`; otherwise a new stream lifecycle is required. Media
services loss blocks activation; reset reapplies session configuration and
requires a new graph. Removed observer generations cannot affect a new stream.

The platform owns session state, never a graph. Output hooks retain their
individual graph until the engine releases that output. Teardown disables engine
render storage, stops RemoteIO and disposes readers before upstream units. A
disposal failure stops that chain and retains the raw callback storage through
the engine's lifetime guard. Session deactivation waits until stream observation
is removed and the final graph lease is released. Route rebuilds keep the
session active between graphs. Deactivation failure is logged privately and is
retried on later cleanup.

The tracked engine revision and local override procedure are documented in
[CONTRIBUTING.md](../CONTRIBUTING.md). Lifecycle tests inject session/AudioUnit
calls; they do not prove playback. Unsigned Simulator/device builds, executed
hosted tests, and physical speakers plus wired/Bluetooth route changes,
interruption, media reset, stop/reconnect, sustained audio and power
measurements are separate acceptance evidence.

Apple's
[interruption guidance](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
and
[media-services reset guidance](https://developer.apple.com/library/archive/qa/qa1749/_index.html)
describe the system lifecycle. The graph uses the engine's render limits and
reads RemoteIO's
[maximum render quantum](https://developer.apple.com/library/archive/qa/qa1777/_index.html)
before initializing processing units.

## Receive-to-output boundaries

The receive socket remains unconnected and filters only the PC's IP, permitting
Sunshine's different source port. Both platforms use `receiveOne`; iOS has no
audio-specific connected-socket path. A failed receive startup can leave video
running; inspect the receive error in Apple system logs.

The shared receiver rejects malformed RTP and invalid encrypted payloads before
queue admission. The queue can hold, discard or recover packets; startup backlog
draining deliberately withholds stale packets. Ordered payloads pass through
AES-CBC to AudioToolbox Opus, then the decoder's admission gate, PCM pool,
latency-bound scheduling and SPSC ring. Reconfiguration, pool exhaustion, failed
decode, overrun and unavailable output can each prevent PCM from reaching
render. Native output and lifecycle tests cover these boundaries.

The iOS-specific boundaries are session activation, usable route validation,
stereo-only source admission, RemoteIO format negotiation, unit initialization
and generation-checked start. Graph setup failure deliberately leaves receive
and video alive while recovery retries, so decoder initialization success does
not establish playback. A stale lease, interruption or media-services loss can
block start. Interruption end without `shouldResume` requires a new stream.

The iOS graph does not copy a hardware channel layout and requests stereo, so
the Mac copied-layout/LFE failure has no direct counterpart here. It converts
the 48 kHz source to the negotiated output rate. Playback category bypasses the
silent switch; system media volume and route selection still apply. The shared
mute flag defaults off in the iOS stream configuration. Ring consumption stays
disabled until priming succeeds. Custom mixer probes are Mac-only.

History records the native adapter introduction at `341f417d` with physical
audio validation still open. The imported history does not establish a last
known audible iPhone revision. Passing synthetic output tests cannot identify
the failing stage in TestFlight build 6 without evidence from the device.

## Diagnose silent playback

RemoteIO may report a zero hardware sample rate before initialization. The
adapter uses the activated session's rate in that case. Simulator coverage feeds
synthetic encrypted 5 ms stereo RTP through the receiver, Opus decoder and PCM
ring, then pulls the native varispeed and mixer and requires nonzero output. It
does not prove socket delivery, physical output or audibility on an iPhone.

Use Apple's logs for the device:

1. Play a known audible source on the PC, select the iPhone speakers and raise
   the media volume. Record the app build and iOS version.
2. Stream for 30 seconds. Note whether sound ever starts and the time of any
   output change or interruption.
3. Review Glimmer's session activation, route, interruption, graph and receive
   messages in Console, or collect a sysdiagnose when requested.
4. Compare the timestamps with Sunshine's logs and the player's notes.

Glimmer writes no iOS session telemetry, audio probes or diagnostic files in any
flavour. System messages redact private error details and contain no audio
samples, keys or button presses. Logs cannot establish physical audibility;
verify speakers, wired and Bluetooth routes on authorized test hardware.

Next: [investigate an iPhone or iPad problem](DIAGNOSTICS.md).
