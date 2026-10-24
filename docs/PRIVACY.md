---
description: Understand connections, local diagnostics and what you share.
icon: user-shield
---

# Play without accounts or tracking

| Glimmer contacts | Purpose                                   |
| ---------------- | ----------------------------------------- |
| Your PC          | Pairing, apps, artwork, streaming, input. |
| Local network    | Discovery, wake.                          |
| Update service   | Checks, signed downloads.                 |

No analytics or other third-party calls.
[Connection security](SECURITY.md#network-paths).

## Local diagnostics

{% hint style="info" %}

[Telemetry](guides/TROUBLESHOOTING.md#record-a-rough-moment) defaults off.
Nothing uploads automatically.

{% endhint %}

| Data                       | Contents                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------- |
| In-app logs                | May show PC names, addresses, errors.                                                        |
| Copied/system/session logs | Private values hidden; no keys, PINs, certificates.                                          |
| Telemetry                  | Performance, apps, setup; PC/Mac names replaced with codes.                                  |
| Optional input trace       | Pointer, controller, motion, scroll; no keys, mouse buttons, pasted text, touchpad contacts. |
| Audio diagnostics          | State/timing; no device names/IDs.                                                           |

## Review before sharing

1. Open `~/Library/Logs/Glimmer/`.
2. Check for identifying app, display or network details.

{% hint style="warning" %}

Never share pairing files, keys, PINs, certificates or profiles. Other software
using your account can access Glimmer's data and commands. Streams can appear in
screen shares. [Security](SECURITY.md#threat-model).

{% endhint %}

{% hint style="info" %}

Logs expire after 14 days;
[size limits and network access](PROFILING.md#opt-in-telemetry) are documented
separately. Glimmer never captures microphones or reads, stores or exports
head-pose or spatial-audio profile data.

{% endhint %}

Next: [report a problem](guides/TROUBLESHOOTING.md#report-a-problem).
