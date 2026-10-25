---
description:
  Reduce Mac Wi-Fi interruptions and use adaptive stream quality in beta builds.
icon: wifi
---

# Reduce Wi-Fi interruptions

On Mac, enable the optional Wi-Fi helper. It isn't part of the iPhone or iPad
app.

1. Accept Glimmer's helper offer, or open Settings › Quality › Wi-Fi.
2. Turn on the helper.
3. Approve it in System Settings › General › Login Items & Extensions when
   asked.

{% hint style="info" %}

AirDrop pauses during streams and returns afterward. The helper needs
administrator approval; see [Security](../SECURITY.md#runtime-hardening). The
offer appears on every Mac until enabled or declined for good.

{% endhint %}

{% hint style="info" %}

Setup failed? Follow the recovery message in Settings.

{% endhint %}

## Adaptive stream quality in beta builds

Beta builds on Mac, iPhone and iPad enable “Adaptive stream quality” by default.
It lowers the bitrate within seconds when the connection struggles, then raises
it again once the connection recovers. The game stays running on the PC while
Glimmer reconnects in the same stream view. A longer adjustment says “Adjusting
stream quality…”; brief changes may show no message.

To compare it with a fixed bitrate:

1. Open Settings › Diagnostics.
2. Turn off “Adaptive stream quality”.
3. Start a new stream.

On Mac, if the switch is hidden, open Settings › About and Option-click the
version number to reveal the extra Diagnostics controls. Production iPhone and
iPad builds omit Diagnostics.

### Low Data Mode on iPhone and iPad

With adaptive quality on, Low Data Mode caps the bitrate at 9 Mbps and starts
new streams at up to 1080p and 60 fps. Continuing a running game keeps its known
size rather than changing it for Low Data Mode. Without adaptive quality, iPhone
and iPad request 20 Mbps and do not apply this Low Data Mode profile.

Next:
[get help with continuing stutters](TROUBLESHOOTING.md#record-a-rough-moment).
