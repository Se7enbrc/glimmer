// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  NetworkClientRequestTests.swift
//
//  NetworkClient against a fake Sunshine: which port and scheme each endpoint uses, the query
//  it sends, how replies hydrate or fail, and that the launch query is redacted before logging.
//

import Foundation
import Testing
@testable import Glimmer

struct NetworkClientRequestTests {

    private static let serverInfoBody = """
        <hostname>TOWER-PC</hostname><uniqueid>tower-id</uniqueid><appversion>7.1.431.-1</appversion>
        <HttpsPort>47990</HttpsPort><ServerCodecModeSupport>65793</ServerCodecModeSupport>
        <currentgame>881448767</currentgame><state>SUNSHINE_SERVER_BUSY</state>
        """

    private static func isHex(_ value: String?, count: Int) -> Bool {
        guard let value else { return false }
        return value.count == count && value.allSatisfy(\.isHexDigit)
    }

    // MARK: - /serverinfo

    @Test func unpairedServerInfoIsPlainHTTPWithoutCredentialsAndHydrates() async throws {
        let sunshine = FakeSunshine { _ in FakeSunshine.xml(Self.serverInfoBody) }
        let info = try await sunshine.client(FakeSunshine.server()).fetchServerInfo()

        let request = try #require(sunshine.requests.first)
        #expect(sunshine.requests.count == 1)
        #expect((request.host, request.port, request.path, request.tls) == ("192.0.2.10", 47989, "/serverinfo", false))
        #expect(request.credential.clientCertPEM == nil && request.credential.pinnedCertPEM == nil)
        #expect(request.query["uniqueid"] == FakeSunshine.clientUniqueID)
        #expect(Self.isHex(request.query["uuid"], count: 32))
        #expect(request.userAgent.contains("Moonlight"))
        #expect(info.serverName == "TOWER-PC" && info.appVersion == "7.1.431.-1" && info.httpsPort == 47990)
        #expect(info.serverCodecModeRaw == 65793 && info.serverCodecSupport.contains(.hevc))
        #expect(info.isBusy && info.currentGameID == 881_448_767)
        #expect(info.pairStatus == .unpaired)
    }

    @Test func pinnedServerInfoIsMutualTLSWithThePinAndProvesPairing() async throws {
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("<hostname>TOWER-PC</hostname>") }
        let info = try await sunshine.client(FakeSunshine.server(pin: "host-pin"),
                                             identity: ("our-cert", "our-key")).fetchServerInfo()

        let request = try #require(sunshine.requests.first)
        #expect((request.port, request.tls) == (47984, true))
        #expect(request.credential.clientCertPEM == "our-cert" && request.credential.clientKeyPEM == "our-key")
        #expect(request.credential.pinnedCertPEM == "host-pin")
        #expect(info.pairStatus == .paired)
    }

    @Test func aChangedCertificateIsReportedWithoutFallingBackToPlainHTTP() async throws {
        let sunshine = FakeSunshine { _ in throw StreamError.hostUnreachable("pinned host cert mismatch") }
        let error = await #expect(throws: StreamError.self) {
            _ = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).fetchServerInfo()
        }
        guard case .hostCertChanged(let message) = error else {
            Issue.record("expected hostCertChanged, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("Tower's certificate changed."))
        #expect(sunshine.requests.map(\.tls) == [true])
    }

    @Test func aWedgedSecurePortIsToldApartByAReadOnlyPlainProbe() async throws {
        let sunshine = FakeSunshine { request in
            if request.tls { throw StreamError.hostUnreachable("connect to 192.0.2.10:47984 failed or timed out") }
            return FakeSunshine.xml("<PairStatus>1</PairStatus>")
        }
        let client = sunshine.client(FakeSunshine.server(pin: "host-pin"))
        let error = await #expect(throws: StreamError.self) { _ = try await client.fetchServerInfo() }
        guard case .sunshineNeedsRestart = error else {
            Issue.record("expected sunshineNeedsRestart, got \(String(describing: error))")
            return
        }
        #expect(sunshine.requests.map(\.port) == [47984, 47989])
        #expect(await client.pinnedServerCertPEM() == "host-pin")
    }

    @Test func pairingVerificationRefusesAnotherPCsIdentity() async {
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("<uniqueid>someone-else</uniqueid>") }
        let error = await #expect(throws: StreamError.self) {
            _ = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).fetchServerInfo(requiredUniqueId: "tower-id")
        }
        guard case .pairingRejected = error else {
            Issue.record("expected pairingRejected, got \(String(describing: error))")
            return
        }
    }

    @Test func transportAndStatusFailuresSurfaceAsTheirOwnErrors() async {
        let proxy = FakeSunshine { _ in ControlTransport.Response(status: 401, body: Data()) }
        let httpError = await #expect(throws: StreamError.self) {
            _ = try await proxy.client(FakeSunshine.server()).fetchServerInfo()
        }
        #expect(httpError?.description.contains("HTTP 401 on /serverinfo") == true)

        let unpaired = FakeSunshine { _ in FakeSunshine.xml("", status: 401) }
        let statusError = await #expect(throws: StreamError.self) {
            _ = try await unpaired.client(FakeSunshine.server()).fetchServerInfo()
        }
        guard case .hostUnreachable(let detail) = statusError else {
            Issue.record("expected hostUnreachable, got \(String(describing: statusError))")
            return
        }
        #expect(detail.contains("Host requires pairing"))
    }

    @Test func httpsWithoutAPinNeverReachesTheTransport() async {
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("") }
        await #expect(throws: StreamError.self) { _ = try await sunshine.client(FakeSunshine.server()).appList() }
        await #expect(throws: StreamError.self) { try await sunshine.client(FakeSunshine.server()).cancel() }
        #expect(sunshine.requests.isEmpty)
    }

    // MARK: - /applist and /cancel

    @Test func appListParsesTitlesHdrAndHiddenOverTLS() async throws {
        let sunshine = FakeSunshine { _ in
            FakeSunshine.xml("""
                <App><AppTitle>Desktop</AppTitle><ID>1</ID></App>
                <App><AppTitle>Portal 2</AppTitle><ID>42</ID><IsHdrSupported>1</IsHdrSupported></App>
                <App><ID>7</ID><IsAppCollectorGame>1</IsAppCollectorGame></App>
                <App><AppTitle>No id</AppTitle></App>
                """)
        }
        let apps = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).appList()
        #expect(apps.map(\.id) == [1, 42, 7])
        #expect(apps.map(\.name) == ["Desktop", "Portal 2", "App 7"])
        #expect(apps.map(\.hdrCapable) == [false, true, false])
        #expect(apps.map(\.hidden) == [false, false, true])
        #expect(sunshine.requests.map(\.path) == ["/applist"])
        #expect(sunshine.requests.allSatisfy { $0.tls })
    }

    @Test func quitIsAPinnedCancelThatChecksTheStatus() async throws {
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("<cancel>1</cancel>") }
        try await sunshine.client(FakeSunshine.server(pin: "host-pin")).cancel()
        #expect(sunshine.requests.map(\.path) == ["/cancel"])
        #expect(sunshine.requests.first?.tls == true)

        let refusing = FakeSunshine { _ in FakeSunshine.xml("", status: 503) }
        let error = await #expect(throws: StreamError.self) {
            try await refusing.client(FakeSunshine.server(pin: "host-pin")).cancel()
        }
        guard case .hostRefused(_, let code) = error else {
            Issue.record("expected hostRefused, got \(String(describing: error))")
            return
        }
        #expect(code == 503)
    }

    // MARK: - /launch and /resume

    private static let launchReply = FakeSunshine.xml("""
        <sessionUrl0>rtspenc://192.0.2.10:48010</sessionUrl0>
        <gcmkey>000102030405060708090a0b0c0d0e0f</gcmkey><gcmkeyid>a0a1a2a3</gcmkeyid>
        """)

    @Test func launchSendsTheStreamQueryAndReturnsTheSessionKeys() async throws {
        let sunshine = FakeSunshine { _ in Self.launchReply }
        var config = StreamConfig(width: 2560, height: 1440, fps: 120, bitrateKbps: 50_000)
        config.videoFormats = [.h264, .hevc, .hevcMain10]
        config.playAudioOnHost = true
        let launch = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).launch(appID: 42, config: config)

        #expect(launch.sessionURL == "rtspenc://192.0.2.10:48010")
        #expect(launch.gcmKey == Data((0..<16).map { UInt8($0) }))
        #expect(launch.gcmKeyId == Data([0xA0, 0xA1, 0xA2, 0xA3]))
        let request = try #require(sunshine.requests.first)
        let query = request.query
        #expect(request.path == "/launch" && request.tls)
        #expect(query["mode"] == "2560x1440x120" && query["appid"] == "42")
        #expect(query["localAudioPlayMode"] == "1" && query["corever"] == "1" && query["sops"] == "1")
        #expect(Self.isHex(query["rikey"], count: 32))
        #expect(query["rikeyid"].flatMap(Int32.init) != nil)
        #expect(query["hdrMode"] == "1")
        #expect(request.target.hasSuffix("&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"))
        #expect(request.timeout <= NetworkClient.launchTimeout && request.timeout > NetworkClient.controlTimeout)
    }

    @Test(arguments: [VideoFormats.h264, .hevc, .hevcMain10, .av1, .av1Main10])
    func rec709FullDoesNotChangeLaunchHDRIntent(_ formats: VideoFormats) async throws {
        let sunshine = FakeSunshine { _ in Self.launchReply }
        var config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        config.videoFormats = formats
        #expect((config.colorSpace.cValue << 1) | config.colorRange.cValue == 3)
        _ = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).launch(appID: 1, config: config)
        let query = try #require(sunshine.requests.first?.query)
        let hdr = !formats.isDisjoint(with: [.hevcMain10, .av1Main10])
        #expect(query["hdrMode"] == (hdr ? "1" : nil))
    }

    @Test func resumeOmitsTheAppAndAnEightBitStreamSendsNoHdr() async throws {
        let sunshine = FakeSunshine { _ in Self.launchReply }
        var config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        config.videoFormats = [.h264]
        _ = try await sunshine.client(FakeSunshine.server(pin: "host-pin")).resume(config: config)
        let query = try #require(sunshine.requests.first?.query)
        #expect(sunshine.requests.first?.path == "/resume")
        #expect(query["appid"] == nil && query["hdrMode"] == nil)
        #expect(query["localAudioPlayMode"] == "0")
    }

    @Test func launchWithoutASessionURLFailsAndMissingKeysFallBackToTheInputKey() async throws {
        let empty = FakeSunshine { _ in FakeSunshine.xml("<gcmkey>00</gcmkey>") }
        let config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        let error = await #expect(throws: StreamError.self) {
            _ = try await empty.client(FakeSunshine.server(pin: "host-pin")).launch(appID: 1, config: config)
        }
        #expect(error?.description.contains("RTSP session URL") == true)

        let bare = FakeSunshine { _ in FakeSunshine.xml("<sessionUrl0>rtsp://192.0.2.10:48010</sessionUrl0>") }
        let launch = try await bare.client(FakeSunshine.server(pin: "host-pin")).launch(appID: 1, config: config)
        let rikey = try #require(bare.requests.first?.query["rikey"])
        #expect(launch.gcmKey == NetworkClient.hexDecode(rikey))
        #expect(launch.gcmKeyId.count == 16)
    }

    @Test func theLoggedLaunchQueryRedactsEverySessionSecret() {
        let config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        var query = NetworkClient.launchQuery(config: config, riKeyHex: "deadbeefdeadbeefdeadbeefdeadbeef",
                                              riKeyID: 1_234_567, appID: 9)
        query["uuid"] = "feedfacefeedface"
        query["UniqueID"] = "C11E47"
        let dump = NetworkClient.redactedQueryDump(query)
        for secret in ["deadbeef", "1234567", "feedface", "C11E47"] { #expect(!dump.contains(secret)) }
        #expect(dump.contains("rikey=<redacted>") && dump.contains("rikeyid=<redacted>"))
        #expect(dump.contains("UniqueID=<redacted>") && dump.contains("uuid=<redacted>"))
        #expect(dump.contains("mode=1920x1080x60") && dump.contains("appid=9"))
        let keys = dump.split(separator: "&").map { String($0.prefix { $0 != "=" }) }
        #expect(keys == keys.sorted())
    }
}
