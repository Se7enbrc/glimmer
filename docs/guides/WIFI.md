---
description: Reduce Mac Wi-Fi interruptions and choose a Bandwidth setting.
icon: wifi
---

# Reduce Wi-Fi interruptions

On Mac, enable the optional Wi-Fi helper. It isn't part of the iPhone or iPad
app.

1. Accept Glimmer's helper offer, or open Settings › Quality › Network.
2. Turn on “Smooth out Wi-Fi stutter”.
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

## Bandwidth: Automatic, Maximum and Saver

Settings › Quality › Network has a “Bandwidth” choice. On Mac it offers
Automatic, Maximum and Saver. On iPhone and iPad it offers Automatic and Saver.

- Automatic starts at the most the connection can carry and steps down only
  while it struggles, then raises the bitrate again once the connection
  recovers. The game stays running on the PC while Glimmer reconnects in the
  same stream view. A longer adjustment says “Adjusting stream quality…”; brief
  changes may show no message.
- Maximum (Mac only) asks for the most detail the connection allows, with
  automatic adjustment off.
- Saver uses a lower, fixed bitrate with automatic adjustment off. On iPhone and
  iPad it is a fixed 20 Mbps.

On Mac, the public release channel starts at Maximum; beta and diagnostic builds
start at Automatic. On iPhone and iPad, TestFlight builds start at Automatic and
production builds start at Saver. Your choice is kept and applies to the next
stream.

### Low Data Mode on iPhone and iPad

With Automatic, Low Data Mode caps the bitrate at 9 Mbps and starts new streams
at up to 1080p and 60 fps. Continuing a running game keeps its known size rather
than changing it for Low Data Mode. With Saver, iPhone and iPad request 20 Mbps
and do not apply this Low Data Mode profile.

Next:
[get help with continuing stutters](TROUBLESHOOTING.md#record-a-rough-moment).
