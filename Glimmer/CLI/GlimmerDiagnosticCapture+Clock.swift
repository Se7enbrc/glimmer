// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension GlimmerDiagnosticCapture {
    struct ClockAnchor: Codable, Sendable {
        let session: String
        let id: UInt64
        let traceNanos: UInt64
        let uptimeBeforeNanos: UInt64
        let uptimeAfterNanos: UInt64
        var lowerOffsetNanos: UInt64 { uptimeBeforeNanos - traceNanos }
        var upperOffsetNanos: UInt64 { uptimeAfterNanos - traceNanos }
    }

    struct ClockSession: Codable, Sendable {
        let session: String
        let pairs: Int
        let firstTraceNanos: UInt64
        let lastTraceNanos: UInt64
        let largestGapNanos: UInt64
    }

    struct ClockAlignment: Codable, Sendable {
        let pid: Int32
        var status = "anchors_missing"
        var anchors: [ClockAnchor] = []
        var sessions: [ClockSession] = []
        var unpairedEvents = 0
        var malformedEvents = 0
        var lowerOffsetNanos: UInt64?
        var upperOffsetNanos: UInt64?
        var firstTraceNanos: UInt64?
        var lastTraceNanos: UInt64?
        var limits = ["Offsets bound the first signpost emission between two process uptime reads.",
                      "The bound applies only to the observed clock domain; sleep or clock discontinuities invalidate it.",
                      "Anchor coverage is explicit; timestamps outside anchor bounds are not independently verified."]
    }

    static func preflightClock(manifest: inout Manifest, output: URL, options: URL, runner: Runner) async throws -> Bool {
        let directory = output.appendingPathComponent("clock-preflight")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let trace = directory.appendingPathComponent("preflight.trace")
        let command = Command(label: "clock-preflight-record", executable: "/usr/bin/xcrun", arguments: [
            "xctrace", "record", "--template", "System Trace", "--attach", String(manifest.pid), "--time-limit", "6s",
            "--recording-options", options.path, "--output", trace.path], timeoutSeconds: 186,
            stdout: directory.appendingPathComponent("record.stdout"),
            stderr: directory.appendingPathComponent("record.stderr"), captureDirectory: output)
        let result = await runner(command)
        manifest.commands.append(result)
        guard result.succeeded else { return false }
        try await exportClock(manifest: &manifest, output: directory, trace: trace, runner: runner, captureRoot: output)
        manifest.preflightClockAlignment = manifest.clockAlignment
        manifest.clockAlignment = nil
        return manifest.preflightClockAlignment?.status == "bounded_clock_verified"
    }

    static func exportClock(manifest: inout Manifest, output: URL, trace: URL, runner: Runner,
                            captureRoot: URL? = nil) async throws {
        let command = Command(label: "clock-anchors", executable: "/usr/bin/xcrun", arguments: ["xctrace", "export",
            "--input", trace.path, "--xpath",
            "/trace-toc/run[@number='1']/data/table[@schema='os-signpost'][@category='PointsOfInterest']"],
            timeoutSeconds: 120, stdout: output.appendingPathComponent("clock-anchors.xml"),
            stderr: output.appendingPathComponent("clock-anchors.stderr"), maximumOutputBytes: 16_777_216,
            captureDirectory: captureRoot ?? output)
        let result = await runner(command)
        manifest.commands.append(result)
        var alignment = ClockAlignment(pid: manifest.pid)
        if result.succeeded {
            alignment = inspectClock(command.stdout, pid: manifest.pid)
        } else { alignment.status = "anchor_export_failed" }
        manifest.clockAlignment = alignment
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateWrite(encoder.encode(alignment), to: output.appendingPathComponent("clock-alignment.json"))
    }

    static func inspectClock(_ url: URL, pid: Int32) -> ClockAlignment {
        var alignment = ClockAlignment(pid: pid)
        guard let data = boundedRead(url, maximum: 16_777_216),
              let document = try? XMLDocument(data: data, options: []),
              let definitions = try? document.nodes(forXPath: "//*[@id]"), definitions.count <= 100_000,
              let rows = try? document.nodes(forXPath: "//row"), rows.count <= 10_000 else {
            alignment.status = "anchor_xml_unverified"
            return alignment
        }
        var ids: [String: XMLElement] = [:]
        for case let element as XMLElement in definitions {
            if let id = element.attribute(forName: "id")?.stringValue { ids[id] = element }
        }
        let resolver = ClockResolver(ids: ids)
        var begins: [String: ClockEvent] = [:], ends: [String: ClockEvent] = [:]
        for case let row as XMLElement in rows {
            guard let event = resolver.event(row, pid: pid, malformed: &alignment.malformedEvents) else { continue }
            let key = event.session + ":" + String(event.id)
            if event.begin {
                if let existing = begins.updateValue(event, forKey: key), existing != event { alignment.malformedEvents += 1 }
            } else if let existing = ends.updateValue(event, forKey: key), existing != event { alignment.malformedEvents += 1 }
        }
        for (key, begin) in begins {
            guard let end = ends.removeValue(forKey: key) else { alignment.unpairedEvents += 1; continue }
            guard end.uptime >= begin.uptime, end.trace >= begin.trace, begin.uptime >= begin.trace else {
                alignment.malformedEvents += 1; continue
            }
            alignment.anchors.append(ClockAnchor(session: begin.session, id: begin.id, traceNanos: begin.trace,
                uptimeBeforeNanos: begin.uptime, uptimeAfterNanos: end.uptime))
        }
        alignment.unpairedEvents += ends.count
        finalizeClock(&alignment)
        return alignment
    }

    private static func finalizeClock(_ alignment: inout ClockAlignment) {
        alignment.anchors.sort { $0.traceNanos < $1.traceNanos }
        alignment.firstTraceNanos = alignment.anchors.first?.traceNanos
        alignment.lastTraceNanos = alignment.anchors.last?.traceNanos
        alignment.lowerOffsetNanos = alignment.anchors.map(\.lowerOffsetNanos).max()
        alignment.upperOffsetNanos = alignment.anchors.map(\.upperOffsetNanos).min()
        let sessions = Dictionary(grouping: alignment.anchors, by: \.session)
        alignment.sessions = sessions.compactMap { session, anchors in
            guard let first = anchors.first?.traceNanos, let last = anchors.last?.traceNanos else { return nil }
            let largestGap = zip(anchors, anchors.dropFirst()).map { $1.traceNanos - $0.traceNanos }.max() ?? 0
            return ClockSession(session: session, pairs: anchors.count, firstTraceNanos: first,
                                lastTraceNanos: last, largestGapNanos: largestGap)
        }.sorted { $0.session < $1.session }
        guard alignment.malformedEvents == 0 else { alignment.status = "anchors_malformed"; return }
        guard alignment.unpairedEvents == 0 else { alignment.status = "anchors_unpaired"; return }
        guard !sessions.isEmpty, sessions.values.allSatisfy({ $0.count >= 2 && $0.first?.traceNanos != $0.last?.traceNanos }) else {
            alignment.status = "anchors_insufficient"; return
        }
        guard let lower = alignment.lowerOffsetNanos, let upper = alignment.upperOffsetNanos, lower <= upper else {
            alignment.status = "clock_intervals_disagree"; return
        }
        guard alignment.sessions.allSatisfy({ $0.largestGapNanos <= 3_000_000_000 }) else {
            alignment.status = "clock_alignment_partial"; return
        }
        alignment.status = "bounded_clock_verified"
    }

    private struct ClockEvent: Equatable {
        let session: String
        let id: UInt64
        let trace: UInt64
        let uptime: UInt64
        let begin: Bool
    }

    private struct ClockResolver {
        let ids: [String: XMLElement]

        func resolve(_ value: XMLElement?) -> XMLElement? {
            guard let value else { return nil }
            guard let ref = value.attribute(forName: "ref")?.stringValue else { return value }
            return ids[ref]
        }

        func values(_ value: XMLElement?) -> [String] {
            guard let value else { return [] }
            var budget = 4096
            guard let raw = text(value, depth: 0, budget: &budget) else { return [] }
            return [raw]
        }

        func text(_ node: XMLElement, depth: Int, budget: inout Int) -> String? {
            guard depth < 16, let node = resolve(node) else { return nil }
            let children = node.children?.compactMap { $0 as? XMLElement } ?? []
            if children.isEmpty {
                let raw = node.stringValue ?? ""
                guard raw.utf8.count <= budget else { return nil }
                budget -= raw.utf8.count
                return raw
            }
            var result = ""
            for child in children {
                guard let part = text(child, depth: depth + 1, budget: &budget) else { return nil }
                result += part
            }
            return result
        }

        func child(_ row: XMLElement, _ names: [String]) -> XMLElement? {
            row.children?.compactMap { $0 as? XMLElement }.first { names.contains($0.name ?? "") }
        }

        func event(_ row: XMLElement, pid: Int32, malformed: inout Int) -> ClockEvent? {
            let names = values(child(row, ["signpost-name", "name"]))
            let begin = names.contains("GlimmerClockAnchorBegin")
            guard begin || names.contains("GlimmerClockAnchorEnd") else { return nil }
            guard let process = resolve(child(row, ["process"])),
                  let rowPID = values(child(process, ["pid"])).compactMap(Int32.init).first else {
                malformed += 1; return nil
            }
            guard rowPID == pid else { return nil }
            guard values(child(row, ["subsystem"])).contains("io.ugfugl.Glimmer"),
                  values(child(row, ["category"])).contains("PointsOfInterest") else {
                malformed += 1; return nil
            }
            guard let trace = values(child(row, ["event-time", "time"])).compactMap(UInt64.init).first else {
                malformed += 1; return nil
            }
            for message in values(child(row, ["os-log-metadata", "message"])) {
                if let event = decode(message, trace: trace, begin: begin) { return event }
            }
            malformed += 1
            return nil
        }

        func decode(_ message: String, trace: UInt64, begin: Bool) -> ClockEvent? {
            let tokens = message.split(whereSeparator: \.isWhitespace)
            guard tokens.count == 3 else { return nil }
            var fields: [String: String] = [:]
            for token in tokens {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { return nil }
            }
            guard let session = fields["session"], session.count == 16,
                  session.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
                  let id = fields["anchor_id"].flatMap(UInt64.init),
                  let uptime = fields[begin ? "uptime_before_ns" : "uptime_after_ns"].flatMap(UInt64.init) else { return nil }
            return ClockEvent(session: session, id: id, trace: trace, uptime: uptime, begin: begin)
        }
    }
}
