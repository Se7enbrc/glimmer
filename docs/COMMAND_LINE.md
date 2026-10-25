# Run Glimmer from Terminal on Mac

Use the Mac app's command line to pair, launch and control streams with the same
PCs and settings as the launcher.

## Install the command

| Task                          | Command or control                                                                           |
| ----------------------------- | -------------------------------------------------------------------------------------------- |
| Homebrew install              | [Install Glimmer](INSTALL.md); includes `glimmer`.                                           |
| DMG install                   | Glimmer › Install command line tool…; administrator approval links `/usr/local/bin/glimmer`. |
| Missing command in older cask | `brew reinstall --cask glimmer`                                                              |
| Help / open app               | `glimmer help` / `glimmer`                                                                   |
| Examples                      | Replace “Living Room”, “Steam” and `192.0.2.10` with your PC and app.                        |

## Commands and flags

| Command                                | Result                                                                           |
| -------------------------------------- | -------------------------------------------------------------------------------- |
| `glimmer pair 192.0.2.10 [--pin NNNN]` | Pair; enter generated or supplied four-digit PIN on Sunshine's PIN page.         |
| `glimmer list [<pc>] [--csv\|--json]`  | List PCs, or a PC's apps. CSV app columns: Name, ID, HDR Support, Hidden.        |
| `glimmer stop [<pc>] [--json]`         | End the local stream, following your disconnect setting; optional PC must match. |
| `glimmer status [--json]`              | Local stream; doesn't open Glimmer or contact PC.                                |
| `glimmer stream <pc> [<app>]`          | Stream; omitted app prefers running app, then Start with.                        |

| PC action                    | Result                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| `glimmer wake <pc> [--wait]` | Wake; optionally wait for answer.                                                           |
| `glimmer quit <pc>`          | Quit PC app and session without confirmation. Save first.                                   |
| `<pc>`                       | Saved name, ID or address; case-insensitive.                                                |
| Stream quality               | Glimmer Settings; `--resolution`, `--bitrate` and other moonlight-qt quality flags refused. |

| Stream flag                | Result                                                                                          |
| -------------------------- | ----------------------------------------------------------------------------------------------- |
| None                       | Return when launch request accepted. Occupied PC prompts in terminal, fails in script.          |
| `--force`                  | Authorize quitting occupied PC app; unsaved progress may be lost.                               |
| `--wait`                   | Return when stream ends.                                                                        |
| `--exit-after-first-frame` | Return after first frame; keep streaming.                                                       |
| `--json`                   | One JSON object per connection event; return at live unless `--wait`. `_ms` values are numbers. |

{% hint style="warning" %}

Stopping, closing the window or quitting Glimmer follows “Leave games running
when you disconnect” in Settings › General. It is off by default, so save first.
An explicit `glimmer quit` still quits the PC app.

{% endhint %}

## Exit status

| Code | Meaning                                                                     |
| ---- | --------------------------------------------------------------------------- |
| 0    | Success.                                                                    |
| 1    | Failure, including no app response or a stop request naming a different PC. |
| 2    | Usage error.                                                                |
| 3    | PC unreachable.                                                             |
| 4    | Unpaired PC, trust failure or no saved match.                               |
| 5    | Nothing is streaming.                                                       |

## URL commands

| URL                                           | Result                                                                               |
| --------------------------------------------- | ------------------------------------------------------------------------------------ |
| `glimmer://stream?pc=Living%20Room&app=Steam` | Start or bring matching stream forward; normal takeover checks.                      |
| `glimmer://wake?pc=Living%20Room`             | Wake without activating Glimmer; shell: `open -g 'glimmer://wake?pc=Living%20Room'`. |
| `glimmer://stop`                              | Stop the current stream; optional `pc` limits it to that saved PC.                   |
| `glimmer://quit?pc=Living%20Room`             | Always confirm, even when running app unknown.                                       |

| Parameter | Rule                                                                                                                          |
| --------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `pc`      | Saved name, ID or address; case-insensitive. Required except for stop.                                                        |
| `app`     | Optional for stream only; omitted prefers known running app, then Start with.                                                 |
| Encoding  | Percent-encode; `%20` is space, `+` is literal plus.                                                                          |
| Rejected  | Unknown action/PC/app, unknown or duplicate parameters, empty/control-character values, paths, credentials, ports, fragments. |
| Limits    | No flags, confirmation bypass or pair action. Invalid links ignored without logging URL or PC name.                           |

## JSON for automation

| Contract                                           | Rule                                                            |
| -------------------------------------------------- | --------------------------------------------------------------- |
| `list --json`, `list <pc> --json`, `status --json` | One object plus newline; `version: 1`.                          |
| Compatibility                                      | Stable keys/types within version; ignore new keys.              |
| Missing values                                     | `null`; empty collections `[]`.                                 |
| Errors                                             | stderr and exit codes above; check exit code before parsing.    |
| Formats                                            | Don't combine `--csv` and `--json`; stream events are separate. |

### PCs

| `glimmer list --json` → `pcs` array | Meaning                                                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `id`, `name`                        | Strings: saved ID and display name.                                                                          |
| `address`                           | Saved address or `null`; never substituted by discovery. Pairing may normalize pasted URLs.                  |
| `paired`                            | Pin exists with no detected trust failure; can be true asleep.                                               |
| `state`                             | `ready`: idle; `reachable`: app running or trust needed; `asleep`: unreachable; `unknown`: no usable answer. |
| `runningApp`, `default`             | Known app or `null` (integer ID/string name independently nullable); boolean selection before polling.       |

### Apps on a PC

| `glimmer list "Living Room" --json` → `apps` array, including hidden | Meaning                                                 |
| -------------------------------------------------------------------- | ------------------------------------------------------- |
| `id`, `name`                                                         | Integer ID, string name.                                |
| `hdr`, `hidden`                                                      | Booleans: reported HDR support and visibility flag.     |
| `running`                                                            | Matches running ID from this request's PC status check. |

### This Mac's stream

| `glimmer status --json` field | Meaning                                                                          |
| ----------------------------- | -------------------------------------------------------------------------------- |
| `live`                        | Boolean; true only during playback, false idle/connecting/reconnecting/stopping. |
| `pc`, `app`                   | Objects with ID/name; PC ID string, app ID integer.                              |
| `resolution`, `fps`           | Integer pixel width/height; negotiated frame-rate limit.                         |
| `hdr`, `codec`                | Active HDR output and selected codec label.                                      |
| `bitrateMbps`                 | Negotiated Mbps, not measured traffic.                                           |

| Availability        | Result                                      |
| ------------------- | ------------------------------------------- |
| Unknown detail      | `null`.                                     |
| Glimmer not running | Success; `live: false`, all details `null`. |
| Running, no answer  | Exit 1.                                     |
| Plain text          | “Streaming.” or “Not streaming.”            |

Next: [build launcher buttons and scripts](AUTOMATION.md#add-a-launcher-button).
