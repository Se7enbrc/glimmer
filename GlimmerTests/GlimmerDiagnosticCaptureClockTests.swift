// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

struct GlimmerDiagnosticCaptureClockTests {
    private final class ResourceBundle {}

    private static func fixture() throws -> String {
        let url = try #require(Bundle(for: ResourceBundle.self)
            .url(forResource: "instruments-clock-references", withExtension: "xml"))
        return try String(contentsOf: url, encoding: .utf8)
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
        let text = try Self.fixture().replacingOccurrences(of: "<event-time ref=\"time0\"/>",
                                                       with: "<event-time>1000000100</event-time>")
        let result = try inspect(text)
        #expect(result.status == "anchors_malformed" && result.malformedEvents == 1)
    }

    @Test func missingRawReferenceCannotBeReplacedByFormattedMetadata() throws {
        let text = try Self.fixture().replacingOccurrences(of: "<string ref=\"session\"/>",
                                                       with: "<string ref=\"missing\"/>")
            .replacingOccurrences(of: "2,000,000,000", with: "2000000000")
        #expect(try inspect(text).status == "anchor_xml_unverified")
    }

    @Test func cyclicMetadataReferenceIsRejectedWithoutUnboundedExpansion() throws {
        let text = try Self.fixture().replacingOccurrences(of: "<string id=\"session\">0123456789abcdef</string>",
                                                       with: "<string id=\"session\"><string ref=\"session\"/></string>")
        #expect(try inspect(text).status == "anchors_malformed")
    }

    @Test(arguments: ["signpost-name", "event-time", "process", "os-log-metadata"])
    func unresolvedReferencesNeverDisappearAsUnrelatedEvents(_ element: String) throws {
        let text = try Self.fixture().replacingOccurrences(of: "<\(element) ref=\"", with: "<\(element) ref=\"missing-")
        #expect(try inspect(text).status == "anchor_xml_unverified")
    }

    @Test func identicalRepeatedDefinitionsRemainValid() throws {
        let text = try Self.fixture().replacingOccurrences(of: "</trace-query-result>",
            with: "<signpost-name id=\"name0\">GlimmerClockAnchorBegin</signpost-name></trace-query-result>")
        let result = try inspect(text)
        #expect(result.status == "bounded_clock_verified" && result.anchors.count == 2)
    }

    @Test func duplicateDefinitionsCannotOverwriteEarlierEvidence() throws {
        let text = try Self.fixture().replacingOccurrences(of: "</trace-query-result>",
            with: "<signpost-name id=\"name0\">OtherEvent</signpost-name></trace-query-result>")
        #expect(try inspect(text).status == "anchor_xml_unverified")
    }

    @Test func referenceChainsResolveAndCyclesFailClosed() throws {
        let text = try Self.fixture().replacingOccurrences(of: "<process ref=\"process\"/>",
            with: "<process ref=\"alias\"/>")
            .replacingOccurrences(of: "</definitions>", with: "<process id=\"alias\" ref=\"process\"/></definitions>")
        #expect(try inspect(text).status == "bounded_clock_verified")
        let cycle = text.replacingOccurrences(of: "id=\"alias\" ref=\"process\"", with: "id=\"alias\" ref=\"alias\"")
        #expect(try inspect(cycle).status == "anchor_xml_unverified")
    }

    @Test func undecodableEventNamesCannotBeSilentlySkipped() throws {
        let text = try Self.fixture().replacingOccurrences(of: "</trace-query-result>", with: """
            <node><row><signpost-name id="broken"><string ref="broken"/></signpost-name></row></node>
            </trace-query-result>
            """)
        #expect(try inspect(text).status == "anchors_malformed")
    }
}
