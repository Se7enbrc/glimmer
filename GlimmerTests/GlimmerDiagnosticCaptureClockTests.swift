// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

struct GlimmerDiagnosticCaptureClockTests {
    // Matches Instruments' nested raw values, shared references and duplicate Points of Interest tables.
    private static func fixture() -> String {
        var rows = "<node>"
        var repeated = "<node>"
        for index in 0..<4 {
            let begin = index.isMultiple(of: 2)
            let trace = UInt64(index / 2 + 1) * 1_000_000_000 + (begin ? 0 : 1000)
            let uptime = UInt64(index / 2 + 2) * 1_000_000_000 + (begin ? 0 : 500)
            let prefix = begin ? "before" : "after"
            let metadata = """
                <os-log-metadata id="message\(index)"
                    fmt="session=0123456789abcdef anchor_id=\(index / 2) uptime_\(prefix)_ns=2,000,000,000">
                <narrative-text>session=</narrative-text><string ref="session"/>
                <narrative-text> anchor_id=</narrative-text><uint64>\(index / 2)</uint64>
                <narrative-text> uptime_\(prefix)_ns=</narrative-text><uint64 fmt="2,000,000,000">\(uptime)</uint64>
                </os-log-metadata>
                """
            rows += """
                <row><event-time id="time\(index)">\(trace)</event-time><process ref="process"/>
                <signpost-name id="name\(index)">GlimmerClockAnchor\(begin ? "Begin" : "End")</signpost-name>
                <subsystem ref="subsystem"/><category ref="category"/>\(metadata)</row>
                """
            repeated += """
                <row><event-time ref="time\(index)"/><process ref="process"/><signpost-name ref="name\(index)"/>
                <subsystem ref="subsystem"/><category ref="category"/><os-log-metadata ref="message\(index)"/></row>
                """
        }
        return """
            <trace-query-result><definitions><process id="process"><pid>17</pid></process>
            <string id="session">0123456789abcdef</string><subsystem id="subsystem">io.ugfugl.Glimmer</subsystem>
            <category id="category">PointsOfInterest</category></definitions>\(rows)</node>\(repeated)</node></trace-query-result>
            """
    }

    private func inspect(_ text: String) throws -> GlimmerDiagnosticCapture.ClockAlignment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(text.utf8).write(to: url)
        return GlimmerDiagnosticCapture.inspectClock(url, pid: 17)
    }

    @Test func nestedRawReferencesAndIdenticalDuplicateTablesPreserveClockBounds() throws {
        let result = try inspect(Self.fixture())
        #expect(result.status == "bounded_clock_verified")
        #expect(result.anchors.count == 2 && result.malformedEvents == 0)
        #expect(result.lowerOffsetNanos == 1_000_000_000 && result.upperOffsetNanos == 1_000_000_500)
    }

    @Test func conflictingDuplicateInvalidatesTheWholeAlignment() throws {
        let text = Self.fixture().replacingOccurrences(of: "<event-time ref=\"time0\"/>",
                                                       with: "<event-time>1000000100</event-time>")
        let result = try inspect(text)
        #expect(result.status == "anchors_malformed" && result.malformedEvents == 1)
    }

    @Test func missingRawReferenceCannotBeReplacedByFormattedMetadata() throws {
        let text = Self.fixture().replacingOccurrences(of: "<string ref=\"session\"/>",
                                                       with: "<string ref=\"missing\"/>")
            .replacingOccurrences(of: "2,000,000,000", with: "2000000000")
        #expect(try inspect(text).status == "anchors_malformed")
    }

    @Test func cyclicMetadataReferenceIsRejectedWithoutUnboundedExpansion() throws {
        let text = Self.fixture().replacingOccurrences(of: "<string id=\"session\">0123456789abcdef</string>",
                                                       with: "<string id=\"session\"><string ref=\"session\"/></string>")
        #expect(try inspect(text).status == "anchors_malformed")
    }
}
