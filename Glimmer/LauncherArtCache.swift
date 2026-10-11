// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import Foundation
import ImageIO

actor LauncherArtCache {
    static let shared = LauncherArtCache()
    private let base: URL?
    private let byteLimit: Int

    init(base: URL? = nil, byteLimit: Int = 64 * 1024 * 1024) {
        self.base = base
        self.byteLimit = byteLimit
    }

    static func key(pcID: String, appID: Int, apps: [LibraryApp]) -> String {
        let revision = apps.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.name.utf8.count):\($0.name):\($0.hdr):\($0.hidden)"
        }
        let identity = "\(pcID.utf8.count):\(pcID):\(appID):" + revision.joined(separator: ":")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func image(key: String, fetch: @Sendable () async throws -> Data) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let directory = try? URL.supportRoot(base: base).appendingPathComponent("Glimmer/Covers", isDirectory: true)
        let file = directory?.appendingPathComponent(key).appendingPathExtension("png")
        if let file, let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return image
        }
        guard let data = try? await fetch(), !Task.isCancelled, let image = Self.decode(data) else { return nil }
        if let directory, let file, data.count <= byteLimit {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                try evict(in: directory)
            } catch {
                // A full or read-only disk must not keep usable art off the launcher.
            }
        }
        return image
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        // Sunshine's box.png is the 130 × 180 placeholder, also recognized by Moonlight's AppView.qml.
        guard width != 130 || height != 180 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private func evict(in directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let entries = try files.filter { $0.pathExtension == "png" }.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url: url, size: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > byteLimit {
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
