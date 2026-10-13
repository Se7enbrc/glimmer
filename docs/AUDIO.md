# iOS audio output

`IOSAudio.platform(environment:)` supplies the public engine `AudioPlatform`
contract. The caller supplies its measured PC/link environment and constructs
`AudioDecoder(platform:)`, then passes it to `StreamConnection` as its audio
sink. The connection's audio configuration starts at stereo. No stream is
started by the adapter or the current preview UI.

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

The tracked project pins the reviewed audio-engine merge at
`7891fac58264b211830a0e630e6e4bdb7cc55599`; normal builds resolve that exact
commit. For local engine development use
`make app ENGINE_PATH=/absolute/path/to/glimmer`. Lifecycle tests inject
session/AudioUnit calls; they do not prove playback. Unsigned Simulator/device
builds, executed hosted tests, and physical speakers plus wired/Bluetooth route
changes, interruption, media reset, stop/reconnect, sustained audio and power
measurements are separate acceptance evidence.

Apple's
[interruption guidance](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
and
[media-services reset guidance](https://developer.apple.com/library/archive/qa/qa1749/_index.html)
describe the system lifecycle. The graph uses the engine's render limits and
reads RemoteIO's
[maximum render quantum](https://developer.apple.com/library/archive/qa/qa1777/_index.html)
before initializing processing units.
