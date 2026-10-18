// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension FrameTimingTracker {
    package enum UnresolvedReason: String, Sendable {
        case sessionEnd = "session_end"
        case attemptEnd = "attempt_end"
    }

    package enum PacerDiscardReason: String, Sendable {
        case overflow, suppressed, trim, backoff, stopped, rebind, cleared, recovery
    }

    package struct StageRecord: Sendable {
        package enum Event: String, Sendable {
            case decodeOutput = "decode_output"
            case decodeSubmitReturned = "decode_submit_returned"
            case decodeCallbackFinished = "decode_callback_finished"
            case pacerSubmitted = "pacer_submitted"
            case pacerDiscard = "pacer_discard"
            case unresolvedExpiry = "frame_expired"
            case unresolvedBoundary = "frame_unresolved"
        }

        package let event: Event
        package let rtpTimestamp: UInt32
        package let uptimeNanos: UInt64
        package let timing: Timing?
        package let beganNanos: UInt64?
        package let status: Int32?
        package let flags: UInt32?
        package let decoded: Bool?
        package let reason: PacerDiscardReason?
        package let unresolvedReason: UnresolvedReason?
        package let attemptID: String?

        package init(event: Event, rtpTimestamp: UInt32, uptimeNanos: UInt64,
                     timing: Timing? = nil, beganNanos: UInt64? = nil,
                     status: Int32? = nil, flags: UInt32? = nil, decoded: Bool? = nil,
                     reason: PacerDiscardReason? = nil, unresolvedReason: UnresolvedReason? = nil,
                     attemptID: String? = nil) {
            self.event = event
            self.rtpTimestamp = rtpTimestamp
            self.uptimeNanos = uptimeNanos
            self.timing = timing
            self.beganNanos = beganNanos
            self.status = status
            self.flags = flags
            self.decoded = decoded
            self.reason = reason
            self.unresolvedReason = unresolvedReason
            self.attemptID = attemptID
        }
    }

    package func recordSubmitReturned(rtpTimestamp: UInt32, beganNanos: UInt64,
                                      status: Int32, flags: UInt32, attemptID: String? = nil) {
        guard rtpTimestamp != 0 else { return }
        traceWriter.appendStage(StageRecord(event: .decodeSubmitReturned, rtpTimestamp: rtpTimestamp,
                                            uptimeNanos: now(), beganNanos: beganNanos,
                                            status: status, flags: flags, attemptID: attemptID), sessionId: sessionId)
    }

    package func recordCallbackFinished(rtpTimestamp: UInt32, entryNanos: UInt64, attemptID: String? = nil) {
        guard rtpTimestamp != 0 else { return }
        traceWriter.appendStage(StageRecord(event: .decodeCallbackFinished, rtpTimestamp: rtpTimestamp,
                                            uptimeNanos: now(), beganNanos: entryNanos,
                                            attemptID: attemptID), sessionId: sessionId)
    }

    package func recordPacerSubmitted(rtpTimestamp: UInt32) {
        guard rtpTimestamp != 0 else { return }
        traceWriter.appendStage(StageRecord(event: .pacerSubmitted, rtpTimestamp: rtpTimestamp,
                                            uptimeNanos: now(), attemptID: attemptForFrame(rtpTimestamp: rtpTimestamp)),
                                sessionId: sessionId)
    }

    package func recordPacerDiscard(rtpTimestamp: UInt32, reason: PacerDiscardReason,
                                    uptimeNanos: UInt64? = nil) {
        guard rtpTimestamp != 0 else { return }
        let stamp = uptimeNanos ?? now()
        let timing = takeTiming(rtpTimestamp: rtpTimestamp)
        traceWriter.appendStage(StageRecord(event: .pacerDiscard, rtpTimestamp: rtpTimestamp,
                                            uptimeNanos: stamp, timing: timing, reason: reason), sessionId: sessionId)
    }

    /// These boundaries measure client calls and callbacks, not hardware execution or scanout.
    package static func renderStageLine(_ record: StageRecord, sessionId: String) -> String {
        var row = TelemetryRenderer.NDJSONBuilder()
        row.addString("session", sessionId)
        row.addString("event", record.event.rawValue)
        row.addCount("rtp", UInt64(record.rtpTimestamp))
        row.add("t_ms", Double(record.uptimeNanos) / 1_000_000)
        if let began = record.beganNanos {
            row.add("t_begin_ms", Double(began) / 1_000_000)
            if record.uptimeNanos >= began {
                row.add("duration_ms", Double(record.uptimeNanos - began) / 1_000_000)
            }
        }
        if let status = record.status { row.addInt("status", Int(status)) }
        if let flags = record.flags { row.addCount("flags", UInt64(flags)) }
        row.addBool("decoded", record.decoded)
        if let reason = record.reason { row.addString("reason", reason.rawValue) }
        if let reason = record.unresolvedReason { row.addString("reason", reason.rawValue) }
        if let timing = record.timing {
            let stage = timing.outputNanos > 0 ? "decoded" : timing.submitNanos > 0 ? "submitted" : "assembled"
            row.addString("stage", stage)
            row.addInt("frame", Int(timing.frameIndex))
            row.addString("type", timing.isIDR ? "idr" : "p")
            row.addInt("bytes", Int(timing.frameBytes))
            row.addBool("assembled_hidden", timing.assembledHidden)
            row.add("t_receive_ms", Double(timing.receiveNanos) / 1_000_000)
            row.add("t_assemble_ms", Double(timing.assembleNanos) / 1_000_000)
            if timing.submitNanos > 0 { row.add("t_submit_ms", Double(timing.submitNanos) / 1_000_000) }
            if timing.outputNanos > 0 { row.add("t_output_ms", Double(timing.outputNanos) / 1_000_000) }
        }
        return row.line()
    }
}
