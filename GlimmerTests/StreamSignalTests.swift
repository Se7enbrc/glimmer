// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  StreamSignalTests.swift
//
//  The in-stream signals: banner pills (width clamp, the leave hint, VoiceOver), the leave-hint
//  budget, the watchdog's idle clock, the codes a video-less bring-up or a lost link ends with,
//  their toasts, and the stats HUD's non-color emphasis.
//

import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import GlimmerEngine
@testable import Glimmer

@MainActor
struct StreamSignalTests {
    private let settings = IsolatedDefaults()

    @MainActor private final class Spoken {
        var lines: [String] = []
    }

    // The stream window stays offscreen, so notices lay out without appearing on the owner's display.
    private func banner(hostWidth: CGFloat = 1_200) -> (StreamBanner, NSWindow, Spoken) {
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: hostWidth, height: 400), styleMask: .borderless,
                            backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        let pill = StreamBanner(anchor: .topCenter, accent: .systemOrange)
        let spoken = Spoken()
        pill.announce = { spoken.lines.append($0) }
        pill.attach(to: host)
        return (pill, host, spoken)
    }

    @Test func aNoticeExistsOnlyWhileShownAndReshowsDuringItsFade() {
        let (pill, _, _) = banner()
        pill.setText("Reconnecting…")
        #expect(pill.noticeFrame == nil)
        pill.setVisible(true)
        #expect(pill.isVisible && pill.noticeFrame != nil)
        pill.setVisible(false)
        pill.setVisible(true)
        #expect(pill.isVisible && pill.noticeFrame != nil)
    }

    @Test func macOS15UsesTheMaterialFallback() {
        let (pill, _, _) = banner()
        pill.glassAvailable = false
        pill.setText("Reconnecting…")
        #expect(!pill.content.glass)
        pill.glassAvailable = true
        #expect(pill.content.glass)
    }

    private let longText = "Weak connection. Lowering quality to 150 Mbps… and then some more words"

    // MARK: Width

    /// A pill wider than a narrow mini player keeps a 16pt margin each side
    /// instead of losing both ends off the panel.
    @Test func aLongPillFitsANarrowHost() {
        let (pill, _, _) = banner(hostWidth: 320)
        pill.setText(longText)
        pill.setVisible(true)
        let frame = pill.noticeFrame ?? .null
        #expect(frame.minX >= 16 - 0.5)
        #expect(frame.maxX <= 304 + 0.5)
    }

    /// Short text still sizes to fit and centers.
    @Test func aShortPillSizesToItsText() {
        let (pill, host, _) = banner()
        pill.setText("Reconnecting…")
        pill.setVisible(true)
        let frame = pill.noticeFrame ?? .null
        #expect(frame.width < 200)
        #expect(abs(frame.midX - host.contentLayoutRect.midX) < 1)
    }

    /// Text that was laid out full screen re-flows when the same pill is shown
    /// again in a window that has since shrunk.
    @Test func aReshowReflowsForTheCurrentHostSize() {
        let (pill, host, _) = banner()
        pill.setText(longText)
        pill.setVisible(true)
        pill.setVisible(false)
        host.setContentSize(CGSize(width: 320, height: 200))
        pill.setVisible(true)
        #expect((pill.noticeFrame ?? .null).maxX <= 304 + 0.5)
    }

    // MARK: Linger hint

    /// A pill that stays up earns the way out; a fresh show starts without it.
    @Test func aStuckPillSaysHowToLeave() throws {
        let (pill, _, _) = banner()
        var callbacks: [@MainActor () -> Void] = []
        pill.scheduleLingerDelay = { delay, action in
            #expect(delay == 5)
            callbacks.append(action)
        }
        pill.lingerHint = { "Press ⌃⌥Q to stop streaming" }
        pill.setText("Reconnecting…")
        pill.setVisible(true)
        #expect(pill.displayedText == "Reconnecting…")
        let linger = try #require(callbacks.first)
        linger()
        #expect(pill.displayedText == "Reconnecting… · Press ⌃⌥Q to stop streaming")

        pill.setText("Waiting for video…")
        #expect(pill.displayedText == "Waiting for video… · Press ⌃⌥Q to stop streaming")

        pill.setVisible(false)
        pill.setVisible(true)
        linger()
        #expect(pill.displayedText == "Waiting for video…")
    }

    /// A pill hidden before its linger delay never grows the hint.
    @Test func aHiddenPillDoesNotLinger() throws {
        let (pill, _, _) = banner()
        var callback: (@MainActor () -> Void)?
        pill.scheduleLingerDelay = { delay, action in
            #expect(delay == 5)
            callback = action
        }
        pill.lingerHint = { "Press ⌃⌥Q to stop streaming" }
        pill.setText("Reconnecting…")
        pill.setVisible(true)
        pill.setVisible(false)
        let linger = try #require(callback)
        linger()
        #expect(pill.displayedText == "Reconnecting…")
    }

    /// Pills without a hint (the network pill) never change their text.
    @Test func aPillWithoutAHintNeverGrows() {
        let (pill, _, _) = banner()
        var scheduled = false
        pill.scheduleLingerDelay = { _, _ in scheduled = true }
        pill.setText("Stream stuttering")
        pill.setVisible(true)
        #expect(!scheduled)
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

    @Test func hiddenStreamLetsTheDisplaySleep() {
        let visible = StreamSession.sessionActivityOptions(hidden: false)
        let hidden = StreamSession.sessionActivityOptions(hidden: true)
        #expect(visible == [
            .userInitiated, .latencyCritical,
            .idleDisplaySleepDisabled, .idleSystemSleepDisabled
        ])
        #expect(!hidden.contains(.idleDisplaySleepDisabled))
        #expect(hidden.contains(.latencyCritical))
        #expect(hidden.contains(.idleSystemSleepDisabled))
    }

    @Test func backgroundBeforeDecoderAdoptionReleasesDisplayAssertion() async {
        let decoder = VideoDecoder()
        decoder.setPresentSuppressed(true)
        let native = MacSessionServices()
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, audioDecoder: AudioDecoder(defaults: settings.defaults),
            services: native.services(), backend: MacTransport.makeBackend(),
            makeNetwork: { NetworkClient(server: $0) }, makeBackend: { MacTransport.makeBackend() })
        let (beforeAdoption, afterAdoption) = await session.checkEarlyBackgroundAdoption(decoder, native: native)
        #expect(!beforeAdoption)
        #expect(afterAdoption)
        decoder.teardown()
    }

    @Test func resettingStallLatchesClearsEveryLatch() async {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession)
        await session.setStallLatchesForTesting()
        await session.resetStallLatches()
        #expect(!session.didLogDecodeOnlyStall)
        #expect(!session.didAttemptStallRecovery)
        #expect(!session.didLogWatchdogHold)
        #expect(await !session.didLogDownshiftDecision)
    }

    @Test func rendererFailureRecoveryCoalescesQueuedHops() async {
        let decoder = VideoDecoder()

        #expect(decoder.recoverPresentPathFromRenderQueue(reason: "renderer_failed"))
        #expect(!decoder.recoverPresentPathFromRenderQueue(reason: "renderer_failed"))

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(decoder.recoverPresentPathFromRenderQueue(reason: "renderer_failed"))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

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
        #expect(lost == "Lost the connection to Den PC. Check the network, then try again.")
        #expect(other == "Stream to Den PC ended unexpectedly.")
        #expect(Set([traffic, frame, lost, other]).count == 4)
        #expect(![traffic, frame, lost, other].contains { $0.localizedCaseInsensitiveContains("host") })
    }

    @Test func aKnownVideoPathAsksForRetryInsteadOfFirewallChanges() {
        let message = AppModel.streamEndedMessage(code: -100, hostName: "Den PC", hasReceivedVideo: true)
        #expect(message == "Den PC didn't start sending video. Try again.")
        #expect(!message.contains("firewall"))
        #expect(AppModel.streamEndedMessage(code: -100, hostName: "Den PC", hasReceivedVideo: false)
            .contains("UDP port 47998"))
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
        #expect(!StatsOverlayLayer.valueFont(for: .critical, differentiateWithoutColor: true).isFixedPitch)
    }
}

private extension StreamSession {
    func setStallLatchesForTesting() {
        didLogDecodeOnlyStall = true
        didAttemptStallRecovery = true
        didLogWatchdogHold = true
        didLogDownshiftDecision = true
    }
}

extension StreamSession {
    func checkEarlyBackgroundAdoption(_ decoder: VideoDecoder, native: MacSessionServices) -> (Bool, Bool) {
        isStreaming = true
        beginPowerAssertion()
        defer {
            endPowerAssertion()
            videoDecoder = nil
            isStreaming = false
        }
        refreshPowerAssertion()
        let beforeAdoption = native.isHidden
        adoptVideoDecoder(decoder)
        return (beforeAdoption, native.isHidden)
    }
}

@MainActor
struct MouseModeBadgeTests {
    @Test func theBadgeFollowsMouseModeAfterTheNotice() throws {
        let stream = StreamWindow()
        defer { stream.close() }
        stream.leaveHintBanner.announce = { _ in }
        var pending: [@MainActor () -> Void] = []
        stream.scheduleMouseModeBadge = { delay, action in
            #expect(delay == 2)
            pending.append(action)
        }
        stream.showControllerMouseMode("Controller is now a mouse.", enabled: true)
        #expect(!stream.mouseModeBadge.isVisible && stream.leaveHintBanner.isVisible)
        pending.removeFirst()()
        #expect(stream.mouseModeBadge.isVisible)
        #expect(stream.mouseModeBadge.content.accessibilityName == "Mouse mode on")
        stream.showControllerMouseMode("Controller is back in the game.", enabled: false)
        #expect(!stream.mouseModeBadge.isVisible && stream.leaveHintBanner.isVisible)
        // A quick off-on-off never revives a stale badge.
        stream.showControllerMouseMode("Controller is now a mouse.", enabled: true)
        stream.showControllerMouseMode("Controller is back in the game.", enabled: false)
        for action in pending { action() }
        #expect(!stream.mouseModeBadge.isVisible)
    }

    @Test(arguments: StatsOverlayCorner.allCases)
    func theBadgeNeverCoversTheStatsOrANotice(corner: StatsOverlayCorner) throws {
        let stream = StreamWindow()
        defer { stream.close() }
        stream.window.setContentSize(CGSize(width: 1280, height: 720))
        stream.statsOverlay.corner = corner
        for banner in [stream.leaveHintBanner, stream.networkBanner, stream.reconnectBanner] {
            banner.announce = { _ in }
            banner.setText("A long notice that reaches well toward both edges of the stream window")
            banner.setVisible(true)
        }
        stream.mouseModeBadge.setVisible(true)
        let height = stream.displayView.bounds.height
        let badge = try #require(stream.mouseModeBadge.noticeFrame)
        let flipped = CGRect(x: badge.minX, y: height - badge.maxY, width: badge.width, height: badge.height)
        #expect(stream.mouseModeBadgeObstacles().allSatisfy { !$0.intersects(flipped) }, "\(corner)")
    }

    // Renders the real stats panel and badge over bright and dark frames on the forced macOS 15 material.
    @Test(arguments: [false, true])
    func badgeCaptureBesideTheStatsPanel(dark: Bool) throws {
        let stream = StreamWindow()
        defer { stream.close() }
        stream.window.setContentSize(CGSize(width: 960, height: 540))
        var snapshot = StreamStatsSnapshot()
        snapshot.renderedFps = 119.9
        snapshot.rttMs = 3.5
        snapshot.measuredBitrateMbps = 46.2
        snapshot.videoCodec = "HEVC"
        stream.statsOverlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 120)
        stream.statsOverlay.setVisible(true)
        stream.statsOverlay.layoutInHost(stream.displayLayer)
        stream.mouseModeBadge.glassAvailable = false
        stream.mouseModeBadge.setVisible(true)
        let badge = try #require(stream.mouseModeBadge.noticeFrame)
        let size = stream.displayView.bounds.size
        let context = try #require(CGContext(data: nil, width: Int(size.width) * 2, height: Int(size.height) * 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        let colors = dark
            ? [CGColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1), CGColor(red: 0.18, green: 0.12, blue: 0.22, alpha: 1)]
            : [CGColor(red: 0.62, green: 0.82, blue: 0.98, alpha: 1), CGColor(red: 0.98, green: 0.93, blue: 0.80, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        let stats = stream.statsOverlay.layer
        context.saveGState()
        context.translateBy(x: stats.frame.minX, y: stats.frame.minY)
        stats.render(in: context)
        context.restoreGState()
        let host = NSHostingView(rootView: stream.mouseModeBadge.content)
        let holder = NSWindow(contentRect: CGRect(origin: .zero, size: badge.size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        holder.isReleasedWhenClosed = false
        holder.isOpaque = false
        holder.backgroundColor = .clear
        holder.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        holder.contentView = host
        defer { holder.close() }
        host.frame = CGRect(origin: .zero, size: badge.size)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let image = rep.cgImage { context.draw(image, in: badge) }
        let composed = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]))
        #expect(!stats.frame.intersects(badge.insetBy(dx: -8, dy: -8)))
        Attachment.record(data, named: "mac-badge-macos15-\(dark ? "dark" : "light").png")
    }
}
