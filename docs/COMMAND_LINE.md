# Command line

`glimmer` is the app itself, run from a terminal: it pairs, lists, wakes and
quits headless, and hands a stream to the app so it gets its window. Stream
settings come from Glimmer's Settings. `glimmer help` is the full reference.
Installed from the `.dmg`, choose Glimmer › Install Command Line Tool… once and
macOS asks for an administrator password to link `glimmer` into
`/usr/local/bin`.

```bash
glimmer pair 192.0.2.10          # prints the PIN to enter in Sunshine
glimmer list                     # paired PCs and whether each is ready
glimmer stream "Living Room" Steam --wait
```

Coming from moonlight-qt:

| moonlight-qt                         | Glimmer                               | Difference                                            |
| ------------------------------------ | ------------------------------------- | ----------------------------------------------------- |
| `moonlight pair <host> [--pin NNNN]` | `glimmer pair <address> [--pin NNNN]` | None.                                                 |
| `moonlight list <host> [--csv]`      | `glimmer list <pc> [--csv]`           | `glimmer list [--csv]` lists the paired PCs.          |
| `moonlight stream <host> <app> ...`  | `glimmer stream <pc> [<app>]`         | The app is optional; see below.                       |
| `moonlight quit <host>`              | `glimmer quit <pc> [--force]`         | Asks before quitting; `--force` confirms for scripts. |
|                                      | `glimmer stop <pc>`                   | Disconnects and leaves the PC app running.            |
|                                      | `glimmer wake <pc> [--wait]`          | Wake on LAN, optionally waiting for an answer.        |

Stopping a stream, closing its window, or quitting Glimmer leaves the game
running on the PC. Choose the same app again to resume with this Mac's current
stream settings. Quit the app separately from its launcher context menu, the
menu bar, or the stream-ended notice. Glimmer asks first because unsaved
progress may be lost. Shortcuts has separate Stop Streaming and Quit App on PC
actions.

Without an app, `glimmer stream` streams the PC's running app, else follows
Settings › General › Start with. The `--resolution`, `--bitrate` and other
moonlight-qt stream options are refused, since Settings holds them; Glimmer adds
`--force`, `--wait`, `--exit-after-first-frame` and `--json`. The CSV from
`glimmer list <pc> --csv` has Name, ID, HDR Support and Hidden.

`<pc>` is a paired PC's name or address, ignoring case. Exit status: 0 success,
1 failure, 2 usage error, 3 PC unreachable, 4 PC not paired or no paired PC by
that name.
