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
    /// the power glyph as the button draws it and 10 pt of spacing.
    private let lineWidth: CGFloat = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let glyph = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        return 380 - 2 * 22 - (glyph?.size.width ?? 20) - 10
    }()

    private let pc = Host(
        id: "pc-1", name: "tower", customName: "Tower", localAddress: "192.0.2.10", manualAddress: nil,
        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
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

    /// The engine re-runs its connect stages during a reconnect; they mustn't
    /// turn the line back into a first connect.
    @Test func aReconnectKeepsItsLineThroughTheEngineStages() {
        let model = AppModel()
        model.handleNativeEvent(.reconnecting, host: pc)
        model.handleNativeEvent(.stageStarting(name: "RTSP handshake"), host: pc)
        #expect(model.streamPhase == .connecting(stage: "Reconnecting to Tower…"))
    }

    @Test func engineStagesSitUnderTheConnectingLine() {
        let primary = StreamButton.connectingPrimary(stage: "RTSP handshake", selectedName: "Tower")
        #expect(primary == "Connecting to Tower…")
        #expect(StreamButton.connectingSubtext(stage: "RTSP handshake", primary: primary) == "RTSP handshake")
        #expect(StreamButton.connectingPrimary(stage: "Cancelling…", selectedName: "Tower") == "Cancelling…")
        #expect(StreamButton.connectingPrimary(stage: nil, selectedName: nil) == "Connecting…")
    }

    private func role(_ phase: StreamPhase = .idle, reconnecting: Bool = false, chip: ChipPresentation = .ready(rttMs: 3),
                      backgrounded: Bool = false, shown: Bool = true) -> StreamButton.ButtonRole {
        let action = MenuBarPresentation.primaryAction(
            phase: phase, reconnecting: reconnecting,
            host: MenuBarHost(chip: chip, canWake: true, waking: false), heroApp: "Desktop")
        return StreamButton.role(for: action, backgrounded: backgrounded, connectingShown: shown)
    }

    /// The capsule and the menu bar's first row make the same call.
    @Test func theCapsuleFollowsTheMenuBarsPrimaryAction() {
        #expect(role() == .connect)
        #expect(role(chip: .certMismatch) == .pairAgain)
        #expect(role(chip: .asleep) == .wake)
        #expect(role(.connecting(stage: "Connecting to Tower…")) == .connecting)
        #expect(role(.connecting(stage: "Reconnecting to Tower…"), reconnecting: true) == .reconnecting)
        #expect(role(.streaming, backgrounded: true) == .liveBackgrounded)
    }

    /// Inside the 400 ms hold a connect still reads as the Stream button.
    @Test func aConnectInsideTheHoldKeepsTheStreamButton() {
        #expect(role(.connecting(stage: "Connecting to Tower…"), shown: false) == .connect)
        #expect(role(.connecting(stage: "Reconnecting to Tower…"), reconnecting: true, shown: false) == .connect)
    }
}
