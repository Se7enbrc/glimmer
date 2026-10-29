// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)

import Foundation
import os

/// Producers append bounded typed records; formatting, files and manifest state belong to flushQueue.
/// The buffer lock protects admission, sequence allocation and the two reusable pending buffers.
package final class FrameTraceWriter: @unchecked Sendable {
    package static let defaultMaxFileBytes: UInt64 = 96 * 1024 * 1024
    package static let maxTraceFiles = 4
    private static let maxPendingLines = 10_000
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")
    private let directory: URL
    private let maxFileBytes: UInt64
    private let maxRetainedSegments: Int
    private let sessionId: String
    private let now: @Sendable () -> UInt64
    private let write: (FileHandle, Data) throws -> Void
    private let flushQueue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry.frames", qos: .utility)
    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?
    private var isoStamp = ""
    private var started = false
    private var stopped = false
    private var manifest: Manifest
    private var segmentIndex = 0

    package struct Segment: Codable, Sendable {
        package var name: String
        package var index: Int
        package var firstSequence: UInt64?
        package var lastSequence: UInt64?
        package var firstRecordedMs: Double?
        package var lastRecordedMs: Double?
        package var records: UInt64 = 0
        package var bytes: UInt64 = 0
    }

    package struct Manifest: Codable, Sendable {
        package var schema = 1
        package var session: String
        package var activeAttempt: String?
        package var startedMs: Double?
        package var stoppedMs: Double?
        package var closed = false
        package var complete = false
        package var acceptedRecords: UInt64 = 0
        package var writtenRecords: UInt64 = 0
        package var overflowRecords: UInt64 = 0
        package var unwrittenRecords: UInt64 = 0
        package var writeFailures: UInt64 = 0
        package var manifestWriteFailures: UInt64 = 0
        package var prunedRecords: UInt64 = 0
        package var prunedSegments: UInt64 = 0
        package var firstPrunedSequence: UInt64?
        package var lastPrunedSequence: UInt64?
        package var firstUnwrittenSequence: UInt64?
        package var lastUnwrittenSequence: UInt64?
        package var segments: [Segment] = []
    }

    private enum Record: Sendable {
        case line(String)
        case frame(session: String, timing: FrameTimingTracker.TraceRecord)
        case stage(session: String, timing: FrameTimingTracker.StageRecord)

        func render() -> String {
            switch self {
            case .line(let line): return line
            case .frame(let session, let timing):
                return FrameTimingTracker.renderTraceLine(timing, sessionId: session)
            case .stage(let session, let timing):
                return FrameTimingTracker.renderStageLine(timing, sessionId: session)
            }
        }
    }

    private struct Pending: Sendable {
        let record: Record
        let sequence: UInt64
        let recordedNanos: UInt64
        let attempt: String?
    }

    private struct Loss {
        var records: UInt64 = 0
        var firstSequence: UInt64?
        var lastSequence: UInt64?
        var firstNanos: UInt64?
        var lastNanos: UInt64?

        mutating func include(_ record: Pending) {
            if firstSequence == nil { firstSequence = record.sequence; firstNanos = record.recordedNanos }
            lastSequence = record.sequence
            lastNanos = record.recordedNanos
            records &+= 1
        }
    }

    private let bufferLock = NSLock()
    private var pending: [Pending] = []
    private var spare: [Pending] = []
    private var oldestIndex = 0
    private var lost = Loss()
    private var accepted: UInt64 = 0
    private var accepting = true
    private var activeAttempt: String?

    package init(directory: URL, maxFileBytes: UInt64 = defaultMaxFileBytes, sessionId: String = "",
                 maxRetainedSegments: Int = maxTraceFiles,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxRetainedSegments = max(2, maxRetainedSegments)
        self.sessionId = sessionId
        self.now = now
        self.write = write
        manifest = Manifest(session: sessionId)
        pending.reserveCapacity(Self.maxPendingLines)
        spare.reserveCapacity(Self.maxPendingLines)
    }

    package var status: Manifest { flushQueue.sync { manifest } }

    package func setAttempt(_ id: UUID) {
        let value = id.uuidString
        bufferLock.withLock { activeAttempt = value }
    }

    package func start(isoStamp: String) {
        flushQueue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.isoStamp = isoStamp
            self.manifest.startedMs = Double(self.now()) / 1_000_000
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.openSegment()
            } catch {
                self.manifest.writeFailures &+= 1
                self.log.error("Frame trace directory unavailable: \(error.localizedDescription, privacy: .private)")
            }
            self.writeManifest()
            let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250),
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.flushTimer = timer
            timer.activate()
        }
    }

    /// Drain a checkpoint without closing producer admission.
    package func flush() { flushQueue.sync { if !stopped { drain(); writeManifest() } } }

    package func stop() {
        flushQueue.sync {
            guard !stopped else { return }
            stopped = true
            flushTimer?.cancel()
            flushTimer = nil
            drain(stopping: true)
            do { try fileHandle?.close() } catch { manifest.writeFailures &+= 1 }
            fileHandle = nil
            manifest.closed = true
            manifest.stoppedMs = Double(now()) / 1_000_000
            writeManifest()
        }
    }

    package func append(_ line: String) { append(.line(line), attempt: nil, useActiveAttempt: true) }

    package func appendFrame(_ record: FrameTimingTracker.TraceRecord, sessionId: String) {
        append(.frame(session: sessionId, timing: record), attempt: record.attemptID)
    }

    package func appendStage(_ record: FrameTimingTracker.StageRecord, sessionId: String) {
        append(.stage(session: sessionId, timing: record), attempt: record.attemptID ?? record.timing?.attemptID)
    }

    private func append(_ record: Record, attempt: String?, useActiveAttempt: Bool = false) {
        bufferLock.withLock {
            guard accepting else { return }
            let stamp = now()
            accepted &+= 1
            let item = Pending(record: record, sequence: accepted, recordedNanos: stamp,
                               attempt: useActiveAttempt ? activeAttempt : attempt)
            if pending.count < Self.maxPendingLines {
                pending.append(item)
            } else {
                lost.include(pending[oldestIndex])
                pending[oldestIndex] = item
                oldestIndex = (oldestIndex + 1) % Self.maxPendingLines
            }
        }
    }

    private func drain(stopping: Bool = false) {
        var batch = spare
        spare = []
        bufferLock.lock()
        swap(&batch, &pending)
        let first = oldestIndex
        let loss = lost
        manifest.acceptedRecords = accepted
        manifest.activeAttempt = activeAttempt
        oldestIndex = 0
        lost = Loss()
        if stopping { accepting = false }
        bufferLock.unlock()
        defer { batch.removeAll(keepingCapacity: true); spare = batch }
        manifest.overflowRecords &+= loss.records
        guard !batch.isEmpty else { return }
        let orderedFirst = batch[first]
        let orderedLast = batch[(first + batch.count - 1) % batch.count]
        guard let fileHandle else { noteUnwritten(batch.count, first: orderedFirst, last: orderedLast); return }
        var lines: [String] = []
        lines.reserveCapacity(batch.count + (loss.records > 0 ? 1 : 0))
        if loss.records > 0 { lines.append(renderLoss(loss)) }
        for offset in batch.indices { lines.append(render(batch[(first + offset) % batch.count])) }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            try write(fileHandle, data)
            manifest.writtenRecords &+= UInt64(batch.count)
            updateSegment(first: orderedFirst, last: orderedLast, count: batch.count, bytes: data.count)
        } catch {
            manifest.writeFailures &+= 1
            noteUnwritten(batch.count, first: orderedFirst, last: orderedLast)
            log.error("Frame trace write failed: \(error.localizedDescription, privacy: .private)")
            try? fileHandle.close()
            self.fileHandle = nil
            writeManifest()
            return
        }
        if let segment = manifest.segments.last, segment.bytes >= maxFileBytes {
            do { try fileHandle.close() } catch { manifest.writeFailures &+= 1 }
            self.fileHandle = nil
            openSegment()
            writeManifest()
        }
    }

    private func render(_ item: Pending) -> String {
        let line = item.record.render()
        var metadata = TelemetryRenderer.NDJSONBuilder()
        metadata.addCount("trace_seq", item.sequence)
        metadata.add("trace_recorded_ms", Double(item.recordedNanos) / 1_000_000)
        metadata.addString("trace_session", sessionId)
        if let attempt = item.attempt { metadata.addString("trace_attempt", attempt) }
        let tail = metadata.line().dropFirst()
        return String(line.dropLast()) + (line == "{}" ? "" : ",") + tail
    }

    private func renderLoss(_ loss: Loss) -> String {
        var row = TelemetryRenderer.NDJSONBuilder()
        row.addString("event", "trace_overflow")
        row.addString("trace_session", sessionId)
        row.add("t_ms", Double(now()) / 1_000_000)
        row.addCount("dropped_records", loss.records)
        row.addCount("first_lost_seq", loss.firstSequence)
        row.addCount("last_lost_seq", loss.lastSequence)
        if let stamp = loss.firstNanos { row.add("first_lost_recorded_ms", Double(stamp) / 1_000_000) }
        if let stamp = loss.lastNanos { row.add("last_lost_recorded_ms", Double(stamp) / 1_000_000) }
        return row.line()
    }

    private func noteUnwritten(_ count: Int, first: Pending, last: Pending) {
        manifest.unwrittenRecords &+= UInt64(count)
        if manifest.firstUnwrittenSequence == nil { manifest.firstUnwrittenSequence = first.sequence }
        manifest.lastUnwrittenSequence = last.sequence
    }

    private func updateSegment(first: Pending, last: Pending, count: Int, bytes: Int) {
        guard let index = manifest.segments.indices.last else { return }
        if manifest.segments[index].firstSequence == nil {
            manifest.segments[index].firstSequence = first.sequence
            manifest.segments[index].firstRecordedMs = Double(first.recordedNanos) / 1_000_000
        }
        manifest.segments[index].lastSequence = last.sequence
        manifest.segments[index].lastRecordedMs = Double(last.recordedNanos) / 1_000_000
        manifest.segments[index].records &+= UInt64(count)
        manifest.segments[index].bytes &+= UInt64(bytes)
    }

    private func openSegment() {
        let suffix = segmentIndex == 0 ? "" : "-\(segmentIndex)"
        let name = "telemetry-frames-\(isoStamp)\(suffix).ndjson"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            manifest.writeFailures &+= 1
            log.error("Frame trace segment could not be created")
            return
        }
        do {
            fileHandle = try FileHandle(forWritingTo: url)
            manifest.segments.append(Segment(name: name, index: segmentIndex))
            segmentIndex += 1
            while manifest.segments.count > maxRetainedSegments {
                let stale = manifest.segments.remove(at: 1)
                manifest.prunedSegments &+= 1
                manifest.prunedRecords &+= stale.records
                if manifest.firstPrunedSequence == nil { manifest.firstPrunedSequence = stale.firstSequence }
                manifest.lastPrunedSequence = stale.lastSequence
                do {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(stale.name))
                } catch {
                    try? fileHandle?.close()
                    fileHandle = nil
                    throw error
                }
            }
        } catch {
            manifest.writeFailures &+= 1
            log.error("Frame trace open failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func writeManifest() {
        guard !isoStamp.isEmpty else { return }
        manifest.complete = manifest.closed && manifest.writeFailures == 0 && manifest.manifestWriteFailures == 0
            && manifest.overflowRecords == 0 && manifest.unwrittenRecords == 0 && manifest.prunedRecords == 0
            && manifest.acceptedRecords == manifest.writtenRecords
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent("telemetry-frames-\(isoStamp)-manifest.json"), options: .atomic)
        } catch {
            manifest.manifestWriteFailures &+= 1
            manifest.complete = false
            log.error("Frame trace manifest write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    package static func trimSegments(_ segments: inout [URL]) -> [URL] {
        var stale: [URL] = []
        while segments.count > maxTraceFiles { stale.append(segments.remove(at: 1)) }
        return stale
    }
}

#endif
