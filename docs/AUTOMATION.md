---
description: Use Glimmer links, Shortcuts, Siri, Spotlight and scripts.
icon: bolt
---

# Start or wake your PC from another app

## Open a Glimmer link

1. Pair your PC in Glimmer.
2. Replace “Living Room” and “Steam” below with your saved names.
3. Open the link:

   ```bash
   open 'glimmer://stream?pc=Living%20Room&app=Steam'
   ```

{% hint style="info" %}

Use `%20` for spaces. Without `app`, Glimmer prefers the running app, then
Settings › General › Start with. [URL rules](COMMAND_LINE.md#url-commands) cover
accepted parameters.

{% endhint %}

## End a stream from anywhere

Stopping works like the menu bar Stop: it also quits the app on the PC.

```bash
glimmer stop
open 'glimmer://stop'
```

{% hint style="info" %}

Add `pc=Living%20Room` (or `glimmer stop "Living Room"`) to stop only that PC.
`glimmer stop` exits 5 when nothing is streaming.

{% endhint %}

## Add a launcher button

1. Add an Open URL action in Raycast Quicklinks, Stream Deck or Alfred.
2. Paste your stream link.

The [Raycast extension](https://github.com/Se7enbrc/raycast-glimmer) has its own
installation steps.

## Use Shortcuts, Siri and Spotlight

1. Find Glimmer's actions in Shortcuts.
2. Add an action.
3. Select your paired PC.

| Action         | Result                                       |
| -------------- | -------------------------------------------- |
| Stream from PC | Opens a stream; app name is optional.        |
| Wake PC        | Wakes and waits for an answer.               |
| Quit App on PC | Quits without confirmation. Save first.      |
| Stop Streaming | Ends the stream and quits its app on the PC. |

{% hint style="info" %}

Siri and Spotlight also offer stream and wake. Try “Stream Living Room in
Glimmer” or “Wake Living Room with Glimmer”. Pairing or renaming updates PC
names.

{% endhint %}

## Wake then stream

1. Enable [Wake on LAN](guides/PCS.md#enable-wake-on-lan).
2. With the [command installed](COMMAND_LINE.md#install-the-command), run:

   ```bash
   glimmer wake "Living Room" --wait && glimmer stream "Living Room" Steam
   ```

{% hint style="info" %}

In Shortcuts, put Wake PC before Stream from PC for the same PC. A wake URL
alone does not wait. To wake in the background:

```bash
open -g 'glimmer://wake?pc=Living%20Room'
```

{% endhint %}

## Read status in a script

1. With `jq` installed, run:

   ```bash
   set -o pipefail
   glimmer status --json | jq -e '.version == 1 and .live == true'
   ```

Next: [look up commands, JSON fields and exit codes](COMMAND_LINE.md).
