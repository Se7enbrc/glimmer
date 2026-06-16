//
//  RtpAudioReceiver+Events.swift
//
//  The audio startup event emission: the one-shot `audio_ttf` row (both
//  honest TTF spans plus the startup-pacing verdict), the silent-audio
//  `audio_pending` probe, and the shared two-sink EVENT carrier (Diag NOTICE
//  line + TelemetryExporter NDJSON row). Split out of RtpAudioReceiver.swift
//  — pure move, the FramePacer split idiom — to keep that file
//  under the length limit; the TTF latch fields stay declared on the
//  receiver.
//

import Foundation

extension RtpAudioReceiver {

    /// Emit the one-shot `audio_ttf` EVENT: both honest TTF spans in one
    /// machine-readable row — ping→first-RTP (the Diag METRIC span) and
    /// connectStart→first-decoded (the user-facing span; with the backlog-aware
    /// gate the first arrival IS the first decode, so no fixed drop inflates
    /// it) — plus the ping count, the gate's verdict (`startup`, `dropped_ms`),
    /// an `over_target` flag against the <1s goal (so a slow cold start is a
    /// greppable alarm instead of an unflagged log line), and the warm/cold
    /// `ttf_class` + `host_idle_s` covariate (see `AudioTtfContext`) so every
    /// session self-labels the bimodal host bring-up instead of leaving it to
    /// a multi-session offline scan. On the receive thread, called exactly
    /// once from `latchStartupVerdict` (the verdict is why the row is deferred
    /// past the first-decoded latch at all).
    func emitAudioTtfEvent() {
        var fields = ["\"event\":\"audio_ttf\""]
        if let pingMs = firstRtpPingToRtpMs {
            fields.append(String(format: "\"ping_to_rtp_ms\":%.1f", pingMs))
        }
        // The connectStart→first-decoded span the always-live counters
        // computed in recordAudioFirstPacket() — read back so the event and the
        // exporter gauge can never disagree.
        let connectMs = TelemetryCounters.shared.audioFirstPacketMs
        if let connectMs {
            fields.append(String(format: "\"connect_to_decoded_ms\":%.1f", connectMs))
        }
        fields.append("\"pings\":\(firstRtpPings)")
        // The startup-pacing verdict travels with the TTF spans — one row
        // tells the whole startup story: how fast audio came up, and how much
        // (if any) stale backlog was discarded to get there.
        fields.append("\"startup\":\"\(startupVerdictBurst ? "burst" : "paced")\"")
        fields.append("\"dropped_ms\":\(startupDroppedPackets * audioPacketDuration)")
        // Warm/cold host-bring-up classification + the host-idle covariate,
        // latched through the shared TTF context (first-writer-wins): this row
        // emits exactly the record the session scorecard reads at stop, so the
        // two sinks can never disagree on the split. A nil ping span classifies
        // cold (no RTP answer inside any warm window); host_idle_s is OMITTED
        // when underivable (first stream this process run — absent ≠ 0).
        let record = TelemetryCounters.shared.audioTtf.latchClassifying(
            pingToRtpMs: firstRtpPingToRtpMs,
            startup: startupVerdictBurst ? "burst" : "paced")
        fields.append("\"ttf_class\":\"\(record.ttfClass)\"")
        if let idleSeconds = record.hostIdleSeconds {
            fields.append(String(format: "\"host_idle_s\":%.1f", idleSeconds))
        }
        // The cushion seed rides the startup row (latched at decoder init,
        // before any RTP flows): the session self-describes the target/floor
        // it STARTED from, so a clean first-3-minutes is attributable to the
        // per-host memory and a ratchet walk to a missing one. Link only —
        // the host half of the memory key never leaves UserDefaults.
        if let seed = AudioCushionTelemetry.shared.seed {
            fields.append(String(format: "\"cushion_seed_ms\":%.0f", seed.targetMs))
            fields.append(String(format: "\"cushion_seed_floor_ms\":%.0f", seed.floorMs))
            fields.append("\"cushion_seed_link\":\"\(seed.link)\"")
            fields.append("\"cushion_seed_source\":\"\(seed.fromMemory ? "memory" : "default")\"")
        }
        // over_target keys on the user-facing span (fallback: the ping span).
        fields.append("\"over_target\":\((connectMs ?? firstRtpPingToRtpMs ?? 0) > 1000)")
        emitAudioEvent(fields)
    }

    /// Arm the one-shot silent-audio probe: if no audio RTP has arrived
    /// `audioPendingProbeSeconds` after the receive path comes up, emit an
    /// `audio_pending` event. Sessions have been abandoned by the user with
    /// audio never arriving and NOTHING flagged the silence — this makes it
    /// visible (with the ping count as evidence the keepalive loop is alive).
    /// A detached utility-QoS one-shot: it cannot run on `recvQueue` (the
    /// blocking receive loop occupies it for the session), so it reads the
    /// cross-thread `firstRtpReceived` latch instead of `receivedDataFromPeer`.
    func armAudioPendingProbe() {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.audioPendingProbeSeconds
        ) { [weak self] in
            guard let self, !self.interrupted.isSet, !self.firstRtpReceived.isSet else { return }
            let pings = self.pingsSent.load()
            Diag.warn("NativeAudio no audio RTP \(Int(Self.audioPendingProbeSeconds))s after "
                + "receive start (\(pings) pings sent — ping loop alive; host hasn't aimed audio "
                + "at us yet; still retrying)", Self.cat)
            self.emitAudioEvent([
                "\"event\":\"audio_pending\"",
                "\"after_ms\":\(Int(Self.audioPendingProbeSeconds * 1000))",
                "\"pings\":\(pings)"
            ])
        }
    }

    /// EVENT carrier, two sinks like the exporter's bookmark events (NOTICE line
    /// + NDJSON row): one human-readable line through Diag for the log, and the
    /// machine row into the session's telemetry NDJSON. The receiver has no
    /// handle to the session's TelemetryExporter (StreamSession owns it), so the
    /// row goes through the exporter's static event sink
    /// (`TelemetryExporter.recordEvent`), which stamps the `ts`+`session` header
    /// keys the bookmark/handshake rows carry. A row fired BEFORE the exporter
    /// is up (warm hosts: this receiver spins up mid-handshake, the exporter
    /// only after the connection establishes — audio_ttf lost that race by 61ms
    /// and vanished) is BUFFERED by the sink and flushed at exporter start, so
    /// the one-shots survive the ordering. Thread-safe (Diag is lock-guarded;
    /// the sink hops onto the exporter queue); called from the receive thread
    /// (audio_ttf) and the pending probe (audio_pending).
    private func emitAudioEvent(_ fields: [String]) {
        Diag.notice("EVENT {" + fields.joined(separator: ",") + "}", Self.cat)
        TelemetryExporter.recordEvent(fields)
    }
}
