// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension GlimmerDiagnosticCapture {
    static func inspectSamples(_ url: URL, pid: Int32) -> SampleSummary? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1200
        guard let referencesParser = XMLParser(contentsOf: url) else { return nil }
        let references = ClockReferences(deadline: deadline)
        referencesParser.delegate = references
        guard referencesParser.parse(), let parser = XMLParser(contentsOf: url) else { return nil }
        let summary = SampleSummary(pid: pid, referencedClocks: references.ids, deadline: deadline)
        parser.delegate = summary
        guard parser.parse(), summary.unresolvedRows == 0 else { return nil }
        return summary
    }

    final class ClockReferences: NSObject, XMLParserDelegate {
        var ids: Set<UInt64> = []
        private let deadline: Double
        private var elements = 0

        init(deadline: Double) { self.deadline = deadline }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            elements += 1
            if elements % 10_000 == 0, ProcessInfo.processInfo.systemUptime > deadline { parser.abortParsing() }
            guard name == "sample-time" || name == "start-time", let ref = attributes["ref"].flatMap(UInt64.init) else {
                return
            }
            ids.insert(ref)
            if ids.count > 2_000_000 { parser.abortParsing() }
        }
    }

    final class SampleSummary: NSObject, XMLParserDelegate {
        let pid: Int32
        var rows = 0
        var targetRows = 0
        var first: UInt64?
        var last: UInt64?
        var unresolvedRows = 0
        private let referencedClocks: Set<UInt64>
        private let deadline: Double
        private var path: [String] = []
        private var target: Bool?
        private var time: UInt64?
        private var capture: String?
        private var captureID: String?
        private var value = ""
        private var processIDs: [String: Bool] = [:]
        private var pidIDs: [String: Bool] = [:]
        private var processes: [(id: String?, direct: Bool)] = []
        private var clockValues: [UInt64: UInt64] = [:]
        private var elements = 0

        init(pid: Int32, referencedClocks: Set<UInt64>, deadline: Double) {
            self.pid = pid
            self.referencedClocks = referencedClocks
            self.deadline = deadline
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            elements += 1
            if elements % 10_000 == 0, ProcessInfo.processInfo.systemUptime > deadline { parser.abortParsing() }
            let parent = path.last
            path.append(name)
            if name == "row" { target = nil; time = nil }
            guard path.contains("row") else { return }
            if name == "process" {
                processes.append((attributes["id"], parent == "row"))
                if parent == "row", let ref = attributes["ref"] { target = processIDs[ref] }
            }
            if parent == "row", name == "sample-time" || name == "start-time" {
                if let ref = attributes["ref"].flatMap(UInt64.init) { time = clockValues[ref] }
                capture = name; captureID = attributes["id"]; value = ""
            } else if name == "pid", !processes.isEmpty {
                if let ref = attributes["ref"], let matches = pidIDs[ref] { markProcess(matches) }
                capture = name; captureID = attributes["id"]; value = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capture != nil else { return }
            guard value.utf8.count + string.utf8.count <= 128 else { parser.abortParsing(); return }
            value += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == capture {
                if name == "pid", let number = Int32(value) {
                    markProcess(number == pid)
                    if let captureID { pidIDs[captureID] = number == pid }
                } else if name != "pid", let number = UInt64(value) {
                    time = number
                    if let id = captureID.flatMap(UInt64.init), referencedClocks.contains(id) { clockValues[id] = number }
                }
                capture = nil
            }
            if processIDs.count > 100_000 || pidIDs.count > 100_000 { parser.abortParsing(); return }
            if name == "process", !processes.isEmpty { processes.removeLast() }
            if name == "row" {
                rows += 1
                if target == nil { unresolvedRows += 1 }
                if target == true {
                    if let time {
                        targetRows += 1
                        first = min(first ?? time, time)
                        last = max(last ?? time, time)
                    } else { unresolvedRows += 1 }
                }
            }
            if !path.isEmpty { path.removeLast() }
        }

        private func markProcess(_ matches: Bool) {
            guard let process = processes.last else { return }
            if let id = process.id { processIDs[id] = matches }
            if process.direct { target = matches }
        }
    }
}
