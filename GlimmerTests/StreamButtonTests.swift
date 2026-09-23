//
//  StreamButtonTests.swift
//
//  The launcher's Stream capsule: a failed wake explains itself in a line
//  that fits, a stopped wake shows nothing, and a reconnect reads as a
//  reconnect to the right PC.
//

import AppKit
import Testing
@testable import Glimmer

@MainActor
struct StreamButtonTests {

    /// Text column inside the 380 pt capsule: 22 pt padding each side, then
    /// the 16 pt glyph and 10 pt of spacing.
    private let lineWidth: CGFloat = 380 - 2 * 22 - 16 - 10

    private let pc = Host(
        id: "pc-1", name: "tower", customName: "Tower", localAddress: "192.0.2.10", manualAddress: nil,
        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil,
        macAddress: "aa:bb:cc:dd:ee:ff")

    @Test func wakeFailureLinesFitTheCapsule() {
        let font = NSFont.systemFont(ofSize: 11)
        for reason in [AppModel.WakeFailureReason.noAnswer, .couldNotSend] {
            let line = StreamButton.wakeFailureLine(reason, pcName: "Living Room PC")
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= lineWidth, "\(line) is \(width) pt wide")
        }
    }

    @Test func wakeFailureLineNamesTheCause() {
        #expect(StreamButton.wakeFailureLine(.noAnswer, pcName: "Tower").contains("Tower"))
        #expect(StreamButton.wakeFailureLine(.couldNotSend, pcName: "Tower").contains("this Mac"))
    }

    /// Stop Waiting during the bursts ends the wake at once, and not as a failure.
    @Test func aStoppedWakeEndsAtOnceWithoutAFailure() async {
        let model = AppModel()
        let wake = Task { await model.sendWakeAndWait(pc, waitSeconds: 90) { _, _ in 1 } }
        wake.cancel()
        let outcome = await wake.value
        #expect(outcome == .sent)
        #expect(outcome.failureReason == nil)
    }

    @Test func reconnectShowsOneLineNamingTheSessionsPC() {
        let stage = "Reconnecting to Tower…"
        let primary = StreamButton.connectingPrimary(stage: stage, selectedName: "Den")
        #expect(primary == stage)
        #expect(StreamButton.connectingSubtext(stage: stage, primary: primary) == nil)
    }

    @Test func engineStagesSitUnderTheConnectingLine() {
        let primary = StreamButton.connectingPrimary(stage: "RTSP handshake", selectedName: "Tower")
        #expect(primary == "Connecting to Tower…")
        #expect(StreamButton.connectingSubtext(stage: "RTSP handshake", primary: primary) == "RTSP handshake")
        #expect(StreamButton.connectingPrimary(stage: "Cancelling…", selectedName: "Tower") == "Cancelling…")
        #expect(StreamButton.connectingPrimary(stage: nil, selectedName: nil) == "Connecting…")
    }
}
