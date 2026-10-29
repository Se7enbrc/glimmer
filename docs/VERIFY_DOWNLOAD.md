---
description:
  Check provenance, notarization and update signatures before opening a release.
icon: file-shield
---

# Check a download before opening it

## Check build provenance

1. In Terminal, change to your download directory.
2. With GitHub CLI installed, replace the filename and run:

   ```bash
   gh attestation verify Glimmer-2026.10.8.dmg --repo Se7enbrc/glimmer \
     --signer-workflow Se7enbrc/glimmer/.github/workflows/release.yml \
     --source-ref refs/heads/release-candidate --deny-self-hosted-runners
   ```

{% hint style="info" %}

Exit status 0 confirms matching signed build provenance. Repeat for a ZIP.
Attestations began with 2026.10.6-rc.1; missing newer attestations need
investigation.

{% endhint %}

## Check the DMG before mounting

Current candidates sign and notarize the DMG container separately from the app.
For 2026.10.8, run:

```bash
codesign --verify --strict --verbose=2 Glimmer-2026.10.8.dmg
spctl -a -t open --context context:primary-signature --verbose=2 Glimmer-2026.10.8.dmg
xcrun stapler validate Glimmer-2026.10.8.dmg
```

Expect a valid signature, `accepted` with `Notarized Developer ID`, and
successful ticket validation. These checks do not mount the image or launch the
app. Older releases can have unsigned DMG containers; check their recorded
release evidence rather than applying that exception to a current candidate.

## Check the app

1. Mount your downloaded DMG read-only:

   ```bash
   mkdir -p /tmp/glimmer-check
   hdiutil attach -readonly -nobrowse -mountpoint /tmp/glimmer-check Glimmer-2026.10.8.dmg
   ```

2. Check its signature:

   ```bash
   codesign --verify --deep --strict --verbose=2 /tmp/glimmer-check/Glimmer.app
   ```

3. Check Apple's approval:

   ```bash
   spctl -a -vv /tmp/glimmer-check/Glimmer.app
   ```

4. Check the notarization ticket:

   ```bash
   xcrun stapler validate /tmp/glimmer-check/Glimmer.app
   ```

5. Detach the image:

   ```bash
   hdiutil detach /tmp/glimmer-check
   ```

{% hint style="warning" %}

Stop if a check fails. Expect `accepted`, `Notarized Developer ID`,
`steven Miller (5T7M4RH3F8)` and successful ticket validation. The app and
current DMG container are separately signed. Updates verify automatically;
[manual ZIP checks](CONTRIBUTING.md#release-artifact-checks) use the
[appcast](https://se7enbrc.github.io/glimmer/appcast.xml).

{% endhint %}

Next: [install Glimmer](INSTALL.md).
