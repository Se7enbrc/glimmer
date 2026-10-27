// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import AppKit
@testable import GlimmerEngine
import os

@MainActor
final class JourneyMacPC {
    static var active: JourneyMacPC?
    let receipts: JourneyReceipts
    let network: JourneyMacNetwork
    private let driver: JourneyControllerDriver
    private var videoTask: Task<Void, Never>?
    private var prepared: (StreamWindow, InputForwarder, VideoDecoder)?

    init() {
        guard let path = ProcessInfo.processInfo.environment["GLIMMER_JOURNEY_DIRECTORY"] else {
            preconditionFailure("A journey needs isolated receipt storage")
        }
        let directory = PersistentStorage.checked(URL(fileURLWithPath: path))
        receipts = JourneyReceipts(directory: directory)
        network = JourneyMacNetwork(receipts: receipts)
        driver = JourneyControllerDriver(directory: directory, receipts: receipts)
        driver.start()
        receipts.record(["fixture": 1])
    }

    func launcher() -> AppModel {
        let model = AppModel()
        model.makeNetwork = { [network] in network.client($0) }
        model.measureRTT = { _, _, _ in .reachable(rttMs: 1) }
        model.streamDisplayMode = .window
        model.streamHDR = false
        let app = LibraryApp(id: 1, name: "Journey game", hdr: false, hidden: false)
        let host = Host(id: "journey-pc", name: "Journey PC", customName: nil, localAddress: "127.0.0.1",
                        manualAddress: nil, apps: [app], lastConnected: nil, serverCertPEM: "fixture-only",
                        appVersion: "7.1.431.-1", macAddress: nil)
        do {
            try model.saveHost(uuid: host.id, hostname: host.name, address: "127.0.0.1",
                serverCertPEM: "fixture-only", appVersion: host.appVersion,
                apps: [.init(id: 1, name: "Journey game", hdr: false, hidden: false)])
        } catch { preconditionFailure("Could not seed isolated PC storage") }
        model.hosts = [host]
        model.selectedHost = host
        model.hostStatusTask?.cancel()
        model.hostLiveStatus = .init(hostID: host.id, state: .idle, capturedAt: .now)
        model.startLiveRefresh()
        return model
    }

    func session(disposition: StreamHostDisposition) -> (StreamSession, BandwidthSignals?) {
        var services = SessionServices()
        services.feedback = .mac()
        let backend = JourneyBackend(receipts: receipts) { [self] in await connected() }
        return (StreamSession(hostDisposition: disposition, audioDecoder: AudioDecoder(), services: services,
            backend: backend, makeNetwork: { [network] in network.client($0) },
            makeBackend: { backend }, adaptiveBandwidth: false), nil)
    }

    func prepare(_ setup: (StreamWindow, InputForwarder, VideoDecoder)) { prepared = setup }

    private func connected() {
        guard let (window, input, decoder) = prepared else { preconditionFailure("Missing native stream surface") }
        input.setReady(true)
        let video = JourneyVideo(layer: window.displayLayer)
        videoTask?.cancel()
        videoTask = Task { [receipts] in
            var first = true
            do {
                while !Task.isCancelled && !window.didClose {
                    try video.draw()
                    if first && video.ready {
                        first = false
                        decoder.onFirstDecodedFrame?()
                        receipts.record(["rendered": 1])
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                receipts.record(["stop": 1])
            } catch is CancellationError { return } catch { receipts.record(["videoError": 1]) }
        }
    }
}

final class JourneyMacNetwork: Sendable {
    private let running = OSAllocatedUnfairLock(initialState: 0)
    private let receipts: JourneyReceipts
    init(receipts: JourneyReceipts) { self.receipts = receipts }

    func client(_ server: ServerInfo) -> NetworkClient {
        NetworkClient(server: server, deviceName: { "Journey Mac" }, transport: { [self] _, _, target, _, _, _, _ in
            let path = URLComponents(string: target)?.path ?? ""
            return try reply(path)
        }, identity: { ("fixture-cert", "fixture-key", "journey-client") })
    }

    private func reply(_ path: String) throws -> ControlTransport.Response {
        let body: String
        switch path {
        case "/serverinfo":
            let game = running.withLock { $0 }
            body = """
                <hostname>Journey PC</hostname><appversion>7.1.431.-1</appversion><PairStatus>1</PairStatus>
                <state>\(game == 0 ? "SUNSHINE_SERVER_FREE" : "SUNSHINE_SERVER_BUSY")</state>
                <currentgame>\(game)</currentgame><uniqueid>journey-pc</uniqueid>
                """
        case "/applist":
            body = "<App><AppTitle>Journey game</AppTitle><ID>1</ID><IsHdrSupported>0</IsHdrSupported></App>"
        case "/launch", "/resume":
            running.withLock { $0 = 1 }
            receipts.record([path == "/launch" ? "launch" : "resume": 1])
            body = """
                <sessionUrl0>rtspenc://pc.invalid:48010</sessionUrl0>
                <gcmkey>000102030405060708090a0b0c0d0e0f</gcmkey><gcmkeyid>a0a1a2a3</gcmkeyid>
                """
        case "/cancel":
            running.withLock { $0 = 0 }
            receipts.record(["quit": 1])
            body = "<cancel>1</cancel>"
        case "/appasset": return .init(status: 200, body: Data())
        default: throw StreamError.launchFailed("Unexpected isolated journey request")
        }
        return .init(status: 200, body: Data("<root status_code=\"200\">\(body)</root>".utf8))
    }
}
#endif
