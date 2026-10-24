// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Foundation
import Testing
@testable import GlimmerEngine
@testable import Glimmer

@Suite(.serialized)
struct SessionContinuationTests {
    private let settings = IsolatedDefaults()

    private func makeSession(_ disposition: StreamHostDisposition, sunshine: FakeSunshine) -> StreamSession {
        StreamSession(hostDisposition: disposition, audioDecoder: AudioDecoder(defaults: settings.defaults),
            services: SessionServices(), backend: InputRecordingBackend(),
            makeNetwork: { sunshine.client($0) }, makeBackend: { InputRecordingBackend() })
    }

    @Test(arguments: [false, true])
    func sameAppResumesAndStopHonorsSetting(leaveRunning: Bool) async throws {
        let sunshine = FakeSunshine.scripted(["resume": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 7
        let session = makeSession(.init(leaveGamesRunning: leaveRunning), sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
            config: SessionFlow.config.request, info: pc)
        #expect(sunshine.paths == ["resume"])
        #expect(sunshine.requests.first?.query["sops"] == "0")
        await session.stop()
        await session.stop()
        #expect(sunshine.paths == (leaveRunning ? ["resume"] : ["resume", "cancel"]))
    }

    @Test(arguments: [false, true])
    func differentAppRequiresSpecificApproval(leaveRunning: Bool) async throws {
        let sunshine = FakeSunshine.scripted([:])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 9
        let session = makeSession(.init(leaveGamesRunning: leaveRunning), sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        let failure = await #expect(throws: TakeoverRequired.self) {
            _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
                config: SessionFlow.config.request, info: pc)
        }
        #expect(failure?.appID == 9)
        #expect(sunshine.paths.isEmpty)
    }

    @Test(arguments: [false, true])
    func approvedSwitchCancelsOnceThenLaunches(leaveRunning: Bool) async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(9), SessionFlow.idle],
            "cancel": [SessionFlow.cancelled], "launch": [SessionFlow.launched]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 9
        let session = makeSession(.init(leaveGamesRunning: leaveRunning), sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        await session.approveReplacement(of: 9)
        _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
            config: SessionFlow.config.request, info: pc)
        #expect(sunshine.paths == ["serverinfo", "cancel", "serverinfo", "launch"])
    }

    @Test func changedOccupantCannotInheritApproval() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(11)]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 9
        let session = makeSession(.disconnectOnly, sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        await session.approveReplacement(of: 9)
        let error = await #expect(throws: TakeoverRequired.self) {
            _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
                config: SessionFlow.config.request, info: pc)
        }
        #expect(error?.appID == 11)
        #expect(sunshine.paths == ["serverinfo"])
    }

    @Test func idleAfterApprovalStartsWithoutCancel() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 9
        let session = makeSession(.disconnectOnly, sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        await session.approveReplacement(of: 9)
        _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
            config: SessionFlow.config.request, info: pc)
        #expect(sunshine.paths == ["serverinfo", "launch"])
    }

    @Test func endedContinuationNeverBecomesLaunch() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let pc = SessionFlow.pairedPC()
        let session = makeSession(.disconnectOnly, sunshine: sunshine)
        await session.prepareLaunchFlow(server: pc)
        await session.requireContinuation()
        await #expect(throws: RunningAppFailure.self) {
            _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
                config: SessionFlow.config.request, info: pc)
        }
        #expect(sunshine.paths.isEmpty)
    }

    @Test(arguments: [false, true])
    func uncertainCancelIsRefreshedNeverRepeated(idle: Bool) async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [SessionFlow.running(9), idle ? SessionFlow.idle : SessionFlow.running(9)],
            "cancel": [.failure(.hostTimedOut)]])
        let network = sunshine.client(SessionFlow.pairedPC())
        if idle {
            try await StreamSession.quitRunningApp(network: network, expectedAppID: 9)
        } else {
            await #expect(throws: StreamError.self) {
                try await StreamSession.quitRunningApp(network: network, expectedAppID: 9)
            }
        }
        #expect(sunshine.paths == ["serverinfo", "cancel", "serverinfo"])
    }

    @Test func duplicateQuitDoesNotCancelTwice() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(9), SessionFlow.idle],
                                              "cancel": [SessionFlow.cancelled]])
        let network = sunshine.client(SessionFlow.pairedPC())
        async let first: Void = StreamSession.quitRunningApp(network: network, expectedAppID: 9)
        async let second: Void = StreamSession.quitRunningApp(network: network, expectedAppID: 9)
        _ = try await (first, second)
        #expect(sunshine.paths.filter { $0 == "cancel" }.count == 1)
    }

    @Test @MainActor func settingDefaultsToQuitAndPersistsOnlyExplicitChoice() {
        let settings = IsolatedDefaults()
        let model = AppModel(defaults: settings.defaults)
        #expect(!model.leaveGamesRunning)
        model.leaveGamesRunning = true
        #expect(AppModel(defaults: settings.defaults).leaveGamesRunning)
        model.leaveGamesRunning = false
        #expect(!AppModel(defaults: settings.defaults).leaveGamesRunning)
    }

    @Test(arguments: [false, true]) @MainActor
    func cmdQWaitsForTheChosenDisconnectPolicy(leaveRunning: Bool) async throws {
        let defaults = IsolatedDefaults()
        let sunshine = FakeSunshine.scripted(["resume": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 7
        let session = StreamSession(hostDisposition: .init(leaveGamesRunning: leaveRunning),
            audioDecoder: AudioDecoder(defaults: defaults.defaults), services: SessionServices(),
            backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
            makeBackend: { InputRecordingBackend() })
        await session.prepareLaunchFlow(server: pc)
        _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
            config: SessionFlow.config.request, info: pc)
        let model = AppModel(defaults: defaults.defaults)
        model.nativeSession = session
        let delegate = AppDelegate()
        delegate.model = model
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let reply = delegate.terminationReply(restorePointer: {}, reply: {
            continuation.yield(())
            continuation.finish()
        })
        #expect(reply == .terminateLater)
        for await _ in events { }
        #expect(sunshine.paths == (leaveRunning ? ["resume"] : ["resume", "cancel"]))
    }

    @Test(arguments: [false, true]) @MainActor
    func closingTheStreamWindowUsesTheChosenDisconnectPolicy(leaveRunning: Bool) async throws {
        let defaults = IsolatedDefaults()
        let sunshine = FakeSunshine.scripted(["resume": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        var pc = SessionFlow.pairedPC()
        pc.currentGameID = 7
        let session = StreamSession(hostDisposition: .init(leaveGamesRunning: leaveRunning),
            audioDecoder: AudioDecoder(defaults: defaults.defaults), services: SessionServices(),
            backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
            makeBackend: { InputRecordingBackend() })
        await session.prepareLaunchFlow(server: pc)
        _ = try await session.launchWithDeadline(network: sunshine.client(pc), appID: 7,
            config: SessionFlow.config.request, info: pc)
        let window = StreamWindow()
        let input = InputForwarder()
        let media = StreamSession.prepareMacMedia((window, input, VideoDecoder()), session: session,
            statsRowsProvider: { [] }, statsThresholdsProvider: { StatsThresholds() })
        let disposed = SafetyTestGate()
        media.presentation.waitForVisualClose = { await disposed.open() }
        await session.installCloseFixture(media.presentation)
        window.handleUserCloseRequest()
        await disposed.wait()
        await session.stop()
        #expect(sunshine.paths == (leaveRunning ? ["resume"] : ["resume", "cancel"]))
    }

    @Test @MainActor func historyExpiresAndRejectsInvalidFormats() {
        let settings = IsolatedDefaults()
        let history = ContinuationHistory(defaults: settings.defaults)
        let format = ContinuationFormat(width: 1920, height: 1080, fps: 60, hdr: false)
        let now = Date(timeIntervalSince1970: 100_000)
        history.remember(format, pc: "pc", app: 7, now: now)
        #expect(history.previous(pc: "pc", app: 7, now: now) == format)
        #expect(history.previous(pc: "other", app: 7, now: now) == nil)
        #expect(history.previous(pc: "pc", app: 7, now: now.addingTimeInterval(86_401)) == nil)
        #expect(history.previous(pc: "pc", app: 7, now: now.addingTimeInterval(-1)) == nil)
        history.remember(.init(width: -1, height: 1080, fps: 60, hdr: false), pc: "pc", app: 7, now: now)
        #expect(history.previous(pc: "pc", app: 7, now: now) == format)
    }

    @Test @MainActor func picturePreferenceNeverPromotesAContinuationToNative() {
        let settings = IsolatedDefaults()
        let history = ContinuationHistory(defaults: settings.defaults)
        let previous = ContinuationFormat(width: 1920, height: 1080, fps: 60, hdr: false)
        let native = ContinuationFormat(width: 2622, height: 1206, fps: 60, hdr: false)
        history.prefer(native, previous: previous, pc: "pc", app: 7)
        #expect(history.previous(pc: "pc", app: 7) == previous)
        #expect(history.preferredStart(pc: "pc", app: 7, source: previous, screen: native) == native)
        #expect(history.preferredStart(pc: "pc", app: 7, source: native, screen: native) == nil)
        history.reject(native, previous: previous, pc: "pc", app: 7)
        #expect(history.rejected(native, pc: "pc", app: 7))
        #expect(history.preferredStart(pc: "pc", app: 7, source: previous, screen: native) == nil)
        history.invalidate(pc: "pc")
        #expect(history.previous(pc: "pc", app: 7) == nil)
        #expect(history.rejected(native, pc: "pc", app: 7))
    }

    @Test func trialRecoveryUsesThePreviousRequest() {
        let previous = ContinuationFormat(width: 1920, height: 1080, fps: 60, hdr: false)
        var trial = SessionFlow.config.request
        trial.width = 3024
        trial.height = 1964
        trial.fps = 120
        let recovery = previous.applying(to: trial)
        #expect(recovery.width == 1920 && recovery.height == 1080 && recovery.fps == 60)
        #expect(recovery.changeResolution && recovery.resumeResolutionChange)
    }

    @Test func incompatibleFormatKeepsAspectAndSuppressesResolutionChange() throws {
        let old = ContinuationFormat(width: 7680, height: 4320, fps: 120, hdr: true)
        let supported = try #require(old.supported(maximumWidth: 3840, maximumHeight: 2160,
                                                    maximumFPS: 60, supportsHDR: false))
        #expect(supported.width == 3840 && supported.height == 2160 && supported.fps == 60)
        #expect(!supported.hdr && !supported.changeResolution)
    }
}

extension StreamSession {
    func installCloseFixture(_ value: SessionPresentation) { presentation = value }
}
