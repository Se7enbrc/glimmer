// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import AppKit
import Foundation
import os
import SwiftUI
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glimmer

struct LauncherExperienceTests {
    private let settings = IsolatedDefaults()

    @Test @MainActor func buttonsAreDefaultAndExplicitChoicePersistsPerPC() throws {
        let store = try IsolatedStore("launcher-style")
        defer { store.remove() }
        let model = AppModel(defaults: settings.defaults)
        model.hostsDefaults = store.defaults
        model.supportBase = store.directory
        defer { model.hostStatusTask?.cancel() }
        store.defaults.set("covers", forKey: "launcherStyle")
        for id in ["one", "two"] {
            try model.saveHost(uuid: id, hostname: id, address: "192.0.2.1", serverCertPEM: nil,
                               appVersion: nil, apps: [.init(id: 1, name: "Desktop", hdr: false, hidden: false)],
                               defaults: store.defaults)
        }
        let first = try #require(model.hosts.first { $0.id == "one" })
        let second = try #require(model.hosts.first { $0.id == "two" })
        #expect(model.hosts.allSatisfy { $0.launcherStyle == .buttons })
        model.setLauncherStyle(.covers, for: first)
        model.loadHosts(defaults: store.defaults)
        model.selectHost(try #require(model.hosts.first { $0.id == first.id }), defaults: store.defaults)
        #expect(model.launcherStyle == .covers)
        model.isStreaming = true
        model.selectHost(second, defaults: store.defaults)
        #expect(model.selectedHost?.id == second.id)
        #expect(model.launcherStyle == .buttons)
        #expect(LauncherStyle.load(for: first.id, defaults: store.defaults) == .covers)
        model.isStreaming = false
        model.setLauncherStyle(.buttons, for: first)
        #expect(LauncherStyle.load(for: first.id, defaults: store.defaults) == .buttons)
        store.defaults.set("unknown", forKey: "glimmer.launcherStyle.one")
        #expect(LauncherStyle.load(for: first.id, defaults: store.defaults) == .buttons)
    }

    @Test func pairingOffersAChoiceOnlyForVisibleNonStockApps() {
        func apps(_ names: [String]) -> [LibraryApp] {
            names.enumerated().map { .init(id: $0.offset, name: $0.element, hdr: false, hidden: false) }
        }
        for names in [[], ["Desktop"], ["Steam Big Picture"], ["Desktop", "Steam Big Picture"]] {
            #expect(!LauncherStyle.offersChoice(apps: apps(names)))
        }
        #expect(LauncherStyle.offersChoice(apps: apps(["Desktop", "Steam Big Picture", "Game"])))
        #expect(LauncherStyle.offersChoice(apps: apps(["Game"])))
        #expect(!LauncherStyle.offersChoice(apps: [.init(id: 1, name: "Game", hdr: false, hidden: true)]))
    }

    @Test func columnCountFillsRowsAndBoundsLargeLibraries() {
        let expected = [1, 1, 2, 3, 4, 3, 3, 4, 4, 3, 4, 4, 4]
        for (count, columns) in expected.enumerated() {
            #expect(LauncherLayout.columns(appCount: count) == columns)
        }
        #expect(LauncherLayout.windowWidth == LauncherLayout.contentWidth + 2 * LauncherLayout.horizontalPadding)
        #expect(LauncherLayout.windowWidth == 580)
        for count in 1...200 {
            #expect((1...4).contains(LauncherLayout.columns(appCount: count)))
            #expect(LauncherLayout.coverHeight(appCount: count) <= 240)
            let columns = CGFloat(LauncherLayout.columns(appCount: count))
            let width = LauncherLayout.coverWidth(appCount: count) * columns
                + (columns - 1) * 10 + LauncherLayout.coverPadding * 2
            #expect(abs(width - LauncherLayout.contentWidth) < 0.001)
        }
    }

    @Test func assetRequestIsPinnedAndCarriesMoonlightsParameters() async throws {
        let data = Data([1, 2, 3])
        let sunshine = FakeSunshine { _ in ControlTransport.Response(status: 200, body: data) }
        var server = FakeSunshine.server(pin: "pin")
        server.httpsPort = 47990
        let reply = try await sunshine.client(server).appAsset(appID: 42)
        #expect(reply == data)
        let request = try #require(sunshine.requests.first)
        #expect(request.path == "/appasset" && request.port == 47990 && request.tls)
        #expect(request.query["appid"] == "42")
        #expect(request.query["AssetType"] == "2" && request.query["AssetIdx"] == "0")
        #expect(request.credential.pinnedCertPEM == "pin")
        #expect(request.credential.clientCertPEM != nil && request.credential.clientKeyPEM != nil)
        #expect(request.query["uniqueid"] == FakeSunshine.clientUniqueID)
        #expect(request.query["uuid"]?.count == 32)
        #expect(sunshine.requests.count == 1)
    }

    @Test func assetsNeverUseAnUnpinnedConnectionOrIgnoreHTTPFailure() async {
        let sunshine = FakeSunshine { _ in ControlTransport.Response(status: 404, body: Data()) }
        await #expect(throws: StreamError.self) { try await sunshine.client(FakeSunshine.server()).appAsset(appID: 1) }
        #expect(sunshine.requests.isEmpty)
        await #expect(throws: NetworkClient.AssetError.self) {
            try await sunshine.client(FakeSunshine.server(pin: "pin")).appAsset(appID: 1)
        }
        #expect(sunshine.requests.count == 1)
    }

    @Test func cacheKeysSeparatePCsAppsAndListRevisions() {
        let apps = [LibraryApp(id: 1, name: "Game", hdr: false, hidden: false)]
        let revision = LauncherArtCache.revision(apps: apps)
        let key = LauncherArtCache.key(pcID: "../pc", appID: 1, revision: revision)
        #expect(key.count == 129 && key.filter { $0 != "-" }.allSatisfy(\.isHexDigit))
        #expect(key == LauncherArtCache.key(pcID: "../pc", appID: 1, revision: revision))
        #expect(key != LauncherArtCache.key(pcID: "another PC", appID: 1, revision: revision))
        #expect(key != LauncherArtCache.key(pcID: "../pc", appID: 2, revision: revision))
        #expect(key != LauncherArtCache.key(pcID: "../pc", appID: 1, revision: LauncherArtCache.revision(apps: [])))
    }

    @Test func cacheSurvivesReopeningAndEvictsLeastRecentlyUsedArt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: base, byteLimit: data.count * 2)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "first", fetch: { data }) != nil)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "second", fetch: { data }) != nil)
        let directory = base.appendingPathComponent("Glimmer/Covers")
        let secondFile = directory.appendingPathComponent(
            LauncherArtCache.key(pcID: "pc", appID: 1, revision: "second") + ".png")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: secondFile.path)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "third", fetch: { data }) != nil)
        #expect(!FileManager.default.fileExists(atPath: secondFile.path))
        let reopened = LauncherArtCache(base: base, byteLimit: data.count * 2)
        let cached = await reopened.image(pcID: "pc", appID: 1, revision: "first") { throw CancellationError() }
        #expect(cached != nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
    }

    @Test func missingCorruptAndPlaceholderArtFallsBackWithoutCaching() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = LauncherArtCache(base: base)
        let missing = await cache.image(pcID: "pc", appID: 1, revision: "missing") { throw CancellationError() }
        #expect(missing == nil)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "corrupt", fetch: { Data("<root/>".utf8) }) == nil)
        let placeholder = try Self.png(width: 130, height: 180)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "placeholder", fetch: { placeholder }) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Glimmer/Covers").path))
    }

    @Test func corruptCacheIsReplacedAndOversizedArtIsRejected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("Glimmer/Covers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            LauncherArtCache.key(pcID: "pc", appID: 1, revision: "corrupt") + ".png")
        try Data("bad image".utf8).write(to: file)
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: base)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "corrupt", fetch: { data }) != nil)
        #expect(try Data(contentsOf: file) == data)
        #expect(LauncherArtCache.decode(Data(count: 4 * 1024 * 1024 + 1)) == nil)
    }

    @Test func cancelledArtworkDoesNotFetch() async {
        let sunshine = FakeSunshine { _ in ControlTransport.Response(status: 200, body: Data()) }
        let cache = LauncherArtCache()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(pcID: "pc", appID: 1, revision: "cancelled") {
                try await sunshine.client(FakeSunshine.server(pin: "pin")).appAsset(appID: 1)
            }
        }
        #expect(await task.value == nil)
        #expect(sunshine.requests.isEmpty)
    }

    @Test func memoryAndNegativeResultsAvoidRepeatedDiskAndNetworkWork() async throws {
        let store = try IsolatedStore("launcher-memory")
        defer { store.remove() }
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: store.directory)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { data }) == data)
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("Glimmer/Covers"))
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { throw CancellationError() }) == data)
        let missing = FakeSunshine { _ in ControlTransport.Response(status: 404, body: Data()) }
        for _ in 0..<3 {
            #expect(await cache.image(pcID: "pc", appID: 2, revision: "a", fetch: {
                try await missing.client(FakeSunshine.server(pin: "pin")).appAsset(appID: 2)
            }) == nil)
        }
        #expect(missing.requests.count == 1)
        #expect(await cache.image(pcID: "pc", appID: 2, revision: "b", fetch: { data }) == data)
    }

    @Test @MainActor func removingAPCClearsOnlyItsArtAndStyle() async throws {
        let store = try IsolatedStore("launcher-removal")
        defer { store.remove() }
        let model = AppModel(defaults: settings.defaults)
        model.supportBase = store.directory
        model.hostsDefaults = store.defaults
        let data = try Self.png(width: 3, height: 4)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.setLauncherStyle(.covers, for: host)
        let cache = model.launcherArtCache
        for id in ["pc", "other"] {
            #expect(await cache.image(pcID: id, appID: 1, revision: "a", fetch: { data }) == data)
        }
        try await model.unpair(host, defaults: store.defaults, supportBase: store.directory).value
        #expect(LauncherStyle.load(for: host.id, defaults: store.defaults) == .buttons)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { throw CancellationError() }) == nil)
        #expect(await cache.image(pcID: "other", appID: 1, revision: "a", fetch: { throw CancellationError() }) == data)
        let reopened = LauncherArtCache(base: store.directory)
        #expect(await reopened.image(pcID: "pc", appID: 1, revision: "a", fetch: { throw CancellationError() }) == nil)
        #expect(await reopened.image(pcID: "other", appID: 1, revision: "a", fetch: { data }) == data)
        await cache.remove(pcID: "pc")
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { data }) == data)
    }

    @Test func removingAPCDiscardsAnArtworkFetchStillInFlight() async throws {
        let store = try IsolatedStore("launcher-inflight-removal")
        defer { store.remove() }
        let cache = LauncherArtCache(base: store.directory)
        let data = try Self.png(width: 3, height: 4)
        let started = DispatchSemaphore(value: 0)
        let release = AsyncStream<Void>.makeStream()
        let pending = Task {
            await cache.image(pcID: "pc", appID: 1, revision: "a") {
                started.signal()
                for await _ in release.stream { break }
                return data
            }
        }
        #expect(await started.waitAsync(for: .seconds(2)) == .success)
        await cache.remove(pcID: "pc")
        release.continuation.yield(())
        release.continuation.finish()
        #expect(await pending.value == nil)
        let reopened = LauncherArtCache(base: store.directory)
        #expect(await reopened.image(pcID: "pc", appID: 1, revision: "a", fetch: { Data() }) == nil)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { Data() }) == nil)
    }

    @Test func transientArtworkFailuresRetryWithoutChangingTheRevision() async throws {
        let store = try IsolatedStore("launcher-art-retry")
        defer { store.remove() }
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: store.directory)
        let errors: [any Error & Sendable] = [
            StreamError.hostTimedOut, StreamError.hostUnreachable("asleep"),
            StreamError.launchFailed("HTTP 503 on /appasset"), CancellationError()
        ]
        for (id, error) in errors.enumerated() {
            #expect(await cache.image(pcID: "pc", appID: id, revision: "same", fetch: { throw error }) == nil)
            #expect(await cache.image(pcID: "pc", appID: id, revision: "same", fetch: { data }) == data)
        }
        #expect(await cache.image(pcID: "pc", appID: 10, revision: "same", fetch: { Data([0]) }) == nil)
        #expect(await cache.image(pcID: "pc", appID: 10, revision: "same", fetch: { data }) == data)
        let placeholder = try Self.png(width: 130, height: 180)
        #expect(await cache.image(pcID: "pc", appID: 11, revision: "same", fetch: { placeholder }) == nil)
        #expect(await cache.image(pcID: "pc", appID: 11, revision: "same", fetch: { data }) == nil)
    }

    @Test @MainActor func coverMemoryHitsDoNotConstructClientsAndReachabilityRetries() async throws {
        let store = try IsolatedStore("launcher-art-client")
        defer { store.remove() }
        let model = AppModel(defaults: settings.defaults)
        model.supportBase = store.directory
        let data = try Self.png(width: 3, height: 4)
        let sunshine = FakeSunshine.scripted(["appasset": [
            .failure(.hostTimedOut), .success(.init(status: 200, body: data))
        ]])
        let clients = OSAllocatedUnfairLock(initialState: 0)
        model.makeNetwork = { server in
            clients.withLock { $0 += 1 }
            return sunshine.client(server)
        }
        let app = LibraryApp(id: 1, name: "Game", hdr: false, hidden: false)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: "192.0.2.1", manualAddress: nil,
                        apps: [app], lastConnected: nil, serverCertPEM: "pin", appVersion: nil, macAddress: nil)
        model.hostLiveStatus = .init(hostID: "pc", state: .asleep, capturedAt: .now)
        #expect(!model.launcherArtReachable(for: host.id))
        #expect(await model.launcherArt(for: app, on: host, revision: "a") == nil)
        model.hostLiveStatus?.state = .idle
        #expect(model.launcherArtReachable(for: host.id))
        #expect(!model.launcherArtReachable(for: "other"))
        #expect(await model.launcherArt(for: app, on: host, revision: "a") == data)
        #expect(clients.withLock { $0 } == 2)
        #expect(await model.launcherArt(for: app, on: host, revision: "a") == data)
        #expect(clients.withLock { $0 } == 2)
        model.isStreaming = true
        #expect(await model.launcherArt(for: app, on: host, revision: "b") == nil)
        #expect(clients.withLock { $0 } == 2)
    }

    @Test @MainActor func streamMenuAllowsPCSelectionDuringAStream() throws {
        let store = try IsolatedStore("launcher-stream-menu")
        defer { store.remove() }
        let model = AppModel(defaults: settings.defaults)
        model.hostsDefaults = store.defaults
        model.supportBase = store.directory
        defer { model.hostStatusTask?.cancel() }
        let host = Host(id: "pc", name: "Other PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.hosts = [host]
        model.isStreaming = true
        let menu = NSHostingMenu(rootView: StreamMenu(model: model))
        menu.update()
        let item = try #require(menu.items.first { $0.title == host.displayName })
        #expect(item.isEnabled)
    }

    @Test @MainActor func runningOverflowAppKeepsATileWithoutChangingTheGridSize() {
        let apps = (1...8).map { LibraryApp(id: $0, name: "Game \($0)", hdr: false, hidden: false) }
        let visible = AppIconsRow.inlineApps(apps, runningAppID: 7)
        let overflow = AppIconsRow.overflowApps(apps, runningAppID: 7)
        #expect(visible.map(\.id) == [1, 2, 7])
        #expect(overflow.map(\.id) == [3, 4, 5, 6, 8])
        #expect(visible.count == AppIconsRow.inlineApps(apps).count)
        #expect(Set((visible + overflow).map(\.id)) == Set(apps.map(\.id)))
    }

    @Test @MainActor func runningTileAndResumeMenuReturnToTheSameSession() async throws {
        let model = AppModel(defaults: settings.defaults)
        let app = LibraryApp(id: 1, name: "Desktop", hdr: false, hidden: false)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [app], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        let sunshine = FakeSunshine.scripted([:])
        let session = StreamSession(hostDisposition: .disconnectOnly,
                                    audioDecoder: AudioDecoder(defaults: settings.defaults),
                                    services: SessionServices(), backend: InputRecordingBackend(),
                                    makeNetwork: { sunshine.client($0) }, makeBackend: { InputRecordingBackend() })
        let presentation = SessionPresentation()
        let events = AsyncStream<Void>.makeStream()
        presentation.resume = { events.continuation.yield(()) }
        await session.installCloseFixture(presentation, streaming: true)
        model.nativeSession = session
        model.isStreaming = true
        model.streamPhase = .streaming
        model.nativeStreamBackgrounded = true
        model.lastLaunchAttempt = (app, host)
        var iterator = events.stream.makeAsyncIterator()
        AppIconsRow.activate(app, on: host, model: model, connectingShown: false)
        await iterator.next()
        let menu = NSHostingMenu(rootView: RunningGameMenu(host: host, app: app, requestSize: {}).environment(model))
        menu.update()
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Resume" }))
        await iterator.next()
        #expect(model.nativeSession === session && model.pendingTakeover == nil)
        #expect(model.nativeStreamTask == nil)
        events.continuation.finish()
    }

    @Test @MainActor func runningTileMenuOffersResumeAndQuitWithoutASecondLaunch() throws {
        let model = AppModel(defaults: settings.defaults)
        let app = LibraryApp(id: 1, name: "Desktop", hdr: false, hidden: false)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [app], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.isStreaming = true
        model.streamPhase = .streaming
        model.lastLaunchAttempt = (app, host)
        let menu = NSHostingMenu(rootView: RunningGameMenu(host: host, app: app, requestSize: {}).environment(model))
        menu.update()
        let resume = try #require(menu.items.firstIndex { $0.title == "Resume" })
        #expect(menu.items.contains { $0.title == "Quit Desktop…" && $0.isEnabled })
        menu.performActionForItem(at: resume)
        #expect(model.pendingTakeover == nil && model.lastLaunchAttempt?.app.id == app.id)
        #expect(model.nativeStreamTask == nil)
    }

    @Test @MainActor func runningTileUsesTheAppIDWhenNamesMatch() {
        let model = AppModel(defaults: settings.defaults)
        let app = LibraryApp(id: 7, name: "Desktop", hdr: false, hidden: false)
        let duplicate = LibraryApp(id: 8, name: "Desktop", hdr: false, hidden: false)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [app, duplicate], lastConnected: nil, serverCertPEM: nil,
                        appVersion: nil, macAddress: nil)
        model.hostLiveStatus = .init(hostID: host.id, state: .streamingApp(name: app.name),
                                    capturedAt: .now, runningAppID: app.id)
        #expect(model.launcherAppIsRunning(app, on: host))
        #expect(!model.launcherAppIsRunning(duplicate, on: host))
        #expect(AppIconsRow.tileState(app, on: host, model: model, connectingShown: false).spoken.value == "Running")
    }

    @Test @MainActor func runningCoverFollowsTheLiveSessionOrFreshPCStatus() {
        let model = AppModel(defaults: settings.defaults)
        let app = LibraryApp(id: 7, name: "Game", hdr: false, hidden: false)
        let other = LibraryApp(id: 8, name: "Other", hdr: false, hidden: false)
        let host = Host(id: "pc", name: "PC", customName: nil, localAddress: nil, manualAddress: nil,
                        apps: [app, other], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        #expect(!model.launcherAppIsRunning(app, on: host))
        for state in [HostLiveStatus.State.idle, .asleep, .unknown, .certMismatch] {
            model.hostLiveStatus = .init(hostID: host.id, state: state, capturedAt: .now)
            #expect(!model.launcherAppIsRunning(app, on: host))
        }
        for state in [HostLiveStatus.State.streamingApp(name: app.name), .streamingUnknownApp(id: app.id)] {
            model.hostLiveStatus = .init(hostID: host.id, state: state, capturedAt: .now)
            #expect(model.launcherAppIsRunning(app, on: host))
            #expect(!model.launcherAppIsRunning(other, on: host))
            model.hostLiveStatus?.capturedAt = .distantPast
            #expect(!model.launcherAppIsRunning(app, on: host))
            model.hostLiveStatus = .init(hostID: "other", state: state, capturedAt: .now)
            #expect(!model.launcherAppIsRunning(app, on: host))
        }
        model.isStreaming = true
        model.lastLaunchAttempt = (app, host)
        model.streamPhase = .streaming
        #expect(model.launcherAppIsRunning(app, on: host))
        #expect(!model.launcherAppIsRunning(other, on: host))
        model.streamPhase = .connecting(stage: "Connecting")
        #expect(!model.launcherAppIsRunning(app, on: host))
    }

    @Test func unusableCacheDirectoryStillReturnsArtAndKeepsItInMemory() async throws {
        let store = try IsolatedStore("launcher-art-unwritable")
        defer { store.remove() }
        let file = store.directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        let cache = LauncherArtCache(base: file)
        let data = try Self.png(width: 3, height: 4)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: { data }) == data)
        #expect(await cache.image(pcID: "pc", appID: 1, revision: "a", fetch: {
            Issue.record("A failed disk write must not evict usable memory art")
            return Data()
        }) == data)
        #expect(try Data(contentsOf: file) == Data([1]))
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

struct LauncherNavigationTests {
    @Test func controllerFocusUsesOneTargetAndOneActivationWithEitherKeyboardSetting() {
        #expect(LauncherNavigation.needsControllerFocus(keyboardNavigation: false, controllerNavigating: true))
        #expect(!LauncherNavigation.needsControllerFocus(keyboardNavigation: true, controllerNavigating: true))
        for keyboard in [false, true] {
            for focused in [false, true] {
                for enabled in [false, true] {
                    #expect(LauncherNavigation.handlesSpace(keyboardNavigation: keyboard, controllerNavigating: true,
                                                           focused: focused, enabled: enabled)
                            == (!keyboard && focused && enabled))
                }
            }
        }
    }

    /// Opening the launcher must not focus (and ring) the PC name before a controller moves.
    @Test func nothingTakesControllerFocusUntilAControllerNavigates() {
        #expect(!LauncherNavigation.needsControllerFocus(keyboardNavigation: false, controllerNavigating: false))
        #expect(!LauncherNavigation.handlesSpace(keyboardNavigation: false, controllerNavigating: false,
                                                 focused: true, enabled: true))
    }

    @Test func navigationRequiresTheLauncherAndYieldsToStreamingAndDiagnostics() {
        func enabled(streaming: Bool = false, testing: Bool = false, active: Bool = true,
                     launcher: Bool = true, sheet: Bool = false) -> Bool {
            LauncherNavigation.isEnabled(streaming: streaming, testing: testing, active: active,
                                         launcherKey: launcher, sheetKey: sheet)
        }
        #expect(enabled())
        #expect(!enabled(streaming: true))
        #expect(!enabled(testing: true))
        #expect(!enabled(active: false))
        #expect(!enabled(launcher: false))
        #expect(enabled(launcher: false, sheet: true))
        #expect(!enabled(streaming: true, launcher: false, sheet: true))
    }

    @Test func axisMappingHasADeadZoneAndUsesTheDominantAxis() {
        #expect(LauncherCommand.direction(x: 0.4, y: -0.4) == nil)
        #expect(LauncherCommand.direction(x: 1, y: 0.8) == .right)
        #expect(LauncherCommand.direction(x: -1, y: 0) == .left)
        #expect(LauncherCommand.direction(x: 0, y: 1) == .up)
        #expect(LauncherCommand.direction(x: 0, y: -1) == .down)
    }

    @Test func bothLayoutsReachTheSwitcherAndRespectRowEdges() {
        let cells: [LauncherFocus] = [.app(1), .app(2), .app(3), .overflow]
        func move(_ focus: LauncherFocus?, _ command: LauncherCommand, columns: Int = 2) -> LauncherFocus? {
            LauncherNavigation.destination(from: focus, command: command, cells: cells,
                                           columns: columns, hasSwitcher: true)
        }
        #expect(move(nil, .down) == .app(1))
        #expect(move(.app(1), .up) == .pc)
        #expect(move(.pc, .down) == .app(1))
        #expect(move(.app(1), .right) == .app(2))
        #expect(move(.app(2), .right) == .app(2))
        #expect(move(.app(2), .down) == .overflow)
        #expect(move(.overflow, .left) == .app(3))
        #expect(move(.app(1), .down, columns: 3) == .overflow)
        #expect(move(.overflow, .up, columns: 3) == .app(1))
        #expect(move(.app(3), .down) == .app(3))
        #expect(move(.app(3), .activate) == .app(3))
        #expect(move(.app(3), .dismiss) == .app(3))
    }

    @Test func partialRowsOverflowAndStateAreReachableWithoutWrapping() {
        let cells: [LauncherFocus] = [.app(1), .app(2), .app(3), .overflow, .state]
        func move(_ focus: LauncherFocus?, _ command: LauncherCommand) -> LauncherFocus? {
            LauncherNavigation.destination(from: focus, command: command, cells: cells, columns: 3, hasSwitcher: true)
        }
        #expect(move(.app(2), .down) == .overflow)
        #expect(move(.app(3), .down) == .overflow)
        #expect(move(.overflow, .right) == .overflow)
        #expect(move(.overflow, .down) == .state)
        #expect(move(.state, .up) == .overflow)
        #expect(move(.state, .left) == .state)
        #expect(move(.state, .down) == .state)
        #expect(LauncherNavigation.destination(from: nil, command: .down, cells: [.state],
                                               columns: 2, hasSwitcher: false) == .state)
        #expect(LauncherNavigation.destination(from: .state, command: .up, cells: [.state],
                                               columns: 2, hasSwitcher: true) == .pc)
        #expect(LauncherNavigation.destination(from: .app(8), command: .right, cells: [.overflow, .state],
                                               columns: 2, hasSwitcher: false) == .overflow)
    }

    @Test @MainActor func pollingSleepsAtNeutralAndStopsDuringAHandoff() {
        var enabled = true
        let controller = LauncherController(navigationEnabled: { enabled })
        defer { controller.detach() }
        let id = ObjectIdentifier(controller)
        var commands: [LauncherCommand] = []
        controller.handle = { commands.append($0) }
        controller.poll(inputs: [id: .init()])
        #expect(!controller.isPolling)
        controller.inputChanged(inputs: [id: .init(direction: .right)])
        #expect(controller.isPolling)
        #expect(commands == [.right])
        controller.inputChanged(inputs: [id: .init(dismiss: true)])
        #expect(commands == [.right])
        controller.poll(inputs: [id: .init()])
        #expect(!controller.isPolling)
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(commands == [.right, .activate])
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(commands == [.right, .activate])
        controller.poll(inputs: [id: .init()])
        controller.handle = { _ in enabled = false }
        controller.poll(inputs: [id: .init(activate: true)])
        #expect(!controller.isPolling)
    }

    @Test func repeatDelaysAndButtonsOnlyFireOnPress() {
        var state = LauncherControllerRepeat()
        #expect(state.commands(.init(activate: true), at: 0).isEmpty)
        #expect(state.commands(.init(), at: 0.1).isEmpty)
        #expect(state.commands(.init(direction: .right), at: 1) == [.right])
        #expect(state.commands(.init(direction: .right), at: 1.3).isEmpty)
        #expect(state.commands(.init(direction: .right), at: 1.41) == [.right])
        #expect(state.commands(.init(direction: .right), at: 1.5).isEmpty)
        #expect(state.commands(.init(direction: .right), at: 1.54) == [.right])
        #expect(state.commands(.init(activate: true), at: 2) == [.activate])
        #expect(state.commands(.init(activate: true), at: 3).isEmpty)
        #expect(state.commands(.init(dismiss: true), at: 4) == [.dismiss])
        #expect(state.commands(.init(dismiss: true), at: 5).isEmpty)
    }
}
