---
description:
  Learn what Glimmer sends to your PC, what stays on your device and what you
  share.
icon: user-shield
---

# Privacy policy

Learn what Glimmer sends to your PC, what stays on your device and how to ask
about information you share. This policy covers Glimmer for iPhone, iPad and
Mac, and its GitHub Pages website. Updated October 26, 2026.

## Your PC connection

Glimmer connects to Sunshine on the PC you choose. It receives app names,
artwork, picture and sound, and sends pairing information, stream requests and
your input back to the PC. Pairing sends a device name, an app-generated
identifier and a public certificate. Supported controller motion and battery
information may also be sent to the PC. On Mac, input includes keyboard and
mouse actions, and clipboard text when you choose Paste.

Glimmer uses local network discovery to find the PC and can send Wake on LAN
packets on Mac. If you enter an address, the connection follows your network's
routing, including any VPN or tunnel you choose. Your PC, DNS provider and
network or VPN services have their own data practices. Glimmer does not send
your stream or input to its developer. Read about
[connection security](SECURITY.md#network-paths).

## Information on your device

Glimmer saves preferences, PC details and pairing information on your device. It
may cache app artwork received from the PC. No Glimmer account is required. The
app contains no advertising or analytics service and does not track you across
other apps or websites.

The iPhone and iPad app records no diagnostics of its own, in beta or
production. It writes no session logs, performance files, frame traces or input
captures. It ignores old recording preferences and leaves files from earlier
betas untouched. Apple provides system logs and crash and performance reports
through Console, sysdiagnose and Xcode Organizer, subject to Apple's sharing
settings and TestFlight practices.

Mac offers optional local recording. Nothing uploads automatically. Mac can save
the following on your device:

- In-app logs may show PC names, addresses and errors. Copied, system and
  session logs hide private fields and do not include keys, PINs or
  certificates.
- Performance files can include app, display, network and stream configuration
  details. PC and Mac names in telemetry use per-install codes.
- Optional input traces can include pointer, controller, motion and scroll data.
  They exclude keyboard keys, mouse buttons, pasted text and touchpad contacts.
- Audio diagnostics contain state and timing, not device names or identifiers.

Glimmer does not capture microphones or read, store or export head-pose or
spatial-audio profile data. See
[Mac diagnostic details and limits](PROFILING.md#opt-in-telemetry).

## Your choices

On Mac, turn off telemetry in Settings → Diagnostics to stop future captures.
Existing Mac logs follow the retention limits described in the diagnostic guide.

Use Settings → PCs → Forget… on iPhone and iPad, or Unpair on Mac, to remove a
saved PC and its local trust record. This does not remove the paired-device
record on the PC or every cached image. Manage the PC's pairing record in
Sunshine.

Deleting Glimmer on iPhone or iPad removes its local app container. Removing the
Mac app does not automatically remove its saved data or logs. Backups and files
you copied elsewhere are managed separately. You can revoke local network access
in system Settings.

## Review before sharing

Check diagnostic files for identifying app, display or network details before
sharing them. On Mac, local logs are in `~/Library/Logs/Glimmer/`. Never share
pairing files, keys, PINs, certificates or profiles.

Other software using your account can access Glimmer's data and commands.
Streams can appear in screen shares. Read about
[security limits](SECURITY.md#threat-model).

## Mac updates and website visits

The Mac app uses Sparkle to check for updates and download them from GitHub.
These requests reach GitHub with connection information such as your IP address.
The iPhone and iPad app receives updates through Apple's App Store or
TestFlight.

This website is served by GitHub Pages. GitHub may log connection information
when you visit it. The site has no advertising, analytics scripts or tracking
cookies. See
[GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
for its practices. Opening a support or privacy link in Glimmer opens your
browser and loads this website.

## Beta testing and support

When you use TestFlight, Apple handles testing information and feedback and
makes some of it available to the developer. See
[Apple's TestFlight information](https://testflight.apple.com/) for details.

If you email support or choose to share diagnostic files, the Glimmer maintainer
receives your message, email address and any files you send to answer your
request and investigate the problem. Contact
[glimmer-prerelease@ugfugl.io](mailto:glimmer-prerelease@ugfugl.io) for privacy
questions or to request deletion of information you have sent. Apple and your PC
software manage information they retain separately.

Next: [get help with Glimmer](https://se7enbrc.github.io/glimmer/support/).
