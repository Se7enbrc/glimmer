//
//  StreamSignalTests.swift
//
//  The in-stream signals: banner pills (width clamp, the leave hint, VoiceOver), the leave-hint
//  budget, the codes a video-less bring-up or a lost link ends with and their toasts, and the stats
//  HUD's non-color emphasis.
//

import AppKit
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StreamSignalTests {

    @MainActor private final class Spoken {
        var lines: [String] = []
    }

    private func banner(hostWidth: CGFloat = 1_200) -> (StreamBannerLayer, CALayer, Spoken) {
        let host = CALayer()
        host.bounds = CGRect(x: 0, y: 0, width: hostWidth, height: 400)
        let pill = StreamBannerLayer(anchor: .topCenter, accent: NSColor.systemOrange.cgColor)
        let spoken = Spoken()
        pill.announce = { spoken.lines.append($0) }
        pill.attach(to: host)
        return (pill, host, spoken)
    }

    private let longText = "Weak connection. Lowering quality to 150 Mbps… and then some more words"

    // MARK: Width

    /// A pill wider than a narrow mini player keeps a 16pt margin each side
    /// instead of losing both ends off the panel.
    @Test func aLongPillFitsANarrowHost() {
        let (pill, _, _) = banner(hostWidth: 320)
        pill.setText(longText)
        #expect(pill.layer.frame.minX >= 16)
        #expect(pill.layer.frame.maxX <= 304)
    }

    /// Short text still sizes to fit and centers.
    @Test func aShortPillSizesToItsText() {
        let (pill, host, _) = banner()
        pill.setText("Reconnecting…")
        #expect(pill.layer.frame.width < 200)
        #expect(abs(pill.layer.frame.midX - host.bounds.midX) < 1)
    }

    /// Text that was laid out full screen re-flows when the same pill is shown
    /// again in a window that has since shrunk.
    @Test func aReshowReflowsForTheCurrentHostSize() {
        let (pill, host, _) = banner()
        pill.setText(longText)
        pill.setVisible(true)
        pill.setVisible(false)
        host.bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
        pill.setVisible(true)
        #expect(pill.layer.frame.maxX <= 304)
    }

    // MARK: Linger hint

    /// A pill that stays up earns the way out; a fresh show starts without it.
    @Test func aStuckPillSaysHowToLeave() async {
        let (pill, _, _) = banner()
        pill.lingerDelay = 0
        pill.lingerHint = { "Press ⌃⌥Q to stop streaming" }
        pill.setText("Reconnecting…")
        pill.setVisible(true)
        #expect(pill.displayedText == "Reconnecting…")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pill.displayedText == "Reconnecting… · Press ⌃⌥Q to stop streaming")

        pill.setText("Waiting for video…")
        #expect(pill.displayedText == "Waiting for video… · Press ⌃⌥Q to stop streaming")

        pill.setVisible(false)
        pill.setVisible(true)
        #expect(pill.displayedText == "Waiting for video…")
    }

    /// A pill hidden before its linger delay never grows the hint.
    @Test func aHiddenPillDoesNotLinger() async {
        let (pill, _, _) = banner()
        pill.lingerDelay = 0.02
        pill.lingerHint = { "Press ⌃⌥Q to stop streaming" }
        pill.setText("Reconnecting…")
        pill.setVisible(true)
        pill.setVisible(false)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(pill.displayedText == "Reconnecting…")
    }

    /// Pills without a hint (the network pill) never change their text.
    @Test func aPillWithoutAHintNeverGrows() async {
        let (pill, _, _) = banner()
        pill.lingerDelay = 0
        pill.setText("Stream stuttering")
        pill.setVisible(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pill.displayedText == "Stream stuttering")
    }

    // MARK: VoiceOver

    /// Shown and changed text is spoken once; the 4 Hz network gate
    /// re-asserting a latched pill says nothing more.
    @Test func announcementsFollowWhatIsOnScreen() {
        let (pill, _, spoken) = banner()
        pill.setText("Reconnecting…")
        #expect(spoken.lines.isEmpty)
        pill.setVisible(true)
        #expect(spoken.lines == ["Reconnecting…"])
        pill.setVisible(true)
        pill.setText("Reconnecting…")
        #expect(spoken.lines.count == 1)
        pill.setText("Waiting for video…")
        #expect(spoken.lines.last == "Waiting for video…")
        pill.setVisible(false)
        pill.setText("Reconnecting…")
        #expect(spoken.lines.count == 2)
    }

    @Test func aLatchedNetworkPillAnnouncesOnce() {
        let (pill, _, spoken) = banner()
        for _ in 0..<40 { pill.setSustained(true, text: "Stream stuttering") }
        #expect(spoken.lines == ["Stream stuttering"])
    }

    // MARK: Leave hint budget

    /// Fixed scratch domain, cleaned on both ends (see ContainerMigrationTests).
    private static let leaveHintDomain = "io.ugfugl.Glimmer.tests.leave-hint"

    /// Three shows per chord; rebinding the chord is a new lesson.
    @Test func theLeaveHintShowsThreeTimesPerChord() throws {
        let domain = Self.leaveHintDomain
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }

        let text = "Press ⌃⌥Q to stop streaming"
        let shows = (0..<6).filter { _ in StreamSession.claimLeaveHintShow(text, defaults: defaults) }
        #expect(shows.count == 3)
        #expect(StreamSession.claimLeaveHintShow("Press ⌃⌥W to stop streaming", defaults: defaults))
    }

    // MARK: Watchdog end codes

    /// moonlight-common-c's codes: -100 when no video ever arrived, -101 when
    /// it arrived but never decoded. A stall after video flowed stays -1.
    @Test func aStreamThatNeverShowedVideoSaysWhy() {
        let code = StreamSession.watchdogTerminationCode
        #expect(code(true, .infinity) == -100)
        #expect(code(true, 2.5) == -101)
        #expect(code(false, 2.5) == -1)
        #expect(code(false, .infinity) == -1)
    }

    /// Each bring-up code reaches the user as its own fix, not the generic toast.
    @Test func theEndedToastNamesTheFix() {
        let traffic = AppModel.streamEndedMessage(code: -100, hostName: "Den PC")
        let frame = AppModel.streamEndedMessage(code: -101, hostName: "Den PC")
        let lost = AppModel.streamEndedMessage(code: -1, hostName: "Den PC")
        let other = AppModel.streamEndedMessage(code: -102, hostName: "Den PC")
        #expect(traffic.contains("Den PC") && traffic.contains("UDP port 47998"))
        #expect(frame.contains("Den PC") && frame.contains("codec"))
        #expect(lost == "Lost the connection to Den PC.")
        #expect(other == "Stream to Den PC ended unexpectedly.")
        #expect(Set([traffic, frame, lost, other]).count == 4)
        #expect(![traffic, frame, lost, other].contains { $0.localizedCaseInsensitiveContains("host") })
    }

    // MARK: Stats HUD

    /// With Differentiate Without Color on, warning and critical values are
    /// heavier than healthy ones; off, weight carries nothing.
    @Test func warningValuesAreHeavierWithoutColor() {
        func weight(_ health: StatsRow.Health, _ differentiate: Bool) -> Int {
            NSFontManager.shared.weight(
                of: StatsOverlayLayer.valueFont(for: health, differentiateWithoutColor: differentiate))
        }
        let regular = weight(.healthy, true)
        #expect(weight(.warning, true) > regular)
        #expect(weight(.critical, true) > regular)
        #expect(weight(.neutral, true) == regular)
        #expect(weight(.critical, false) == regular)
        #expect(StatsOverlayLayer.valueFont(for: .critical, differentiateWithoutColor: true).isFixedPitch)
    }
}
