// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SessionLaunchFlowTests.swift
//
//  StreamSession's start and launch decisions against a fake Sunshine: which requests go out in
//  which order, when a busy PC is cancelled or needs a takeover, and the copy a refusal carries.
//

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

/// Replies and fixtures the session flow tests share.
enum SessionFlow {
    static let sessionURL = "rtspenc://192.0.2.10:48010"
    static let launched: Result<ControlTransport.Response, StreamError> = .success(FakeSunshine.xml("""
        <sessionUrl0>\(sessionURL)</sessionUrl0>
        <gcmkey>000102030405060708090a0b0c0d0e0f</gcmkey><gcmkeyid>a0a1a2a3</gcmkeyid>
        """))
    static let cancelled: Result<ControlTransport.Response, StreamError> = .success(FakeSunshine.xml("<cancel>1</cancel>"))
    static let idle = serverInfo(state: "SUNSHINE_SERVER_FREE", game: 0)

    static func running(_ appID: Int) -> Result<ControlTransport.Response, StreamError> {
        serverInfo(state: "SUNSHINE_SERVER_BUSY", game: appID)
    }

    static func serverInfo(state: String, game: Int) -> Result<ControlTransport.Response, StreamError> {
        .success(FakeSunshine.xml("""
            <hostname>Tower</hostname><appversion>7.1.431.-1</appversion><state>\(state)</state>
            <currentgame>\(game)</currentgame>
            """))
    }

    /// A paired PC of its own, so launch bookkeeping keyed by PC can't cross between tests.
    static func pairedPC() -> ServerInfo {
        var server = ServerInfo(address: "192.0.2.10", uniqueId: UUID().uuidString, serverName: "Tower")
        server.serverCertPEM = "host-pin"
        return server
    }

    static let config: StreamConfig = {
        var config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        config.remoteness = .local
        return config
    }()
}

@Suite(.serialized)
struct SessionLaunchFlowTests {

    /// Mirrors start(): the verified /serverinfo, then the launch under its deadline.
    private func launch(
        on sunshine: FakeSunshine, server: ServerInfo, appID: Int = 7,
        prepare: (StreamSession) async -> Void = { _ in }
    ) async throws -> (StreamSession, LaunchResponse) {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let network = sunshine.client(server)
        await session.prepareLaunchFlow(server: server)
        await prepare(session)
        let info = try await session.fetchAndVerifyServerInfo(network: network, pcName: server.serverName)
        let response = try await session.launchWithDeadline(
            network: network, appID: appID, config: SessionFlow.config.request, info: info)
        return (session, response)
    }

    @Test func anIdlePcGetsOneLaunchAndTheSessionOwnsIt() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched]])
        let (session, response) = try await launch(on: sunshine, server: SessionFlow.pairedPC())
        #expect(sunshine.paths == ["serverinfo", "launch"])
        #expect(sunshine.requests.last?.query["appid"] == "7")
        #expect(response.sessionURL == SessionFlow.sessionURL)
        #expect(await session.ownsHostSession)
        #expect(await session.hostSessionClientID == FakeSunshine.clientUniqueID)
        #expect(await session.hostSessionAppID == 7)
    }

    /// Continuing must not restart the game or make an unapproved display request.
    @Test func ourOwnRunningGameResumesWithoutCancellation() async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [SessionFlow.running(7), SessionFlow.idle],
            "resume": [SessionFlow.launched]
        ])
        _ = try await launch(on: sunshine, server: SessionFlow.pairedPC()) {
            await $0.claimPC(client: FakeSunshine.clientUniqueID, appID: 7)
        }
        #expect(sunshine.paths == ["serverinfo", "resume"])
    }

    @Test func anotherDevicesSessionNeedsATakeoverBeforeAnythingIsCancelled() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(9)]])
        do {
            _ = try await launch(on: sunshine, server: SessionFlow.pairedPC())
            Issue.record("A PC streaming to someone else must ask before taking over")
        } catch let takeover as TakeoverRequired {
            #expect(takeover.appID == 9)
        }
        #expect(sunshine.paths == ["serverinfo"])
    }

    @Test func anAuthorizedTakeoverCancelsTheOtherSessionThenLaunches() async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [SessionFlow.running(9), SessionFlow.running(9), SessionFlow.idle],
            "cancel": [SessionFlow.cancelled], "launch": [SessionFlow.launched]
        ])
        let (session, _) = try await launch(on: sunshine, server: SessionFlow.pairedPC()) {
            await $0.authorizeTakeover(true)
        }
        #expect(sunshine.paths == ["serverinfo", "serverinfo", "cancel", "serverinfo", "launch"])
        #expect(await session.hostSessionAppID == 7)
    }

    @Test(arguments: [StreamError.hostTimedOut, .hostRefused(message: "Busy", code: 503)])
    func failedLaunchNeverBlindlyCancelsOrRetries(error: StreamError) async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [SessionFlow.idle], "launch": [.failure(error)]
        ])
        await #expect(throws: StreamError.self) {
            _ = try await launch(on: sunshine, server: SessionFlow.pairedPC())
        }
        let refresh: [String]
        if case .hostRefused = error { refresh = ["serverinfo"] } else { refresh = [] }
        #expect(sunshine.paths == ["serverinfo", "launch"] + refresh)
    }

    @Test func anExpiredLaunchBudgetSendsNothing() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        await session.prepareLaunchFlow(server: SessionFlow.pairedPC())
        await #expect(throws: StreamError.self) {
            _ = try await session.launchWithDeadline(
                network: sunshine.client(SessionFlow.pairedPC()), appID: 7, config: SessionFlow.config.request,
                info: SessionFlow.pairedPC(), deadline: Date())
        }
        #expect(sunshine.requests.isEmpty)
    }

    // MARK: - Start refuses a PC it can't stream from

    @Test func anUnpairedPcIsRefusedWithThePairAgainCopyAndNoLaunch() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle]])
        let server = ServerInfo(address: "192.0.2.10", uniqueId: UUID().uuidString, serverName: "Tower")
        let error = await #expect(throws: StreamError.self) {
            _ = try await launch(on: sunshine, server: server)
        }
        #expect(error?.description == NetworkClient.notPaired("Tower").description)
        #expect(sunshine.paths == ["serverinfo"])
        #expect(sunshine.requests.first?.tls == false)
    }

    @Test func aGameStreamPcIsRefusedWithTheSharedSunshineCopy() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.serverInfo(state: "MJOLNIR_STATE_FREE", game: 0)]])
        let error = await #expect(throws: StreamError.self) {
            _ = try await launch(on: sunshine, server: SessionFlow.pairedPC())
        }
        #expect(error?.description == AppModel.needsSunshineMessage("the PC"))
        #expect(sunshine.paths == ["serverinfo"])
    }
}

extension StreamSession {
    /// The state start() sets before its first request.
    func prepareLaunchFlow(server: ServerInfo) {
        isStreaming = true
        reconnectServer = server
    }

    /// As if an earlier launch of `appID` by `client` had succeeded.
    func claimPC(client: String, appID: Int) {
        ownsHostSession = true
        hostSessionClientID = client
        hostSessionAppID = appID
    }
}
