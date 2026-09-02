//
//  StatsOverlayHostEncodeTests.swift
//
//  The overlay's "Host encode" row exists to answer "why is the framerate
//  sagging" by putting the host's per-frame capture+encode time next to the
//  frame budget. A wrong band here is worse than no row at all - a healthy
//  colour while the host is over budget sends the user hunting their network
//  for a problem that lives on the gaming PC - so the format and the three
//  bands are pinned here.
//

import Foundation
import Testing
@testable import Glimmer

struct StatsOverlayHostEncodeTests {

    private func snapshot(hostEncodeMs: Double?) -> StreamStatsSnapshot {
        var snap = StreamStatsSnapshot()
        snap.avgHostProcessingLatencyMs = hostEncodeMs
        return snap
    }

    /// Value cell is "average / budget", one decimal each: 8ms of host encode
    /// against a 240fps stream's 4.17ms budget.
    @Test func formatsAverageAgainstFrameBudget() {
        #expect(snapshot(hostEncodeMs: 8.0).formatHostEncode(targetFps: 240) == "8.0 ms / 4.2")
        #expect(snapshot(hostEncodeMs: 5.2).formatHostEncode(targetFps: 60) == "5.2 ms / 16.7")
    }

    /// No host measurement renders the same em-dash every other unknown row
    /// uses, and stays neutral - never "0.0 ms" in healthy white, which would
    /// read as a flawless host when the truth is we have no reading (GFE never
    /// reports the field at all).
    @Test func unknownHostEncodeRendersDashAndStaysNeutral() {
        #expect(snapshot(hostEncodeMs: nil).formatHostEncode(targetFps: 60) == "\u{2014}")
        #expect(snapshot(hostEncodeMs: nil).hostEncodeHealth(targetFps: 60) == .neutral)
    }

    /// Before a rate is negotiated there is no budget to divide by, so the row
    /// still shows the honest raw encode time rather than an infinity.
    @Test func missingTargetFpsDropsTheBudgetHalf() {
        #expect(snapshot(hostEncodeMs: 8.0).formatHostEncode(targetFps: 0) == "8.0 ms")
        #expect(snapshot(hostEncodeMs: 8.0).hostEncodeHealth(targetFps: 0) == .neutral)
    }

    /// The three bands at 60fps (16.67ms budget): healthy under 13.33ms (80%),
    /// warning across the 80-100% edge band, critical once encode costs more
    /// than a whole frame.
    @Test func healthBandsTrackTheFrameBudget() {
        #expect(snapshot(hostEncodeMs: 4.0).hostEncodeHealth(targetFps: 60) == .healthy)
        #expect(snapshot(hostEncodeMs: 13.0).hostEncodeHealth(targetFps: 60) == .healthy)
        #expect(snapshot(hostEncodeMs: 14.0).hostEncodeHealth(targetFps: 60) == .warning)
        #expect(snapshot(hostEncodeMs: 20.0).hostEncodeHealth(targetFps: 60) == .critical)
    }

    /// Boundaries: exactly 80% of budget warns, exactly one frame budget is
    /// still warning (the host is keeping up, barely), a hair over is critical.
    @Test func healthBandBoundaries() {
        let budget = 1000.0 / 120.0
        #expect(snapshot(hostEncodeMs: budget * 0.8).hostEncodeHealth(targetFps: 120) == .warning)
        #expect(snapshot(hostEncodeMs: budget).hostEncodeHealth(targetFps: 120) == .warning)
        #expect(snapshot(hostEncodeMs: budget * 1.01).hostEncodeHealth(targetFps: 120) == .critical)
    }

    /// The budget tightens with the requested rate: the same 8ms encode is
    /// comfortable at 60fps and over budget at 240fps.
    @Test func sameEncodeTimeChangesBandWithRequestedFps() {
        #expect(snapshot(hostEncodeMs: 8.0).hostEncodeHealth(targetFps: 60) == .healthy)
        #expect(snapshot(hostEncodeMs: 8.0).hostEncodeHealth(targetFps: 240) == .critical)
    }

    /// The row ships in Standard and Extended (not Minimal), and renders next
    /// to the client-side "Decode time" row so host and client frame costs
    /// read as a pair.
    @Test func rowIsInStandardAndExtendedAndSitsAfterDecodeTime() {
        #expect(StatsOverlayDefaults.microRows.contains(.hostProcessing))
        #expect(StatsOverlayDefaults.extendedRows.contains(.hostProcessing))
        #expect(!StatsOverlayDefaults.minimalRows.contains(.hostProcessing))

        let kinds = snapshot(hostEncodeMs: 8.0)
            .rows(enabled: StatsOverlayDefaults.extendedRows, targetFps: 60)
            .map(\.kind)
        guard let decodeTimeIndex = kinds.firstIndex(of: .decodeTime),
              let hostEncodeIndex = kinds.firstIndex(of: .hostProcessing) else {
            Issue.record("Extended preset is missing the decode-time / host-encode rows")
            return
        }
        #expect(hostEncodeIndex == decodeTimeIndex + 1)
    }

    /// End to end through the row builder: label, formatted value and health
    /// are what the overlay will actually draw.
    @Test func builtRowCarriesLabelValueAndHealth() {
        let rows = snapshot(hostEncodeMs: 20.0)
            .rows(enabled: [.hostProcessing], targetFps: 60)
        #expect(rows.count == 1)
        #expect(rows.first?.label == "Host encode")
        #expect(rows.first?.value == "20.0 ms / 16.7")
        #expect(rows.first?.health == .critical)
    }
}
