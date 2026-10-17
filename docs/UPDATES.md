---
description: Update Glimmer or join the release-candidate channel.
icon: arrows-rotate
---

# Update Glimmer

1. Choose Glimmer › Check for updates…

{% hint style="info" %}

Automatic checks default to daily and wait until streaming ends. Manual checks
run immediately. Turning off automatic checks stays saved.

{% endhint %}

## Homebrew

1. Run:

   ```bash
   brew upgrade --greedy glimmer
   ```

## Try release candidates

1. [Download a candidate](https://github.com/Se7enbrc/glimmer/releases).
2. [Verify the download](VERIFY_DOWNLOAD.md).
3. Quit Glimmer after saving your game.
4. Install the candidate.
5. Run before reopening:

   ```bash
   defaults write io.ugfugl.Glimmer GlimmerUpdateChannel -string rc
   ```

{% hint style="info" %}

Enrollment includes future candidates and stable releases. To leave, run this
before reopening Glimmer; it won't downgrade the app:

```bash
defaults write io.ugfugl.Glimmer GlimmerUpdateChannel -string stable
```

{% endhint %}

Next: [read the release notes](https://github.com/Se7enbrc/glimmer/releases).
