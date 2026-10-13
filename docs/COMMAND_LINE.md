# Command line

`glimmer` is the app itself, run from a terminal: it pairs, lists, wakes and
quits headless, stops the current stream, and hands a stream to the app so it
gets its window. Stream settings come from Glimmer's Settings. `glimmer help` is
the full reference. Installed from the `.dmg`, choose Glimmer › Install Command
Line Tool… once and macOS asks for an administrator password to link `glimmer`
into `/usr/local/bin`.

```bash
glimmer pair 192.0.2.10          # prints the PIN to enter in Sunshine
glimmer list                     # paired PCs and whether each is ready
glimmer stream "Living Room" Steam --wait
```

Coming from moonlight-qt:

| moonlight-qt                         | Glimmer                               | Difference                                     |
| ------------------------------------ | ------------------------------------- | ---------------------------------------------- |
| `moonlight pair <host> [--pin NNNN]` | `glimmer pair <address> [--pin NNNN]` | None.                                          |
| `moonlight list <host> [--csv]`      | `glimmer list <pc> [--csv]`           | `glimmer list [--csv]` lists the paired PCs.   |
| `moonlight stream <host> <app> ...`  | `glimmer stream <pc> [<app>]`         | The app is optional; see below.                |
| `moonlight quit <host>`              | `glimmer quit <pc>`                   | Quits the app and ends its stream.             |
|                                      | `glimmer wake <pc> [--wait]`          | Wake on LAN, optionally waiting for an answer. |

Stopping a stream, closing its window, or quitting Glimmer ends the session and
quits its app on the PC. `glimmer quit <pc>` and the Quit App on PC shortcut use
the same teardown when this Mac is streaming, or cancel the PC app directly
otherwise. `glimmer stop [<pc>]` stops only this Mac's current session through
the menu bar's Stop Streaming action, without confirmation. It also stops a
connecting or reconnecting session once that session exists. It does not cancel
a queued launch that has not created a session yet. Save progress before
stopping.

Stop waits for the existing teardown, including its best-effort cancellation of
the app on the PC. Success does not guarantee that an unreachable PC received
the cancellation. It never opens Glimmer or probes the PC first. An optional
`<pc>` must match the active session's PC, even if another PC is selected in the
launcher or the saved list has changed. A mismatch returns 1 without stopping
anything. No session, an already-stopping session, or an app that isn't running
returns 5; an app that doesn't answer within 15 seconds returns 1.

Without an app, `glimmer stream` streams the PC's running app, else follows
Settings › General › Start with. The `--resolution`, `--bitrate` and other
moonlight-qt stream options are refused, since Settings holds them; Glimmer adds
`--force`, `--wait`, `--exit-after-first-frame` and `--json`. The CSV from
`glimmer list <pc> --csv` has Name, ID, HDR Support and Hidden.

`<pc>` is a paired PC's name, ID or address, ignoring case. Exit status: 0
success, 1 failure, 2 usage error, 3 PC unreachable, 4 PC not paired or no
paired PC by that name, 5 no active stream (`stop` only).

## URL commands

Glimmer handles these URLs through the same commands as the command line:

```text
glimmer://stream?pc=Living%20Room&app=Steam
glimmer://wake?pc=Living%20Room
glimmer://quit?pc=Living%20Room
glimmer://stop
glimmer://stop?pc=Living%20Room
```

`pc` is optional for `stop`, required for the other actions, and matches a PC's
name, ID or address, ignoring case. Percent-encode query values; `+` is a
literal plus, not a space. Only `stream` accepts `app`. Without it, the current
running app is preferred when known, then Settings › General › Start with. A
link to the current stream brings its window forward. A new stream uses the
normal launch and takeover confirmation. Wake does not activate Glimmer;
launchers should open its URL without activation (from a shell,
`open -g 'glimmer://wake?pc=Living%20Room'`).

Stop uses the menu bar's Stop Streaming action without confirmation and quits
the current session's app on the PC. Its optional `pc` must match the active
session's PC; a mismatch or no active stream does nothing. The stop link does
not quit an app on another PC. For a launcher such as Raycast, use
`open -g 'glimmer://stop'`; URLs have no exit status or JSON response. Use the
CLI when the launcher needs the outcome.

Quit opens Glimmer's confirmation alert, even if the running app isn't known
yet. A quit URL cannot skip confirmation. `glimmer://pair` is unsupported.
Unknown actions, unknown PCs or apps, duplicate or unknown parameters, empty
values, paths, credentials, ports and fragments are ignored. A notice records
that the request was ignored without including the URL or PC name.

## JSON for automation

`list --json`, `list <pc> --json` and `status --json` each print one JSON object
followed by a newline. Their top-level `version` is `1`. Keys and value types
below are stable within that version; consumers should ignore additional keys.
Unknown values are `null`, and empty collections are `[]`. Errors go to stderr
and keep the exit codes above. `--csv` and `--json` cannot be combined. The
existing `stream --json` event format is unchanged.

### PCs

```bash
glimmer list --json
```

```json
{
  "version": 1,
  "pcs": [
    {
      "id": "pc-uuid",
      "name": "Living Room",
      "address": "living-room.local",
      "paired": true,
      "state": "reachable",
      "runningApp": { "id": 7, "name": "Steam" },
      "default": true
    }
  ]
}
```

`id` is the saved PC ID and `name` is its display name. `address` is only the
saved manually entered address, with its spelling preserved; it is `null` when
none was saved. A discovered or updated network address is never substituted.
Pairing may already have normalized a pasted URL before saving its address.
`paired` means a pinned pairing exists and the status probe did not report a
trust failure; an asleep PC can still be paired. `state` is `ready` (awake and
idle), `reachable` (running an app or needing trust), `asleep` (unreachable), or
`unknown` (no usable answer). `runningApp` is `null` when no running app is
known; its name or ID may be `null` if only the other is known. `default` marks
the PC selected before polling. This command uses the existing readiness probe.

### Apps on a PC

```bash
glimmer list "Living Room" --json
```

```json
{
  "version": 1,
  "apps": [
    { "id": 7, "name": "Steam", "hdr": true, "hidden": false, "running": true },
    {
      "id": 9,
      "name": "Desktop",
      "hdr": false,
      "hidden": true,
      "running": false
    }
  ]
}
```

All apps returned by the PC are included, including hidden apps. IDs are
integers. `hdr` is the app's reported HDR capability; `hidden` is its reported
visibility flag. `running` matches the running app ID from the same request's PC
status check.

### This Mac's stream

```bash
glimmer status --json
```

```json
{
  "version": 1,
  "live": true,
  "pc": { "id": "pc-uuid", "name": "Living Room" },
  "app": { "id": 7, "name": "Steam" },
  "resolution": { "width": 2560, "height": 1440 },
  "fps": 120,
  "hdr": true,
  "codec": "HEVC",
  "bitrateMbps": 82.5
}
```

`live` is true while the stream is playing, and false while idle, connecting,
reconnecting or stopping. PC and app describe the current session when one
exists. Resolution is in pixels; `fps` is the negotiated frame-rate limit, `hdr`
is active HDR output, `codec` is the engine's selected codec label, and
`bitrateMbps` is the negotiated video bitrate in megabits per second, not
measured traffic. Unavailable stream details are `null`.

Status reads the running app's session without contacting the PC or opening
Glimmer. If Glimmer isn't running, it succeeds with `live: false` and all stream
details `null`. An app that is running but doesn't answer returns exit code 1,
so a timeout cannot be mistaken for an idle stream. Without `--json`, `status`
prints “Streaming.” or “Not streaming.”

### Stop the current stream

```bash
glimmer stop --json
glimmer stop "Living Room" --json
```

Successful stop, exit code 0:

```json
{ "version": 1, "stopped": true, "result": "stopped" }
```

No active stream, exit code 5:

```json
{ "version": 1, "stopped": false, "result": "noActiveStream" }
```

Each result is one JSON object and a newline on stdout. PC mismatch or an
unanswered request returns 1, writes an explanation to stderr and no JSON to
stdout. Invalid arguments return 2 with the same stderr convention. Without
`--json`, the two results read “Stream stopped.” and “No active stream.”

Shortcuts also offers **Stop Streaming**, with no parameters or confirmation. It
uses the same teardown and reports an error when there is no active stream. The
existing **Quit App on PC** action still accepts a PC and can quit its app even
when this Mac has no stream.
