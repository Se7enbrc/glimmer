// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import Foundation
import ImageIO

public actor LauncherArtCache {
    private let base: URL?
    private let byteLimit: Int
    private var memory: [String: Data] = [:]
    private var recent: [String] = []
    private var missing: Set<String> = []
    private var generations: [String: Int] = [:]

    public init(base: URL? = nil, byteLimit: Int = 64 * 1024 * 1024) {
        self.base = base
        self.byteLimit = byteLimit
    }

    public static func revision(for apps: [HostApp]) -> String {
        revision(apps: apps.map { LibraryApp(id: $0.id, name: $0.name, hdr: $0.hdrCapable, hidden: $0.hidden) })
    }

    private func cacheDirectory() throws -> URL {
        let root = try base ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
        return root.appendingPathComponent("Glimmer/Covers", isDirectory: true)
    }

    package static func revision(apps: [LibraryApp]) -> String {
        let entries = apps.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.name.utf8.count):\($0.name):\($0.hdr):\($0.hidden)"
        }
        return digest(entries.joined(separator: ":"))
    }

    package static func key(pcID: String, appID: Int, revision: String) -> String {
        digest(pcID) + "-" + digest("\(appID):\(revision)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func image(pcID: String, appID: Int, revision: String,
                      fetch: @Sendable () async throws -> Data) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = Self.key(pcID: pcID, appID: appID, revision: revision)
        if let data = memory[key] { remember(data, key: key); return data }
        guard !missing.contains(key) else { return nil }
        let directory = try? cacheDirectory()
        let file = directory?.appendingPathComponent(key).appendingPathExtension("png")
        if let file, let data = try? Data(contentsOf: file), Self.decode(data) != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            remember(data, key: key)
            return data
        }
        let generation = generations[pcID, default: 0]
        let data: Data
        do {
            data = try await fetch()
        } catch {
            if !Task.isCancelled, generations[pcID, default: 0] == generation,
               case NetworkClient.AssetError.missing = error { missing.insert(key) }
            return nil
        }
        guard !Task.isCancelled, generations[pcID, default: 0] == generation else { return nil }
        guard Self.decode(data) != nil else {
            if Self.isPlaceholder(data) { missing.insert(key) }
            return nil
        }
        remember(data, key: key)
        if let directory, let file, data.count <= byteLimit {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                try evict(in: directory)
            } catch {
                // A full or read-only disk must not keep usable art off the launcher.
            }
        }
        return data
    }

    package func remove(pcID: String) {
        generations[pcID, default: 0] += 1
        let prefix = Self.digest(pcID) + "-"
        memory = memory.filter { !$0.key.hasPrefix(prefix) }
        recent.removeAll { $0.hasPrefix(prefix) }
        missing = missing.filter { !$0.hasPrefix(prefix) }
        guard let directory = try? cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func remember(_ data: Data, key: String) {
        guard data.count <= byteLimit else { return }
        memory[key] = data
        recent.removeAll { $0 == key }
        recent.append(key)
        var size = memory.values.reduce(0) { $0 + $1.count }
        while size > byteLimit, let oldest = recent.first {
            size -= memory.removeValue(forKey: oldest)?.count ?? 0
            recent.removeFirst()
        }
    }

    public static func decode(_ data: Data) -> CGImage? {
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

    private static func isPlaceholder(_ data: Data) -> Bool {
        guard data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        return properties[kCGImagePropertyPixelWidth] as? Int == 130
            && properties[kCGImagePropertyPixelHeight] as? Int == 180
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
