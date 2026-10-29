---
description: Update Glimmer on Mac, iPhone or iPad, or try a beta release.
icon: arrows-rotate
---

# Update Glimmer

On Mac, Glimmer checks for updates through Sparkle. On iPhone and iPad, use
[TestFlight](#test-the-iphone-and-ipad-app) for beta updates. App Store updates
will be available when Glimmer is released there.

1. On Mac, choose Glimmer › Check for Updates…

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

For the Mac app:

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

Send feedback on a candidate to
[glimmer-prerelease@ugfugl.io](mailto:glimmer-prerelease@ugfugl.io).

## Test the iPhone and iPad app

The iPhone and iPad app is in beta on TestFlight. To join, email
[glimmer-prerelease@ugfugl.io](mailto:glimmer-prerelease@ugfugl.io) with the
device you'll test on, and you'll get an invitation. You need a PC running
Sunshine, plus iOS 26 or later on iPhone or iPadOS 26 or later on iPad.

Next: [read the release notes](https://github.com/Se7enbrc/glimmer/releases).
