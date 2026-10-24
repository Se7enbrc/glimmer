// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Decisions behind system services, with the services stood in: wake notices,
// Shortcuts streams, display defaults, quitting, paste and the PIN page.

import GlimmerEngine
import Foundation
import Testing
import UserNotifications
@testable import Glimmer

@MainActor
struct SystemServiceSeamTests {
    private let settings = IsolatedDefaults()

    private func pc(id: String = "pc-1", customName: String? = nil, apps: [String] = ["Desktop", "Steam"]) -> Glimmer.Host {
        Glimmer.Host(id: id, name: "Den", customName: customName, localAddress: nil, manualAddress: nil,
                     apps: apps.enumerated().map { LibraryApp(id: $0.offset + 1, name: $0.element, hdr: false, hidden: false) },
                     lastConnected: nil, serverCertPEM: "pin", appVersion: nil, macAddress: nil)
    }

    // MARK: Wake notices

    @Test func aFailedWakeBehindAnotherAppIsReportedInANotice() async {
        var posted: [UNNotificationRequest] = []
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        await model.reportWake(.noAnswer, for: host, thenConnect: true, appActive: false,
                               notifier: WakeNotifier { posted.append($0) }, canPost: { true })
        #expect(model.wakeFailedHostID == host.id)
        #expect(model.wakeFailureReason == .noAnswer)
        #expect(posted.map(\.identifier) == ["wake.pc-1"])
        #expect(posted.first?.content.title == "Den didn't wake up")
        #expect(posted.first?.content.categoryIdentifier == "wake.failed")
    }

    @Test func aFailedWakeInFrontShowsOnlyOnTheButton() async {
        var posted: [UNNotificationRequest] = []
        let model = AppModel(defaults: settings.defaults)
        await model.reportWake(.couldNotSend, for: pc(), thenConnect: true, appActive: true,
                               notifier: WakeNotifier { posted.append($0) }, canPost: { true })
        #expect(model.wakeFailureReason == .couldNotSend)
        #expect(posted.isEmpty)
    }

    @Test func anAnswerBehindAnotherAppNotifiesInsteadOfStreaming() async {
        var posted: [UNNotificationRequest] = []
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        model.selectedHost = host
        await model.reportWake(.answered, for: host, thenConnect: true, appActive: false,
                               notifier: WakeNotifier { posted.append($0) }, canPost: { true })
        #expect(posted.first?.content.title == "Den is awake")
        #expect(posted.first?.content.categoryIdentifier == "wake.awake")
        #expect(model.lastLaunchAttempt == nil)
        #expect(model.wakeFailedHostID == nil)
    }

    @Test func anAnswerForAnotherSelectionDoesNothing() async {
        var posted: [UNNotificationRequest] = []
        let model = AppModel(defaults: settings.defaults)
        model.selectedHost = pc(id: "other")
        await model.reportWake(.answered, for: pc(), thenConnect: true, appActive: false,
                               notifier: WakeNotifier { posted.append($0) }, canPost: { true })
        #expect(posted.isEmpty)
        #expect(model.lastLaunchAttempt == nil)
    }

    // MARK: Stream from PC

    private struct Launch: Equatable {
        let app: String
        let host: String
    }

    private func stream(_ model: AppModel, pc entity: PCEntity, app: String?,
                        settle: @escaping @MainActor (AppModel) -> Void = { _ in }) async throws -> ([String], [Launch]) {
        var calls: [String] = []
        var launches: [Launch] = []
        try await StreamIntent.stream(entity, app: app, model: model,
                                      probe: { _, _ in calls.append("probe") },
                                      settle: { model, _ in calls.append("settle"); settle(model) },
                                      launch: { _, app, host in launches.append(Launch(app: app.name, host: host.id)) })
        return (calls, launches)
    }

    @Test func aNamedAppStreamsOnceTheRouteSettles() async throws {
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        model.hosts = [host]
        model.selectedHost = host
        let (calls, launches) = try await stream(model, pc: PCEntity(host: host), app: "steam")
        #expect(calls == ["settle"])
        #expect(launches == [Launch(app: "Steam", host: host.id)])
    }

    @Test func noAppNamedProbesThePCFirst() async throws {
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        model.hosts = [host]
        model.selectedHost = host
        let (calls, launches) = try await stream(model, pc: PCEntity(host: host), app: nil)
        #expect(calls == ["probe", "settle"])
        #expect(launches.count == 1)
        #expect(host.apps.contains { $0.name == launches.first?.app })
    }

    @Test func anUnknownAppOrPCIsRefused() async throws {
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        await #expect(throws: PCIntentError.notPaired) {
            _ = try await stream(model, pc: PCEntity(host: host), app: nil)
        }
        model.hosts = [host]
        await #expect(throws: PCIntentError.noApp("Halo", pc: "Den")) {
            _ = try await stream(model, pc: PCEntity(host: host), app: "Halo")
        }
    }

    @Test func aStreamThatStartsWhileTheRouteSettlesWins() async throws {
        let model = AppModel(defaults: settings.defaults)
        let host = pc()
        model.hosts = [host]
        model.selectedHost = host
        await #expect(throws: PCIntentError.alreadyStreaming) {
            _ = try await stream(model, pc: PCEntity(host: host), app: "Steam") { $0.isStreaming = true }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func siriRelearnsPCNamesAfterLaunchAndOnRename() async {
        let model = AppModel(defaults: settings.defaults)
        model.hosts = [pc()]
        let (updates, signal) = AsyncStream<Void>.makeStream()
        let tracking = GlimmerShortcuts.trackPCs(of: model, bootstrap: { _ in Task {} }, update: { signal.yield() })
        defer { tracking.cancel() }
        var waiter = updates.makeAsyncIterator()
        #expect(await waiter.next() != nil)
        model.hosts = [pc(customName: "Living Room")]
        #expect(await waiter.next() != nil)
    }

    // MARK: Display defaults

    @Test func presetsFollowTheDisplayItReports() {
        let model = AppModel(defaults: settings.defaults)
        model.displayProbe = { (3456, 2234, 120) }
        let native = model.effectiveValuesForPreset(.matchDisplay)
        #expect((native.width, native.height, native.fps) == (3456, 2234, 120))
        // Half of 2234 is odd; encoders need even sizes.
        let hidpi = model.effectiveValuesForPreset(.hidpi)
        #expect((hidpi.width, hidpi.height, hidpi.fps) == (1728, 1116, 120))
        model.displayProbe = { (1920, 1200, 60) }
        #expect(model.hidpiDefaultsForCurrentDisplay() == (1920, 1200, 60))
    }

    // MARK: Updates

    #if canImport(Sparkle)
    @Test func checkForUpdatesFollowsSparkle() {
        var report: (@MainActor @Sendable (Bool) -> Void)?
        let availability = UpdateAvailability { report = $0; return nil }
        #expect(!availability.canCheckForUpdates)
        report?(true)
        #expect(availability.canCheckForUpdates)
        report?(false)
        #expect(!availability.canCheckForUpdates)
    }
    #endif

    // MARK: Quit

    @Test func quitWithoutASessionIsImmediateAndRestoresThePointer() {
        let delegate = AppDelegate()
        var restored = false
        let reply = delegate.terminationReply(restorePointer: { restored = true }, stop: { _ in },
                                              reply: { Issue.record("an immediate quit has no deferred reply") })
        #expect(reply == .terminateNow)
        #expect(restored)
    }

    @Test(.timeLimit(.minutes(1)))
    func quitWithASessionRepliesAfterItStops() async {
        let model = AppModel(defaults: settings.defaults)
        model.nativeSession = StreamSession(hostDisposition: .cancelOwnedHostSession)
        let delegate = AppDelegate()
        delegate.model = model
        let (events, record) = AsyncStream<String>.makeStream()
        let reply = delegate.terminationReply(restorePointer: {}, stop: { _ in record.yield("stop") },
                                              reply: { record.yield("reply"); record.finish() })
        #expect(reply == .terminateLater)
        var seen: [String] = []
        for await event in events { seen.append(event) }
        #expect(seen == ["stop", "reply"])
    }

    // MARK: Paste and the PIN page

    @Test func pasteTypesTheClipboardItReads() async throws {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        defer { forwarder.detach() }
        #expect(forwarder.pasteClipboardAsText { nil } == nil)
        let task = try #require(forwarder.pasteClipboardAsText { "hunter2" })
        await task.value
        #expect(backend.texts == ["hunter2"])
    }

    @Test func pinPageBracketsAnIPv6Address() {
        var opened: [String] = []
        let model = AppModel(defaults: settings.defaults)
        model.openSunshinePINPage(forHost: "fe80::1") { opened.append($0.absoluteString) }
        model.openSunshinePINPage(forHost: "192.168.1.20") { opened.append($0.absoluteString) }
        #expect(opened == ["https://[fe80::1]:47990/pin", "https://192.168.1.20:47990/pin"])
    }
}
