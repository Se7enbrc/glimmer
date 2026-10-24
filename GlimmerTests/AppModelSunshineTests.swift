// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  AppModelSunshineTests.swift
//
//  The app model's pair, wake, stream, quit and app-list paths against a fake Sunshine, with the
//  PC list and pins in a scratch store: the requests sent, the state left behind, and the copy shown.
//

@testable import GlimmerEngine
import AppKit
import Foundation
import Testing
@testable import Glimmer

/// An AppModel whose PCs live in a scratch store and whose every request reaches `sunshine`.
@MainActor
struct FakePCModel {
    nonisolated static let pin = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
    nonisolated static let desktop = AppModel.PairedApp(id: 1, name: "Desktop", hdr: false, hidden: false)

    let store: IsolatedStore
    let model: AppModel
    let sunshine: FakeSunshine

    init(_ name: String, sunshine: FakeSunshine, rtt: HostReachability.Outcome = .reachable(rttMs: 3),
         identity: (certPEM: String, keyPEM: String)? = nil) throws {
        store = try IsolatedStore("sunshine-\(name)")
        self.sunshine = sunshine
        model = AppModel(defaults: store.defaults)
        model.hostsDefaults = store.defaults
        model.supportBase = store.directory
        model.makeNetwork = { sunshine.client($0, identity: identity) }
        model.measureRTT = { _, _, _ in rtt }
    }

    /// Tower, paired and pinned in the scratch store, before any request goes out.
    @discardableResult
    func pairTower(mac: String? = nil, apps: [AppModel.PairedApp] = [desktop]) throws -> Glimmer.Host {
        try model.saveHost(uuid: "tower-id", hostname: "Tower", address: "192.0.2.10", serverCertPEM: Self.pin,
                           appVersion: "7.1", apps: apps, macAddress: mac,
                           defaults: store.defaults, supportBase: store.directory)
        settle()
        return try #require(model.hosts.first)
    }

    /// Stops the poll a selection starts, so only the test's own requests reach the fake.
    func settle() {
        model.cancelHostReadiness()
        model.hostStatusTask?.cancel()
        model.hostPolling.movedHostSearch?.cancel()
    }

    func remove() {
        settle()
        store.remove()
    }

    nonisolated static func serverInfo(game: Int = 0, state: String = "SUNSHINE_SERVER_FREE", mac: String = "")
        -> Result<ControlTransport.Response, StreamError> {
        .success(FakeSunshine.xml("""
            <hostname>Tower</hostname><uniqueid>tower-id</uniqueid><appversion>7.1.431.-1</appversion>
            <state>\(state)</state><currentgame>\(game)</currentgame><mac>\(mac)</mac>
            """))
    }

    nonisolated static let appList: Result<ControlTransport.Response, StreamError> = .success(FakeSunshine.xml("""
        <App><AppTitle>Desktop</AppTitle><ID>1</ID></App>
        <App><AppTitle>Hades II</AppTitle><ID>7</ID><IsHdrSupported>1</IsHdrSupported></App>
        <App><AppTitle>Steam</AppTitle><ID>9</ID><IsHiddenGame>1</IsHiddenGame></App>
        """))

    nonisolated static let unreachable: Result<ControlTransport.Response, StreamError> =
        .failure(.hostUnreachable("connect to 192.0.2.10 timed out"))

    /// Waits for a condition the main actor will reach; the limit only keeps a failure from hanging.
    func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
@Suite(.serialized)
struct AppModelSunshineTests {

    // MARK: - Pairing

    @Test func anotherPairRequestKeepsThePresentedPCAndAttemptUntilDismissal() throws {
        let fixture = try FakePCModel("pair-presentation", sunshine: .scripted([:]))
        defer { fixture.remove() }
        let first = try fixture.pairTower()
        let second = Host(id: "second", name: "Second", customName: nil, localAddress: "192.0.2.11",
                          manualAddress: nil, apps: first.apps, lastConnected: nil, serverCertPEM: nil,
                          appVersion: nil, macAddress: nil)
        let model = fixture.model
        model.requestPairing(for: first)
        let window = PairingOwnerTestWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        model.pairSheetWindow = window
        let attempt = model.beginPairing(address: AppModel.routeAddress(first))
        model.pairingPhase = .awaitingPin
        model.requestPairing(for: second, owner: .settings)
        #expect(model.pairSheetHost?.id == first.id)
        #expect(model.pairingAttempt == attempt)
        #expect(model.pairingPhase == .awaitingPin)
        #expect(window.focusRequests == 1)
        model.pairingAttempt = nil
        model.pairingPhase = .success
        model.requestPairing(for: second, owner: .settings)
        #expect(model.pairSheetHost?.id == first.id)
        model.pairSheetShown = false
        model.requestPairing(for: second, owner: .settings)
        #expect(model.pairSheetHost?.id == first.id)
        model.finishPairingPresentation(owner: .launcher)
        model.requestPairing(for: second, owner: .settings)
        #expect(model.pairSheetHost?.id == second.id)
        #expect(model.pairSheetOwner == .settings)
        model.finishPairingPresentation(owner: .launcher)
        #expect(model.pairSheetOwner == .settings)
        model.finishPairingPresentation(owner: .settings)
        #expect(!model.pairSheetShown)
    }

    @Test func theRightPinPairsSavesAndPinsThePCWithItsApps() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let pc = FakePairingHost(host: hostIdentity, pin: "4821")
        let sunshine = FakeSunshine { request in
            switch request.path {
            case "/serverinfo": try FakePCModel.serverInfo(mac: "AA:BB:CC:DD:EE:01").get()
            case "/applist": try FakePCModel.appList.get()
            default: try pc.respond(request)
            }
        }
        let fixture = try FakePCModel("pair", sunshine: sunshine, identity: client)
        defer { fixture.remove() }
        let model = fixture.model

        let attempt = model.beginPairing(address: "192.0.2.10")
        let host = try #require(await model.pair(attempt: attempt, pin: "4821"))

        #expect(model.pairingPhase == .success)
        #expect(model.pairingAttempt == nil)
        #expect(host.id == "tower-id" && host.displayName == "Tower" && host.macAddress == "aa:bb:cc:dd:ee:01")
        #expect(host.apps.map(\.name) == ["Desktop", "Hades II"])
        let pinFile = fixture.store.directory.appendingPathComponent("Glimmer/PinnedHosts/tower-id.pem")
        #expect(try String(contentsOf: pinFile, encoding: .utf8) == hostIdentity.certPEM)
        let paths = sunshine.paths
        #expect(paths.first == "serverinfo" && paths.suffix(2) == ["serverinfo", "applist"])
        #expect(paths.count(where: { $0 == "pair" }) == 5)
        // Identity and apps come only over the connection pinned to the PC's new certificate.
        let pinned = sunshine.requests.suffix(2)
        #expect(pinned.allSatisfy { $0.tls && $0.credential.pinnedCertPEM == hostIdentity.certPEM })
    }

    @Test func aWrongPinIsRejectedAndSavesNothing() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let pc = FakePairingHost(host: hostIdentity, pin: "1111")
        let sunshine = FakeSunshine { request in
            request.path == "/serverinfo" ? try FakePCModel.serverInfo().get() : try pc.respond(request)
        }
        let fixture = try FakePCModel("pair-wrong", sunshine: sunshine, identity: client)
        defer { fixture.remove() }

        let attempt = fixture.model.beginPairing(address: "192.0.2.10")
        #expect(await fixture.model.pair(attempt: attempt, pin: "4821") == nil)

        #expect(fixture.model.pairingPhase == .failure(.rejected))
        #expect(fixture.model.hosts.isEmpty)
        #expect(fixture.store.defaults.integer(forKey: "hosts.size") == 0)
        #expect(!sunshine.paths.contains("applist"))
    }

    @Test func aPCThatDoesNotAnswerIsUnreachableBeforeAnyPairingRound() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.unreachable]])
        let fixture = try FakePCModel("pair-unreachable", sunshine: sunshine)
        defer { fixture.remove() }

        let attempt = fixture.model.beginPairing(address: "192.0.2.10")
        #expect(await fixture.model.pair(attempt: attempt, pin: "4821") == nil)

        #expect(fixture.model.pairingPhase == .failure(.unreachable))
        #expect(PairingFailure.unreachable.message(pc: "Tower") == AppModel.unreachableMessage("Tower"))
        #expect(sunshine.paths == ["serverinfo"])
    }

    @Test func aGameStreamPCIsRefusedWithoutAPairingRound() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo(state: "MJOLNIR_STATE_FREE")]])
        let fixture = try FakePCModel("pair-gfe", sunshine: sunshine)
        defer { fixture.remove() }

        let attempt = fixture.model.beginPairing(address: "192.0.2.10")
        #expect(await fixture.model.pair(attempt: attempt, pin: "4821") == nil)

        #expect(fixture.model.pairingPhase == .failure(.gameStream))
        #expect(sunshine.paths == ["serverinfo"])
    }

    @Test func aBadAddressOrPinFailsWithoutARequest() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("pair-input", sunshine: sunshine)
        defer { fixture.remove() }
        let model = fixture.model

        #expect(await model.pair(attempt: model.beginPairing(address: "http://x/"), pin: "4821") == nil)
        #expect(model.pairingPhase == .failure(.invalidAddress))
        #expect(await model.pair(attempt: model.beginPairing(address: "192.0.2.10"), pin: "48a1") == nil)
        #expect(model.pairingPhase == .failure(.rejected))
        #expect(sunshine.requests.isEmpty)
    }

    @Test func aSupersededAttemptSendsNothingAndLeavesTheNewOneAlone() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("pair-stale", sunshine: sunshine)
        defer { fixture.remove() }
        let model = fixture.model

        let stale = model.beginPairing(address: "192.0.2.10")
        let current = model.beginPairing(address: "192.0.2.11")
        #expect(await model.pair(attempt: stale, pin: "4821") == nil)

        #expect(model.pairingAttempt == current)
        #expect(model.pairingPhase == .idle)
        #expect(sunshine.requests.isEmpty)
    }

    // MARK: - Quit and the app list

    @Test func quitSendsCancelOverThePinnedConnection() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [.success(FakeSunshine.xml("<cancel>1</cancel>"))]])
        let fixture = try FakePCModel("quit", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()

        try await fixture.model.quitRunningApp(on: host)
        fixture.settle()

        #expect(sunshine.paths == ["cancel"])
        #expect(sunshine.requests.first?.tls == true && sunshine.requests.first?.credential.pinnedCertPEM == FakePCModel.pin)
    }

    @Test func aRefusedQuitNamesThePCAndTheOtherStream() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [.success(FakeSunshine.xml("", status: 503))]])
        let fixture = try FakePCModel("quit-refused", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()

        let error = await #expect(throws: StreamError.self) { try await fixture.model.quitRunningApp(on: host) }
        fixture.settle()

        let message = AppModel.quitFailureMessage(for: try #require(error), hostName: "Tower")
        #expect(message == "Tower wouldn't quit the app. If another device is streaming from it, stop that stream first.")
        #expect(AppModel.quitFailureMessage(for: StreamError.hostUnreachable("x"), hostName: "Tower")
            == AppModel.unreachableMessage("Tower"))
    }

    @Test func refreshingTheAppListStoresItAndKeepsAHiddenAppHidden() async throws {
        let sunshine = FakeSunshine.scripted(["applist": [FakePCModel.appList, FakePCModel.unreachable]])
        let fixture = try FakePCModel("applist", sunshine: sunshine)
        defer { fixture.remove() }
        let hidden = AppModel.PairedApp(id: 7, name: "Hades II", hdr: true, hidden: true)
        let host = try fixture.pairTower(apps: [FakePCModel.desktop, hidden])

        #expect(await fixture.model.refreshAppList(for: host))
        #expect(fixture.model.hosts.first?.apps.map(\.name) == ["Desktop"])
        #expect(fixture.store.defaults.integer(forKey: "hosts.1.apps.size") == 3)
        #expect(fixture.store.defaults.bool(forKey: "hosts.1.apps.2.hidden"))

        #expect(await fixture.model.refreshAppList(for: host) == false)
        #expect(fixture.store.defaults.integer(forKey: "hosts.1.apps.size") == 3)
        #expect(sunshine.paths == ["applist", "applist"])
        #expect(sunshine.requests.allSatisfy { $0.tls })
    }

    // MARK: - Waking

    @Test func aWokenPCIsAnsweringOnceItsPinnedServerInfoReplies() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()]])
        let fixture = try FakePCModel("wake", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower(mac: "aa:bb:cc:dd:ee:01")

        let answered = await fixture.model.waitForSunshine(host: host, budgetSeconds: 5, searchAddress: { false })

        #expect(answered)
        #expect(sunshine.paths == ["serverinfo"])
        #expect(sunshine.requests.first?.tls == true)
    }

    @Test func aPCThatStaysDownIsNotAnsweringWhenTheBudgetEnds() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.unreachable]])
        let fixture = try FakePCModel("wake-down", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower(mac: "aa:bb:cc:dd:ee:01")

        let answered = await fixture.model.waitForSunshine(host: host, budgetSeconds: 0.5, searchAddress: { false })

        #expect(!answered)
        #expect(sunshine.paths == ["serverinfo"])
        // Wake readiness never falls back to plain HTTP: a down PC is just not answering yet.
        #expect(sunshine.requests.allSatisfy { $0.tls })
    }

    // MARK: - Streaming

    @Test func aPCThatNeverAnswersEndsTheStreamWithTheSharedUnreachableBanner() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.unreachable]])
        let fixture = try FakePCModel("stream-unreachable", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let model = fixture.model

        model.stream(app: host.apps[0], on: host)
        #expect(model.isStreaming)
        #expect(model.streamPhase == .connecting(stage: "Connecting to Tower…"))
        await fixture.waitUntil { !model.isStreaming }
        fixture.settle()

        #expect(model.streamPhase == .idle)
        #expect(model.nativeStreamError == AppModel.unreachableMessage("Tower"))
        #expect(model.nativeStreamErrorKind == .unreachable)
        #expect(model.nativeStreamErrorHostID == "tower-id")
        #expect(model.nativeSession == nil)
        // A failed connect stamps its attempt in the model's own store.
        #expect(fixture.store.defaults.object(forKey: "glimmer.lastConnected.tower-id") is Date)
        #expect(Array(sunshine.paths.prefix(2)) == ["serverinfo", "serverinfo"])
        #expect(sunshine.requests.prefix(2).map(\.tls) == [true, false])
        #expect(sunshine.requests.dropFirst(2).allSatisfy { $0.path == "/serverinfo" && $0.tls })
    }

    @Test func aPCRunningGameStreamIsRefusedWithTheSharedSunshineCopy() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo(state: "MJOLNIR_STATE_FREE")]])
        let fixture = try FakePCModel("stream-gfe", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let model = fixture.model

        model.stream(app: host.apps[0], on: host)
        await fixture.waitUntil { !model.isStreaming }
        fixture.settle()

        #expect(model.nativeStreamError == AppModel.needsSunshineMessage("Tower"))
        #expect(model.nativeStreamErrorKind == .pairing)
        #expect(!sunshine.paths.isEmpty && sunshine.paths.allSatisfy { $0 == "serverinfo" })
        #expect(!sunshine.paths.contains("launch"))
    }

    @Test func aSecondStreamWhileOneIsInFlightSendsNothing() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("stream-reentry", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let model = fixture.model

        model.isStreaming = true
        model.stream(app: host.apps[0], on: host)
        await Task.yield()

        #expect(model.nativeSession == nil)
        #expect(model.streamPhase == .idle)
        #expect(sunshine.requests.isEmpty)
        model.isStreaming = false
    }
}

@MainActor
private final class PairingOwnerTestWindow: NSWindow {
    var focusRequests = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { focusRequests += 1 }
}
