# Clean-room differential tests

Regions rewritten clean-room in 2026.10.8 must behave like the last good
release. These tests replay recorded inputs through the current code and fail on
any behaviour that differs from the baseline, unless the difference is a
reviewed fix.

## Run them

```bash
make differential
```

This runs `CleanRoomEngineDifferentialTests` and `CleanRoomMacDifferentialTests`
on the Mac, then the engine suite on the iOS Simulator. Once built, the tests
take about 7 s on the Mac (the helper scenario waits out three real 2 s XPC
deadlines) and under 1 s on the Simulator. Set `IOS_DESTINATION` to pick a
Simulator.

| Area          | Region (2026.10.8 spec)                    | What a vector holds                                             |
| ------------- | ------------------------------------------ | --------------------------------------------------------------- |
| `audio`       | spec-1, `OpusDecoder`, `OpusEnvelope`      | Multistream packets and losses → frames, RMS, PCM samples       |
| `video`       | spec-2, Annex B recognition and boundaries | RTP payloads or raw bytes → IDR decision, NAL split, units      |
| `helper`      | spec-3, `HelperClient` timeouts            | Reply/silent/late helper script → results, connection churn     |
| `grid`        | spec-4, launcher app row overflow          | App list → inline tiles, overflow control as VoiceOver reads it |
| `observation` | spec-5, `forEachTrackedValue` cancellation | Mutations and cancellation → delivery order                     |

Vectors live in `GlimmerTests/Fixtures/CleanRoomVectors/`, one JSON file per
area. Each case holds `input`, the baseline's `expected` output and, for a
reviewed fix only, `accepted` output with its `reason`.

## Accept an intentional difference

1. Run `make differential`. A failure prints the case name with `actual` and
   `expected` JSON.
2. Copy `actual` into that case's `accepted` field and add a one-line `reason`.
3. Add the case to the table below.

## Regenerate for a new baseline

```bash
scripts/differential/generate.sh 2026.10.9            # audio video helper grid
scripts/differential/generate.sh <ref> observation    # areas the tag lacks
```

The script builds the corpus (`make-corpus.py`, libopus from Homebrew for the
encoder-made packets), checks the baseline out in a detached worktree under
`build/differential/`, injects the probe sources into its own test target, runs
only `CleanRoomOracle` with a scratch home directory, and merges the
observations into the vectors. Reviewed `accepted` entries survive a
regeneration when their input is unchanged. Delete `build/differential/` and run
`git worktree prune` afterwards.

No baseline code enters this tree: only the recorded observations are committed.
The probes (`GlimmerTests/CleanRoomProbe*.swift`) call APIs that both trees
share; `legacy/CleanRoomGridHost.swift` adapts the one initializer that changed.
2026.10.7 has no `forEachTrackedValue`, so `observation` is recorded from
`eb417e6d^`, the last commit before the rewrite.

## Add an area

Write `GlimmerTests/CleanRoomProbe+Name.swift` with an `area(...)` entry and an
`observeName` function, add its cases to `make-corpus.py`, generate, and replay
it from a test like the existing suites.

## Intentional differences

Reviewed against 2026.10.7 on 2026-10-27. Each row is recorded as `accepted`
output in the vectors.

| Cases                                                     | Difference and reason                                                                                   |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `video/{h264,hevc}-{scan,idr}-{leading-zeros,long-start}` | Zero bytes before the first start code are legal Annex B. 2026.10.7 dropped the IDR; now it decodes.    |
| `video/{h264,hevc}-{scan,idr}-forbidden-bit`              | A NAL header with forbidden_zero_bit set is illegal and no longer counts as IDR evidence.               |
| `video/h264-{scan,idr}-h264-nonref-sps`                   | H.264 requires nal_ref_idc above 0 on an SPS; nal_ref_idc 0 is rejected.                                |
| `video/hevc-{scan,idr}-hevc-tid0`                         | HEVC nuh_temporal_id_plus1 of 0 is illegal and rejected.                                                |
| `audio/pack-stereo-code2-lossy`                           | A loss is concealed for the negotiated packet interval, not the last frame, keeping the stream cadence. |
| `grid/apps-{5,6,9,30}*`                                   | The overflow control reads “N more apps” instead of “N more”; its tooltip and chevron were dropped.     |
