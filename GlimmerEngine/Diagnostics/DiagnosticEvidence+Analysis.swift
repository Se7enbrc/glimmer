// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension DiagnosticEvidence {
    /// Chunked JSON-lines reading never holds a whole trace or an unbounded line in memory.
    static func rows(_ url: URL, visit: ([String: Any]) throws -> Void) throws -> Int {
        let (handle, _) = try openRegular(url)
        defer { try? handle.close() }
        var pending = Data(), count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let length = pending.distance(from: pending.startIndex, to: newline)
                guard length > 0, length <= maxLine, count < 5_000_000 else { throw Failure.limit }
                let line = pending.prefix(length)
                guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw Failure.malformed
                }
                try visit(row)
                count += 1
                pending.removeSubrange(pending.startIndex...newline)
            }
            guard pending.count <= maxLine else { throw Failure.limit }
        }
        guard pending.isEmpty else { throw Failure.malformed }
        return count
    }

    static func analyze(_ context: Context) {
        if let metrics = context.metrics {
            do {
                let count = try rows(context.output.appendingPathComponent(metrics)) { row in
                    guard row["session"] as? String == context.session else { throw Failure.malformed }
                    observe(row, frame: false, context: context)
                }
                if count != context.expectedMetricRows { context.issue("Metrics rows disagree with closed receipt.") }
            } catch { context.issue("Malformed, oversized or wrong-session metrics rows.") }
        }
        for segment in context.frames { analyzeSegment(segment, context: context) }
        context.bookmarks.sort { $0.timeMs < $1.timeMs }
        if context.counts["frame_present", default: 0] == 0 { context.issue("No frame enqueue observations found.") }
        let names = ([context.metrics].compactMap { $0 }) + context.frames.map(\.name)
        for name in names {
            do {
                _ = try rows(context.output.appendingPathComponent(name)) { row in
                    observeWindows(row, frame: name.hasPrefix("telemetry-frames-"), context: context)
                }
            } catch { context.issue("Bookmark context is incomplete for \(name).") }
        }
    }

    static func analyzeSegment(_ segment: Segment,
                               context: Context) {
        var count = 0, first: UInt64?, last: UInt64?
        do {
            _ = try rows(context.output.appendingPathComponent(segment.name)) { row in
                guard row["trace_session"] as? String == context.session else { throw Failure.malformed }
                if let session = row["session"] as? String, session != context.session { throw Failure.malformed }
                if row["event"] as? String == "trace_overflow" {
                    context.issue("Trace overflow row present.")
                } else {
                    guard let sequence = row["trace_seq"] as? UInt64, sequence > 0,
                          let recorded = row["trace_recorded_ms"] as? Double, recorded.isFinite, recorded >= 0 else {
                        throw Failure.malformed
                    }
                    if context.lastSequence == UInt64.max || sequence != context.lastSequence + 1 {
                        context.issue("Trace sequence has gaps or duplicates.")
                    }
                    context.lastSequence = sequence
                    if first == nil { first = sequence }
                    last = sequence
                    count += 1
                }
                observe(row, frame: true, context: context)
            }
        } catch { context.issue("Malformed, oversized or wrong-session frame segment: \(segment.name).") }
        if count != segment.records || first != segment.first || last != segment.last {
            context.issue("Frame segment range/count mismatch: \(segment.name).")
        }
        if context.files.first(where: { $0.name == segment.name })?.bytes != segment.bytes {
            context.issue("Frame segment byte count mismatch: \(segment.name).")
        }
    }

    static func event(_ row: [String: Any], frame: Bool) -> String {
        if let event = row["event"] as? String,
           event.count <= 80, event.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
            return event
        }
        return frame && row["t_present_ms"] != nil ? "frame_present" : "sample"
    }

    static func time(_ row: [String: Any], context: Context) -> Double? {
        let relative = (row["t_connect_s"] as? Double).flatMap { seconds in
            context.startedMs.map { $0 + seconds * 1000 }
        }
        let value = (row["t_ms"] as? Double) ?? (row["t_present_ms"] as? Double) ?? relative
        return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static func boundedEvent(_ row: [String: Any], frame: Bool, context: Context) -> String {
        let value = event(row, frame: frame)
        if context.eventLabels.contains(value) { return value }
        guard context.eventLabels.count < 256 else {
            context.issue("Distinct event label limit exceeded.")
            return "other"
        }
        context.eventLabels.insert(value)
        return value
    }

    static func observe(_ row: [String: Any], frame: Bool, context: Context) {
        let label = boundedEvent(row, frame: frame, context: context)
        context.counts[(frame ? "trace_" : "metrics_") + label, default: 0] += 1
        if label == "frame_present" { context.counts["frame_present", default: 0] += 1 }
        if let attempt = row["trace_attempt"] as? String, UUID(uuidString: attempt) != nil {
            if context.attempts.count < 1024 { context.attempts.insert(attempt) } else { context.issue("Attempt count limit exceeded.") }
        } else if frame && row["rtp"] != nil {
            context.issue("Some frame observations lack a valid attempt identity.")
        }
        if label == "bookmark", let stamp = time(row, context: context), !context.bookmarks.contains(where: { $0.timeMs == stamp }) {
            if context.bookmarks.count < 256 {
                context.bookmarks.append(Bookmark(timeMs: stamp))
            } else { context.issue("Bookmark limit exceeded.") }
        }
    }

    static func observeWindows(_ row: [String: Any], frame: Bool, context: Context) {
        guard let stamp = time(row, context: context) else { return }
        let label = (frame ? "trace_" : "metrics_") + boundedEvent(row, frame: frame, context: context)
        let fields = ["recv_to_assemble_ms", "assemble_to_submit_ms", "submit_to_output_ms",
                      "output_to_present_ms", "end_to_end_ms", "duration_ms"]
        for index in context.bookmarks.indices where abs(context.bookmarks[index].timeMs - stamp) <= 2000 {
            context.bookmarks[index].observations += 1
            context.bookmarks[index].counts[label, default: 0] += 1
            for field in fields {
                guard let value = row[field] as? Double, value.isFinite, value >= 0 else { continue }
                let key = field == "duration_ms" ? label + "_duration_ms" : field
                context.bookmarks[index].maximumMs[key] = max(context.bookmarks[index].maximumMs[key] ?? 0, value)
            }
        }
    }
}
