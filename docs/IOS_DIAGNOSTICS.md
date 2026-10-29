# iOS diagnostics boundary

Both iPhone and iPad flavours use Apple's logs and reports. Glimmer records no
diagnostics of its own. Mac retains its opt-in NDJSON, scorecard and frame
trace.

## Compiled boundary

Shared custom recorders and their instrumentation compile only on macOS.
`DiagnosticsAvailability` and `TelemetryGate` return false on iOS, regardless of
saved preferences, environment overrides or a forced recording request.
`SessionServices.recording` returns empty services. The iOS app supplies no
diagnostic directory and writes no controller capability or input evidence file.
`Diag` forwards redacted messages to `Logger`; it creates no local log store.

Operational counters and watchdog clocks remain where stream recovery, adaptive
bandwidth and the on-screen stats need them, including the visible overlay's
brightness sampler. They do not create diagnostic files. Pairing, PC records,
artwork, preferences and controller layouts remain normal application data. Old
diagnostic files are neither read nor removed.

## Flavours and settings

Beta still enables adaptive stream quality by default; production does not.
Saved choices take precedence. Production continues to omit receive queue/jitter
samples. Both show the same switch in Settings → Connection, in the former
Diagnostics page's position. The recording toggle is removed.

The existing `GLIMMER_DIAGNOSTICS` beta compiler flag now selects only that
adaptive-quality default and its in-memory receive timing on iOS. It cannot
enable a shared recorder. Keeping the flavours preserves their existing
stream-control defaults and archive identities; no release workflow or protected
release script changes are needed.

The compiled-content inspector rejects custom recording types and controls in
both flavours. Release archive and export validation retain their flavour,
source and artifact checks. `RELEASE_PATHS` stays unchanged.

## Verification

Run `DiagnosticsDefaultsTests` in both flavours. It checks ignored recording
preferences and environment overrides, inert recording services even when forced
on, untouched sentinel files, retained operational measurements and Settings.
Inspect both compiled Simulator apps with `scripts/check-ios-diagnostics.py`.
Settings captures cover iPhone and iPad in light and dark appearances.

Apple's Console and sysdiagnose supply logs. Xcode Organizer supplies available
crash, hang, launch, energy and disk-write reports for TestFlight and App Store
builds. There is no custom collector, upload service or MetricKit subscriber.
Simulator checks do not establish physical-device streaming quality or the
availability of reports for a particular distribution build.

Next: [investigate an iPhone or iPad problem](../iOS/docs/DIAGNOSTICS.md).
