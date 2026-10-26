# Install Glimmer on Mac, iPhone or iPad

Choose the install path for your [device](REQUIREMENTS.md), then pair with the
same Sunshine PC. The Mac app is generally available through Homebrew or a DMG.
iPhone and iPad are in TestFlight beta, with App Store installation available
when released.

## Homebrew

1. On your Mac, run in Terminal:

   ```bash
   brew tap se7enbrc/glimmer
   brew trust --tap se7enbrc/glimmer
   brew install --cask glimmer
   ```

## Download

1. Download the [DMG](https://github.com/Se7enbrc/glimmer/releases/latest).
2. Open the DMG.
3. Drag Glimmer to Applications.

{% hint style="info" %}

The Mac app requires [Apple Silicon and macOS 15.7 or later](REQUIREMENTS.md).
[Verify the download](VERIFY_DOWNLOAD.md) for signature checks. The optional
[Wi-Fi helper](guides/WIFI.md) needs approval; see [Security](SECURITY.md). Both
Mac installs [update in-app](UPDATES.md) through Sparkle.

{% endhint %}

## iPhone and iPad

1. [Request a TestFlight invitation](UPDATES.md#test-the-iphone-and-ipad-app).
2. Open the invitation on your iPhone or iPad.
3. Follow the invitation to install Glimmer through TestFlight.

Requires iOS 26 or later on iPhone, or iPadOS 26 or later on iPad. Use
TestFlight for beta updates. The App Store will be an install option when
Glimmer is released there.

Next: [pair your PC](GETTING_STARTED.md#3-pair-the-pc).
