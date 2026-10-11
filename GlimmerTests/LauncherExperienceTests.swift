// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glimmer

struct LauncherExperienceTests {
    @Test @MainActor func buttonsAreDefaultAndExplicitChoicePersists() throws {
        let suite = "LauncherExperienceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(launcherDefaults: defaults)
        #expect(model.launcherStyle == .buttons)
        #expect(defaults.string(forKey: LauncherStyle.defaultsKey) == nil)
        model.launcherStyle = .covers
        #expect(AppModel(launcherDefaults: defaults).launcherStyle == .covers)
        model.launcherStyle = .buttons
        #expect(AppModel(launcherDefaults: defaults).launcherStyle == .buttons)
        defaults.set("unknown", forKey: LauncherStyle.defaultsKey)
        #expect(AppModel(launcherDefaults: defaults).launcherStyle == .buttons)
    }

    @Test func onlyCoversFetchArtWhileIdle() {
        #expect(!LauncherStyle.buttons.loadsArt(streaming: false))
        #expect(!LauncherStyle.buttons.loadsArt(streaming: true))
        #expect(LauncherStyle.covers.loadsArt(streaming: false))
        #expect(!LauncherStyle.covers.loadsArt(streaming: true))
    }

    @Test func columnCountFillsRowsAndBoundsLargeLibraries() {
        let expected = [1, 1, 2, 3, 4, 3, 3, 4, 4, 3, 4, 4, 4]
        for (count, columns) in expected.enumerated() {
            #expect(LauncherLayout.columns(appCount: count) == columns)
        }
        for count in 1...200 {
            #expect((1...4).contains(LauncherLayout.columns(appCount: count)))
            #expect(LauncherLayout.coverHeight(appCount: count) <= 240)
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
        await #expect(throws: StreamError.self) {
            try await sunshine.client(FakeSunshine.server(pin: "pin")).appAsset(appID: 1)
        }
        #expect(sunshine.requests.count == 1)
    }

    @Test func cacheKeysSeparatePCsAppsAndListRevisions() {
        let apps = [LibraryApp(id: 1, name: "Game", hdr: false, hidden: false)]
        let key = LauncherArtCache.key(pcID: "../pc", appID: 1, apps: apps)
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit))
        #expect(key == LauncherArtCache.key(pcID: "../pc", appID: 1, apps: apps))
        #expect(key != LauncherArtCache.key(pcID: "another PC", appID: 1, apps: apps))
        #expect(key != LauncherArtCache.key(pcID: "../pc", appID: 2, apps: apps))
        #expect(key != LauncherArtCache.key(pcID: "../pc", appID: 1, apps: []))
    }

    @Test func cacheSurvivesReopeningAndEvictsLeastRecentlyUsedArt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: base, byteLimit: data.count * 2)
        #expect(await cache.image(key: "first", fetch: { data }) != nil)
        #expect(await cache.image(key: "second", fetch: { data }) != nil)
        let directory = base.appendingPathComponent("Glimmer/Covers")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
                                             ofItemAtPath: directory.appendingPathComponent("second.png").path)
        #expect(await cache.image(key: "third", fetch: { data }) != nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.png").path))
        let reopened = LauncherArtCache(base: base, byteLimit: data.count * 2)
        #expect(await reopened.image(key: "first", fetch: { throw CancellationError() }) != nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
    }

    @Test func missingCorruptAndPlaceholderArtFallsBackWithoutCaching() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = LauncherArtCache(base: base)
        #expect(await cache.image(key: "missing", fetch: { throw CancellationError() }) == nil)
        #expect(await cache.image(key: "corrupt", fetch: { Data("<root/>".utf8) }) == nil)
        let placeholder = try Self.png(width: 130, height: 180)
        #expect(await cache.image(key: "placeholder", fetch: { placeholder }) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Glimmer/Covers").path))
    }

    @Test func corruptCacheIsReplacedAndOversizedArtIsRejected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("Glimmer/Covers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("corrupt.png")
        try Data("bad image".utf8).write(to: file)
        let data = try Self.png(width: 3, height: 4)
        let cache = LauncherArtCache(base: base)
        #expect(await cache.image(key: "corrupt", fetch: { data }) != nil)
        #expect(try Data(contentsOf: file) == data)
        #expect(LauncherArtCache.decode(Data(count: 4 * 1024 * 1024 + 1)) == nil)
    }

    @Test func cancelledArtworkDoesNotFetch() async {
        let sunshine = FakeSunshine { _ in ControlTransport.Response(status: 200, body: Data()) }
        let cache = LauncherArtCache()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(key: "cancelled") {
                try await sunshine.client(FakeSunshine.server(pin: "pin")).appAsset(appID: 1)
            }
        }
        #expect(await task.value == nil)
        #expect(sunshine.requests.isEmpty)
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
