//
//  TelemetryExporter+RenderAudio.swift
//
//  The PROMETHEUS render for the P1 AUDIO metric family (the other stream):
//  receive-quality, output-buffer health, A/V clock drift, and the cold-start
//  first-packet time. Split from TelemetryExporter+Render.swift — pure move,
//  same file-split idiom as the FramePacer split — to keep that file under the
//  length budget. Appends to the SAME `PromBuilder` (declared there) so the
//  body stays one document.
//

import Foundation

extension TelemetryRenderer {

    // MARK: - Audio family

    /// P1 AUDIO (the other stream): receive-quality (loss / FEC recovery + the raw
    /// totals so Grafana derives its own rates), output health (buffer fill /
    /// under-runs / over-runs), A/V sync drift, and the cold-start first-packet
    /// time. All numbers, no labels, no secrets.
    static func promAudio(
        _ builder: inout PromBuilder, _ snap: TelemetrySnapshot, _ extras: TelemetrySnapshot.Extras
    ) {
        guard let audio = snap.audio else { return }
        builder.emitCounter("glimmer_audio_packets_total",
                            "Audio data packets accepted into the queue.", audio.packetsTotal)
        builder.emitCounter("glimmer_audio_packets_lost_total",
                            "Audio packets lost AND unrecovered by FEC (audible gaps).",
                            audio.packetsLostTotal)
        builder.emitCounter("glimmer_audio_fec_recovered_total",
                            "Audio packets recovered by Reed-Solomon FEC.", audio.fecRecoveredTotal)
        builder.emitCounter("glimmer_audio_fec_mismatch_total",
                            "Audio FEC blocks dropped on a parity/data block-size mismatch.",
                            extras.audioFecMismatchTotal)
        builder.emit("glimmer_audio_packets_per_second",
                     "Audio data packets accepted per second.", audio.packetsPerSecond)
        builder.emit("glimmer_audio_loss_rate",
                     "Unrecovered audio-loss rate this window (lost/expected).", audio.lossRate)
        builder.emit("glimmer_audio_fec_recovery_rate",
                     "Audio FEC-recovery rate this window (recovered/(recovered+accepted)).",
                     audio.fecRecoveryRate)
        builder.emit("glimmer_audio_buffer_fill_ms",
                     "Decoded audio buffered ahead of the playhead, ms (output buffer level).",
                     audio.bufferFillMs)
        builder.emit("glimmer_audio_buffer_fill_min_ms",
                     "Windowed MIN buffer fill this scrape, ms (the trough that precedes an under-run; reset-on-read).",
                     audio.bufferFillMinMs)
        builder.emit("glimmer_audio_playout_target_ms",
                     "Adaptive playout target the buffer fill is steered toward, ms — fill vs "
                     + "target is the cushion judge (base 30 / cap 150 / ceiling 190).",
                     extras.audioPlayoutTargetMs)
        builder.emitCounter("glimmer_audio_underrun_total",
                            "Audio output under-runs (player drained → audible gap).",
                            audio.underrunTotal)
        builder.emitCounter("glimmer_audio_overrun_total",
                            "Audio output over-runs (decoded buffer dropped — backlog over the ceiling backstop).",
                            audio.overrunTotal)
        builder.emitCounter("glimmer_audio_trim_total",
                            "Designed audio playout-backlog trims (5ms chops back to the playout target).",
                            extras.audioTrimTotal)
        builder.emit("glimmer_audio_trims_per_second",
                     "Audio playout trims per second (bursty at genuine post-gap rebuilds).",
                     extras.audioTrimsPerSecond)
        builder.emitCounter("glimmer_audio_reprime_total",
                            "Playout re-primes (pre-roll re-arm edges after a full drain; the cushion "
                            + "rebuilds via the post-gap catch-up clump, no wall-time pause).",
                            audio.rePrimeTotal)
        builder.emit("glimmer_audio_underruns_per_second",
                     "Audio output under-runs per second (audible-glitch rate).",
                     audio.underrunsPerSecond)
        builder.emit("glimmer_audio_overruns_per_second",
                     "Audio output over-runs per second.", audio.overrunsPerSecond)
        builder.emit("glimmer_audio_clock_drift_ms",
                     "Audio clock drift vs wall clock, ms signed (+ audio played behind wall time, − ahead). Not a cross-stream A/V delta.",
                     audio.audioClockDriftMs)
        // The true cross-stream meter the drift line above disclaims: host-RTP
        // positions of last-presented video vs the audio playhead (schedule
        // head minus buffer fill), pair-anchored. Derives WITHOUT feeding the
        // session accumulator — the NDJSON 1Hz tick is the single feeder, so
        // scrape cadence can never double-count the scorecard percentiles.
        builder.emit("glimmer_av_skew_ms",
                     "Cross-stream A/V skew, ms signed (+ = audio late/behind video; pair-anchored "
                     + "host-RTP positions, small constant bias — trend is the signal).",
                     AudioVideoSkewStore.shared.deriveSkewMs(
                        bufferFillMs: audio.bufferFillMs, accumulate: false))
        builder.emitCounter("glimmer_av_skew_rebase_total",
                            "A/V-skew pair re-anchors after the first (stale stream or RTP "
                            + "discontinuity) — each one steps the skew baseline.",
                            AudioVideoSkewStore.shared.rebaseTotal)
        let cushionFloorMs = AudioCushionTelemetry.shared.floorMs
        builder.emit("glimmer_audio_cushion_floor_ms",
                     "Learned audio cushion LOSS FLOOR, ms (EWMA of the target at each under-run; "
                     + "decay never steps below floor + one step). Absent until learned.",
                     cushionFloorMs > 0 ? cushionFloorMs : nil)
        builder.emit("glimmer_audio_first_packet_ms",
                     "Time from stream start to first decoded audio, ms (cold-start metric).",
                     audio.firstPacketMs)
    }
}
