# Investigate an iPhone or iPad problem

Use Apple's system logs and reports. Glimmer records no diagnostics of its own,
in beta or production: no session files, frame traces, input captures or
Diagnostics folder. There is no recording switch or diagnostic export.

1. Note the time, device and OS version, stream format, audio output and
   controller.
2. Reproduce the problem and note what happened just before it, such as changing
   audio output, connecting a controller or leaving the app.
3. Use Console on a connected Mac to review the device's Glimmer logs, or
   collect an Apple sysdiagnose when support requests one. Review it before
   sharing.
4. For TestFlight and App Store builds, review Apple's crash, hang, launch,
   energy and disk-write reports in Xcode Organizer when available.

System logs retain connection and lifecycle events at sensible levels and hide
private PC details. Glimmer does not log keys, PINs, certificates or button
presses. No MetricKit subscriber or custom upload service is installed.

Old files from an earlier beta remain untouched. Do not copy pairing identity or
certificate storage when investigating a problem. Settings → Connection contains
Adaptive stream quality; it controls the connection, not recording.

Next: [test the exact TestFlight candidate](TESTFLIGHT.md).
