// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import Darwin
import Foundation

extension DiagnosticEvidence {
    static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { throw Failure.unsafePath }
    }

    static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value != 127 }
    }

    static func validateDirectory(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        guard url.isFileURL, canonical.resolvingSymlinksInPath().path == canonical.path,
              try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.unsafePath
        }
    }

    static func openRegular(_ url: URL) throws -> (FileHandle, stat) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw Failure.unsafePath
        }
        return (handle, info)
    }

    static func metadata(_ url: URL) throws -> [String: Any] {
        let (handle, info) = try openRegular(url)
        defer { try? handle.close() }
        guard info.st_size >= 0, info.st_size <= maxMetadata else { throw Failure.limit }
        let data = try handle.read(upToCount: maxMetadata + 1) ?? Data()
        guard data.count <= maxMetadata,
              let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
        return row
    }

    static func copy(_ name: String, context: Context) -> URL? {
        guard safeName(name), name.hasPrefix("telemetry-"), context.files.count < 64 else {
            context.issue("Rejected unsafe filename or file-count limit."); return nil
        }
        let destination = context.output.appendingPathComponent(name)
        if context.files.contains(where: { $0.name == name }) { return destination }
        do {
            let (input, before) = try openRegular(context.source.appendingPathComponent(name))
            defer { try? input.close() }
            guard before.st_size >= 0, UInt64(before.st_size) <= maxBytes - context.bytes else { throw Failure.limit }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { throw Failure.unsafePath }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hash = SHA256(), copied: UInt64 = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                guard UInt64(chunk.count) <= maxBytes - context.bytes else { throw Failure.limit }
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
                copied += UInt64(chunk.count); context.bytes += UInt64(chunk.count)
            }
            try output.synchronize()
            var after = stat(), pathInfo = stat()
            let statOK = fstat(input.fileDescriptor, &after) == 0
                && lstat(context.source.appendingPathComponent(name).path, &pathInfo) == 0
            let changed = !statOK || before.st_size != after.st_size || copied != UInt64(before.st_size)
                || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
                || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
                || before.st_ino != pathInfo.st_ino || before.st_dev != pathInfo.st_dev
            context.files.append(FileRecord(name: name, bytes: copied,
                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), sourceChanged: changed))
            if changed { context.issue("Source changed while copying \(name).") }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            context.issue("Missing, unsafe, oversized or unreadable file: \(safeName(name) ? name : "invalid filename").")
            return nil
        }
    }

    static func firstRowSession(_ url: URL, key: String, emptyAllowed: Bool = false) throws -> String? {
        let (handle, _) = try openRegular(url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
            if let newline = data.firstIndex(of: 10) {
                guard newline <= maxLine,
                      let row = try JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any],
                      let session = row[key] as? String else { throw Failure.malformed }
                return session
            }
            guard data.count <= maxLine else { throw Failure.limit }
        }
        if data.isEmpty && emptyAllowed { return nil }
        throw Failure.malformed
    }

    static func selectFiles(_ context: Context) {
        let receiptName = "telemetry-evidence-\(context.session).json"
        if let receiptURL = copy(receiptName, context: context) {
            do { try selectReceipt(metadata(receiptURL), context: context) } catch { context.issue("Malformed evidence receipt.") }
        }
        guard let enumerator = FileManager.default.enumerator(at: context.source,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsSubdirectoryDescendants]) else {
            context.issue("Cannot enumerate source capture."); return
        }
        var scanned = 0, manifests = 0
        for case let url as URL in enumerator {
            scanned += 1
            guard scanned <= 4096 else { context.issue("Source directory scan limit exceeded."); break }
            let name = url.lastPathComponent
            guard name.hasPrefix("telemetry-frames-"), name.hasSuffix("-manifest.json") else { continue }
            guard let candidate = try? metadata(url), candidate["session"] as? String == context.session else { continue }
            manifests += 1
            guard let snapshot = copy(name, context: context) else { continue }
            do {
                try selectFrameManifest(metadata(snapshot), context: context)
            } catch { context.issue("Malformed frame manifest: \(name).") }
        }
        if manifests != 1 { context.issue("Expected one exact-session frame manifest; found \(manifests).") }
        if context.metrics == nil { context.issue("Metrics snapshot unavailable.") }
        if context.report == nil { context.issue("Session report unavailable.") }
    }

    static func selectReceipt(_ row: [String: Any], context: Context) throws {
        guard row["session"] as? String == context.session, row["schema"] as? Int == 1 else { throw Failure.malformed }
        if row["closed"] as? Bool != true { context.issue("Evidence receipt is not closed.") }
        for key in ["rows_failed", "write_failures"] where row[key] as? Int != 0 {
            context.issue("Receipt \(key) is nonzero or missing.")
        }
        context.expectedMetricRows = row["rows_written"] as? Int
        if let started = row["started_ms"] as? Double, started.isFinite, started >= 0 {
            context.startedMs = started
        } else { context.issue("Receipt monotonic clock origin is missing or invalid.") }
        guard let metrics = row["metrics_file"] as? String, let report = row["report_file"] as? String,
              metrics.hasPrefix("telemetry-"), metrics.hasSuffix(".ndjson"),
              !metrics.hasPrefix("telemetry-frames-"), report.hasPrefix("telemetry-session-"),
              report.hasSuffix(".json") else { throw Failure.malformed }
        guard safeName(metrics), safeName(report),
              try firstRowSession(context.source.appendingPathComponent(metrics), key: "session") == context.session,
              try metadata(context.source.appendingPathComponent(report))["session"] as? String == context.session else {
            throw Failure.malformed
        }
        if let copied = copy(metrics, context: context) { context.metrics = copied.lastPathComponent }
        if let copied = copy(report, context: context) {
            let reportRow = try metadata(copied)
            guard reportRow["session"] as? String == context.session else { throw Failure.malformed }
            context.report = copied.lastPathComponent
        }
    }

    static func selectFrameManifest(_ row: [String: Any], context: Context) throws {
        guard row["session"] as? String == context.session, row["schema"] as? Int == 1,
              let segments = row["segments"] as? [[String: Any]], segments.count <= 20 else { throw Failure.malformed }
        if row["closed"] as? Bool != true || row["complete"] as? Bool != true {
            context.issue("Frame manifest is not closed and complete.")
        }
        let lossFields = ["overflow_records", "unwritten_records", "write_failures", "manifest_write_failures", "pruned_records"]
        for key in lossFields where row[key] as? Int != 0 {
            context.issue("Frame manifest \(key) is nonzero or missing.")
        }
        guard let accepted = row["accepted_records"] as? Int, let written = row["written_records"] as? Int,
              accepted >= 0, written >= 0 else { throw Failure.malformed }
        if accepted != written { context.issue("Accepted and written frame counts disagree.") }
        var expected = 0
        for segment in segments.sorted(by: { ($0["index"] as? Int ?? -1) < ($1["index"] as? Int ?? -1) }) {
            guard let name = segment["name"] as? String, name.hasPrefix("telemetry-frames-"), name.hasSuffix(".ndjson"),
                  let records = segment["records"] as? Int, records >= 0, let bytes = segment["bytes"] as? UInt64 else {
                throw Failure.malformed
            }
            guard records <= 5_000_000, expected <= 5_000_000 - records else { throw Failure.limit }
            expected += records
            guard safeName(name) else { throw Failure.unsafePath }
            do {
                let identity = try firstRowSession(context.source.appendingPathComponent(name),
                                                   key: "trace_session", emptyAllowed: records == 0)
                guard identity == context.session || (identity == nil && records == 0) else { throw Failure.malformed }
            } catch {
                context.issue("Missing, malformed or wrong-session segment: \(name).")
                continue
            }
            if copy(name, context: context) != nil {
                context.frames.append(Segment(name: name, records: records, first: segment["first_sequence"] as? UInt64,
                                              last: segment["last_sequence"] as? UInt64, bytes: bytes))
            }
        }
        if expected != written { context.issue("Frame manifest segment counts disagree with written records.") }
        if segments.isEmpty { context.issue("No frame segments recorded.") }
    }
}
