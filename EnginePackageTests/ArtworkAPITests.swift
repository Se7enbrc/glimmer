// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreGraphics
import Foundation
import GlimmerEngine
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

struct ArtworkAPITests {
    @Test func publicCacheReusesArtworkAndSeparatesPCs() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = LauncherArtCache(base: base)
        let data = try png()
        let fetches = Mutex(0)
        let fetch: @Sendable () async throws -> Data = { fetches.withLock { $0 += 1 }; return data }
        let apps = [HostApp(id: 1, name: "Game", hdrCapable: false, hidden: false)]
        let revision = LauncherArtCache.revision(for: apps)
        #expect(await cache.image(pcID: "first", appID: 1, revision: revision, fetch: fetch) == data)
        #expect(await cache.image(pcID: "first", appID: 1, revision: revision, fetch: fetch) == data)
        #expect(await cache.image(pcID: "second", appID: 1, revision: revision, fetch: fetch) == data)
        #expect(fetches.withLock { $0 } == 2)
        #expect(LauncherArtCache.decode(data)?.width == 3)
        #expect(LauncherArtCache.revision(for: []) != revision)
    }

    @Test func publicCacheDoesNotFetchCancelledWorkOrDecodeInvalidImages() async {
        let cache = LauncherArtCache()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(pcID: "cancelled", appID: 1, revision: "test") {
                Issue.record("Cancelled artwork fetched from the PC.")
                return Data()
            }
        }
        #expect(await task.value == nil)
        #expect(LauncherArtCache.decode(Data("invalid".utf8)) == nil)
        #expect(LauncherArtCache.decode(Data(count: 4 * 1024 * 1024 + 1)) == nil)
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 3, height: 4, bitsPerComponent: 8,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
