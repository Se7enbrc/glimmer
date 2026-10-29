---
description:
  How Glimmer protects connections, verifies downloads, and handles reports.
icon: shield-halved
---

# Protect your connection to the PC

Use these precautions on Mac, iPhone and iPad. Shared pairing and transport
protections have the same protocol limits on each platform.

## Pairing

1. Pair on a trusted network or authenticated encrypted tunnel.
2. Enter Glimmer's four-digit PIN in Sunshine.

{% hint style="warning" %}

Keep Sunshine's pairing and streaming ports off the public internet. First
contact is unverified. Video is unencrypted unless Sunshine requires encryption;
audio encryption has [protocol limits](ARCHITECTURE.md#protocol-security).

{% endhint %}

## Pinning

1. Confirm why the PC's certificate changed when Glimmer shows “Trust needed”.
2. Choose “Pair again…” only after confirming the change.

{% hint style="info" %}

Glimmer remembers the paired PC's certificate and refuses a changed one. It
never silently replaces that trust.

{% endhint %}

## Runtime hardening

On Mac, the optional [Wi-Fi helper](guides/WIFI.md) pauses AirDrop's radio
during streams. It needs administrator approval and accepts requests only from
the signed Glimmer app. It cannot run arbitrary commands.

## Threat model

{% hint style="warning" %}

Protect your Mac account. Glimmer runs without App Sandbox; software running as
you can read pairing data and send local commands, including quitting PC apps.
The iPhone/iPad app keeps its identity and pins in its app container and has no
root helper or Mac local command channel. Neither platform makes a compromised
PC safe. Streams can appear in screen recordings.

{% endhint %}

## Local commands and links

[`glimmer://` links](COMMAND_LINE.md#url-commands) work only with saved PCs.
Quit links always ask; stream links keep takeover checks. Stop links end the
current local stream without confirmation and follow “Leave games running when
you disconnect”; the default also quits the PC app. An optional PC limits the
request. Treat local automation as trusted software.

## Network paths

Read [Privacy](PRIVACY.md) for connections and local diagnostics.

### Protocol limits

See [Architecture](ARCHITECTURE.md#protocol-security) for technical protections.

## Verifying a download

[Check a Mac download](VERIFY_DOWNLOAD.md) for its origin, Apple signature and
notarization. Current candidates sign and notarize both the app and DMG; Sparkle
verifies update ZIP signatures. Stable promotion reuses the accepted candidate's
files. On iPhone and iPad, use the project's TestFlight distribution; an
uploaded beta is not an App Store release or evidence of Apple's review
approval.

## Reporting

1. Open the
   [private report form](https://github.com/Se7enbrc/glimmer/security/advisories/new).
2. Include reproduction steps and your Glimmer version.

| Target   | Response                                             |
| -------- | ---------------------------------------------------- |
| 72 hours | Acknowledge.                                         |
| Day 7    | Assessment and severity.                             |
| Day 30   | Fix or explain delay.                                |
| Day 90   | Public disclosure; earlier by agreement after a fix. |

{% hint style="info" %}

Reporters receive release-note credit unless declined. Report Glimmer parser
bugs here; [Sunshine bugs](https://github.com/LizardByte/Sunshine) go upstream.

{% endhint %}

Next: [review what diagnostics contain](PRIVACY.md).
