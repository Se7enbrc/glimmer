# Audio on macOS

Glimmer follows the Mac's selected audio output during a stream. Compatible
AirPods use spatial playback and head tracking automatically. Change outputs
through macOS; there is no separate spatial-audio switch in Glimmer.

## Bluetooth headphones and voice chat

Using a Bluetooth headset's microphone can change its playback quality and
volume. A game that sounds clear with the microphone idle can sound muffled when
Discord or another voice app starts using it. Apple describes this
[Bluetooth audio behavior](https://support.apple.com/en-us/102217).

When possible, select a separate microphone in your voice app: the Mac's
built-in microphone, a webcam microphone, or a USB microphone. Keep the AirPods
selected as the output. In our testing, switching Discord's input from AirPods
to a Logitech C920 microphone substantially improved playback quality.

The result depends on the headphones, macOS version and voice app. Game Mode
does not guarantee that simultaneous Bluetooth playback and microphone use will
sound the same as playback alone. Glimmer does not capture microphone audio or
change Discord's input selection.

## Volume after a microphone or output change

During testing, changing the microphone sometimes left playback quieter even
though the Mac's volume control still showed its previous level. A small
adjustment with the system volume control restored the expected loudness.

If this happens, make a small system-volume adjustment and return it to your
preferred listening level. This is an observed workaround; the cause of the
retained low volume has not been confirmed. It is separate from the Bluetooth
quality change above.

Glimmer does not normalize loudness or boost its gain to compensate for a quiet
device transition. A compensating boost could become too loud when the device
recovers. When reporting a volume problem, note whether other Mac apps are also
quieter, which input and output are selected, and whether adjusting system
volume restores the sound.
