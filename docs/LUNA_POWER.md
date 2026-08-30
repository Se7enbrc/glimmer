# Host power controls (luna)

Glimmer can wake, sleep, restart, and shut down a Sunshine host that is managed
by UpSnap, by shelling out to the `luna` CLI. The controls only appear when the
machine is already set up for them; on any other Mac there is no power UI at
all, not even a disabled button.

## What you see

When the selected host is asleep and the gate passes, the launcher's primary
button becomes **Wake & Connect**. It runs `luna on`, waits for Sunshine to
answer, and then starts the default app as if you had pressed Stream. While the
wake is running the button reads `Waking <host>…` and there is no cancel:
UpSnap's power routes are synchronous, so luna returns only once the machine has
actually come up. A cold wake takes about 36 seconds.

A power-glyph menu sits in the panel's top-trailing corner. Asleep, it offers a
plain **Wake**, which brings the machine up and stops there. Online and idle, it
offers **Sleep**, **Restart…**, and **Shut Down…**; the last two ask for
confirmation. The menu needs a fresh poll sample to know which set to show, so
it hides entirely while connecting, while streaming, and when the last sample
has aged out. An action other than a wake replaces it with a small progress
capsule (`Sleeping…`, `Restarting…`, `Shutting Down…`).

If luna fails, its one-line stderr reason is shown under the button, and the
device list is refetched so a revoked UpSnap grant closes the gate immediately.

## The gate

Both checks must pass, per host, or nothing is drawn.

**A usable luna.** GUI apps do not inherit a login shell's `PATH`, so Glimmer
probes `~/.local/bin/luna`, `/opt/homebrew/bin/luna`, `/usr/local/bin/luna`, and
then each entry of the process `PATH`. A candidate has to be an executable file,
and `luna version` has to exit 0 printing a three-part calver of at least
2026.7.1. 2026.7.0 has no `devices --json` and fails. On a Mac with no luna the
only work done is a file-existence check per candidate path; no subprocess is
spawned. The probe re-runs at launch and on every app foreground, so installing
or upgrading luna is picked up without a relaunch.

**A MAC match.** The host's MAC comes from Sunshine's `/serverinfo`, which only
answers while the host is awake, so Glimmer stores it at pair time and refreshes
it on every successful poll. It is matched against `luna devices --json`, which
lists only the UpSnap devices the configured user is permitted to see, so the
UpSnap grant doubles as the allowlist. MACs are compared lowercase and
colon-separated. An absent, malformed, or all-zero MAC normalizes to nothing and
fails the match: some NIC configurations make Sunshine report
`00:00:00:00:00:00` and there is no IP fallback and no manual binding. The
device list is cached for 60 seconds and refetched on foreground; a failed fetch
empties it rather than serving a stale one.

## Setup

Install the `luna` CLI (whaleyshire-infra, `dev/luna`) somewhere on the probe
list above; `~/.local/bin` is the usual place. luna owns the UpSnap endpoint and
its own credentials, which it reads from the macOS keychain item `upsnap-power`
or from `UPSNAP_PASSWORD`. Glimmer never reads, stores, or passes credentials:
on a power call it sets `UPSNAP_DEVICE` to the matched device id and nothing
else.
